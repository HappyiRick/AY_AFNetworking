// AFNetworkActivityIndicatorManager.m
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFNetworkActivityIndicatorManager.h"

#if TARGET_OS_IOS
#import "AFURLSessionManager.h"

// 网络活动管理器状态
typedef NS_ENUM(NSInteger, AFNetworkActivityManagerState) {
    AFNetworkActivityManagerStateNotActive, // 网络活动指示器处于非活动状态
    AFNetworkActivityManagerStateDelayingStart, // 网络活动指示器处于延时开始状态
    AFNetworkActivityManagerStateActive, // 网络活动指示器处于活动状态
    AFNetworkActivityManagerStateDelayingEnd // 网络活动指示器处于延时结束状态
};

/// 开始延时时间, 1s
static NSTimeInterval const kDefaultAFNetworkActivityManagerActivationDelay = 1.0;
/// 完成延时时间, 0.17s
static NSTimeInterval const kDefaultAFNetworkActivityManagerCompletionDelay = 0.17;

/// 获取通知中的网络请求对象
static NSURLRequest * AFNetworkRequestFromNotification(NSNotification *notification) {
    if ([[notification object] respondsToSelector:@selector(originalRequest)]) {
        return [(NSURLSessionTask *)[notification object] originalRequest];
    } else {
        return nil;
    }
}

/// 定义了网络状态发生变化时的回调block别名
typedef void (^AFNetworkActivityActionBlock)(BOOL networkActivityIndicatorVisible);

@interface AFNetworkActivityIndicatorManager ()
/// 活动请求数量
@property (readwrite, nonatomic, assign) NSInteger activityCount;
/// 开始延时计时器
@property (readwrite, nonatomic, strong) NSTimer *activationDelayTimer;
/// 完成延时计时器
@property (readwrite, nonatomic, strong) NSTimer *completionDelayTimer;
/// 是否正在活动状态
@property (readonly, nonatomic, getter = isNetworkActivityOccurring) BOOL networkActivityOccurring;
/// 网络状态变化回调
@property (nonatomic, copy) AFNetworkActivityActionBlock networkActivityActionBlock;
/// 当前状态
@property (nonatomic, assign) AFNetworkActivityManagerState currentState;
/// 网络活动指示器是否显示
@property (nonatomic, assign, getter=isNetworkActivityIndicatorVisible) BOOL networkActivityIndicatorVisible;
/// 根据当前的状态改变网络活动指示器的状态
- (void)updateCurrentStateForNetworkActivityChange;
@end

@implementation AFNetworkActivityIndicatorManager
// 获取单例管理类
+ (instancetype)sharedManager {
    static AFNetworkActivityIndicatorManager *_sharedManager = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _sharedManager = [[self alloc] init];
    });

    return _sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 记录当前状态是非活动状态
    self.currentState = AFNetworkActivityManagerStateNotActive;
    // 监听了AFURLSessionManager的三个通知, 分别是任务已经开始、任务已经暂停和任务已经结束
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidStart:) name:AFNetworkingTaskDidResumeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidFinish:) name:AFNetworkingTaskDidSuspendNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidFinish:) name:AFNetworkingTaskDidCompleteNotification object:nil];
    // 为开始和结束延时时间赋值
    self.activationDelay = kDefaultAFNetworkActivityManagerActivationDelay;
    self.completionDelay = kDefaultAFNetworkActivityManagerCompletionDelay;

    return self;
}

- (void)dealloc {
    // 移除对通知的观察
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 结束计时器对象
    [_activationDelayTimer invalidate];
    [_completionDelayTimer invalidate];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    /// 如果设置为NO, 就把网络活动指示器的状态设置为非活动状态
    if (enabled == NO) {
        [self setCurrentState:AFNetworkActivityManagerStateNotActive];
    }
}

- (void)setNetworkingActivityActionWithBlock:(void (^)(BOOL networkActivityIndicatorVisible))block {
    // 记录传入的block
    self.networkActivityActionBlock = block;
}

- (BOOL)isNetworkActivityOccurring {
    /// 加锁获取网络请求数量, 大于0就是正在活动状态
    @synchronized(self) {
        return self.activityCount > 0;
    }
}

- (void)setNetworkActivityIndicatorVisible:(BOOL)networkActivityIndicatorVisible {
    // 如果新老数据不一致
    if (_networkActivityIndicatorVisible != networkActivityIndicatorVisible) {
        // 加锁赋值
        @synchronized(self) {
            _networkActivityIndicatorVisible = networkActivityIndicatorVisible;
        }
        if (self.networkActivityActionBlock) {
            // 如果设置了回调block就调用
            self.networkActivityActionBlock(networkActivityIndicatorVisible);
        } else {
            // 如果没有设置回调block就直接设置网络活动指示器的显示状态
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:networkActivityIndicatorVisible];
        }
    }
}


- (void)incrementActivityCount {
    // 加锁赋值
    @synchronized(self) {
        self.activityCount++;
    }
    // 主队列异步调用
    dispatch_async(dispatch_get_main_queue(), ^{
        // 更新当前网络状态
        [self updateCurrentStateForNetworkActivityChange];
    });
}

- (void)decrementActivityCount {
    // 加锁赋值
    @synchronized(self) {
        self.activityCount = MAX(_activityCount - 1, 0);
    }
    // 主队列异步调用更新当前网络状态
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCurrentStateForNetworkActivityChange];
    });
}

- (void)networkRequestDidStart:(NSNotification *)notification {
    // 接收到任务开始的通知如果请求对象中有URL就增加请求活动数量
    if ([AFNetworkRequestFromNotification(notification) URL]) {
        [self incrementActivityCount];
    }
}

- (void)networkRequestDidFinish:(NSNotification *)notification {
    // 接收到任务结束的通知如果请求对象中有URL就减少请求活动数量
    if ([AFNetworkRequestFromNotification(notification) URL]) {
        [self decrementActivityCount];
    }
}

#pragma mark - Internal State Management
- (void)setCurrentState:(AFNetworkActivityManagerState)currentState {
    // 加锁保护
    @synchronized(self) {
        // 如果新老数据不一致
        if (_currentState != currentState) {
            // 赋值
            _currentState = currentState;
            switch (currentState) {
                // 如果设置的是无活动
                case AFNetworkActivityManagerStateNotActive:
                    // 取消开始和完成延时计时器
                    [self cancelActivationDelayTimer];
                    [self cancelCompletionDelayTimer];
                    // 隐藏网络活动指示器
                    [self setNetworkActivityIndicatorVisible:NO];
                    break;
                // 如果设置的是延时开始
                case AFNetworkActivityManagerStateDelayingStart:
                    // 启动开始延时
                    [self startActivationDelayTimer];
                    break;
                // 如果设置的是启动状态
                case AFNetworkActivityManagerStateActive:
                    // 取消完成延时
                    [self cancelCompletionDelayTimer];
                    // 显示网络活动指示器
                    [self setNetworkActivityIndicatorVisible:YES];
                    break;
                // 如果设置的是延时结束
                case AFNetworkActivityManagerStateDelayingEnd:
                    // 启动完成延时
                    [self startCompletionDelayTimer];
                    break;
            }
        }
    }
}

- (void)updateCurrentStateForNetworkActivityChange {
    // 如果设置指示器是可用的
    if (self.enabled) {
        switch (self.currentState) {
            // 如果目前的状态是非活动
            case AFNetworkActivityManagerStateNotActive:
                // 如果当前有网络活动
                if (self.isNetworkActivityOccurring) {
                    // 将指示器状态设置为延时开始
                    [self setCurrentState:AFNetworkActivityManagerStateDelayingStart];
                }
                break;
            // 如果目前的状态是延时开始就没有操作
            case AFNetworkActivityManagerStateDelayingStart:
                //No op. Let the delay timer finish out.
                break;
            // 如果目前的状态是启动状态
            case AFNetworkActivityManagerStateActive:
                // 如果当前没有网络活动
                if (!self.isNetworkActivityOccurring) {
                    // 将状态设置为延时结束
                    [self setCurrentState:AFNetworkActivityManagerStateDelayingEnd];
                }
                break;
            // 如果目前状态是延时结束
            case AFNetworkActivityManagerStateDelayingEnd:
                // 如果当前有网络活动
                if (self.isNetworkActivityOccurring) {
                    // 将状态设置为开始
                    [self setCurrentState:AFNetworkActivityManagerStateActive];
                }
                break;
        }
    }
}

- (void)startActivationDelayTimer {
    // 设置开始延时计时器并加入到运行循环中
    self.activationDelayTimer = [NSTimer
                                 timerWithTimeInterval:self.activationDelay target:self selector:@selector(activationDelayTimerFired) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.activationDelayTimer forMode:NSRunLoopCommonModes];
}

- (void)activationDelayTimerFired {
    // 如果当前有网络活动
    if (self.networkActivityOccurring) {
        // 就设置状态为启动
        [self setCurrentState:AFNetworkActivityManagerStateActive];
    // 如果当前无网络活动
    } else {
        // 就设置状态为未启动
        [self setCurrentState:AFNetworkActivityManagerStateNotActive];
    }
}

- (void)startCompletionDelayTimer {
    // 先使之前的计时器无效
    [self.completionDelayTimer invalidate];
    // 设置结束延时计时器并加入到运行循环中
    self.completionDelayTimer = [NSTimer timerWithTimeInterval:self.completionDelay target:self selector:@selector(completionDelayTimerFired) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.completionDelayTimer forMode:NSRunLoopCommonModes];
}

- (void)completionDelayTimerFired {
    // 设置状态为未启动
    [self setCurrentState:AFNetworkActivityManagerStateNotActive];
}

- (void)cancelActivationDelayTimer {
    // 使开始延时计时器无效
    [self.activationDelayTimer invalidate];
}

- (void)cancelCompletionDelayTimer {
    // 使完成延时计时器失效
    [self.completionDelayTimer invalidate];
}

@end

#endif

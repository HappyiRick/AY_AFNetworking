// UIActivityIndicatorView+AFNetworking.m
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

#import "UIActivityIndicatorView+AFNetworking.h"
#import <objc/runtime.h>

#if TARGET_OS_IOS || TARGET_OS_TV

#import "AFURLSessionManager.h"

@interface AFActivityIndicatorViewNotificationObserver : NSObject
/// 保存activityIndicatorView
@property (readonly, nonatomic, weak) UIActivityIndicatorView *activityIndicatorView;
/// 初始化方法
- (instancetype)initWithActivityIndicatorView:(UIActivityIndicatorView *)activityIndicatorView;
/// 为指定task绑定加载菊花控件
- (void)setAnimatingWithStateOfTask:(NSURLSessionTask *)task;

@end

@implementation UIActivityIndicatorView (AFNetworking)

// af_notificationObserver getter方法
- (AFActivityIndicatorViewNotificationObserver *)af_notificationObserver {
    AFActivityIndicatorViewNotificationObserver *notificationObserver = objc_getAssociatedObject(self, @selector(af_notificationObserver));
    if (notificationObserver == nil) {
        notificationObserver = [[AFActivityIndicatorViewNotificationObserver alloc] initWithActivityIndicatorView:self];
        objc_setAssociatedObject(self, @selector(af_notificationObserver), notificationObserver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return notificationObserver;
}

// 生成AFActivityIndicatorViewNotificationObserver对象，并通过关联对象保存在扩展的属性af_notificationObserver中，然后调用这个对象的绑定task的方法
- (void)setAnimatingWithStateOfTask:(NSURLSessionTask *)task {
    [[self af_notificationObserver] setAnimatingWithStateOfTask:task];
}

@end

@implementation AFActivityIndicatorViewNotificationObserver

/// 初始化
- (instancetype)initWithActivityIndicatorView:(UIActivityIndicatorView *)activityIndicatorView
{
    self = [super init];
    if (self) {
        _activityIndicatorView = activityIndicatorView;
    }
    return self;
}

/// 为指定task绑定加载菊花控件
- (void)setAnimatingWithStateOfTask:(NSURLSessionTask *)task {
    // 创建通知中心对象
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    // 先移除之前添加的通知
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidResumeNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidSuspendNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidCompleteNotification object:nil];
    // 如果传入的task不为nil
    if (task) {
        // 如果task的状态不是已经执行完成
        if (task.state != NSURLSessionTaskStateCompleted) {
            // 如果task的状态是运行中就显示加载菊花控件, 否则就隐藏
            UIActivityIndicatorView *activityIndicatorView = self.activityIndicatorView;
            if (task.state == NSURLSessionTaskStateRunning) {
                [activityIndicatorView startAnimating];
            } else {
                [activityIndicatorView stopAnimating];
            }
            // 注册通知监听task的开始、完成和暂停
            [notificationCenter addObserver:self selector:@selector(af_startAnimating) name:AFNetworkingTaskDidResumeNotification object:task];
            [notificationCenter addObserver:self selector:@selector(af_stopAnimating) name:AFNetworkingTaskDidCompleteNotification object:task];
            [notificationCenter addObserver:self selector:@selector(af_stopAnimating) name:AFNetworkingTaskDidSuspendNotification object:task];
        }
    }
}

#pragma mark -

- (void)af_startAnimating {
    // 如果接收到了task启动的通知, 就在主队列异步回调中显示加载菊花控件
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.activityIndicatorView startAnimating];
    });
}

- (void)af_stopAnimating {
    // 如果接收到了task完成或暂停的通知, 就在主队列异步回调中隐藏加载菊花控件
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.activityIndicatorView stopAnimating];
    });
}

#pragma mark -

// 销毁时移除通知
- (void)dealloc {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidCompleteNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidResumeNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidSuspendNotification object:nil];
}

@end

#endif

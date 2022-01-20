// AFNetworkReachabilityManager.m
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

#import "AFNetworkReachabilityManager.h"
#if !TARGET_OS_WATCH

#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>

NSString * const AFNetworkingReachabilityDidChangeNotification = @"com.alamofire.networking.reachability.change";
NSString * const AFNetworkingReachabilityNotificationStatusItem = @"AFNetworkingReachabilityNotificationStatusItem";

// 为参数为AFNetworkReachabilityStatus类型无返回值的block起名为AFNetworkReachabilityStatusBlock
typedef void (^AFNetworkReachabilityStatusBlock)(AFNetworkReachabilityStatus status);
typedef AFNetworkReachabilityManager * (^AFNetworkReachabilityStatusCallback)(AFNetworkReachabilityStatus status);

NSString * AFStringFromNetworkReachabilityStatus(AFNetworkReachabilityStatus status) {
    // 根据不同的枚举值返回相对应的文字, 并进行本地化处理
    switch (status) {
        case AFNetworkReachabilityStatusNotReachable:
            return NSLocalizedStringFromTable(@"Not Reachable", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusReachableViaWWAN:
            return NSLocalizedStringFromTable(@"Reachable via WWAN", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusReachableViaWiFi:
            return NSLocalizedStringFromTable(@"Reachable via WiFi", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusUnknown:
        default:
            return NSLocalizedStringFromTable(@"Unknown", @"AFNetworking", nil);
    }
}

// 将SCNetworkReachabilityFlags 类型的枚举切换成AFNetworking自定义的网络状态枚举
static AFNetworkReachabilityStatus AFNetworkReachabilityStatusForFlags(SCNetworkReachabilityFlags flags) {
    // 判断是否连接
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    // 判断是否需要连接
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    // 判断能否自动连接
    BOOL canConnectionAutomatically = (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) || ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0));
    // 判断在用户不设置的情况下, 能够连接
    BOOL canConnectWithoutUserInteraction = (canConnectionAutomatically && (flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0);
    // 判断能否联网
    BOOL isNetworkReachable = (isReachable && (!needsConnection || canConnectWithoutUserInteraction));
    // 根据不同情况转换成对应的网络状态枚举值
    AFNetworkReachabilityStatus status = AFNetworkReachabilityStatusUnknown;
    if (isNetworkReachable == NO) {
        status = AFNetworkReachabilityStatusNotReachable;
    }
#if	TARGET_OS_IPHONE
    else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        status = AFNetworkReachabilityStatusReachableViaWWAN;
    }
#endif
    else {
        status = AFNetworkReachabilityStatusReachableViaWiFi;
    }

    return status;
}

/**
 * Queue a status change notification for the main thread.
 *
 * This is done to ensure that the notifications are received in the same order
 * as they are sent. If notifications are sent directly, it is possible that
 * a queued notification (for an earlier status condition) is processed after
 * the later update, resulting in the listener being left in the wrong state.
 */
/// 为了保证网络状态变化时block回调和发送通知的统一性, 将两者在主线程统一调用
static void AFPostReachabilityStatusChange(SCNetworkReachabilityFlags flags, AFNetworkReachabilityStatusCallback block) {
    // 将flags转成自定义网络状态枚举值
    AFNetworkReachabilityStatus status = AFNetworkReachabilityStatusForFlags(flags);
    // 主队列异步
    dispatch_async(dispatch_get_main_queue(), ^{
        AFNetworkReachabilityManager *manager = nil;
        // 回调block
        if (block) {
            manager = block(status);
        }
        // 发送通知
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        NSDictionary *userInfo = @{ AFNetworkingReachabilityNotificationStatusItem: @(status) };
        [notificationCenter postNotificationName:AFNetworkingReachabilityDidChangeNotification object:manager userInfo:userInfo];
    });
}

/// 将上述方法封装, 作为参数传入网络状态监控回调方法SCNetworkReachabilitySetCallback中
static void AFNetworkReachabilityCallback(SCNetworkReachabilityRef __unused target, SCNetworkReachabilityFlags flags, void *info) {
    AFPostReachabilityStatusChange(flags, (__bridge AFNetworkReachabilityStatusCallback)info);
}

/// 将block复制到堆中, 并封装成方法作为参数构建SCNetworkReachabilityContext结构体
static const void * AFNetworkReachabilityRetainCallback(const void *info) {
    return Block_copy(info);
}

/// 释放复制到堆中的block, 并封装成方法作为参数构建SCNetworkReachabilityContext结构体
static void AFNetworkReachabilityReleaseCallback(const void *info) {
    if (info) {
        Block_release(info);
    }
}

@interface AFNetworkReachabilityManager ()
/// 保存传入的SCNetworkReachabilityRef对象
@property (readonly, nonatomic, assign) SCNetworkReachabilityRef networkReachability;
/// 保存当前网络状态的枚举值
@property (readwrite, nonatomic, assign) AFNetworkReachabilityStatus networkReachabilityStatus;
/// 保存传入的用于回调的block
@property (readwrite, nonatomic, copy) AFNetworkReachabilityStatusBlock networkReachabilityStatusBlock;
@end

@implementation AFNetworkReachabilityManager

+ (instancetype)sharedManager {
    // 调用以默认socket地址实例化对象的方法, 生成单例对象
    static AFNetworkReachabilityManager *_sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedManager = [self manager];
    });

    return _sharedManager;
}

+ (instancetype)managerForDomain:(NSString *)domain {
    // 利用传入的域生成SCNetworkReachabilityRef对象
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [domain UTF8String]);
    // 利用SCNetworkReachabilityRef对象实例化AFNetworkReachabilityManager 对象
    AFNetworkReachabilityManager *manager = [[self alloc] initWithReachability:reachability];
    // 释放SCNetworkReachability对象
    CFRelease(reachability);

    return manager;
}

+ (instancetype)managerForAddress:(const void *)address {
    // 利用传入的地址实例化AFNetworkReachabilityManager对象
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)address);
    // 利用SCNetworkReachabilityRef 对象实例化 AFNetworkReachabilityManager 对象
    AFNetworkReachabilityManager *manager = [[self alloc] initWithReachability:reachability];
    // 释放 SCNetworkReachabilityRef 对象
    CFRelease(reachability);
    
    return manager;
}

+ (instancetype)manager
{
    // 根据版本号适配IPv6 和 IPv4, 获得默认地址
#if (defined(__IPHONE_OS_VERSION_MIN_REQUIRED) && __IPHONE_OS_VERSION_MIN_REQUIRED >= 90000) || (defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 101100)
    struct sockaddr_in6 address;
    bzero(&address, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
#else
    struct sockaddr_in address;
    bzero(&address, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
#endif
    // 以地址为参数进行实例化
    return [self managerForAddress:&address];
}

- (instancetype)initWithReachability:(SCNetworkReachabilityRef)reachability {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 保存或初始化属性
    _networkReachability = CFRetain(reachability);
    self.networkReachabilityStatus = AFNetworkReachabilityStatusUnknown;

    return self;
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:NSGenericException
                                   reason:@"`-init` unavailable. Use `-initWithReachability:` instead"
                                 userInfo:nil];
    return nil;
}

- (void)dealloc {
    // 停止监控
    [self stopMonitoring];
    // 释放SCNetworkReachabilityRef对象
    if (_networkReachability != NULL) {
        CFRelease(_networkReachability);
    }
}

#pragma mark -

- (BOOL)isReachable {
    return [self isReachableViaWWAN] || [self isReachableViaWiFi];
}

- (BOOL)isReachableViaWWAN {
    return self.networkReachabilityStatus == AFNetworkReachabilityStatusReachableViaWWAN;
}

- (BOOL)isReachableViaWiFi {
    return self.networkReachabilityStatus == AFNetworkReachabilityStatusReachableViaWiFi;
}

#pragma mark -

- (void)startMonitoring {
    // 先停止之前的网络监控
    [self stopMonitoring];
    // 如果没有传入或者生成SCNetworkReachabilityRef对象就直接返回
    if (!self.networkReachability) {
        return;
    }
    // 构造网络监控所需的参数
    __weak __typeof(self)weakSelf = self;
    AFNetworkReachabilityStatusCallback callback = ^(AFNetworkReachabilityStatus status) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        // 回调网络状态
        strongSelf.networkReachabilityStatus = status;
        if (strongSelf.networkReachabilityStatusBlock) {
            strongSelf.networkReachabilityStatusBlock(status);
        }
        
        return strongSelf;
    };
    // 生成网络监控上下文
    SCNetworkReachabilityContext context = {0, (__bridge void *)callback, AFNetworkReachabilityRetainCallback, AFNetworkReachabilityReleaseCallback, NULL};
    // 设置网络监控回调
    SCNetworkReachabilitySetCallback(self.networkReachability, AFNetworkReachabilityCallback, &context);
    // 放到运行循环中
    SCNetworkReachabilityScheduleWithRunLoop(self.networkReachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    // 在全局并发队列中异步监听SCNetworkReachabilityRef对象的网络状态, 如果发生变化则进行回调和发送通知
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),^{
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(self.networkReachability, &flags)) {
            AFPostReachabilityStatusChange(flags, callback);
        }
    });
}

- (void)stopMonitoring {
    // 如果没有传入或者生成SCNetworkReachabilityRef对象就直接返回
    if (!self.networkReachability) {
        return;
    }
    // 将SCNetworkReachabilityRef对象从运行循环中移除
    SCNetworkReachabilityUnscheduleFromRunLoop(self.networkReachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

#pragma mark -

- (NSString *)localizedNetworkReachabilityStatusString {
    return AFStringFromNetworkReachabilityStatus(self.networkReachabilityStatus);
}

#pragma mark -

- (void)setReachabilityStatusChangeBlock:(void (^)(AFNetworkReachabilityStatus status))block {
    self.networkReachabilityStatusBlock = block;
}

#pragma mark - NSKeyValueObserving

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
    if ([key isEqualToString:@"reachable"] || [key isEqualToString:@"reachableViaWWAN"] || [key isEqualToString:@"reachableViaWiFi"]) {
        return [NSSet setWithObject:@"networkReachabilityStatus"];
    }

    return [super keyPathsForValuesAffectingValueForKey:key];
}

@end
#endif

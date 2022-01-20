// AFURLSessionManager.m
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

#import "AFURLSessionManager.h"
#import <objc/runtime.h>

// 获取会话管理队列, 用于处理返回的数据
static dispatch_queue_t url_session_manager_processing_queue() {
    static dispatch_queue_t af_url_session_manager_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_processing_queue = dispatch_queue_create("com.alamofire.networking.session.manager.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_url_session_manager_processing_queue;
}

// 获取会话管理完成分派组, 用于处理回调
static dispatch_group_t url_session_manager_completion_group() {
    static dispatch_group_t af_url_session_manager_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_completion_group = dispatch_group_create();
    });

    return af_url_session_manager_completion_group;
}

NSString * const AFNetworkingTaskDidResumeNotification = @"com.alamofire.networking.task.resume";
NSString * const AFNetworkingTaskDidCompleteNotification = @"com.alamofire.networking.task.complete";
NSString * const AFNetworkingTaskDidSuspendNotification = @"com.alamofire.networking.task.suspend";
NSString * const AFURLSessionDidInvalidateNotification = @"com.alamofire.networking.session.invalidate";
NSString * const AFURLSessionDownloadTaskDidMoveFileSuccessfullyNotification = @"com.alamofire.networking.session.download.file-manager-succeed";
NSString * const AFURLSessionDownloadTaskDidFailToMoveFileNotification = @"com.alamofire.networking.session.download.file-manager-error";

NSString * const AFNetworkingTaskDidCompleteSerializedResponseKey = @"com.alamofire.networking.task.complete.serializedresponse";
NSString * const AFNetworkingTaskDidCompleteResponseSerializerKey = @"com.alamofire.networking.task.complete.responseserializer";
NSString * const AFNetworkingTaskDidCompleteResponseDataKey = @"com.alamofire.networking.complete.finish.responsedata";
NSString * const AFNetworkingTaskDidCompleteErrorKey = @"com.alamofire.networking.task.complete.error";
NSString * const AFNetworkingTaskDidCompleteAssetPathKey = @"com.alamofire.networking.task.complete.assetpath";
NSString * const AFNetworkingTaskDidCompleteSessionTaskMetrics = @"com.alamofire.networking.complete.sessiontaskmetrics";
// 管理回话锁名称
static NSString * const AFURLSessionManagerLockName = @"com.alamofire.networking.session.manager.lock";

// block别名
typedef void (^AFURLSessionDidBecomeInvalidBlock)(NSURLSession *session, NSError *error);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);

typedef NSURLRequest * (^AFURLSessionTaskWillPerformHTTPRedirectionBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionTaskDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);
typedef id (^AFURLSessionTaskAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, void (^completionHandler)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential));
typedef void (^AFURLSessionDidFinishEventsForBackgroundURLSessionBlock)(NSURLSession *session);

typedef NSInputStream * (^AFURLSessionTaskNeedNewBodyStreamBlock)(NSURLSession *session, NSURLSessionTask *task);
typedef void (^AFURLSessionTaskDidSendBodyDataBlock)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend);
typedef void (^AFURLSessionTaskDidCompleteBlock)(NSURLSession *session, NSURLSessionTask *task, NSError *error);
#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
typedef void (^AFURLSessionTaskDidFinishCollectingMetricsBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLSessionTaskMetrics * metrics) AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10));
#endif

typedef NSURLSessionResponseDisposition (^AFURLSessionDataTaskDidReceiveResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response);
typedef void (^AFURLSessionDataTaskDidBecomeDownloadTaskBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask);
typedef void (^AFURLSessionDataTaskDidReceiveDataBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data);
typedef NSCachedURLResponse * (^AFURLSessionDataTaskWillCacheResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse);

typedef NSURL * (^AFURLSessionDownloadTaskDidFinishDownloadingBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location);
typedef void (^AFURLSessionDownloadTaskDidWriteDataBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
typedef void (^AFURLSessionDownloadTaskDidResumeBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes);
// 进度回调block别名
typedef void (^AFURLSessionTaskProgressBlock)(NSProgress *);
// 任务完成回调block别名
typedef void (^AFURLSessionTaskCompletionHandler)(NSURLResponse *response, id responseObject, NSError *error);

#pragma mark -

@interface AFURLSessionManagerTaskDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
// 以指定NSURLSessionTask对象初始化方法
- (instancetype)initWithTask:(NSURLSessionTask *)task;
// 网络会话管理者, 为防止循环引用使用weak属性
@property (nonatomic, weak) AFURLSessionManager *manager;
// 保存接收到的数据
@property (nonatomic, strong) NSMutableData *mutableData;
// 上传进度
@property (nonatomic, strong) NSProgress *uploadProgress;
// 下载进度
@property (nonatomic, strong) NSProgress *downloadProgress;
// 下载保存路径
@property (nonatomic, copy) NSURL *downloadFileURL;
#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
@property (nonatomic, strong) NSURLSessionTaskMetrics *sessionTaskMetrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10));
#endif
// 保存下载完成回调block
@property (nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
// 保存上传进度回调block
@property (nonatomic, copy) AFURLSessionTaskProgressBlock uploadProgressBlock;
// 保存下载进度回调block
@property (nonatomic, copy) AFURLSessionTaskProgressBlock downloadProgressBlock;
// 保存任务完成回调block
@property (nonatomic, copy) AFURLSessionTaskCompletionHandler completionHandler;
@end

@implementation AFURLSessionManagerTaskDelegate

- (instancetype)initWithTask:(NSURLSessionTask *)task {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 初始化属性
    _mutableData = [NSMutableData data];
    _uploadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    _downloadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    // 将传入的task的取消、暂停和重启与进度对象相应的操作进行绑定
    __weak __typeof__(task) weakTask = task;
    for (NSProgress *progress in @[ _uploadProgress, _downloadProgress ])
    {
        progress.totalUnitCount = NSURLSessionTransferSizeUnknown;
        progress.cancellable = YES;
        progress.cancellationHandler = ^{
            [weakTask cancel];
        };
        progress.pausable = YES;
        progress.pausingHandler = ^{
            [weakTask suspend];
        };
#if AF_CAN_USE_AT_AVAILABLE
        if (@available(macOS 10.11, *))
#else
        if ([progress respondsToSelector:@selector(setResumingHandler:)])
#endif
        {
            progress.resumingHandler = ^{
                [weakTask resume];
            };
        }
        // 观察进度对象的进度
        [progress addObserver:self
                   forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
    }
    return self;
}

- (void)dealloc {
    // 移除进度对象的观察
    [self.downloadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
    [self.uploadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
}

#pragma mark - NSProgress Tracking
// kVO
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    // 当进度对象的进度发生改变时, 回调对应的block
   if ([object isEqual:self.downloadProgress]) {
        if (self.downloadProgressBlock) {
            self.downloadProgressBlock(object);
        }
    }
    else if ([object isEqual:self.uploadProgress]) {
        if (self.uploadProgressBlock) {
            self.uploadProgressBlock(object);
        }
    }
}

// 认证错误key
static const void * const AuthenticationChallengeErrorKey = &AuthenticationChallengeErrorKey;

#pragma mark - NSURLSessionTaskDelegate
// 当NSURLSessionTaskDelegate 的这个方法被调用时, 意味着这个‘task’已经执行完成, 无论是否出错
- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    // 获取认证错误
    error = objc_getAssociatedObject(task, AuthenticationChallengeErrorKey) ?: error;
    // 因为self.manager属性关键字是weak, 所以为了防止被释放就采用 __strong
    __strong AFURLSessionManager *manager = self.manager;
    // 用来保存请求返回的数据, 为了可以在block中修改, 用了 __block
    __block id responseObject = nil;
    // 用来保存发送通知时传递的数据
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[AFNetworkingTaskDidCompleteResponseSerializerKey] = manager.responseSerializer;
    // 使用临时变量保存请求到的数据, 并把保存数据的属性清空,节约内存
    //Performance Improvement from #2672
    NSData *data = nil;
    if (self.mutableData) {
        data = [self.mutableData copy];
        //We no longer need the reference, so nil it out to gain back some memory.
        self.mutableData = nil;
    }
    
#if AF_CAN_USE_AT_AVAILABLE && AF_CAN_INCLUDE_SESSION_TASK_METRICS
    if (@available(iOS 10, macOS 10.12, watchOS 3, tvOS 10, *)) {
        if (self.sessionTaskMetrics) {
            userInfo[AFNetworkingTaskDidCompleteSessionTaskMetrics] = self.sessionTaskMetrics;
        }
    }
#endif
    // 如果设置了下载文件的保存路径, 就传递保存路径, 否则如果有请求到的数据, 就传递请求到的数据
    if (self.downloadFileURL) {
        userInfo[AFNetworkingTaskDidCompleteAssetPathKey] = self.downloadFileURL;
    } else if (data) {
        userInfo[AFNetworkingTaskDidCompleteResponseDataKey] = data;
    }
    // 如果请求出错
    if (error) {
        // 传递错误信息
        userInfo[AFNetworkingTaskDidCompleteErrorKey] = error;
        // 用户可以自定调度组和队列实现对回调完成的监控
        dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
            // 回调并发送通知
            if (self.completionHandler) {
                self.completionHandler(task.response, responseObject, error);
            }
            // 主线程操作
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
            });
        });
    // 如果请求成功
    } else {
        dispatch_async(url_session_manager_processing_queue(), ^{
            // 解析服务器返回的数据
            NSError *serializationError = nil;
            responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:data error:&serializationError];
            // 如果有保存下载文件的路径则返回路径
            if (self.downloadFileURL) {
                responseObject = self.downloadFileURL;
            }
            // 传递响应化序列对象
            if (responseObject) {
                userInfo[AFNetworkingTaskDidCompleteSerializedResponseKey] = responseObject;
            }
            // 如果解析出错则传递错误对象
            if (serializationError) {
                userInfo[AFNetworkingTaskDidCompleteErrorKey] = serializationError;
            }
            // 回调与发送通知
            dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                if (self.completionHandler) {
                    self.completionHandler(task.response, responseObject, serializationError);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
                });
            });
        });
    }
}

#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10)) {
    self.sessionTaskMetrics = metrics;
}
#endif

#pragma mark - NSURLSessionDataDelegate
// 当此方法被调用时,意味着已经接收到服务器返回的数据了
- (void)URLSession:(__unused NSURLSession *)session
          dataTask:(__unused NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    // 更新下载进度对象的属性
    self.downloadProgress.totalUnitCount = dataTask.countOfBytesExpectedToReceive;
    self.downloadProgress.completedUnitCount = dataTask.countOfBytesReceived;
    // 保存传递的数据
    [self.mutableData appendData:data];
}

// 当此方法被调用时, 意味着已经向服务器上传了数据
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend{
    // 更新上传进度对象的属性
    self.uploadProgress.totalUnitCount = task.countOfBytesExpectedToSend;
    self.uploadProgress.completedUnitCount = task.countOfBytesSent;
}

#pragma mark - NSURLSessionDownloadDelegate
// 当执行下载方法时,此方法会被定期调用, 传递当前下载进度
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite{
    // 更新下载进度对象的属性
    self.downloadProgress.totalUnitCount = totalBytesExpectedToWrite;
    self.downloadProgress.completedUnitCount = totalBytesWritten;
}

// 当该方法被调用时, 表示下载已重启
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes{
    // 更新下载进度对象的属性
    self.downloadProgress.totalUnitCount = expectedTotalBytes;
    self.downloadProgress.completedUnitCount = fileOffset;
}

// 当该方法调用时, 表示下载已完成
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    // 如果用户设置了保存下载文件路径, 就将下载完的文件从临时路径移动过去, 移动完成后发送通知
    self.downloadFileURL = nil;

    if (self.downloadTaskDidFinishDownloading) {
        self.downloadFileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (self.downloadFileURL) {
            NSError *fileManagerError = nil;

            if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:self.downloadFileURL error:&fileManagerError]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:fileManagerError.userInfo];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidMoveFileSuccessfullyNotification object:downloadTask userInfo:nil];
            }
        }
    }
}

@end

#pragma mark -

/**
 *  A workaround for issues related to key-value observing the `state` of an `NSURLSessionTask`.
 *
 *  See:
 *  - https://github.com/AFNetworking/AFNetworking/issues/1477
 *  - https://github.com/AFNetworking/AFNetworking/issues/2638
 *  - https://github.com/AFNetworking/AFNetworking/pull/2702
 */

// 交换某个类两个方法的实现
static inline void af_swizzleSelector(Class theClass, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(theClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(theClass, swizzledSelector);
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

// 给一个类添加一个方法
static inline BOOL af_addMethod(Class theClass, SEL selector, Method method) {
    return class_addMethod(theClass, selector,  method_getImplementation(method),  method_getTypeEncoding(method));
}

// 当一个task重新开始时就会发送这个通知
static NSString * const AFNSURLSessionTaskDidResumeNotification  = @"com.alamofire.networking.nsurlsessiontask.resume";
// 当一个task暂停时就会发送这个通知
static NSString * const AFNSURLSessionTaskDidSuspendNotification = @"com.alamofire.networking.nsurlsessiontask.suspend";

@interface _AFURLSessionTaskSwizzling : NSObject

@end

@implementation _AFURLSessionTaskSwizzling

+ (void)load {
    /**
     WARNING: Trouble Ahead
     https://github.com/AFNetworking/AFNetworking/pull/2702
     */
    // 判断是否有NSURLSessionTask这个类
    if (NSClassFromString(@"NSURLSessionTask")) {
        /**
         iOS 7 and iOS 8 differ in NSURLSessionTask implementation, which makes the next bit of code a bit tricky.
         Many Unit Tests have been built to validate as much of this behavior has possible.
         Here is what we know:
            - NSURLSessionTasks are implemented with class clusters, meaning the class you request from the API isn't actually the type of class you will get back.
            - Simply referencing `[NSURLSessionTask class]` will not work. You need to ask an `NSURLSession` to actually create an object, and grab the class from there.
            - On iOS 7, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `__NSCFURLSessionTask`.
            - On iOS 8, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `NSURLSessionTask`.
            - On iOS 7, `__NSCFLocalSessionTask` and `__NSCFURLSessionTask` are the only two classes that have their own implementations of `resume` and `suspend`, and `__NSCFLocalSessionTask` DOES NOT CALL SUPER. This means both classes need to be swizzled.
            - On iOS 8, `NSURLSessionTask` is the only class that implements `resume` and `suspend`. This means this is the only class that needs to be swizzled.
            - Because `NSURLSessionTask` is not involved in the class hierarchy for every version of iOS, its easier to add the swizzled methods to a dummy class and manage them there.
        
         Some Assumptions:
            - No implementations of `resume` or `suspend` call super. If this were to change in a future version of iOS, we'd need to handle it.
            - No background task classes override `resume` or `suspend`
         
         The current solution:
            1) Grab an instance of `__NSCFLocalDataTask` by asking an instance of `NSURLSession` for a data task.
            2) Grab a pointer to the original implementation of `af_resume`
            3) Check to see if the current class has an implementation of resume. If so, continue to step 4.
            4) Grab the super class of the current class.
            5) Grab a pointer for the current class to the current implementation of `resume`.
            6) Grab a pointer for the super class to the current implementation of `resume`.
            7) If the current class implementation of `resume` is not equal to the super class implementation of `resume` AND the current implementation of `resume` is not equal to the original implementation of `af_resume`, THEN swizzle the methods
            8) Set the current class to the super class, and repeat steps 3-8
         
        NSURLSessionTask的实现在iOS 7和iOS 8中有所不同，这使得下面代码实现起来有些棘手。
            已经做了许多单元测试来验证这个方法的可行性。
            目前我们所知道的是：
             - NSURLSessionTasks是通过类簇设计模式实现的，这就意味着你通过这个类提供的接口获得的类并不是这个类。
             - 简单的通过 ‘[NSURLSessionTask class]’ 方法并不起作用，你需要通过NSURLSession创建一个task，才能获取它所在的类。
             - 在iOS 7中，‘localDataTask’是的类型是‘__NSCFLocalDataTask’，它的继承关系是：__NSCFLocalDataTask -> __NSCFLocalSessionTask -> __NSCFURLSessionTask。
             - 在iOS 8中，‘localDataTask’是的类型是‘__NSCFLocalDataTask’，它的继承关系是：__NSCFLocalDataTask -> __NSCFLocalSessionTask -> NSURLSessionTask。
             - 在iOS 7中，只有‘__NSCFLocalSessionTask’和其父类‘__NSCFURLSessionTask’这两个类实现了它们的‘resume’和‘suspend’方法，并且在方法实现里‘__NSCFLocalSessionTask’类并没有调用其父类的方法，这就意味着两个类都要进行方法交换。
             - 在iOS 8中，只有‘NSURLSessionTask’类实现了‘resume’和‘suspend’方法，这就意味着只对该类进行方法交换即可。
             - 因为‘NSURLSessionTask’类并不是在每个iOS的版本中都存在，所有在这个虚构类里可以更容易添加和管理交换方法

            一些假设前提：
             - ‘resume’和‘suspend’方法在实现时，并没有调用其父类的实现方法。但如果在以后的iOS版本中调用了其父类的实现方法，我们还要再进行处理。
             - ‘resume’和‘suspend’方法不会被其他类复写

            目前的解决方案：
             1) 先通过‘NSURLSession’实例化一个dataTask对象，再通过dataTask对象获取‘__NSCFLocalDataTask’对象。
             2) 获取指向‘af_resume’方法原始实现的指针。
             3) 检查当前类是否实现了resume方法，如果实现了就继续执行第4步
             4) 获取当前类的父类
             5) 获取当前类指向‘resume’方法实现的指针。
             6) 获取当前类的父类指向‘resume’方法实现的指针。
             7) 如果当前类和其父类指向‘resume’方法实现的指针不一致，并且当前类指向‘resume’方法实现的指针和指向‘af_resume’方法原始实现的指针也不一致，就进行方法交换
             8) 然后再通过步骤3-8检查其父类
         */
        
        // 实例化网络会话配置对象
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        // 实例化网络会话对象
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull"
        // 实例化网络会话任务对象
        NSURLSessionDataTask *localDataTask = [session dataTaskWithURL:nil];
#pragma clang diagnostic pop
        // 获取指向当前类的af_resume方法原始实现的指针
        IMP originalAFResumeIMP = method_getImplementation(class_getInstanceMethod([self class], @selector(af_resume)));
        // 获取网络会话任务对象的具体类
        Class currentClass = [localDataTask class];
        // 如果这个类实现了resume方法则进入循环体
        while (class_getInstanceMethod(currentClass, @selector(resume))) {
            // 获取这个具体类的父类
            Class superClass = [currentClass superclass];
            // 获取指向这个具体类的resume方法实现的指针
            IMP classResumeIMP = method_getImplementation(class_getInstanceMethod(currentClass, @selector(resume)));
            // 获取指向的这个具体类的父类的resume方法
            IMP superclassResumeIMP = method_getImplementation(class_getInstanceMethod(superClass, @selector(resume)));
            // 如果指向这个具体类的resume方法实现的指针,和指向其父类的resume方法实现的指针,
            // 以及指向当前类的af_resume方法原始实现的指针,都不一致
            if (classResumeIMP != superclassResumeIMP &&
                originalAFResumeIMP != classResumeIMP) {
                // 向当前这个具体类添加af_resume和 af_suspend方法, 并与其resume和suspend方法作交换
                [self swizzleResumeAndSuspendMethodForClass:currentClass];
            }
            // 获取当前这个具体类的父类,继续循环判断其父类
            currentClass = [currentClass superclass];
        }
        // 取消网络会话任务
        [localDataTask cancel];
        // 立刻结束当前网络会话
        [session finishTasksAndInvalidate];
    }
}

/// 动态添加af_resume和af_suspend方法, 并与之对应的resume和suspend做交换
+ (void)swizzleResumeAndSuspendMethodForClass:(Class)theClass {
    // 获取本类的af_resume和af_suspend方法
    Method afResumeMethod = class_getInstanceMethod(self, @selector(af_resume));
    Method afSuspendMethod = class_getInstanceMethod(self, @selector(af_suspend));
    // 如果想目标类中成功添加了af_resume方法
    if (af_addMethod(theClass, @selector(af_resume), afResumeMethod)) {
        // 交换目标类的resume和af_resume方法
        af_swizzleSelector(theClass, @selector(resume), @selector(af_resume));
    }
    // 如果目标类中成功添加了af_suspend方法
    if (af_addMethod(theClass, @selector(af_suspend), afSuspendMethod)) {
        // 交换目标类的suspend和af_suspend方法
        af_swizzleSelector(theClass, @selector(suspend), @selector(af_suspend));
    }
}

- (NSURLSessionTaskState)state {
    NSAssert(NO, @"State method should never be called in the actual dummy class");
    return NSURLSessionTaskStateCanceling;
}

- (void)af_resume {
    // 获取NSURLSessionDataTask对象的state属性, 并调用其resume方法
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_resume];
    // 如果在调用重启方法之前的状态不是正常运行状态, 就发送通知
    if (state != NSURLSessionTaskStateRunning) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidResumeNotification object:self];
    }
}

- (void)af_suspend {
    // 获取NSURLSessionDataTask对象的state属性, 并调用其suspend方法
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_suspend];
    // 如果在调用暂停方法之前的状态不是暂停状态, 就发送通知
    if (state != NSURLSessionTaskStateSuspended) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidSuspendNotification object:self];
    }
}
@end

#pragma mark -

@interface AFURLSessionManager ()
/// 保存网络会话配置对象
@property (readwrite, nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
/// 保存回调操作队列对象
@property (readwrite, nonatomic, strong) NSOperationQueue *operationQueue;
/// 保存网络会话对象
@property (readwrite, nonatomic, strong) NSURLSession *session;
/// 保存AFURLSessionManagerTaskDelegate对象和task之间的联系
@property (readwrite, nonatomic, strong) NSMutableDictionary *mutableTaskDelegatesKeyedByTaskIdentifier;
/// 保存task的taskDescription属性值, 在代码中被设置为当前对象的地址值
@property (readonly, nonatomic, copy) NSString *taskDescriptionForSessionTasks;
/// 保存锁对象, 这个锁用来保证对mutableTaskDelegatesKeyedByTaskIdentifier存取的线程安全
@property (readwrite, nonatomic, strong) NSLock *lock;
/// 保存session无效时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDidBecomeInvalidBlock sessionDidBecomeInvalid;
/// session接收到验证请求时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDidReceiveAuthenticationChallengeBlock sessionDidReceiveAuthenticationChallenge;
/// session队列中所有的消息都发送出去时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDidFinishEventsForBackgroundURLSessionBlock didFinishEventsForBackgroundURLSession AF_API_UNAVAILABLE(macos);
/// 保存一个HTTP请求试图执行重定向到一个不同的URL时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionTaskWillPerformHTTPRedirectionBlock taskWillPerformHTTPRedirection;
/// 保存task接收到身份验证时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionTaskAuthenticationChallengeBlock authenticationChallengeHandler;
/// task需要一个新的输入流时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionTaskNeedNewBodyStreamBlock taskNeedNewBodyStream;
/// 保存一个来定期追踪上传进度的block回调
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidSendBodyDataBlock taskDidSendBodyData;
/// task执行完成时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidCompleteBlock taskDidComplete;
#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidFinishCollectingMetricsBlock taskDidFinishCollectingMetrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10));
#endif
/// dataTask接收到响应时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveResponseBlock dataTaskDidReceiveResponse;
/// dataTask变成downloadTask时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidBecomeDownloadTaskBlock dataTaskDidBecomeDownloadTask;
/// dataTask接收到数据时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveDataBlock dataTaskDidReceiveData;
/// dataTask将要对相应进行缓存时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskWillCacheResponseBlock dataTaskWillCacheResponse;
/// downloadTask完成一个下载时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
/// 保存一个定期跟踪下载进度的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidWriteDataBlock downloadTaskDidWriteData;
/// downloadTask重新开始下载时的block回调
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidResumeBlock downloadTaskDidResume;
@end

@implementation AFURLSessionManager

- (instancetype)init {
    // 默认配置初始化
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }
    
    // 初始化NSURLSessionConfiguration 如果没有传则用默认
    if (!configuration) {
        configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }

    self.sessionConfiguration = configuration;
    
    // 初始化一个操作队列并设置最大线程并发数为1
    self.operationQueue = [[NSOperationQueue alloc] init];
    self.operationQueue.maxConcurrentOperationCount = 1;
    
    // 初始化 JSON 响应序列对象
    self.responseSerializer = [AFJSONResponseSerializer serializer];
    
    // 初始化JSON响应序列对象
    self.securityPolicy = [AFSecurityPolicy defaultPolicy];
    
    // 初始化网络监测对象
#if !TARGET_OS_WATCH
    self.reachabilityManager = [AFNetworkReachabilityManager sharedManager];
#endif
    
    // 初始化可变字典保存 NSURLSessionTask 和其对应的 delegate, 并以 NSURLSessionTask 的属性 taskIdentifier 做 key, 以 NSURLSession 的 delegate 做 value
    self.mutableTaskDelegatesKeyedByTaskIdentifier = [[NSMutableDictionary alloc] init];
    
    // 初始化 self.mutableTaskDelegatesKeyedByTaskIdentifier 可变字典的锁, 确保字典在多线程访问时的线程安全
    self.lock = [[NSLock alloc] init];
    self.lock.name = AFURLSessionManagerLockName;
    
    // 异步地获取当前 session 的所有未完成的task, 并进行置空处理, 主要是为了从后台切换到前台时初始化session
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionDataTask *task in dataTasks) {
            [self addDelegateForDataTask:task uploadProgress:nil downloadProgress:nil completionHandler:nil];
        }

        for (NSURLSessionUploadTask *uploadTask in uploadTasks) {
            [self addDelegateForUploadTask:uploadTask progress:nil completionHandler:nil];
        }

        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            [self addDelegateForDownloadTask:downloadTask progress:nil destination:nil completionHandler:nil];
        }
    }];

    return self;
}

- (void)dealloc {
    // 移除通知观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -

- (NSURLSession *)session {
    
    @synchronized (self) {
        if (!_session) {
            _session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];
        }
    }
    return _session;
}

#pragma mark -

// 获取当前AFURLSessionManager对象的地址字符串赋值给task的taskDescription属性,
// 目的是通过这个字符串来判断通知监听到的是否是当前AFURLSessionManager对象所拥有的task发出的
- (NSString *)taskDescriptionForSessionTasks {
    return [NSString stringWithFormat:@"%p", self];
}

/// 当task已经重启的时候会通过通知调用这个方法
- (void)taskDidResume:(NSNotification *)notification {
    /// 从通知对象中获取到发送这条通知的task
    NSURLSessionTask *task = notification.object;
    /// 如果这个task属于这个AFURLSessionManager对象
    if ([task respondsToSelector:@selector(taskDescription)]) {
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            /// 主线程异步发送task已经重启
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidResumeNotification object:task];
            });
        }
    }
}

/// 当task已经暂停的时候会通过通知调用此方法
- (void)taskDidSuspend:(NSNotification *)notification {
    ///从通知对象中获取到发送通知的task
    NSURLSessionTask *task = notification.object;
    /// 如果这个task属于这个AFURLSessionManager对象
    if ([task respondsToSelector:@selector(taskDescription)]) {
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                /// 主线程异步发送通知task已经暂停
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidSuspendNotification object:task];
            });
        }
    }
}

#pragma mark -
/// 通过task对象获取其绑定的AFURLSessionManagerTaskDelegate对象
- (AFURLSessionManagerTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);
    
    // 在线程安全的环境下, 通过task的taskIdentifier属性, 从mutableTaskDelegatesKeyedByTaskIdentifier 属性中获取绑定的delegate
    AFURLSessionManagerTaskDelegate *delegate = nil;
    [self.lock lock];
    delegate = self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)];
    [self.lock unlock];

    return delegate;
}

// 为task绑定delegate
- (void)setDelegate:(AFURLSessionManagerTaskDelegate *)delegate
            forTask:(NSURLSessionTask *)task
{
    // 在debug下缺少参数会直接crash
    NSParameterAssert(task);
    NSParameterAssert(delegate);
    
    // 加锁用以保证对字典的操作线程安全
    [self.lock lock];
    // 将NSURLSessionTask对象的taskIdentifier作为key, 将与之对应的AFURLSessionManagerTaskDelegate对象作为value, 存放到字典中
    self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)] = delegate;
    // 为task添加开始与暂停通知
    [self addNotificationObserverForTask:task];
    [self.lock unlock];
}

// 为dataTask绑定delegate
- (void)addDelegateForDataTask:(NSURLSessionDataTask *)dataTask
                uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
              downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
             completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 这个方法里主要生成了一个AFURLSessionManagerTaskDelegate的对象并和NSURLSessionDataTask对象以及AFURLSessionManager对象相关联
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] initWithTask:dataTask];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;
    // 标记dataTask所属的AFURLSessionManager对象
    dataTask.taskDescription = self.taskDescriptionForSessionTasks;
    // 为dataTask绑定delegate
    [self setDelegate:delegate forTask:dataTask];

    delegate.uploadProgressBlock = uploadProgressBlock;
    delegate.downloadProgressBlock = downloadProgressBlock;
}

// 为uploadTask绑定delegate
- (void)addDelegateForUploadTask:(NSURLSessionUploadTask *)uploadTask
                        progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
               completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 通过uploadTask实例化delegate对象, 并初始化属性
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] initWithTask:uploadTask];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;
    // 标记uploadTask所属的AFURLSessionManager对象
    uploadTask.taskDescription = self.taskDescriptionForSessionTasks;
    // 为uploadTask绑定delegate
    [self setDelegate:delegate forTask:uploadTask];

    delegate.uploadProgressBlock = uploadProgressBlock;
}

// 为downloadTask绑定delegate
- (void)addDelegateForDownloadTask:(NSURLSessionDownloadTask *)downloadTask
                          progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                       destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                 completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    // 通过downloadTask实例化delegate对象, 并初始化属性
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] initWithTask:downloadTask];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;
    // 如果设置了保存下载文件的路径, 就赋值给delegate
    if (destination) {
        delegate.downloadTaskDidFinishDownloading = ^NSURL * (NSURLSession * __unused session, NSURLSessionDownloadTask *task, NSURL *location) {
            return destination(location, task.response);
        };
    }
    // 标记downloadTask所属的AFURLSessionManager对象
    downloadTask.taskDescription = self.taskDescriptionForSessionTasks;
    // 为downloadTask绑定delegate
    [self setDelegate:delegate forTask:downloadTask];

    delegate.downloadProgressBlock = downloadProgressBlock;
}

// 移除task绑定的delegate
- (void)removeDelegateForTask:(NSURLSessionTask *)task {
    // 在debug下缺少参数就crash
    NSParameterAssert(task);

    [self.lock lock];
    // 移除对task观察的通知
    [self removeNotificationObserverForTask:task];
    // 从mutableTaskDelegatesKeyedByTaskIdentifier移除task
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeObjectForKey:@(task.taskIdentifier)];
    [self.lock unlock];
}

#pragma mark -
// 通过传入的不同类型task的名称获取对应的tasks
- (NSArray *)tasksForKeyPath:(NSString *)keyPath {
    // 创建临时变量保存获取到的tasks
    __block NSArray *tasks = nil;
    // 创建信号量, 因为getTasksWithCompletionHandler这个方法是异步获取tasks, 为了避免还没获取到tasks就返回, 就是用信号量进行控制
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        // 根据传入的不同类型task的名称获取相应的tasks
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(dataTasks))]) {
            tasks = dataTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(uploadTasks))]) {
            tasks = uploadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(downloadTasks))]) {
            tasks = downloadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(tasks))]) {
            // 利用valueForKeyPath合并数组并保留重复值
            tasks = [@[dataTasks, uploadTasks, downloadTasks] valueForKeyPath:@"@unionOfArrays.self"];
        }
        // 发送一个信号量, 使semaphore变为1, 表示已经获取到tasks, 可以向下执行
        dispatch_semaphore_signal(semaphore);
    }];
    // 等待信号量变为1
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    return tasks;
}

// 通过tasksForKeyPath:方法的实现，我们可以学到如何利用GCD的信号量将异步回调转换为同步执行
// 获取当前AFURLSessionManager对象的所有tasks
- (NSArray *)tasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

// 获取当前AFURLSessionManager对象的所有dataTasks
- (NSArray *)dataTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

// 获取当前AFURLSessionManager对象的所有uploadTasks
- (NSArray *)uploadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

// 获取当前AFURLSessionManager对象的所有downloadTasks
- (NSArray *)downloadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

#pragma mark -
// 当传YES, 就立即关闭当前网络会话; 当传NO, 等待当前任务完成后再关闭当前会话
- (void)invalidateSessionCancelingTasks:(BOOL)cancelPendingTasks resetSession:(BOOL)resetSession {
    if (cancelPendingTasks) {
        [self.session invalidateAndCancel];
    } else {
        [self.session finishTasksAndInvalidate];
    }
    if (resetSession) {
        self.session = nil;
    }
}

#pragma mark -
// 公共接口设置responseSerializer相关属性的set方法
- (void)setResponseSerializer:(id <AFURLResponseSerialization>)responseSerializer {
    NSParameterAssert(responseSerializer);
    // 保存设置的参数
    _responseSerializer = responseSerializer;
}

#pragma mark -
- (void)addNotificationObserverForTask:(NSURLSessionTask *)task {
    // 为task添加开始与暂停通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidResume:) name:AFNSURLSessionTaskDidResumeNotification object:task];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidSuspend:) name:AFNSURLSessionTaskDidSuspendNotification object:task];
}

- (void)removeNotificationObserverForTask:(NSURLSessionTask *)task {
    // 移除task观察通知
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidSuspendNotification object:task];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidResumeNotification object:task];
}

#pragma mark -

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                               uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                             downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                            completionHandler:(nullable void (^)(NSURLResponse *response, id _Nullable responseObject,  NSError * _Nullable error))completionHandler {
    /// 新建数据任务
    NSURLSessionDataTask *dataTask = [self.session dataTaskWithRequest:request];
    /// 为dataTask绑定AFURLSessionManagerTaskDelegate对象, 以监听dataTask对象
    [self addDelegateForDataTask:dataTask uploadProgress:uploadProgressBlock downloadProgress:downloadProgressBlock completionHandler:completionHandler];

    return dataTask;
}

#pragma mark -

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 新建上传任务
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
    // 为uploadTask绑定AFURLSessionManagerTaskDelegate对象, 以监听uploadTask的处理进度和处理数据
    if (uploadTask) {
        [self addDelegateForUploadTask:uploadTask
                              progress:uploadProgressBlock
                     completionHandler:completionHandler];
    }

    return uploadTask;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 通过request和bodyData创建uploadTask
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithRequest:request fromData:bodyData];
    // 为uploadTask绑定AFURLSessionManagerTaskDelegate对象, 以监听uploadTask的处理进度和处理数据
    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
                                                 progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                        completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 通过request创建uploadTask
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithStreamedRequest:request];
    // 为uploadTask绑定AFURLSessionManagerTaskDelegate对象, 以监听uploadTask的处理进度和处理数据
    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

#pragma mark -

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                             progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                          destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                    completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    // 通过传入的request创建downloadTask
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithRequest:request];
    // 为downloadTask绑定AFURLSessionManagerTaskDelegate对象, 以监听downloadTask的处理进度和处理数据
    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
                                                progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                             destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                       completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    // 通过resumeData创建downloadTask
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithResumeData:resumeData];
    // 为downloadTask绑定AFURLSessionManagerTaskDelegate对象, 以监听downloadTask的处理进度和处理数据
    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

#pragma mark -
//  获取task进度方法的公共方法
- (NSProgress *)uploadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] uploadProgress];
}

- (NSProgress *)downloadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] downloadProgress];
}

#pragma mark -

// 设置NSURLSessionDelegate回调的公共方法
- (void)setSessionDidBecomeInvalidBlock:(void (^)(NSURLSession *session, NSError *error))block {
    self.sessionDidBecomeInvalid = block;
}

- (void)setSessionDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.sessionDidReceiveAuthenticationChallenge = block;
}

#if !TARGET_OS_OSX
- (void)setDidFinishEventsForBackgroundURLSessionBlock:(void (^)(NSURLSession *session))block {
    self.didFinishEventsForBackgroundURLSession = block;
}
#endif

#pragma mark -
// 设置NSURLSessionTaskDelegate回调的公共方法
- (void)setTaskNeedNewBodyStreamBlock:(NSInputStream * (^)(NSURLSession *session, NSURLSessionTask *task))block {
    self.taskNeedNewBodyStream = block;
}

- (void)setTaskWillPerformHTTPRedirectionBlock:(NSURLRequest * (^)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request))block {
    self.taskWillPerformHTTPRedirection = block;
}

- (void)setTaskDidSendBodyDataBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend))block {
    self.taskDidSendBodyData = block;
}

- (void)setTaskDidCompleteBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, NSError *error))block {
    self.taskDidComplete = block;
}

#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
- (void)setTaskDidFinishCollectingMetricsBlock:(void (^)(NSURLSession * _Nonnull, NSURLSessionTask * _Nonnull, NSURLSessionTaskMetrics * _Nullable))block AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10)) {
    self.taskDidFinishCollectingMetrics = block;
}
#endif

#pragma mark -
// 设置NSURLSessionDataDelegate回调的公共方法
- (void)setDataTaskDidReceiveResponseBlock:(NSURLSessionResponseDisposition (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response))block {
    self.dataTaskDidReceiveResponse = block;
}

- (void)setDataTaskDidBecomeDownloadTaskBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask))block {
    self.dataTaskDidBecomeDownloadTask = block;
}

- (void)setDataTaskDidReceiveDataBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data))block {
    self.dataTaskDidReceiveData = block;
}

- (void)setDataTaskWillCacheResponseBlock:(NSCachedURLResponse * (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse))block {
    self.dataTaskWillCacheResponse = block;
}

#pragma mark -
// 设置NSURLSessionDownloadDelegate回调的公共方法
- (void)setDownloadTaskDidFinishDownloadingBlock:(NSURL * (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location))block {
    self.downloadTaskDidFinishDownloading = block;
}

- (void)setDownloadTaskDidWriteDataBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite))block {
    self.downloadTaskDidWriteData = block;
}

- (void)setDownloadTaskDidResumeBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes))block {
    self.downloadTaskDidResume = block;
}

#pragma mark - NSObject

- (NSString *)description {
    // 定制打印数据
    return [NSString stringWithFormat:@"<%@: %p, session: %@, operationQueue: %@>", NSStringFromClass([self class]), self, self.session, self.operationQueue];
}

- (BOOL)respondsToSelector:(SEL)selector {
    // 如果没有对相应的block进行赋值, 也不会去调用实现相应的代理
    if (selector == @selector(URLSession:didReceiveChallenge:completionHandler:)) {
        return self.sessionDidReceiveAuthenticationChallenge != nil;
    } else if (selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)) {
        return self.taskWillPerformHTTPRedirection != nil;
    } else if (selector == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:)) {
        return self.dataTaskDidReceiveResponse != nil;
    } else if (selector == @selector(URLSession:dataTask:willCacheResponse:completionHandler:)) {
        return self.dataTaskWillCacheResponse != nil;
    }
#if !TARGET_OS_OSX
    else if (selector == @selector(URLSessionDidFinishEventsForBackgroundURLSession:)) {
        return self.didFinishEventsForBackgroundURLSession != nil;
    }
#endif

    return [[self class] instancesRespondToSelector:selector];
}

#pragma mark - NSURLSessionDelegate
// 当session无效时, 回调用这个代理方法
- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error
{
    // 使用block回调数据
    if (self.sessionDidBecomeInvalid) {
        self.sessionDidBecomeInvalid(session, error);
    }
    // 发送通知
    [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDidInvalidateNotification object:session];
}

// 当session接收到验证请求时, 会调用此方法
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSAssert(self.sessionDidReceiveAuthenticationChallenge != nil, @"`respondsToSelector:` implementation forces `URLSession:didReceiveChallenge:completionHandler:` to be called only if `self.sessionDidReceiveAuthenticationChallenge` is not nil");
    
    // 设置临时变量保存数据
    NSURLCredential *credential = nil;
    NSURLSessionAuthChallengeDisposition disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);
    // 回调结果
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

#pragma mark - NSURLSessionTaskDelegate
// 当一个HTTP请求试图执行重定向到一个不同的URL时, 会调用此方法
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    NSURLRequest *redirectRequest = request;
    // 如果通过block传入重定向的处理方式, 就传参调用
    if (self.taskWillPerformHTTPRedirection) {
        redirectRequest = self.taskWillPerformHTTPRedirection(session, task, response, request);
    }
    // 回调结果
    if (completionHandler) {
        completionHandler(redirectRequest);
    }
}

// 当task接收到身份验证时, 回调用这个代理方法, 这个证书验证的处理方式和上面一样, 只不过上面时session级别的, 这个是task级别的
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    // 设置临时变量保存数据
    BOOL evaluateServerTrust = NO;
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    NSURLCredential *credential = nil;
    // 如果通过block传入了证书处理方式, 则直接传参调用
    if (self.authenticationChallengeHandler) {
        id result = self.authenticationChallengeHandler(session, task, challenge, completionHandler);
        if (result == nil) {
            return;
        } else if ([result isKindOfClass:NSError.class]) {
            objc_setAssociatedObject(task, AuthenticationChallengeErrorKey, result, OBJC_ASSOCIATION_RETAIN);
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        } else if ([result isKindOfClass:NSURLCredential.class]) {
            credential = result;
            disposition = NSURLSessionAuthChallengeUseCredential;
        } else if ([result isKindOfClass:NSNumber.class]) {
            disposition = [result integerValue];
            NSAssert(disposition == NSURLSessionAuthChallengePerformDefaultHandling || disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge || disposition == NSURLSessionAuthChallengeRejectProtectionSpace, @"");
            evaluateServerTrust = disposition == NSURLSessionAuthChallengePerformDefaultHandling && [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
        } else {
            @throw [NSException exceptionWithName:@"Invalid Return Value" reason:@"The return value from the authentication challenge handler must be nil, an NSError, an NSURLCredential or an NSNumber." userInfo:nil];
        }
    } else {
        evaluateServerTrust = [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
    }

    if (evaluateServerTrust) {
        // 如果通过了当前类安全策略的验证
        if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
            // 设置验证模式为通过指定证书验证, 并生成证书
            disposition = NSURLSessionAuthChallengeUseCredential;
            credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        // 如果为通过当前类安全策略验证
        } else {
            // 不需要验证证书
            objc_setAssociatedObject(task, AuthenticationChallengeErrorKey,
                                     [self serverTrustErrorForServerTrust:challenge.protectionSpace.serverTrust url:task.currentRequest.URL],
                                     OBJC_ASSOCIATION_RETAIN);
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        }
    }
    // 回调
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}
// 服务验证错误
- (nonnull NSError *)serverTrustErrorForServerTrust:(nullable SecTrustRef)serverTrust url:(nullable NSURL *)url
{
    NSBundle *CFNetworkBundle = [NSBundle bundleWithIdentifier:@"com.apple.CFNetwork"];
    NSString *defaultValue = @"The certificate for this server is invalid. You might be connecting to a server that is pretending to be “%@” which could put your confidential information at risk.";
    NSString *descriptionFormat = NSLocalizedStringWithDefaultValue(@"Err-1202.w", nil, CFNetworkBundle, defaultValue, @"") ?: defaultValue;
    NSString *localizedDescription = [descriptionFormat componentsSeparatedByString:@"%@"].count <= 2 ? [NSString localizedStringWithFormat:descriptionFormat, url.host] : descriptionFormat;
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: localizedDescription
    } mutableCopy];

    if (serverTrust) {
        userInfo[NSURLErrorFailingURLPeerTrustErrorKey] = (__bridge id)serverTrust;
    }

    if (url) {
        userInfo[NSURLErrorFailingURLErrorKey] = url;

        if (url.absoluteString) {
            userInfo[NSURLErrorFailingURLStringErrorKey] = url.absoluteString;
        }
    }

    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted userInfo:userInfo];
}

// 当task需要一个新的输入流时, 会调用这个代理方法
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    // 创建临时变量保存数据
    NSInputStream *inputStream = nil;
    // 如果通过block回调传入获取输入流的方式, 就传参调用
    if (self.taskNeedNewBodyStream) {
        inputStream = self.taskNeedNewBodyStream(session, task);
    // 否则如果task中原有输入流, 就用原有输入流
    } else if (task.originalRequest.HTTPBodyStream && [task.originalRequest.HTTPBodyStream conformsToProtocol:@protocol(NSCopying)]) {
        inputStream = [task.originalRequest.HTTPBodyStream copy];
    }
    // 回调结果
    if (completionHandler) {
        completionHandler(inputStream);
    }
}

// 向服务器发送数据时调用
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    // 创建临时变量保存数据
    int64_t totalUnitCount = totalBytesExpectedToSend;
    // 如果数据总大小获取失败
    if (totalUnitCount == NSURLSessionTransferSizeUnknown) {
        // 通过请求头中的“Content-Length”字段获取大小
        NSString *contentLength = [task.originalRequest valueForHTTPHeaderField:@"Content-Length"];
        if (contentLength) {
            totalUnitCount = (int64_t) [contentLength longLongValue];
        }
    }
    // 获取与task绑定的delegate对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    // 调用delegate对象所实现相同的代理方法来监听进度
    if (delegate) {
        [delegate URLSession:session task:task didSendBodyData:bytesSent totalBytesSent:totalBytesSent totalBytesExpectedToSend:totalBytesExpectedToSend];
    }
    // 调用block回调数据
    if (self.taskDidSendBodyData) {
        self.taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalUnitCount);
    }
}

// 当task执行完成时, 会调用这个代理方法
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    //  生成 AFURLSessionManagerTaskDelegate 类型 delegate 对象 （获取与task绑定的delegate对象）
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];

    // delegate may be nil when completing a task in the background
    // 当task在后台完成时 delegate 可能为nil
    if (delegate) {
        // 调用delegate对象所实现相同的代理方法来处理结果
        [delegate URLSession:session task:task didCompleteWithError:error];
        // 移除对task监听的通知和其绑定的delegate
        [self removeDelegateForTask:task];
    }
    // 调用block回调数据
    if (self.taskDidComplete) {
        self.taskDidComplete(session, task, error);
    }
}

#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
//
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10))
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    // Metrics may fire after URLSession:task:didCompleteWithError: is called, delegate may be nil
    if (delegate) {
        [delegate URLSession:session task:task didFinishCollectingMetrics:metrics];
    }

    if (self.taskDidFinishCollectingMetrics) {
        self.taskDidFinishCollectingMetrics(session, task, metrics);
    }
}
#endif

#pragma mark - NSURLSessionDataDelegate
// 当dataTask接收到响应时, 回调用这个代理方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    // 创建临时变量保存接收到数据后的处理模式
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
    // 如果通过block传入了处理方式, 则传参调用
    if (self.dataTaskDidReceiveResponse) {
        disposition = self.dataTaskDidReceiveResponse(session, dataTask, response);
    }
    // 回调结果
    if (completionHandler) {
        completionHandler(disposition);
    }
}

// 当dataTask变成downloadTask时, 回调用这个代理方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    // 获取与dataTask绑定的delegate对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    if (delegate) {
        // 把delegate从dataTask上解绑, 然后绑定到downloadTask
        [self removeDelegateForTask:dataTask];
        [self setDelegate:delegate forTask:downloadTask];
    }
    // 调用block回调数据
    if (self.dataTaskDidBecomeDownloadTask) {
        self.dataTaskDidBecomeDownloadTask(session, dataTask, downloadTask);
    }
}

// 当dataTask接收到数据时, 会调用这个代理方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    // 获取与dataTask绑定的delegate对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    // 调用delegate对象所实现相同的代理方法来处理结果
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];
    
    // 通过block更新数据
    if (self.dataTaskDidReceiveData) {
        self.dataTaskDidReceiveData(session, dataTask, data);
    }
}

// 当dataTask将要对响应进行缓存时, 会调用这个代理方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    // 创建临时变量保存要缓存的相应对象
    NSCachedURLResponse *cachedResponse = proposedResponse;
    // 如果通过block传入了处理方式, 则传参调用
    if (self.dataTaskWillCacheResponse) {
        cachedResponse = self.dataTaskWillCacheResponse(session, dataTask, proposedResponse);
    }
    // 回调结果
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

#if !TARGET_OS_OSX
/// 当session队列中所有的消息都发送出去时, 回调用这个代理方法
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    // 主队列异步回调结果
    if (self.didFinishEventsForBackgroundURLSession) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.didFinishEventsForBackgroundURLSession(session);
        });
    }
}
#endif

#pragma mark - NSURLSessionDownloadDelegate
// 下载任务完成后的回调
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    // 获取与downloadTask绑定的delegate对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    // 如果通过block传入了处理方式
    if (self.downloadTaskDidFinishDownloading) {
        // 则传参调用获取下载文件保存路径
        NSURL *fileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (fileURL) {
            delegate.downloadFileURL = fileURL;
            NSError *error = nil;
            // 如果用户设置了保存下载文件的路径，就将下载完的文件从临时路径移动过去，移动完成后发送通知
            if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&error]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:error.userInfo];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidMoveFileSuccessfullyNotification object:downloadTask userInfo:nil];
            }

            return;
        }
    }
    // 调用delegate对象所实现相同的代理方法来处理结果
    if (delegate) {
        [delegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    }
}

// 执行下载任务时定期调用
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    // 获取与downloadTask绑定的delegate对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    
    // 调用delegate对象所实现相同的代理方法来处理数据
    if (delegate) {
        // 更新下载对象的属性
        [delegate URLSession:session downloadTask:downloadTask didWriteData:bytesWritten totalBytesWritten:totalBytesWritten totalBytesExpectedToWrite:totalBytesExpectedToWrite];
    }
    // 调用block回调数据
    if (self.downloadTaskDidWriteData) {
        self.downloadTaskDidWriteData(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}

// 重启下载时调用
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    // 获取与downloadTask绑定的delegate对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    
    // 调用delegate对象所实现相同的代理方法来处理数据
    if (delegate) {
        // 更新下载进度对象的属性
        [delegate URLSession:session downloadTask:downloadTask didResumeAtOffset:fileOffset expectedTotalBytes:expectedTotalBytes];
    }
    
    // 调用block回调数据
    if (self.downloadTaskDidResume) {
        self.downloadTaskDidResume(session, downloadTask, fileOffset, expectedTotalBytes);
    }
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    NSURLSessionConfiguration *configuration = [decoder decodeObjectOfClass:[NSURLSessionConfiguration class] forKey:@"sessionConfiguration"];

    self = [self initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.session.configuration forKey:@"sessionConfiguration"];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithSessionConfiguration:self.session.configuration];
}

@end

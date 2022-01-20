// AFImageDownloader.m
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

#import <TargetConditionals.h>

#if TARGET_OS_IOS || TARGET_OS_TV

#import "AFImageDownloader.h"
#import "AFHTTPSessionManager.h"

@interface AFImageDownloaderResponseHandler : NSObject
/// 手机 uuid
@property (nonatomic, strong) NSUUID *uuid;
/// 成功回调
@property (nonatomic, copy) void (^successBlock)(NSURLRequest *, NSHTTPURLResponse *, UIImage *);
/// 失败回调
@property (nonatomic, copy) void (^failureBlock)(NSURLRequest *, NSHTTPURLResponse *, NSError *);
@end

@implementation AFImageDownloaderResponseHandler

- (instancetype)initWithUUID:(NSUUID *)uuid
                     success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *responseObject))success
                     failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure {
    if (self = [self init]) {
        self.uuid = uuid;
        self.successBlock = success;
        self.failureBlock = failure;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat: @"<AFImageDownloaderResponseHandler>UUID: %@", [self.uuid UUIDString]];
}

@end

@interface AFImageDownloaderMergedTask : NSObject
/// 图片链接标识符
@property (nonatomic, strong) NSString *URLIdentifier;
/// 手机的uuid
@property (nonatomic, strong) NSUUID *identifier;
/// 下载任务
@property (nonatomic, strong) NSURLSessionDataTask *task;
/// 响应回调数组
@property (nonatomic, strong) NSMutableArray <AFImageDownloaderResponseHandler*> *responseHandlers;

@end

@implementation AFImageDownloaderMergedTask

- (instancetype)initWithURLIdentifier:(NSString *)URLIdentifier identifier:(NSUUID *)identifier task:(NSURLSessionDataTask *)task {
    if (self = [self init]) {
        self.URLIdentifier = URLIdentifier;
        self.task = task;
        self.identifier = identifier;
        self.responseHandlers = [[NSMutableArray alloc] init];
    }
    return self;
}
// 添加响应回调
- (void)addResponseHandler:(AFImageDownloaderResponseHandler *)handler {
    [self.responseHandlers addObject:handler];
}
// 删除响应回调
- (void)removeResponseHandler:(AFImageDownloaderResponseHandler *)handler {
    [self.responseHandlers removeObject:handler];
}

@end

@implementation AFImageDownloadReceipt

- (instancetype)initWithReceiptID:(NSUUID *)receiptID task:(NSURLSessionDataTask *)task {
    if (self = [self init]) {
        self.receiptID = receiptID;
        self.task = task;
    }
    return self;
}

@end

@interface AFImageDownloader ()
/// 串行队列
@property (nonatomic, strong) dispatch_queue_t synchronizationQueue;
/// 响应队列
@property (nonatomic, strong) dispatch_queue_t responseQueue;
/// 最大下载数
@property (nonatomic, assign) NSInteger maximumActiveDownloads;
/// 当前活动请求数
@property (nonatomic, assign) NSInteger activeRequestCount;
/// 队列中的任务
@property (nonatomic, strong) NSMutableArray *queuedMergedTasks;
/// 保存任务和其标识符
@property (nonatomic, strong) NSMutableDictionary *mergedTasks;

@end

@implementation AFImageDownloader

// 默认URLCache
+ (NSURLCache *)defaultURLCache {
    NSUInteger memoryCapacity = 20 * 1024 * 1024; // 20MB
    NSUInteger diskCapacity = 150 * 1024 * 1024; // 150MB
    NSURL *cacheURL = [[[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:nil]
                       URLByAppendingPathComponent:@"com.alamofire.imagedownloader"];
    
#if TARGET_OS_MACCATALYST
    return [[NSURLCache alloc] initWithMemoryCapacity:memoryCapacity
                                         diskCapacity:diskCapacity
                                         directoryURL:cacheURL];
#else
    return [[NSURLCache alloc] initWithMemoryCapacity:memoryCapacity
                                         diskCapacity:diskCapacity
                                             diskPath:[cacheURL path]];
#endif
}

/// 实例化默认网络会话配置
+ (NSURLSessionConfiguration *)defaultURLSessionConfiguration {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];

    //TODO set the default HTTP headers

    configuration.HTTPShouldSetCookies = YES;
    configuration.HTTPShouldUsePipelining = NO;

    configuration.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
    configuration.allowsCellularAccess = YES;
    configuration.timeoutIntervalForRequest = 60.0;
    configuration.URLCache = [AFImageDownloader defaultURLCache];

    return configuration;
}

- (instancetype)init {
    // 实例化网络会话配置类对象并以之为参数调用下面的方法
    NSURLSessionConfiguration *defaultConfiguration = [self.class defaultURLSessionConfiguration];
    return [self initWithSessionConfiguration:defaultConfiguration];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    // 实例化 AFHTTPSessionManager 对象
    AFHTTPSessionManager *sessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:configuration];
    sessionManager.responseSerializer = [AFImageResponseSerializer serializer];

    return [self initWithSessionManager:sessionManager
                 downloadPrioritization:AFImageDownloadPrioritizationFIFO
                 maximumActiveDownloads:4
                             imageCache:[[AFAutoPurgingImageCache alloc] init]];
}

- (instancetype)initWithSessionManager:(AFHTTPSessionManager *)sessionManager
                downloadPrioritization:(AFImageDownloadPrioritization)downloadPrioritization
                maximumActiveDownloads:(NSInteger)maximumActiveDownloads
                            imageCache:(id <AFImageRequestCache>)imageCache {
    if (self = [super init]) {
        // 用属性记录参数
        self.sessionManager = sessionManager;

        self.downloadPrioritization = downloadPrioritization;
        self.maximumActiveDownloads = maximumActiveDownloads;
        self.imageCache = imageCache;
        // 初始化属性
        self.queuedMergedTasks = [[NSMutableArray alloc] init];
        self.mergedTasks = [[NSMutableDictionary alloc] init];
        self.activeRequestCount = 0;

        NSString *name = [NSString stringWithFormat:@"com.alamofire.imagedownloader.synchronizationqueue-%@", [[NSUUID UUID] UUIDString]];
        self.synchronizationQueue = dispatch_queue_create([name cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_SERIAL);

        name = [NSString stringWithFormat:@"com.alamofire.imagedownloader.responsequeue-%@", [[NSUUID UUID] UUIDString]];
        self.responseQueue = dispatch_queue_create([name cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_CONCURRENT);
    }

    return self;
}

// 默认实例
+ (instancetype)defaultInstance {
    static AFImageDownloader *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (nullable AFImageDownloadReceipt *)downloadImageForURLRequest:(NSURLRequest *)request
                                                        success:(void (^)(NSURLRequest * _Nonnull, NSHTTPURLResponse * _Nullable, UIImage * _Nonnull))success
                                                        failure:(void (^)(NSURLRequest * _Nonnull, NSHTTPURLResponse * _Nullable, NSError * _Nonnull))failure {
    // 以UUID为标识调用下面的方法
    return [self downloadImageForURLRequest:request withReceiptID:[NSUUID UUID] success:success failure:failure];
}

- (nullable AFImageDownloadReceipt *)downloadImageForURLRequest:(NSURLRequest *)request
                                                  withReceiptID:(nonnull NSUUID *)receiptID
                                                        success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse  * _Nullable response, UIImage *responseObject))success
                                                        failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure {
    // 生成临时变量
    __block NSURLSessionDataTask *task = nil;
    // 同步串行队列
    dispatch_sync(self.synchronizationQueue, ^{
        // 如果没有图片连接就返回并调用错误信息
        NSString *URLIdentifier = request.URL.absoluteString;
        if (URLIdentifier == nil) {
            if (failure) {
                NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    failure(request, nil, error);
                });
            }
            return;
        }

        // 1) Append the success and failure blocks to a pre-existing request if it already exists
        /// 1) 如果已经发送过这个请求, 就直接把回调放在数组中等待回调, task直接赋值, 不再生成, 然后返回
        AFImageDownloaderMergedTask *existingMergedTask = self.mergedTasks[URLIdentifier];
        if (existingMergedTask != nil) {
            AFImageDownloaderResponseHandler *handler = [[AFImageDownloaderResponseHandler alloc] initWithUUID:receiptID success:success failure:failure];
            [existingMergedTask addResponseHandler:handler];
            task = existingMergedTask.task;
            return;
        }

        // 2) Attempt to load the image from the image cache if the cache policy allows it
        /// 2) 如果缓存策略允许就从缓存中加载图像
        switch (request.cachePolicy) {
            case NSURLRequestUseProtocolCachePolicy:
            case NSURLRequestReturnCacheDataElseLoad:
            case NSURLRequestReturnCacheDataDontLoad: {
                /// 从图片缓存对象中获取图片
                UIImage *cachedImage = [self.imageCache imageforRequest:request withAdditionalIdentifier:nil];
                if (cachedImage != nil) {
                    if (success) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            success(request, nil, cachedImage);
                        });
                    }
                    return;
                }
                break;
            }
            default:
                break;
        }

        // 3) Create the request and set up authentication, validation and response serialization
        /// 3) 创建请求并设置认证, 验证和响应序列化
        NSUUID *mergedTaskIdentifier = [NSUUID UUID];
        NSURLSessionDataTask *createdTask;
        __weak __typeof__(self) weakSelf = self;

        createdTask = [self.sessionManager
                       dataTaskWithRequest:request
                       uploadProgress:nil
                       downloadProgress:nil
                       completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
                           dispatch_async(self.responseQueue, ^{
                               __strong __typeof__(weakSelf) strongSelf = weakSelf;
                               // 获取到URLIdentifier对应的任务对象
                               AFImageDownloaderMergedTask *mergedTask = [strongSelf safelyGetMergedTask:URLIdentifier];
                               // 如果是同一个任务对象
                               if ([mergedTask.identifier isEqual:mergedTaskIdentifier]) {
                                   // 就从任务队列中删除
                                   mergedTask = [strongSelf safelyRemoveMergedTaskWithURLIdentifier:URLIdentifier];
                                   // 如果出错就找出对应的错误block进行回调
                                   if (error) {
                                       for (AFImageDownloaderResponseHandler *handler in mergedTask.responseHandlers) {
                                           if (handler.failureBlock) {
                                               dispatch_async(dispatch_get_main_queue(), ^{
                                                   handler.failureBlock(request, (NSHTTPURLResponse *)response, error);
                                               });
                                           }
                                       }
                                   // 如果不是同一个任务
                                   } else {
                                       // 把下载完成的图片添加到缓存中
                                       if ([strongSelf.imageCache shouldCacheImage:responseObject forRequest:request withAdditionalIdentifier:nil]) {
                                           [strongSelf.imageCache addImage:responseObject forRequest:request withAdditionalIdentifier:nil];
                                       }
                                       // 找出对应的成功回调block进行回调
                                       for (AFImageDownloaderResponseHandler *handler in mergedTask.responseHandlers) {
                                           if (handler.successBlock) {
                                               dispatch_async(dispatch_get_main_queue(), ^{
                                                   handler.successBlock(request, (NSHTTPURLResponse *)response, responseObject);
                                               });
                                           }
                                       }
                                       
                                   }
                               }
                               // 减少当前的任务数
                               [strongSelf safelyDecrementActiveTaskCount];
                               // 开始下一个任务
                               [strongSelf safelyStartNextTaskIfNecessary];
                           });
                       }];

        // 4) Store the response handler for use when the request completes
        // 4) 保存响应处理回调以在请求完成时使用
        // 根据标识符、成功回调block和失败回调block生成图片下载响应对象
        AFImageDownloaderResponseHandler *handler = [[AFImageDownloaderResponseHandler alloc] initWithUUID:receiptID
                                                                                                   success:success
                                                                                                   failure:failure];
        // 将生成的图片下载响应对象添加到图片下载合并任务对象中
        AFImageDownloaderMergedTask *mergedTask = [[AFImageDownloaderMergedTask alloc]
                                                   initWithURLIdentifier:URLIdentifier
                                                   identifier:mergedTaskIdentifier
                                                   task:createdTask];
        // 将生成的图片下载响应对象添加到图片下载合并任务对象中
        [mergedTask addResponseHandler:handler];
        // 根据图片链接保存其对应的图片下载合并任务对象
        self.mergedTasks[URLIdentifier] = mergedTask;

        // 5) Either start the request or enqueue it depending on the current active request count
        // 5) 依据当前活动的请求数量开始请求或者将其排入队列
        if ([self isActiveRequestCountBelowMaximumLimit]) {
            [self startMergedTask:mergedTask];
        } else {
            [self enqueueMergedTask:mergedTask];
        }

        task = mergedTask.task;
    });
    // 生成任务封装并返回
    if (task) {
        return [[AFImageDownloadReceipt alloc] initWithReceiptID:receiptID task:task];
    } else {
        return nil;
    }
}

- (void)cancelTaskForImageDownloadReceipt:(AFImageDownloadReceipt *)imageDownloadReceipt {
    dispatch_sync(self.synchronizationQueue, ^{
        // 通过图片封装对象获取到任务的链接
        NSString *URLIdentifier = imageDownloadReceipt.task.originalRequest.URL.absoluteString;
        // 通过链接获取到任务
        AFImageDownloaderMergedTask *mergedTask = self.mergedTasks[URLIdentifier];
        // 通过标识符获取到响应对象在数组中的索引
        NSUInteger index = [mergedTask.responseHandlers indexOfObjectPassingTest:^BOOL(AFImageDownloaderResponseHandler * _Nonnull handler, __unused NSUInteger idx, __unused BOOL * _Nonnull stop) {
            return handler.uuid == imageDownloadReceipt.receiptID;
        }];
        // 如果找到了图片封装对象在数组中的索引
        if (index != NSNotFound) {
            // 通过索引获取到响应对象
            AFImageDownloaderResponseHandler *handler = mergedTask.responseHandlers[index];
            // 从数组中移除掉响应对象
            [mergedTask removeResponseHandler:handler];
            // 生成错误对象并回调错误block
            NSString *failureReason = [NSString stringWithFormat:@"ImageDownloader cancelled URL request: %@",imageDownloadReceipt.task.originalRequest.URL.absoluteString];
            NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey:failureReason};
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:userInfo];
            if (handler.failureBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler.failureBlock(imageDownloadReceipt.task.originalRequest, nil, error);
                });
            }
        }
        // 如果回调对象为空, 并且任务已经暂停, 就取消任务, 并移除掉对应的任务合并对象
        if (mergedTask.responseHandlers.count == 0) {
            [mergedTask.task cancel];
            [self removeMergedTaskWithURLIdentifier:URLIdentifier];
        }
    });
}

/// 通过标识符安全移除合并任务对象
- (AFImageDownloaderMergedTask *)safelyRemoveMergedTaskWithURLIdentifier:(NSString *)URLIdentifier {
    // 串行队列同步执行移除合并任务对象
    __block AFImageDownloaderMergedTask *mergedTask = nil;
    dispatch_sync(self.synchronizationQueue, ^{
        mergedTask = [self removeMergedTaskWithURLIdentifier:URLIdentifier];
    });
    return mergedTask;
}

//This method should only be called from safely within the synchronizationQueue
// 通过标识符移除合并任务对象, 这个方法只能在self.synchronizationQueue队列中安全调用
- (AFImageDownloaderMergedTask *)removeMergedTaskWithURLIdentifier:(NSString *)URLIdentifier {
    // 通过标识符从可变字典中获取合并任务对象
    AFImageDownloaderMergedTask *mergedTask = self.mergedTasks[URLIdentifier];
    // 通过标识符从可变字典中移除对应的合并任务对象
    [self.mergedTasks removeObjectForKey:URLIdentifier];
    return mergedTask;
}

// 安全地减少当前任务活动数量
- (void)safelyDecrementActiveTaskCount {
    // 串行队列同步执行
    dispatch_sync(self.synchronizationQueue, ^{
        // 减少当前正在活动的请求数量
        if (self.activeRequestCount > 0) {
            self.activeRequestCount -= 1;
        }
    });
}

// 如果必要的话安全地开启下一个任务
- (void)safelyStartNextTaskIfNecessary {
    // 串行队列同步执行
    dispatch_sync(self.synchronizationQueue, ^{
        // 如果当前活动的请求数量没有达到上限
        if ([self isActiveRequestCountBelowMaximumLimit]) {
            // 如果当前排队中有合并任务
            while (self.queuedMergedTasks.count > 0) {
                // 获取到排队中的第一个合并任务对象
                AFImageDownloaderMergedTask *mergedTask = [self dequeueMergedTask];
                // 如果合并任务对象的任务的状体啊是暂停, 就启动这个任务
                if (mergedTask.task.state == NSURLSessionTaskStateSuspended) {
                    [self startMergedTask:mergedTask];
                    break;
                }
            }
        }
    });
}

// 启动合并任务对象
- (void)startMergedTask:(AFImageDownloaderMergedTask *)mergedTask {
    // 启动合并任务对象中的任务
    [mergedTask.task resume];
    // 增加当前活动请求数量
    ++self.activeRequestCount;
}

// 将合并任务对象添加到队列中
- (void)enqueueMergedTask:(AFImageDownloaderMergedTask *)mergedTask {
    switch (self.downloadPrioritization) {
        case AFImageDownloadPrioritizationFIFO:
            // 如果优先级是先进先出, 就添加到最后一个
            [self.queuedMergedTasks addObject:mergedTask];
            break;
        case AFImageDownloadPrioritizationLIFO:
            // 如果是先入后出, 就插入到第一个
            [self.queuedMergedTasks insertObject:mergedTask atIndex:0];
            break;
    }
}

// 获取到排队中的第一个合并任务对象
- (AFImageDownloaderMergedTask *)dequeueMergedTask {
    AFImageDownloaderMergedTask *mergedTask = nil;
    mergedTask = [self.queuedMergedTasks firstObject];
    [self.queuedMergedTasks removeObject:mergedTask];
    return mergedTask;
}

// 判断当前活动请求数量是否达到限制数量
- (BOOL)isActiveRequestCountBelowMaximumLimit {
    return self.activeRequestCount < self.maximumActiveDownloads;
}

/// 通过URLIdentifier安全地获取合并任务对象
- (AFImageDownloaderMergedTask *)safelyGetMergedTask:(NSString *)URLIdentifier {
    __block AFImageDownloaderMergedTask *mergedTask;
    dispatch_sync(self.synchronizationQueue, ^(){
        mergedTask = self.mergedTasks[URLIdentifier];
    });
    return mergedTask;
}

@end

#endif

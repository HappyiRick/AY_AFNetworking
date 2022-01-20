// WkWebView+AFNetworking.m
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

#import "WKWebView+AFNetworking.h"

#import <objc/runtime.h>

#if TARGET_OS_IOS

#import "AFHTTPSessionManager.h"
#import "AFURLResponseSerialization.h"
#import "AFURLRequestSerialization.h"

@interface WKWebView (_AFNetworking)
/// 保存任务对象
@property (readwrite, nonatomic, strong, setter = af_setURLSessionTask:) NSURLSessionDataTask *af_URLSessionTask;
@end

@implementation WKWebView (_AFNetworking)
/// 通过关联对象添加属性
- (NSURLSessionDataTask *)af_URLSessionTask {
    return (NSURLSessionDataTask *)objc_getAssociatedObject(self, @selector(af_URLSessionTask));
}

- (void)af_setURLSessionTask:(NSURLSessionDataTask *)af_URLSessionTask {
    objc_setAssociatedObject(self, @selector(af_URLSessionTask), af_URLSessionTask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark -

@implementation WKWebView (AFNetworking)
/// 通过关联对象为分类添加属性
/// 网络会话管理者对象
- (AFHTTPSessionManager *)sessionManager {
    static AFHTTPSessionManager *_af_defaultHTTPSessionManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _af_defaultHTTPSessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        _af_defaultHTTPSessionManager.requestSerializer = [AFHTTPRequestSerializer serializer];
        _af_defaultHTTPSessionManager.responseSerializer = [AFHTTPResponseSerializer serializer];
    });
    
    return objc_getAssociatedObject(self, @selector(sessionManager)) ?: _af_defaultHTTPSessionManager;
}

- (void)setSessionManager:(AFHTTPSessionManager *)sessionManager {
    objc_setAssociatedObject(self, @selector(sessionManager), sessionManager, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// 响应序列化对象
- (AFHTTPResponseSerializer <AFURLResponseSerialization> *)responseSerializer {
    static AFHTTPResponseSerializer <AFURLResponseSerialization> *_af_defaultResponseSerializer = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _af_defaultResponseSerializer = [AFHTTPResponseSerializer serializer];
    });
    
    return objc_getAssociatedObject(self, @selector(responseSerializer)) ?: _af_defaultResponseSerializer;
}

- (void)setResponseSerializer:(AFHTTPResponseSerializer<AFURLResponseSerialization> *)responseSerializer {
    objc_setAssociatedObject(self, @selector(responseSerializer), responseSerializer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark -

- (void)loadRequest:(NSURLRequest *)request
         navigation:(WKNavigation * _Nonnull)navigation
           progress:(NSProgress * _Nullable __autoreleasing * _Nullable)progress
            success:(nullable NSString * (^)(NSHTTPURLResponse *response, NSString *HTML))success
            failure:(nullable void (^)(NSError *error))failure {
    // 调用mime方法
    [self loadRequest:request navigation:navigation MIMEType:nil textEncodingName:nil progress:progress success:^NSData * _Nonnull(NSHTTPURLResponse * _Nonnull response, NSData * _Nonnull data) {
        // 设置字符编码方式为UTF8
        NSStringEncoding stringEncoding = NSUTF8StringEncoding;
        // 如果响应对象有文本编码方式, 就将字符编码方式设置为响应的文本编码方式
        if (response.textEncodingName) {
            CFStringEncoding encoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)response.textEncodingName);
            if (encoding != kCFStringEncodingInvalidId) {
                stringEncoding = CFStringConvertEncodingToNSStringEncoding(encoding);
            }
        }
        // 将返回的数据进行编码
        NSString *string = [[NSString alloc] initWithData:data encoding:stringEncoding];
        // 如果设置了成功回调就用block传递数据
        if (success) {
            string = success(response, string);
        }
        // 将字符串编码成二进制数据后返回
        return [string dataUsingEncoding:stringEncoding];
    } failure:failure];
}

- (void)loadRequest:(NSURLRequest *)request
         navigation:(WKNavigation * _Nonnull)navigation
           MIMEType:(nullable NSString *)MIMEType
   textEncodingName:(nullable NSString *)textEncodingName
           progress:(NSProgress * _Nullable __autoreleasing * _Nullable)progress
            success:(nullable NSData * (^)(NSHTTPURLResponse *response, NSData *data))success
            failure:(nullable void (^)(NSError *error))failure {
    NSParameterAssert(request);
    // 如果当前已有任务正在进行或者暂停, 就取消掉这个任务, 并将保存它的属性置空
    if (self.af_URLSessionTask.state == NSURLSessionTaskStateRunning || self.af_URLSessionTask.state == NSURLSessionTaskStateSuspended) {
        [self.af_URLSessionTask cancel];
    }
    self.af_URLSessionTask = nil;
    // 生成任务
    __weak __typeof(self)weakSelf = self;
    __block NSURLSessionDataTask *dataTask;
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    __strong __typeof(weakSelf.navigationDelegate) strongSelfDelegate = strongSelf.navigationDelegate;
    dataTask = [self.sessionManager dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        // 如果出错就调用失败回调block
        if (error) {
            if (failure) {
                failure(error);
            }
        // 如果成功
        } else {
            // 先调用成功回调block
            if (success) {
                success((NSHTTPURLResponse *)response, responseObject);
            }
            // 调用WKWebView加载本地数据的方式加载页面
            [strongSelf loadData:responseObject MIMEType:MIMEType characterEncodingName:textEncodingName baseURL:[dataTask.currentRequest URL]];
            // 调用WKWebView代理中的完成加载方法
            if ([strongSelfDelegate respondsToSelector:@selector(webView:didFinishNavigation:)]) {
                [strongSelfDelegate webView:strongSelf didFinishNavigation:navigation];
            }
        }
    }];
    // 用属性保存任务对象
    self.af_URLSessionTask = dataTask;
    // 如果设置了进度对象, 就获取到网络会话管理者的下载进程对象
    if (progress != nil) {
        *progress = [self.sessionManager downloadProgressForTask:dataTask];
    }
    // 启动任务
    [self.af_URLSessionTask resume];
    // 调用WKWebView代理中的开始加载方法
    if ([strongSelfDelegate respondsToSelector:@selector(webView:didStartProvisionalNavigation:)]) {
        [strongSelfDelegate webView:self didStartProvisionalNavigation:navigation];
    }
}

@end

#endif

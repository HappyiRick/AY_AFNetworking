// UIProgressView+AFNetworking.m
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

#import "UIProgressView+AFNetworking.h"

#import <objc/runtime.h>

#if TARGET_OS_IOS || TARGET_OS_TV

#import "AFURLSessionManager.h"

/// 任务发送字节数量上下文标识
static void * AFTaskCountOfBytesSentContext = &AFTaskCountOfBytesSentContext;
/// 任务接收字节数量上下文标识
static void * AFTaskCountOfBytesReceivedContext = &AFTaskCountOfBytesReceivedContext;

#pragma mark -

@implementation UIProgressView (AFNetworking)

/// 通过关联对象为分类添加属性保存进度条的动画选项
- (BOOL)af_uploadProgressAnimated {
    return [(NSNumber *)objc_getAssociatedObject(self, @selector(af_uploadProgressAnimated)) boolValue];
}

- (void)af_setUploadProgressAnimated:(BOOL)animated {
    objc_setAssociatedObject(self, @selector(af_uploadProgressAnimated), @(animated), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)af_downloadProgressAnimated {
    return [(NSNumber *)objc_getAssociatedObject(self, @selector(af_downloadProgressAnimated)) boolValue];
}

- (void)af_setDownloadProgressAnimated:(BOOL)animated {
    objc_setAssociatedObject(self, @selector(af_downloadProgressAnimated), @(animated), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark -

- (void)setProgressWithUploadProgressOfTask:(NSURLSessionUploadTask *)task
                                   animated:(BOOL)animated
{
    // 如果任务已经执行完就不继续向下执行
    if (task.state == NSURLSessionTaskStateCompleted) {
        return;
    }
    // 通过KVO观察task的state和countOfBytesSent属性
    [task addObserver:self forKeyPath:@"state" options:(NSKeyValueObservingOptions)0 context:AFTaskCountOfBytesSentContext];
    [task addObserver:self forKeyPath:@"countOfBytesSent" options:(NSKeyValueObservingOptions)0 context:AFTaskCountOfBytesSentContext];
    // 保存动画选项
    [self af_setUploadProgressAnimated:animated];
}

- (void)setProgressWithDownloadProgressOfTask:(NSURLSessionDownloadTask *)task
                                     animated:(BOOL)animated
{
    // 如果任务已经执行完就不继续向下执行
    if (task.state == NSURLSessionTaskStateCompleted) {
        return;
    }
    // 通过KVO观察task的state和countOfBytesSent属性
    [task addObserver:self forKeyPath:@"state" options:(NSKeyValueObservingOptions)0 context:AFTaskCountOfBytesReceivedContext];
    [task addObserver:self forKeyPath:@"countOfBytesReceived" options:(NSKeyValueObservingOptions)0 context:AFTaskCountOfBytesReceivedContext];
    // 保存动画选项
    [self af_setDownloadProgressAnimated:animated];
}

#pragma mark - NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(__unused NSDictionary *)change
                       context:(void *)context
{
    // 如果是通过这个分类添加的观察者
    if (context == AFTaskCountOfBytesSentContext || context == AFTaskCountOfBytesReceivedContext) {
        // 如果是task的countOfBytesSent属性发生了变化
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesSent))]) {
            // 如果有要发送的总大小
            if ([object countOfBytesExpectedToSend] > 0) {
                // 主队列异步调用
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 计算当前的发送进度并为控件赋值
                    [self setProgress:[object countOfBytesSent] / ([object countOfBytesExpectedToSend] * 1.0f) animated:self.af_uploadProgressAnimated];
                });
            }
        }
        // 如果是task的countOfBytesReceived属性发生了变化
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesReceived))]) {
            // 如果有要接受的总大小
            if ([object countOfBytesExpectedToReceive] > 0) {
                // 主队列异步调用
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 计算当前的接收进度并为控件赋值
                    [self setProgress:[object countOfBytesReceived] / ([object countOfBytesExpectedToReceive] * 1.0f) animated:self.af_downloadProgressAnimated];
                });
            }
        }
        // 如果是task的state属性发生了变化
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(state))]) {
            // 如果状态变成了已完成, 就移除掉对task属性的观察
            if ([(NSURLSessionTask *)object state] == NSURLSessionTaskStateCompleted) {
                @try {
                    [object removeObserver:self forKeyPath:NSStringFromSelector(@selector(state))];

                    if (context == AFTaskCountOfBytesSentContext) {
                        [object removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesSent))];
                    }

                    if (context == AFTaskCountOfBytesReceivedContext) {
                        [object removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))];
                    }
                }
                @catch (NSException * __unused exception) {}
            }
        }
    }
}

@end

#endif

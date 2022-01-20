// UIImageView+AFNetworking.m
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

#import "UIImageView+AFNetworking.h"

#import <objc/runtime.h>

#if TARGET_OS_IOS || TARGET_OS_TV

#import "AFImageDownloader.h"

@interface UIImageView (_AFNetworking)
/// 拓展属性
@property (readwrite, nonatomic, strong, setter = af_setActiveImageDownloadReceipt:) AFImageDownloadReceipt *af_activeImageDownloadReceipt;
@end

@implementation UIImageView (_AFNetworking)

/// 通过关联对象生成getter && setter 方法
- (AFImageDownloadReceipt *)af_activeImageDownloadReceipt {
    return (AFImageDownloadReceipt *)objc_getAssociatedObject(self, @selector(af_activeImageDownloadReceipt));
}

- (void)af_setActiveImageDownloadReceipt:(AFImageDownloadReceipt *)imageDownloadReceipt {
    objc_setAssociatedObject(self, @selector(af_activeImageDownloadReceipt), imageDownloadReceipt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark -

@implementation UIImageView (AFNetworking)

// 关联对象生成getter方法
+ (AFImageDownloader *)sharedImageDownloader {
    return objc_getAssociatedObject([UIImageView class], @selector(sharedImageDownloader)) ?: [AFImageDownloader defaultInstance];
}

// 关联对象生成setter方法
+ (void)setSharedImageDownloader:(AFImageDownloader *)imageDownloader {
    objc_setAssociatedObject([UIImageView class], @selector(sharedImageDownloader), imageDownloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark -

- (void)setImageWithURL:(NSURL *)url {
    [self setImageWithURL:url placeholderImage:nil];
}

- (void)setImageWithURL:(NSURL *)url
       placeholderImage:(UIImage *)placeholderImage
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];

    [self setImageWithURLRequest:request placeholderImage:placeholderImage success:nil failure:nil];
}

- (void)setImageWithURLRequest:(NSURLRequest *)urlRequest
              placeholderImage:(UIImage *)placeholderImage
                       success:(void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *image))success
                       failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure
{
    // 如果请求对象的链接为空, 就取消掉之前的图片下载任务, 展示占位图, 返回结束
    if ([urlRequest URL] == nil) {
        self.image = placeholderImage;
        if (failure) {
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
            failure(urlRequest, nil, error);
        }
        return;
    }
    // 如果网络请求正在执行就中止
    if ([self isActiveTaskURLEqualToURLRequest:urlRequest]) {
        return;
    }
    // 取消之前的图片下载任务
    [self cancelImageDownloadTask];
    // 获取图片下载器对象
    AFImageDownloader *downloader = [[self class] sharedImageDownloader];
    // 获取图片下载器对象中的图片缓存对象
    id <AFImageRequestCache> imageCache = downloader.imageCache;

    //Use the image from the image cache if it exists
    // 从缓存对象中获取缓存图片
    UIImage *cachedImage = [imageCache imageforRequest:urlRequest withAdditionalIdentifier:nil];
    // 如果有缓存图片
    if (cachedImage) {
        // 如果设置了成功回调block就调用block, 否则就直接设置图片
        if (success) {
            success(urlRequest, nil, cachedImage);
        } else {
            self.image = cachedImage;
        }
        [self clearActiveDownloadInformation];
    // 如果没有缓存图片
    } else {
        // 如果设置了占位图就先展示占位图
        if (placeholderImage) {
            self.image = placeholderImage;
        }
        // 获取UUID, 生成下载封装对象, 并开始下载
        __weak __typeof(self)weakSelf = self;
        NSUUID *downloadID = [NSUUID UUID];
        AFImageDownloadReceipt *receipt;
        receipt = [downloader
                   downloadImageForURLRequest:urlRequest
                   withReceiptID:downloadID
                   success:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, UIImage * _Nonnull responseObject) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                        // 如果是当前控件发起的任务
                       if ([strongSelf.af_activeImageDownloadReceipt.receiptID isEqual:downloadID]) {
                           // 如果设置了成功回调block就调用block, 否则就直接设置图片
                           if (success) {
                               success(request, response, responseObject);
                           } else if (responseObject) {
                               strongSelf.image = responseObject;
                           }
                           // 清除该控件的下载任务信息
                           [strongSelf clearActiveDownloadInformation];
                       }

                   }
                   failure:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, NSError * _Nonnull error) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                        if ([strongSelf.af_activeImageDownloadReceipt.receiptID isEqual:downloadID]) {
                            if (failure) {
                                failure(request, response, error);
                            }
                            [strongSelf clearActiveDownloadInformation];
                        }
                   }];
        // 使用属性保存生成的下载封装对象
        self.af_activeImageDownloadReceipt = receipt;
    }
}

- (void)cancelImageDownloadTask {
    // 如果当前有下载任务
    if (self.af_activeImageDownloadReceipt != nil) {
        // 通过任务封装对象将下载任务取消
        [[self.class sharedImageDownloader] cancelTaskForImageDownloadReceipt:self.af_activeImageDownloadReceipt];
        // 清除该控件的下载任务信息
        [self clearActiveDownloadInformation];
     }
}

- (void)clearActiveDownloadInformation {
    // 将保存下载封装对象的属性置空
    self.af_activeImageDownloadReceipt = nil;
}

- (BOOL)isActiveTaskURLEqualToURLRequest:(NSURLRequest *)urlRequest {
    // 判断属性中保存的下载封装对象的下载链接和传入的请求对象下载链接是否相同
    return [self.af_activeImageDownloadReceipt.task.originalRequest.URL.absoluteString isEqualToString:urlRequest.URL.absoluteString];
}

@end

#endif

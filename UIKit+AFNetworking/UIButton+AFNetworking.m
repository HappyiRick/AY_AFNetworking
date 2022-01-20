// UIButton+AFNetworking.m
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

#import "UIButton+AFNetworking.h"

#import <objc/runtime.h>

#if TARGET_OS_IOS || TARGET_OS_TV

#import "UIImageView+AFNetworking.h"
#import "AFImageDownloader.h"

@interface UIButton (_AFNetworking)
@end

@implementation UIButton (_AFNetworking)

#pragma mark -
// image相关
static char AFImageDownloadReceiptNormal;  // 普通
static char AFImageDownloadReceiptHighlighted; // 高亮
static char AFImageDownloadReceiptSelected; // 已选
static char AFImageDownloadReceiptDisabled; // 禁用

// 通过传入的控件状态返回对应的静态字符
static const char * af_imageDownloadReceiptKeyForState(UIControlState state) {
    switch (state) {
        case UIControlStateHighlighted:
            return &AFImageDownloadReceiptHighlighted;
        case UIControlStateSelected:
            return &AFImageDownloadReceiptSelected;
        case UIControlStateDisabled:
            return &AFImageDownloadReceiptDisabled;
        case UIControlStateNormal:
        default:
            return &AFImageDownloadReceiptNormal;
    }
}

// 通过Runtime的关联对象为分类添加属性的getter
- (AFImageDownloadReceipt *)af_imageDownloadReceiptForState:(UIControlState)state {
    return (AFImageDownloadReceipt *)objc_getAssociatedObject(self, af_imageDownloadReceiptKeyForState(state));
}

// 通过Runtime的关联对象为分类添加属性的setter
- (void)af_setImageDownloadReceipt:(AFImageDownloadReceipt *)imageDownloadReceipt
                           forState:(UIControlState)state
{
    objc_setAssociatedObject(self, af_imageDownloadReceiptKeyForState(state), imageDownloadReceipt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark -
// 背景图片相关
static char AFBackgroundImageDownloadReceiptNormal;
static char AFBackgroundImageDownloadReceiptHighlighted;
static char AFBackgroundImageDownloadReceiptSelected;
static char AFBackgroundImageDownloadReceiptDisabled;

static const char * af_backgroundImageDownloadReceiptKeyForState(UIControlState state) {
    switch (state) {
        case UIControlStateHighlighted:
            return &AFBackgroundImageDownloadReceiptHighlighted;
        case UIControlStateSelected:
            return &AFBackgroundImageDownloadReceiptSelected;
        case UIControlStateDisabled:
            return &AFBackgroundImageDownloadReceiptDisabled;
        case UIControlStateNormal:
        default:
            return &AFBackgroundImageDownloadReceiptNormal;
    }
}

- (AFImageDownloadReceipt *)af_backgroundImageDownloadReceiptForState:(UIControlState)state {
    return (AFImageDownloadReceipt *)objc_getAssociatedObject(self, af_backgroundImageDownloadReceiptKeyForState(state));
}

- (void)af_setBackgroundImageDownloadReceipt:(AFImageDownloadReceipt *)imageDownloadReceipt
                                     forState:(UIControlState)state
{
    objc_setAssociatedObject(self, af_backgroundImageDownloadReceiptKeyForState(state), imageDownloadReceipt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark -

@implementation UIButton (AFNetworking)

// 通过关联对象实现getter 和 setter 方法
+ (AFImageDownloader *)sharedImageDownloader {

    return objc_getAssociatedObject([UIButton class], @selector(sharedImageDownloader)) ?: [AFImageDownloader defaultInstance];
}

+ (void)setSharedImageDownloader:(AFImageDownloader *)imageDownloader {
    objc_setAssociatedObject([UIButton class], @selector(sharedImageDownloader), imageDownloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark -

- (void)setImageForState:(UIControlState)state
                 withURL:(NSURL *)url
{
    [self setImageForState:state withURL:url placeholderImage:nil];
}

- (void)setImageForState:(UIControlState)state
                 withURL:(NSURL *)url
        placeholderImage:(UIImage *)placeholderImage
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];

    [self setImageForState:state withURLRequest:request placeholderImage:placeholderImage success:nil failure:nil];
}

- (void)setImageForState:(UIControlState)state
          withURLRequest:(NSURLRequest *)urlRequest
        placeholderImage:(nullable UIImage *)placeholderImage
                 success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *image))success
                 failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure
{
    // 如果这个网络请求正在进行中就不重复执行
    if ([self isActiveTaskURLEqualToURLRequest:urlRequest forState:state]) {
        return;
    }
    
    // 取消掉这个状态的图片下载任务
    [self cancelImageDownloadTaskForState:state];
    // 实例化图片下载器
    AFImageDownloader *downloader = [[self class] sharedImageDownloader];
    // 获取到图片缓存对象
    id <AFImageRequestCache> imageCache = downloader.imageCache;

    //Use the image from the image cache if it exists
    // 获取到缓存图片
    UIImage *cachedImage = [imageCache imageforRequest:urlRequest withAdditionalIdentifier:nil];
    // 如果有缓存
    if (cachedImage) {
        // 如果设置了成功回调block就调用, 否则就为按钮设置图片
        if (success) {
            success(urlRequest, nil, cachedImage);
        } else {
            [self setImage:cachedImage forState:state];
        }
        [self af_setImageDownloadReceipt:nil forState:state];
    // 如果没有缓存
    } else {
        // 如果有占位图先设置占位图
        if (placeholderImage) {
            [self setImage:placeholderImage forState:state];
        }
        // 开始下载
        __weak __typeof(self)weakSelf = self;
        NSUUID *downloadID = [NSUUID UUID];
        AFImageDownloadReceipt *receipt;
        receipt = [downloader
                   downloadImageForURLRequest:urlRequest
                   withReceiptID:downloadID
                   success:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, UIImage * _Nonnull responseObject) {
                        // 如果是当前按钮的下载回调
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                       if ([[strongSelf af_imageDownloadReceiptForState:state].receiptID isEqual:downloadID]) {
                           // 如果设置了成功回调block就调用, 否则就为按钮设置图片
                           if (success) {
                               success(request, response, responseObject);
                           } else if (responseObject) {
                               [strongSelf setImage:responseObject forState:state];
                           }
                           // 将保存下载封装对象的属性置nil
                           [strongSelf af_setImageDownloadReceipt:nil forState:state];
                       }

                   }
                   failure:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, NSError * _Nonnull error) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                        // 如果是当前按钮的下载回调
                       if ([[strongSelf af_imageDownloadReceiptForState:state].receiptID isEqual:downloadID]) {
                           // 失败回调block
                           if (failure) {
                               failure(request, response, error);
                           }
                           // 将保存下载封装对象的属性置nil
                           [strongSelf  af_setImageDownloadReceipt:nil forState:state];
                       }
                   }];
        // 用分类的属性保存图片下载封装对象
        [self af_setImageDownloadReceipt:receipt forState:state];
    }
}

#pragma mark -

- (void)setBackgroundImageForState:(UIControlState)state
                           withURL:(NSURL *)url
{
    [self setBackgroundImageForState:state withURL:url placeholderImage:nil];
}

- (void)setBackgroundImageForState:(UIControlState)state
                           withURL:(NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholderImage
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];

    [self setBackgroundImageForState:state withURLRequest:request placeholderImage:placeholderImage success:nil failure:nil];
}

- (void)setBackgroundImageForState:(UIControlState)state
                    withURLRequest:(NSURLRequest *)urlRequest
                  placeholderImage:(nullable UIImage *)placeholderImage
                           success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *image))success
                           failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure
{
    // 如果正在下载则直接中止
    if ([self isActiveBackgroundTaskURLEqualToURLRequest:urlRequest forState:state]) {
        return;
    }
    // 取消当前状态的背景图片下载任务
    [self cancelBackgroundImageDownloadTaskForState:state];
    // 图片下载器实例
    AFImageDownloader *downloader = [[self class] sharedImageDownloader];
    // 获取到图片缓存对象
    id <AFImageRequestCache> imageCache = downloader.imageCache;
    // 获取到缓存图片
    //Use the image from the image cache if it exists
    UIImage *cachedImage = [imageCache imageforRequest:urlRequest withAdditionalIdentifier:nil];
    // 如果有缓存
    if (cachedImage) {
        // 如果设置了成功回调block就调用, 否则就为按钮设置图片
        if (success) {
            success(urlRequest, nil, cachedImage);
        } else {
            [self setBackgroundImage:cachedImage forState:state];
        }
        [self af_setBackgroundImageDownloadReceipt:nil forState:state];
    // 如果没有缓存
    } else {
        // 如果有占位图先设置占位图
        if (placeholderImage) {
            [self setBackgroundImage:placeholderImage forState:state];
        }
        // 开始下载
        __weak __typeof(self)weakSelf = self;
        NSUUID *downloadID = [NSUUID UUID];
        AFImageDownloadReceipt *receipt;
        receipt = [downloader
                   downloadImageForURLRequest:urlRequest
                   withReceiptID:downloadID
                   success:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, UIImage * _Nonnull responseObject) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                        // 如果设置了成功回调block就调用, 否则就为按钮设置图片
                       if ([[strongSelf af_backgroundImageDownloadReceiptForState:state].receiptID isEqual:downloadID]) {
                           if (success) {
                               success(request, response, responseObject);
                           } else if (responseObject) {
                               [strongSelf setBackgroundImage:responseObject forState:state];
                           }
                           // 将保存下载封装对象的属性置nil
                           [strongSelf af_setBackgroundImageDownloadReceipt:nil forState:state];
                       }

                   }
                   failure:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, NSError * _Nonnull error) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                        // 如果是当前按钮的下载回调
                       if ([[strongSelf af_backgroundImageDownloadReceiptForState:state].receiptID isEqual:downloadID]) {
                           // 失败回调block
                           if (failure) {
                               failure(request, response, error);
                           }
                           // 将保存下载封装对象的属性置nil
                           [strongSelf  af_setBackgroundImageDownloadReceipt:nil forState:state];
                       }
                   }];
        // 用分类的属性保存图片下载封装对象
        [self af_setBackgroundImageDownloadReceipt:receipt forState:state];
    }
}

#pragma mark -

- (void)cancelImageDownloadTaskForState:(UIControlState)state {
    // 通过状态获取到图片下载封装对象
    AFImageDownloadReceipt *receipt = [self af_imageDownloadReceiptForState:state];
    if (receipt != nil) {
        // 根据下载封装对象取消对应的图片下载任务
        [[self.class sharedImageDownloader] cancelTaskForImageDownloadReceipt:receipt];
        // 把保存图片下载封装对象的属性置nil
        [self af_setImageDownloadReceipt:nil forState:state];
    }
}

- (void)cancelBackgroundImageDownloadTaskForState:(UIControlState)state {
    // 通过状态获取到图片下载封装对象
    AFImageDownloadReceipt *receipt = [self af_backgroundImageDownloadReceiptForState:state];
    if (receipt != nil) {
        // 根据下载封装对象取消对应的图片下载任务
        [[self.class sharedImageDownloader] cancelTaskForImageDownloadReceipt:receipt];
        // 把保存图片下载封装对象的属性置nil
        [self af_setBackgroundImageDownloadReceipt:nil forState:state];
    }
}

/// 判断图片下载请求是否已经正在进行中
- (BOOL)isActiveTaskURLEqualToURLRequest:(NSURLRequest *)urlRequest forState:(UIControlState)state {
    // 获取图片下载封装对象
    AFImageDownloadReceipt *receipt = [self af_imageDownloadReceiptForState:state];
    // 根据两者的谅解是否相同进行比较
    return [receipt.task.originalRequest.URL.absoluteString isEqualToString:urlRequest.URL.absoluteString];
}

/// 判断背景图片下载请求是否已经正在进行中
- (BOOL)isActiveBackgroundTaskURLEqualToURLRequest:(NSURLRequest *)urlRequest forState:(UIControlState)state {
    // 获取图片下载封装对象
    AFImageDownloadReceipt *receipt = [self af_backgroundImageDownloadReceiptForState:state];
    // 根据两者的谅解是否相同进行比较
    return [receipt.task.originalRequest.URL.absoluteString isEqualToString:urlRequest.URL.absoluteString];
}


@end

#endif

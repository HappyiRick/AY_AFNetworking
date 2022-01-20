// AFAutoPurgingImageCache.m
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

#import "AFAutoPurgingImageCache.h"

@interface AFCachedImage : NSObject
/// 被缓存的图片
@property (nonatomic, strong) UIImage *image;
/// 被缓存图片的识别
@property (nonatomic, copy) NSString *identifier;
/// 被缓存图片的大小
@property (nonatomic, assign) UInt64 totalBytes;
/// 被缓存图片最后访问的时间
@property (nonatomic, strong) NSDate *lastAccessDate;
/// 当前内存使用大小
@property (nonatomic, assign) UInt64 currentMemoryUsage;

@end

@implementation AFCachedImage

- (instancetype)initWithImage:(UIImage *)image identifier:(NSString *)identifier {
    if (self = [self init]) {
        // 属性保存参数
        self.image = image;
        self.identifier = identifier;
        // 获取图片的像素尺寸, 并以每像素4字节计算图片大小
        CGSize imageSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
        CGFloat bytesPerPixel = 4.0;
        CGFloat bytesPerSize = imageSize.width * imageSize.height;
        self.totalBytes = (UInt64)bytesPerPixel * (UInt64)bytesPerSize;
        // 获取当前时间保存为最后访问时间
        self.lastAccessDate = [NSDate date];
    }
    return self;
}

- (UIImage *)accessImage {
    // 记录获取被缓存图片的时间
    self.lastAccessDate = [NSDate date];
    return self.image;
}

- (NSString *)description {
    // 定制打印数据
    NSString *descriptionString = [NSString stringWithFormat:@"Idenfitier: %@  lastAccessDate: %@ ", self.identifier, self.lastAccessDate];
    return descriptionString;

}

@end

@interface AFAutoPurgingImageCache ()
/// 使用可变字典保存缓存图片
@property (nonatomic, strong) NSMutableDictionary <NSString* , AFCachedImage*> *cachedImages;
/// 当前内存使用量
@property (nonatomic, assign) UInt64 currentMemoryUsage;
/// 同步队列
@property (nonatomic, strong) dispatch_queue_t synchronizationQueue;
@end

@implementation AFAutoPurgingImageCache

- (instancetype)init {
    /// 初始化方法
    return [self initWithMemoryCapacity:100 * 1024 * 1024 preferredMemoryCapacity:60 * 1024 * 1024];
}

- (instancetype)initWithMemoryCapacity:(UInt64)memoryCapacity preferredMemoryCapacity:(UInt64)preferredMemoryCapacity {
    if (self = [super init]) {
        /// 初始化属性
        self.memoryCapacity = memoryCapacity;
        self.preferredMemoryUsageAfterPurge = preferredMemoryCapacity;
        self.cachedImages = [[NSMutableDictionary alloc] init];
        /// 自定义并发队列
        NSString *queueName = [NSString stringWithFormat:@"com.alamofire.autopurgingimagecache-%@", [[NSUUID UUID] UUIDString]];
        self.synchronizationQueue = dispatch_queue_create([queueName cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_CONCURRENT);
        /// 发送通知监听内存警告
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(removeAllImages)
         name:UIApplicationDidReceiveMemoryWarningNotification
         object:nil];

    }
    return self;
}

- (void)dealloc {
    // 移除通知监听
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UInt64)memoryUsage {
    // 同步并发队列获取当前内存使用量
    __block UInt64 result = 0;
    dispatch_sync(self.synchronizationQueue, ^{
        result = self.currentMemoryUsage;
    });
    return result;
}

/// AFImageCache协议方法实现
- (void)addImage:(UIImage *)image withIdentifier:(NSString *)identifier {
    // 等待之前队列中的任务完成后再执行以下代码
    dispatch_barrier_async(self.synchronizationQueue, ^{
        // 创建AFCachedImage对象
        AFCachedImage *cacheImage = [[AFCachedImage alloc] initWithImage:image identifier:identifier];
        // 检查缓存中是否已经有指定标识符的缓存图片, 如果有就删除
        AFCachedImage *previousCachedImage = self.cachedImages[identifier];
        if (previousCachedImage != nil) {
            self.currentMemoryUsage -= previousCachedImage.totalBytes;
        }
        // 保存图片
        self.cachedImages[identifier] = cacheImage;
        // 更新缓存
        self.currentMemoryUsage += cacheImage.totalBytes;
    });
    // 等待之前队列中的任务完成后再执行以下代码
    dispatch_barrier_async(self.synchronizationQueue, ^{
        // 如果当前内存使用量已经超出了最大内存使用量
        if (self.currentMemoryUsage > self.memoryCapacity) {
            // 计算需要清除的缓存量
            UInt64 bytesToPurge = self.currentMemoryUsage - self.preferredMemoryUsageAfterPurge;
            // 获取到目前所有的图片
            NSMutableArray <AFCachedImage*> *sortedImages = [NSMutableArray arrayWithArray:self.cachedImages.allValues];
            // 设置排序描述对象为按照属性lastAccessDate的升序排列
            NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"lastAccessDate"
                                                                           ascending:YES];
            // 按照排序描述对象进行重排
            [sortedImages sortUsingDescriptors:@[sortDescriptor]];
            // 设置临时变量保存已清除缓存的大小
            UInt64 bytesPurged = 0;
            // 遍历已缓存的图片
            for (AFCachedImage *cachedImage in sortedImages) {
                // 从缓存中删除指定标识符的图片
                [self.cachedImages removeObjectForKey:cachedImage.identifier];
                // 计算已清除缓存的大小
                bytesPurged += cachedImage.totalBytes;
                // 如果已清除缓存量满足了需要清除的缓存量, 就跳出循环不再清除
                if (bytesPurged >= bytesToPurge) {
                    break;
                }
            }
            // 重新计算清除缓存后的当前内存用量
            self.currentMemoryUsage -= bytesPurged;
        }
    });
}

- (BOOL)removeImageWithIdentifier:(NSString *)identifier {
    __block BOOL removed = NO;
    dispatch_barrier_sync(self.synchronizationQueue, ^{
        // 获取到指定标识符的图片缓存对象
        AFCachedImage *cachedImage = self.cachedImages[identifier];
        if (cachedImage != nil) {
            // 如果有这张图片就从缓存中删除并重新计算当前内存使用量
            [self.cachedImages removeObjectForKey:identifier];
            self.currentMemoryUsage -= cachedImage.totalBytes;
            removed = YES;
        }
    });
    return removed;
}

- (BOOL)removeAllImages {
    __block BOOL removed = NO;
    dispatch_barrier_sync(self.synchronizationQueue, ^{
        if (self.cachedImages.count > 0) {
            // 删除所有图片缓存并置零内存使用量
            [self.cachedImages removeAllObjects];
            self.currentMemoryUsage = 0;
            removed = YES;
        }
    });
    return removed;
}

- (nullable UIImage *)imageWithIdentifier:(NSString *)identifier {
    __block UIImage *image = nil;
    dispatch_sync(self.synchronizationQueue, ^{
        // 获取到指定标识符的图片缓存对象
        AFCachedImage *cachedImage = self.cachedImages[identifier];
        image = [cachedImage accessImage];
    });
    return image;
}

/// AFImageRequestCache 协议方法实现
- (void)addImage:(UIImage *)image forRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    // 用request和identifier生成一个新标识符后添加图片
    [self addImage:image withIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}

- (BOOL)removeImageforRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    // 移除用request和identifier生成一个新标识符的图片
    return [self removeImageWithIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}

- (nullable UIImage *)imageforRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    // 获取用request和identifier生成一个新标识符的图片
    return [self imageWithIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}

- (NSString *)imageCacheKeyFromURLRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)additionalIdentifier {
    // 将标识符拼在请求链接后面组成字符串
    NSString *key = request.URL.absoluteString;
    if (additionalIdentifier != nil) {
        key = [key stringByAppendingString:additionalIdentifier];
    }
    return key;
}

- (BOOL)shouldCacheImage:(UIImage *)image forRequest:(NSURLRequest *)request withAdditionalIdentifier:(nullable NSString *)identifier {
    // 只返回YES
    return YES;
}

@end

#endif

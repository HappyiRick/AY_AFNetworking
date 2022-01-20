// AFURLResponseSerialization.m
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

#import "AFURLResponseSerialization.h"

#import <TargetConditionals.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#elif TARGET_OS_WATCH
#import <WatchKit/WatchKit.h>
#elif defined(__MAC_OS_X_VERSION_MIN_REQUIRED)
#import <Cocoa/Cocoa.h>
#endif

NSString * const AFURLResponseSerializationErrorDomain = @"com.alamofire.error.serialization.response";
NSString * const AFNetworkingOperationFailingURLResponseErrorKey = @"com.alamofire.serialization.response.error.response";
NSString * const AFNetworkingOperationFailingURLResponseDataErrorKey = @"com.alamofire.serialization.response.error.data";

/// 该方法用于将一个NSError对象作为另一个NSError对象的附属NSError对象, 并将其放到userInfo属性NSUnderlyingErrorKey键对应的值中
static NSError * AFErrorWithUnderlyingError(NSError *error, NSError *underlyingError) {
    // 没有error为空的话就直接返回underlyingError
    if (!error) {
        return underlyingError;
    }
    // 如果underlyingError为空或者error中已经有附属underlyingError就直接返回error
    if (!underlyingError || error.userInfo[NSUnderlyingErrorKey]) {
        return error;
    }
    // 获取error的userInfo, 并将underlyingError作为键NSUnderlyingErrorKey对应的值赋给error
    NSMutableDictionary *mutableUserInfo = [error.userInfo mutableCopy];
    mutableUserInfo[NSUnderlyingErrorKey] = underlyingError;

    return [[NSError alloc] initWithDomain:error.domain code:error.code userInfo:mutableUserInfo];
}

/// 该方法用来判断error或者underlyingError是否为指定code和domain的error
static BOOL AFErrorOrUnderlyingErrorHasCodeInDomain(NSError *error, NSInteger code, NSString *domain) {
    // 如果error符合指定条件则返回YES
    if ([error.domain isEqualToString:domain] && error.code == code) {
        return YES;
    // 如果error不符合但是有underlyingError, 则递归调用本方法
    } else if (error.userInfo[NSUnderlyingErrorKey]) {
        return AFErrorOrUnderlyingErrorHasCodeInDomain(error.userInfo[NSUnderlyingErrorKey], code, domain);
    }
    // 如果都不满足就返回NO
    return NO;
}

/// 该方法用于过滤解析后的json数据中NSDictionary类型数据值为Null的键
id AFJSONObjectByRemovingKeysWithNullValues(id JSONObject, NSJSONReadingOptions readingOptions) {
    // 如果解析后的json数据是NSArray类型的
    if ([JSONObject isKindOfClass:[NSArray class]]) {
        // 遍历元素如果还是NSArray类型的就递归调用本方法直至元素不为NSArray类型
        NSMutableArray *mutableArray = [NSMutableArray arrayWithCapacity:[(NSArray *)JSONObject count]];
        for (id value in (NSArray *)JSONObject) {
            if (![value isEqual:[NSNull null]]) {
                [mutableArray addObject:AFJSONObjectByRemovingKeysWithNullValues(value, readingOptions)];
            }
        }
        // 根据传入参数的可变性来返回对应可变性的NSArray对象
        return (readingOptions & NSJSONReadingMutableContainers) ? mutableArray : [NSArray arrayWithArray:mutableArray];
    // 如果解析后的json数据是NSDictionary类型的
    } else if ([JSONObject isKindOfClass:[NSDictionary class]]) {
        // 遍历所有的key并取出对应的value
        NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionaryWithDictionary:JSONObject];
        for (id <NSCopying> key in [(NSDictionary *)JSONObject allKeys]) {
            id value = (NSDictionary *)JSONObject[key];
            // 如果value不存在或者是NSNull类型的对象,就将其移除
            if (!value || [value isEqual:[NSNull null]]) {
                [mutableDictionary removeObjectForKey:key];
            // 如果value是NSArray或者NSDictionary类型的对象就递归调用本方法直至元素不为NSArray或者NSDictionary类型的对象
            } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
                mutableDictionary[key] = AFJSONObjectByRemovingKeysWithNullValues(value, readingOptions);
            }
        }
        // 根据传入参数的可变性来返回对应可变性的NSDictionary对象
        return (readingOptions & NSJSONReadingMutableContainers) ? mutableDictionary : [NSDictionary dictionaryWithDictionary:mutableDictionary];
    }
    // 如果不是NSArray或者NSDictionary类型的对象就直接返回
    return JSONObject;
}

@implementation AFHTTPResponseSerializer

+ (instancetype)serializer {
    // 实例化
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    
    // 可接受的状态码为200～299之间
    self.acceptableStatusCodes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 100)];
    self.acceptableContentTypes = nil;

    return self;
}

#pragma mark -

- (BOOL)validateResponse:(NSHTTPURLResponse *)response
                    data:(NSData *)data
                   error:(NSError * __autoreleasing *)error
{
    // 设置临时变量
    BOOL responseIsValid = YES;
    NSError *validationError = nil;
    // 如果response有值,并且response是NSHTTPURLResponse类型的对象
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        // 如果设置了可接受的ContentTypes, 并且响应的content-type不再可接受的范围内, 并且响应的content-type有值或者返回了数据
        if (self.acceptableContentTypes && ![self.acceptableContentTypes containsObject:[response MIMEType]] &&
            !([response MIMEType] == nil && [data length] == 0)) {
            //如果返回了数据,并且响应有URL
            if ([data length] > 0 && [response URL]) {
                // 拼接错误信息
                NSMutableDictionary *mutableUserInfo = [@{
                                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: unacceptable content-type: %@", @"AFNetworking", nil), [response MIMEType]],
                                                          NSURLErrorFailingURLErrorKey:[response URL],
                                                          AFNetworkingOperationFailingURLResponseErrorKey: response,
                                                        } mutableCopy];
                if (data) {
                    mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
                }
                // 处理错误信息,将之前的错误信息和最新的错误信息合并
                validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:mutableUserInfo], validationError);
            }

            responseIsValid = NO;
        }
        // 如果设置了可接受状态码,并且响应的状态码不在可接受的范围内, 并且响应有URL
        if (self.acceptableStatusCodes && ![self.acceptableStatusCodes containsIndex:(NSUInteger)response.statusCode] && [response URL]) {
            NSMutableDictionary *mutableUserInfo = [@{
                                               NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: %@ (%ld)", @"AFNetworking", nil), [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], (long)response.statusCode],
                                               NSURLErrorFailingURLErrorKey:[response URL],
                                               AFNetworkingOperationFailingURLResponseErrorKey: response,
                                       } mutableCopy];

            if (data) {
                mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
            }
            // 处理错误信息, 将之前的错误信息和最新的错误信息合并
            validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorBadServerResponse userInfo:mutableUserInfo], validationError);

            responseIsValid = NO;
        }
    }
    // 如果传了NSError对象,并且响应无效,就赋值后返回错误信息
    if (error && !responseIsValid) {
        *error = validationError;
    }

    return responseIsValid;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 作为基类, 仅仅实现了对响应和数据
    [self validateResponse:(NSHTTPURLResponse *)response data:data error:error];

    return data;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [self init];
    if (!self) {
        return nil;
    }

    self.acceptableStatusCodes = [decoder decodeObjectOfClass:[NSIndexSet class] forKey:NSStringFromSelector(@selector(acceptableStatusCodes))];
    self.acceptableContentTypes = [decoder decodeObjectOfClass:[NSSet class] forKey:NSStringFromSelector(@selector(acceptableContentTypes))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.acceptableStatusCodes forKey:NSStringFromSelector(@selector(acceptableStatusCodes))];
    [coder encodeObject:self.acceptableContentTypes forKey:NSStringFromSelector(@selector(acceptableContentTypes))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFHTTPResponseSerializer *serializer = [[[self class] allocWithZone:zone] init];
    serializer.acceptableStatusCodes = [self.acceptableStatusCodes copyWithZone:zone];
    serializer.acceptableContentTypes = [self.acceptableContentTypes copyWithZone:zone];

    return serializer;
}

@end

#pragma mark -

@implementation AFJSONResponseSerializer

+ (instancetype)serializer {
    // 重写父类方法, 以不选择json解析选项的方式调用了自己的实例化工程方法
    return [self serializerWithReadingOptions:(NSJSONReadingOptions)0];
}

+ (instancetype)serializerWithReadingOptions:(NSJSONReadingOptions)readingOptions {
    // 实例化本类对象指定json解析选项并返回
    AFJSONResponseSerializer *serializer = [[self alloc] init];
    serializer.readingOptions = readingOptions;

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 设置了可接受的Content-Type
    self.acceptableContentTypes = [NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 如果服务器返回的数据验证失败
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        // 如果验证失败并且没有错误信息就直接返回
        // 如果验证失败并且返回的数据类型无法解析就直接返回
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }
    // 为了解决在Safari的一个bug, 如果返回的数据为空或者是一个空格就直接返回
    // Workaround for behavior of Rails to return a single space for `head :ok` (a workaround for a bug in Safari), which is not interpreted as valid input by NSJSONSerialization.
    // See https://github.com/rails/rails/issues/1742
    BOOL isSpace = [data isEqualToData:[NSData dataWithBytes:" " length:1]];
    
    if (data.length == 0 || isSpace) {
        return nil;
    }
    // 解析服务器返回的二进制数据
    NSError *serializationError = nil;
    
    id responseObject = [NSJSONSerialization JSONObjectWithData:data options:self.readingOptions error:&serializationError];
    // 如果没有解析后的数据就直接返回
    if (!responseObject)
    {
        // 如果传入了错误信息参数
        if (error) {
            // 就将传入的错误信息添加到serializationError 的 NSUnderlyingErrorKey 字段中
            *error = AFErrorWithUnderlyingError(serializationError, *error);
        }
        return nil;
    }
    // 如果想要过滤NSNull, 就进行过滤
    if (self.removesKeysWithNullValues) {
        return AFJSONObjectByRemovingKeysWithNullValues(responseObject, self.readingOptions);
    }

    return responseObject;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.readingOptions = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(readingOptions))] unsignedIntegerValue];
    self.removesKeysWithNullValues = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(removesKeysWithNullValues))] boolValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:@(self.readingOptions) forKey:NSStringFromSelector(@selector(readingOptions))];
    [coder encodeObject:@(self.removesKeysWithNullValues) forKey:NSStringFromSelector(@selector(removesKeysWithNullValues))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFJSONResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.readingOptions = self.readingOptions;
    serializer.removesKeysWithNullValues = self.removesKeysWithNullValues;

    return serializer;
}

@end

#pragma mark -

@implementation AFXMLParserResponseSerializer

+ (instancetype)serializer {
    // 实例化对象
    AFXMLParserResponseSerializer *serializer = [[self alloc] init];

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 设置了可接受的Content-Type
    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"application/xml", @"text/xml", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSHTTPURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 如果服务器返回的数据验证失败
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        // 如果验证失败并且没有错误信息就直接返回
        // 如果验证失败并且返回的数据类型无法解析就直接返回
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }
    // 返回NSXMLParser对象
    return [[NSXMLParser alloc] initWithData:data];
}

@end

#pragma mark -

#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED

@implementation AFXMLDocumentResponseSerializer

+ (instancetype)serializer {
    // 调用本类的实例化工厂方法
    return [self serializerWithXMLDocumentOptions:0];
}

+ (instancetype)serializerWithXMLDocumentOptions:(NSUInteger)mask {
    // 实例化对象并设置参数
    AFXMLDocumentResponseSerializer *serializer = [[self alloc] init];
    serializer.options = mask;
    // 返回对象
    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 设置了可接受的Content-Type
    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"application/xml", @"text/xml", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 如果服务器返回的数据验证失败
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        // 如果验证失败并且没有错误信息就直接返回
        // 如果验证失败并且返回的数据类型无法解析就直接返回
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }
    // 实例化NSXMLDocument对象
    NSError *serializationError = nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithData:data options:self.options error:&serializationError];
    // 如果实例化没有成功就直接返回
    if (!document)
    {
        // 如果传入了错误信息参数
        if (error) {
            // 就将传入的错误信息添加到serializationError的NSUnderlyingErrorKey字段中
            *error = AFErrorWithUnderlyingError(serializationError, *error);
        }
        return nil;
    }
    
    return document;
}

#pragma mark - NSSecureCoding

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.options = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(options))] unsignedIntegerValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:@(self.options) forKey:NSStringFromSelector(@selector(options))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFXMLDocumentResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.options = self.options;

    return serializer;
}

@end

#endif

#pragma mark -

@implementation AFPropertyListResponseSerializer

+ (instancetype)serializer {
    // 调用本类的实例化工厂方法
    return [self serializerWithFormat:NSPropertyListXMLFormat_v1_0 readOptions:0];
}

+ (instancetype)serializerWithFormat:(NSPropertyListFormat)format
                         readOptions:(NSPropertyListReadOptions)readOptions
{
    // 实例化对象并设置参数
    AFPropertyListResponseSerializer *serializer = [[self alloc] init];
    serializer.format = format;
    serializer.readOptions = readOptions;

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 设置了可接受的Content-Type
    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"application/x-plist", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 如果服务器返回的数据验证失败
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        // 如果验证失败并且没有错误信息就直接返回
        // 如果验证失败并且返回的数据类型无法解析就直接返回
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }
    // 如果没有数据就直接返回
    if (!data) {
        return nil;
    }
    // 实例化NSPropertyListSerialization对象解析data
    NSError *serializationError = nil;
    
    id responseObject = [NSPropertyListSerialization propertyListWithData:data options:self.readOptions format:NULL error:&serializationError];
    // 如果没有解析成功就直接返回
    if (!responseObject)
    {
        if (error) {
            // 就将传入的错误信息添加到serializationError的NSUnderlyingErrorKey字段中
            *error = AFErrorWithUnderlyingError(serializationError, *error);
        }
        return nil;
    }

    return responseObject;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.format = (NSPropertyListFormat)[[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(format))] unsignedIntegerValue];
    self.readOptions = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(readOptions))] unsignedIntegerValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:@(self.format) forKey:NSStringFromSelector(@selector(format))];
    [coder encodeObject:@(self.readOptions) forKey:NSStringFromSelector(@selector(readOptions))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFPropertyListResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.format = self.format;
    serializer.readOptions = self.readOptions;

    return serializer;
}

@end

#pragma mark -

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

@interface UIImage (AFNetworkingSafeImageLoading)
/// 利用二进制数据安全生成图片对象的方法
+ (UIImage *)af_safeImageWithData:(NSData *)data;
@end
/// 声明了一个锁对象用于安全生成图片
static NSLock* imageLock = nil;

@implementation UIImage (AFNetworkingSafeImageLoading)

+ (UIImage *)af_safeImageWithData:(NSData *)data {
    // 声明图片变量
    UIImage* image = nil;
    /// 利用GCD仅实例化一遍锁对象
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageLock = [[NSLock alloc] init];
    });
    // 安全的利用二进制数据生成图片对象
    [imageLock lock];
    image = [UIImage imageWithData:data];
    [imageLock unlock];
    return image;
}

@end

/// 生成对应缩放因子的图片
static UIImage * AFImageWithDataAtScale(NSData *data, CGFloat scale) {
    // 根据二进制数据安全生成图片对象
    UIImage *image = [UIImage af_safeImageWithData:data];
    // 如果是gif图就直接返回图片对象
    if (image.images) {
        return image;
    }
    // 生成对应缩放因子的图片
    return [[UIImage alloc] initWithCGImage:[image CGImage] scale:scale orientation:image.imageOrientation];
}

/// 生成对应缩放因子的图片并进行解压
static UIImage * AFInflatedImageFromResponseWithDataAtScale(NSHTTPURLResponse *response, NSData *data, CGFloat scale) {
    // 如果没有数据就直接返回
    if (!data || [data length] == 0) {
        return nil;
    }
    // 创建画布和图片数据提供者
    CGImageRef imageRef = NULL;
    CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    // 如果是png格式则直接解压
    if ([response.MIMEType isEqualToString:@"image/png"]) {
        imageRef = CGImageCreateWithPNGDataProvider(dataProvider,  NULL, true, kCGRenderingIntentDefault);
    // 如果是jpg格式
    } else if ([response.MIMEType isEqualToString:@"image/jpeg"]) {
        // 先进行解压
        imageRef = CGImageCreateWithJPEGDataProvider(dataProvider, NULL, true, kCGRenderingIntentDefault);
        // 如果解压成功
        if (imageRef) {
            CGColorSpaceRef imageColorSpace = CGImageGetColorSpace(imageRef);
            CGColorSpaceModel imageColorSpaceModel = CGColorSpaceGetModel(imageColorSpace);
            // 如果jpg的色彩空间是CMKY而不是RGB的话, 不进行解压
            // CGImageCreateWithJPEGDataProvider does not properly handle CMKY, so fall back to AFImageWithDataAtScale
            if (imageColorSpaceModel == kCGColorSpaceModelCMYK) {
                CGImageRelease(imageRef);
                imageRef = NULL;
            }
        }
    }
    // 释放图片提供者
    CGDataProviderRelease(dataProvider);
    // 按照缩放因子生成对应的图片
    UIImage *image = AFImageWithDataAtScale(data, scale);
    // 如果没有解压成功
    if (!imageRef) {
        // 如果是gif图或者没有生成图片就直接返回
        if (image.images || !image) {
            return image;
        }
        // 如果没有生成图片画布就直接返回
        imageRef = CGImageCreateCopy([image CGImage]);
        if (!imageRef) {
            return nil;
        }
    }
    // 获取图片尺寸和一个像素占用的字节数
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    // 如果图片太大或这一个像素占用的字节超过8就不解压了
    if (width * height > 1024 * 1024 || bitsPerComponent > 8) {
        CGImageRelease(imageRef);

        return image;
    }
    // 配置绘图上下文的参数
    // CGImageGetBytesPerRow() calculates incorrectly in iOS 5.0, so defer to CGBitmapContextCreate
    size_t bytesPerRow = 0;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGColorSpaceModel colorSpaceModel = CGColorSpaceGetModel(colorSpace);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);

    if (colorSpaceModel == kCGColorSpaceModelRGB) {
        uint32_t alpha = (bitmapInfo & kCGBitmapAlphaInfoMask);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
        if (alpha == kCGImageAlphaNone) {
            bitmapInfo &= ~kCGBitmapAlphaInfoMask;
            bitmapInfo |= kCGImageAlphaNoneSkipFirst;
        } else if (!(alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast)) {
            bitmapInfo &= ~kCGBitmapAlphaInfoMask;
            bitmapInfo |= kCGImageAlphaPremultipliedFirst;
        }
#pragma clang diagnostic pop
    }
    // 生成绘图上下文
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, bitsPerComponent, bytesPerRow, colorSpace, bitmapInfo);
    // 释放色彩空间
    CGColorSpaceRelease(colorSpace);
    // 如果没有成功生成绘图上下文就释放画布并直接返回
    if (!context) {
        CGImageRelease(imageRef);

        return image;
    }
    // 绘制图片
    CGContextDrawImage(context, CGRectMake(0.0f, 0.0f, width, height), imageRef);
    CGImageRef inflatedImageRef = CGBitmapContextCreateImage(context);
    // 释放绘图上下文
    CGContextRelease(context);
    // 生成图片
    UIImage *inflatedImage = [[UIImage alloc] initWithCGImage:inflatedImageRef scale:scale orientation:image.imageOrientation];
    // 释放画布
    CGImageRelease(inflatedImageRef);
    CGImageRelease(imageRef);

    return inflatedImage;
}
#endif


@implementation AFImageResponseSerializer

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 设置了可支持的content-Type
    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"image/tiff", @"image/jpeg", @"image/gif", @"image/png", @"image/ico", @"image/x-icon", @"image/bmp", @"image/x-bmp", @"image/x-xbitmap", @"image/x-win-bitmap", nil];

#if TARGET_OS_IOS || TARGET_OS_TV
    self.imageScale = [[UIScreen mainScreen] scale];
    self.automaticallyInflatesResponseImage = YES;
#elif TARGET_OS_WATCH
    self.imageScale = [[WKInterfaceDevice currentDevice] screenScale];
    self.automaticallyInflatesResponseImage = YES;
#endif

    return self;
}

#pragma mark - AFURLResponseSerializer

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 如果服务器返回的数据验证失败
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        // 如果验证失败并且没有错误信息就直接返回
        // 如果验证失败并且返回的数据类型无法解析就直接返回
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }
    // 在移动端需要手动解压
#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
    // 如果设置了自动解压则进行解压, 否则就直接生成
    if (self.automaticallyInflatesResponseImage) {
        return AFInflatedImageFromResponseWithDataAtScale((NSHTTPURLResponse *)response, data, self.imageScale);
    } else {
        return AFImageWithDataAtScale(data, self.imageScale);
    }
    // 在MAC上可以直接调用系统方法解压
#else
    // Ensure that the image is set to it's correct pixel width and height
    NSBitmapImageRep *bitimage = [[NSBitmapImageRep alloc] initWithData:data];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize([bitimage pixelsWide], [bitimage pixelsHigh])];
    [image addRepresentation:bitimage];

    return image;
    // 否则就直接返回
#endif

    return nil;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

#if TARGET_OS_IOS  || TARGET_OS_TV || TARGET_OS_WATCH
    NSNumber *imageScale = [decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(imageScale))];
#if CGFLOAT_IS_DOUBLE
    self.imageScale = [imageScale doubleValue];
#else
    self.imageScale = [imageScale floatValue];
#endif

    self.automaticallyInflatesResponseImage = [decoder decodeBoolForKey:NSStringFromSelector(@selector(automaticallyInflatesResponseImage))];
#endif

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
    [coder encodeObject:@(self.imageScale) forKey:NSStringFromSelector(@selector(imageScale))];
    [coder encodeBool:self.automaticallyInflatesResponseImage forKey:NSStringFromSelector(@selector(automaticallyInflatesResponseImage))];
#endif
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFImageResponseSerializer *serializer = [super copyWithZone:zone];

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
    serializer.imageScale = self.imageScale;
    serializer.automaticallyInflatesResponseImage = self.automaticallyInflatesResponseImage;
#endif

    return serializer;
}

@end

#pragma mark -

@interface AFCompoundResponseSerializer ()
/// 响应解析对象数组
@property (readwrite, nonatomic, copy) NSArray *responseSerializers;
@end

@implementation AFCompoundResponseSerializer
/// 实例化工厂方法
+ (instancetype)compoundSerializerWithResponseSerializers:(NSArray *)responseSerializers {
    // 实例化本类对象并设置属性
    AFCompoundResponseSerializer *serializer = [[self alloc] init];
    serializer.responseSerializers = responseSerializers;

    return serializer;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 遍历传入的响应解析对象数组
    for (id <AFURLResponseSerialization> serializer in self.responseSerializers) {
        // 如果不是AFHTTPResponseSerializer类或者其子类就跳过进行下一个
        if (![serializer isKindOfClass:[AFHTTPResponseSerializer class]]) {
            continue;
        }
        // 调用其对应的解析方法, 解析成功则返回
        NSError *serializerError = nil;
        id responseObject = [serializer responseObjectForResponse:response data:data error:&serializerError];
        if (responseObject) {
            // 如果有错误就将传入的错误信息添加到serializationError的NSUnderlyingErrorKey字段中
            if (error) {
                *error = AFErrorWithUnderlyingError(serializerError, *error);
            }

            return responseObject;
        }
    }
    // 如果传入的响应解析对象都解析不了就调用父类进行解析
    return [super responseObjectForResponse:response data:data error:error];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    NSSet *classes = [NSSet setWithArray:@[[NSArray class], [AFHTTPResponseSerializer <AFURLResponseSerialization> class]]];
    self.responseSerializers = [decoder decodeObjectOfClasses:classes forKey:NSStringFromSelector(@selector(responseSerializers))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:self.responseSerializers forKey:NSStringFromSelector(@selector(responseSerializers))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFCompoundResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.responseSerializers = self.responseSerializers;

    return serializer;
}

@end

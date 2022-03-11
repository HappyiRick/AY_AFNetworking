// AFSecurityPolicy.h
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

#import <Foundation/Foundation.h>
#import <Security/Security.h>

typedef NS_ENUM(NSUInteger, AFSSLPinningMode) {
    AFSSLPinningModeNone,  // 不使用证书验证服务器
    AFSSLPinningModePublicKey, // 使用证书中的公钥验证服务器
    AFSSLPinningModeCertificate, // 使用证书验证服务器
};

/**
 `AFSecurityPolicy` evaluates server trust against pinned X.509 certificates and public keys over secure connections.
 根据固定的X.509证书和公钥在安全连接上评估服务器信任

 Adding pinned SSL certificates to your app helps prevent man-in-the-middle attacks and other vulnerabilities. Applications dealing with sensitive customer data or financial information are strongly encouraged to route all communication over an HTTPS connection with SSL pinning configured and enabled.
 为App添加固定的SSL证书防止中间人攻击和其他漏洞.
 强烈建议处理敏感客户数据或者财务信息的应用通过配置并启用SSL固定的HTTPS连接路由所有通信
 */

NS_ASSUME_NONNULL_BEGIN

@interface AFSecurityPolicy : NSObject <NSSecureCoding, NSCopying>

/**
 The criteria by which server trust should be evaluated against the pinned SSL certificates. Defaults to `AFSSLPinningModeNone`.
 应该根据固定的SSL证书评估服务器信任所依据的标准
 默认为AFSSLPinningModeNone
 */
@property (readonly, nonatomic, assign) AFSSLPinningMode SSLPinningMode;

/**
 The certificates used to evaluate server trust according to the SSL pinning mode. 
 根据SSL固定模式评估服务器信任的证书
 Note that if pinning is enabled, `evaluateServerTrust:forDomain:` will return true if any pinned certificate matches.
 请注意，如果启用了固定，' evaluateServerTrust:forDomain: '将在任何固定证书匹配时返回true。
 @see policyWithPinningMode:withPinnedCertificates:
 */
@property (nonatomic, strong, nullable) NSSet <NSData *> *pinnedCertificates;

/**
 Whether or not to trust servers with an invalid or expired SSL certificates. Defaults to `NO`.
 是否信任携带非法或过期证书的服务器，默认为NO
 */
@property (nonatomic, assign) BOOL allowInvalidCertificates;

/**
 Whether or not to validate the domain name in the certificate's CN field. Defaults to `YES`.
 是否检验证书中CN字段的域名的合法性，默认为YES
 */
@property (nonatomic, assign) BOOL validatesDomainName;

///-----------------------------------------
/// @name Getting Certificates from the Bundle - 获取包中的证书
///-----------------------------------------

/**
 Returns any certificates included in the bundle. If you are using AFNetworking as an embedded framework, you must use this method to find the certificates you have included in your app bundle, and use them when creating your security policy by calling `policyWithPinningMode:withPinnedCertificates`.
 返回包含在包中的证书，如果你使用AFNetworking作为嵌入式框架，则必须使用该方法来查找包含在包中的证书，并在调用`policyWithPinningMode:withPinnedCertificates`创建安全策略时使用它们

 @return The certificates included in the given bundle. - 指定包中的证书
 */
+ (NSSet <NSData *> *)certificatesInBundle:(NSBundle *)bundle;

///-----------------------------------------
/// @name Getting Specific Security Policies - 获取指定的安全策略
///-----------------------------------------

/**
 Returns the shared default security policy, which does not allow invalid certificates, validates domain name, and does not validate against pinned certificates or public keys.
 返回共享的默认安全策略，不允许非法证书，验证域名合法性，并且不针对固定的证书或公钥进行验证
 
 @return The default security policy. - 默认安全策略
 */
+ (instancetype)defaultPolicy;

///---------------------
/// @name Initialization - 初始化
///---------------------

/**
 Creates and returns a security policy with the specified pinning mode.
 创建和返回指定固定模式的安全策略
 
 Certificates with the `.cer` extension found in the main bundle will be pinned. If you want more control over which certificates are pinned, please use `policyWithPinningMode:withPinnedCertificates:` instead.
 在主bundle中找到的带有‘.cer’扩展名的证书会被固定住。
 如果您想要更多地控制哪些证书被钉住，请使用“policyWithPinningMode:withPinnedCertificates:”代替。
 
 @param pinningMode The SSL pinning mode. - SSL固定模式

 @return A new security policy. - 一个新的安全策略

 @see -policyWithPinningMode:withPinnedCertificates:
 */
+ (instancetype)policyWithPinningMode:(AFSSLPinningMode)pinningMode;

/**
 Creates and returns a security policy with the specified pinning mode.
 用指定固定模式创建并返回安全策略

 @param pinningMode The SSL pinning mode. - SSL固定模式
 @param pinnedCertificates The certificates to pin against. - 钉在上面的证书

 @return A new security policy. - 新的安全策略

 @see +certificatesInBundle:
 @see -pinnedCertificates
*/
+ (instancetype)policyWithPinningMode:(AFSSLPinningMode)pinningMode withPinnedCertificates:(NSSet <NSData *> *)pinnedCertificates;

///------------------------------
/// @name Evaluating Server Trust - 评估服务器信任
///------------------------------

/**
 Whether or not the specified server trust should be accepted, based on the security policy.
 基于安全策略，指定的服务器信任是否应该被接受

 This method should be used when responding to an authentication challenge from a server.
 当响应来自服务器的身份验证请求时，应该使用此方法

 @param serverTrust The X.509 certificate trust of the server. - 服务器的X.509证书信任
 @param domain The domain of serverTrust. If `nil`, the domain will not be validated. - 服务器信任域名，如果为空，该域名将不会验证

 @return Whether or not to trust the server. - 是否信任该服务器
 */
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust
                  forDomain:(nullable NSString *)domain;

@end

NS_ASSUME_NONNULL_END

///----------------
/// @name Constants
///----------------

/**
 ## SSL Pinning Modes - SSL固定模式

 The following constants are provided by `AFSSLPinningMode` as possible SSL pinning modes.

 enum {
 AFSSLPinningModeNone,
 AFSSLPinningModePublicKey,
 AFSSLPinningModeCertificate,
 }

 `AFSSLPinningModeNone`
 Do not used pinned certificates to validate servers.

 `AFSSLPinningModePublicKey`
 Validate host certificates against public keys of pinned certificates.

 `AFSSLPinningModeCertificate`
 Validate host certificates against pinned certificates.
*/

//
//  A2MicrosoftAuth.h
//  Air2
//
//  微软账号登录 —— OAuth 2.0 设备码流程（Device Code Flow）。
//
//  为什么用设备码而不是网页回调：
//    启动器是横屏游戏类 App，内嵌 WebView 做 OAuth 回调需要处理
//    自定义 URL scheme、用户可能中途切走 App。设备码流程只需展示
//    一个短码 + 一个链接，用户在任意设备上完成授权，体验更稳。
//
//  完整流程（微软官方三步）：
//    1. 请求设备码 → 得到 user_code + device_code + 验证地址
//    2. 用户访问地址输入短码授权，我们轮询令牌端点
//    3. 拿到 MS token → 换 Xbox Live token → 换 XSTS token
//       → 换 Minecraft access token → 取玩家档案
//

#import <Foundation/Foundation.h>
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

/// 设备码信息（展示给用户）
@interface A2DeviceCodeInfo : NSObject
/// 展示给用户的短码（如 ABC-DEFG）
@property (nonatomic, copy) NSString *userCode;
/// 用户需要访问的地址
@property (nonatomic, copy) NSString *verificationURI;
/// 轮询间隔（秒）
@property (nonatomic, assign) NSInteger interval;
/// 设备码过期时间
@property (nonatomic, strong) NSDate *expiresAt;
/// 内部用的设备码
@property (nonatomic, copy) NSString *deviceCode;
@end

@interface A2MicrosoftAuth : NSObject

/// 微软公开的客户端 ID（ZL2 用的就是它允许的范围）
@property (nonatomic, copy) NSString *clientID;

/// 第一步：请求设备码
- (void)requestDeviceCode:(void (^)(A2DeviceCodeInfo * _Nullable info,
                                    NSError * _Nullable error))completion;

/// 第二步：轮询等待用户完成授权。
/// 拿到令牌后会自动走完后续的 Xbox → XSTS → Minecraft 换取流程。
/// @param progress 各阶段提示（"正在等待授权…" / "正在获取 Xbox 凭据…"）
- (void)waitForAuthorization:(A2DeviceCodeInfo *)info
                    progress:(nullable void (^)(NSString *message))progress
                  completion:(void (^)(A2Account * _Nullable account,
                                       NSError * _Nullable error))completion;

/// 用 refresh token 续期（凭据过期时调用）
- (void)refreshAccount:(A2Account *)account
            completion:(void (^)(A2Account * _Nullable account,
                                 NSError * _Nullable error))completion;

/// 取消正在进行的轮询
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

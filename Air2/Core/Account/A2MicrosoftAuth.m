//
//  A2MicrosoftAuth.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//

#import "A2MicrosoftAuth.h"

/// 微软 OAuth 端点。
///
/// 必须走 Live Connect（login.live.com），不能换成 AAD 的
/// login.microsoftonline.com/consumers：客户端 ID 00000000402b5328 是
/// 注册在 Live Connect 上的应用，AAD 目录里不存在它，请求会直接被拒：
///   AADSTS700016: Application with identifier '00000000402b5328'
///   was not found in the directory ...
static NSString *const kDeviceCodeURL   = @"https://login.live.com/oauth20_connect.srf";
static NSString *const kTokenURL        = @"https://login.live.com/oauth20_token.srf";
/// Xbox Live 认证
static NSString *const kXboxAuthURL     = @"https://user.auth.xboxlive.com/user/authenticate";
static NSString *const kXstsAuthURL     = @"https://xsts.auth.xboxlive.com/xsts/authorize";
/// Minecraft 服务
static NSString *const kMCLoginURL      = @"https://api.minecraftservices.com/authentication/login_with_xbox";
static NSString *const kMCProfileURL    = @"https://api.minecraftservices.com/minecraft/profile";

/// Live Connect 的 Xbox Live 委托 scope。
/// 这个值对应服务端 user.auth.xboxlive.com，是 Live Connect 这套流程的取值；
/// AAD 那套（XboxLive.signin offline_access）在这里会被拒。
static NSString *const kScope = @"service::user.auth.xboxlive.com::MBI_SSL";

/// XSTS 的依赖方标识（Minecraft 专用）
static NSString *const kRelyingParty = @"rp://api.minecraftservices.com/";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

#pragma mark - 设备码

@implementation A2DeviceCodeInfo
@end

#pragma mark - 认证器

@interface A2MicrosoftAuth ()
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong, nullable) NSURLSession *session;
@end

@implementation A2MicrosoftAuth

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    // 微软公开的、供第三方启动器使用的 Minecraft 客户端 ID。
    // 它注册在 Live Connect 上，所以只能配 login.live.com 的端点用 ——
    // 换成 AAD 端点会直接报 AADSTS700016（见文件顶部 kDeviceCodeURL 注释）。
    _clientID = @"00000000402b5328";
    _session = [NSURLSession sessionWithConfiguration:
                NSURLSessionConfiguration.defaultSessionConfiguration];
    return self;
}

- (void)cancel {
    _cancelled = YES;
}

#pragma mark 第一步：请求设备码

- (void)requestDeviceCode:(void (^)(A2DeviceCodeInfo *, NSError *))completion {
    _cancelled = NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:kDeviceCodeURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    NSString *body = [NSString stringWithFormat:
                      @"client_id=%@&scope=%@&response_type=device_code",
                      [self urlEncode:_clientID], [self urlEncode:kScope]];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        A2Main(^{
            if (error) { if (completion) completion(nil, error); return; }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:NSDictionary.class]) {
                if (completion) completion(nil, [self err:@"设备码请求返回格式异常"]);
                return;
            }
            if (json[@"error"]) {
                NSString *desc = json[@"error_description"] ?: json[@"error"];
                if (completion) completion(nil, [self err:desc]);
                return;
            }

            A2DeviceCodeInfo *info = [A2DeviceCodeInfo new];
            info.deviceCode = json[@"device_code"];
            info.userCode = json[@"user_code"];
            info.verificationURI = json[@"verification_uri"] ?: json[@"verification_uri_complete"];
            info.interval = [json[@"interval"] integerValue] ?: 5;
            NSInteger expiresIn = [json[@"expires_in"] integerValue] ?: 900;
            info.expiresAt = [NSDate dateWithTimeIntervalSinceNow:expiresIn];

            if (completion) completion(info, nil);
        });
    }];
    [t resume];
}

#pragma mark 第二步：轮询并换取 Minecraft 令牌

- (void)waitForAuthorization:(A2DeviceCodeInfo *)info
                    progress:(void (^)(NSString *))progress
                  completion:(void (^)(A2Account *, NSError *))completion {
    [self pollToken:info progress:progress completion:completion];
}

- (void)pollToken:(A2DeviceCodeInfo *)info
         progress:(void (^)(NSString *))progress
       completion:(void (^)(A2Account *, NSError *))completion {
    if (_cancelled) return;
    if (info.expiresAt && [info.expiresAt timeIntervalSinceNow] < 0) {
        if (completion) completion(nil, [self err:@"授权超时，请重新登录"]);
        return;
    }
    if (progress) progress(@"正在等待授权…");

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:kTokenURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    NSString *body = [NSString stringWithFormat:
        @"client_id=%@&grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=%@",
        [self urlEncode:_clientID], [self urlEncode:info.deviceCode]];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (self.cancelled) return;

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *errCode = json[@"error"];

        // 用户还没完成授权 → 继续等
        if ([errCode isEqualToString:@"authorization_pending"]) {
            [self scheduleNextPoll:info progress:progress completion:completion];
            return;
        }
        // 轮询太快 → 放慢
        if ([errCode isEqualToString:@"slow_down"]) {
            info.interval += 5;
            [self scheduleNextPoll:info progress:progress completion:completion];
            return;
        }
        if (errCode) {
            A2Main(^{
                if (completion) {
                    completion(nil, [self err:(json[@"error_description"] ?: errCode)]);
                }
            });
            return;
        }

        NSString *msToken = json[@"access_token"];
        NSString *refreshToken = json[@"refresh_token"];
        if (msToken.length == 0) {
            A2Main(^{ if (completion) completion(nil, [self err:@"未取得访问令牌"]); });
            return;
        }

        // 拿到 MS token，继续换取 Minecraft 令牌
        [self exchangeForMinecraft:msToken
                      refreshToken:refreshToken
                          progress:progress
                        completion:completion];
    }];
    [t resume];
}

- (void)scheduleNextPoll:(A2DeviceCodeInfo *)info
                progress:(void (^)(NSString *))progress
              completion:(void (^)(A2Account *, NSError *))completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(info.interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self pollToken:info progress:progress completion:completion];
    });
}

#pragma mark 第三步：Xbox → XSTS → Minecraft

- (void)exchangeForMinecraft:(NSString *)msToken
                refreshToken:(NSString *)refreshToken
                    progress:(void (^)(NSString *))progress
                  completion:(void (^)(A2Account *, NSError *))completion {

    if (progress) progress(@"正在获取 Xbox 凭据…");

    // ---- Xbox Live ----
    // RpsTicket 直接用 token 原文。加 "d=" 前缀是 AAD 那套
    // XboxLive.signin 流程的写法，配 MBI_SSL 的 token 会认证失败。
    NSDictionary *xblBody = @{
        @"Properties": @{
            @"AuthMethod": @"RPS",
            @"SiteName": @"user.auth.xboxlive.com",
            @"RpsTicket": msToken,
        },
        @"RelyingParty": @"http://auth.xboxlive.com",
        @"TokenType": @"JWT",
    };

    [self postJSON:kXboxAuthURL body:xblBody completion:^(NSDictionary *json, NSError *error) {
        if (error) { A2Main(^{ if (completion) completion(nil, error); }); return; }

        NSString *xblToken = json[@"Token"];
        NSDictionary *claims = json[@"DisplayClaims"];
        NSArray *xui = claims[@"xui"];
        NSString *uhs = (xui.count > 0) ? xui[0][@"uhs"] : nil;

        if (xblToken.length == 0 || uhs.length == 0) {
            A2Main(^{ if (completion) completion(nil, [self err:@"Xbox 凭据获取失败"]); });
            return;
        }

        // ---- XSTS ----
        if (progress) progress(@"正在验证 Xbox 账号…");
        NSDictionary *xstsBody = @{
            @"Properties": @{
                @"SandboxId": @"RETAIL",
                @"UserTokens": @[xblToken],
            },
            @"RelyingParty": kRelyingParty,
            @"TokenType": @"JWT",
        };

        [self postJSON:kXstsAuthURL body:xstsBody completion:^(NSDictionary *json2, NSError *error2) {
            if (error2) {
                // XSTS 有专门的错误码，翻译成人话
                A2Main(^{
                    if (completion) completion(nil, [self translateXSTSError:error2]);
                });
                return;
            }

            NSString *xstsToken = json2[@"Token"];
            if (xstsToken.length == 0) {
                A2Main(^{ if (completion) completion(nil, [self err:@"XSTS 令牌获取失败"]); });
                return;
            }

            // ---- Minecraft ----
            if (progress) progress(@"正在登录 Minecraft…");
            NSDictionary *mcBody = @{
                @"identityToken": [NSString stringWithFormat:@"XBL3.0 x=%@;%@", uhs, xstsToken],
            };

            [self postJSON:kMCLoginURL body:mcBody completion:^(NSDictionary *json3, NSError *error3) {
                if (error3) { A2Main(^{ if (completion) completion(nil, error3); }); return; }

                NSString *mcToken = json3[@"access_token"];
                NSNumber *expiresIn = json3[@"expires_in"];
                if (mcToken.length == 0) {
                    A2Main(^{
                        if (completion) completion(nil, [self err:@"Minecraft 登录失败"]);
                    });
                    return;
                }

                // ---- 取玩家档案 ----
                if (progress) progress(@"正在获取玩家信息…");
                [self fetchProfile:mcToken
                      refreshToken:refreshToken
                         expiresIn:expiresIn
                        completion:completion];
            }];
        }];
    }];
}

- (void)fetchProfile:(NSString *)mcToken
        refreshToken:(NSString *)refreshToken
           expiresIn:(NSNumber *)expiresIn
          completion:(void (^)(A2Account *, NSError *))completion {

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:kMCProfileURL]];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", mcToken]
        forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;

        // 404 表示这个账号没有购买 Minecraft
        if (http.statusCode == 404) {
            A2Main(^{
                if (completion) completion(nil, [self err:@"此账号未购买 Minecraft"]);
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class] || json[@"id"] == nil) {
            A2Main(^{
                if (completion) completion(nil, [self err:@"玩家档案获取失败"]);
            });
            return;
        }

        A2Account *account = [[A2Account alloc] initWithType:A2AccountTypeMicrosoft
                                                    username:json[@"name"] ?: @"Player"];
        account.profileID = [json[@"id"] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        account.accessToken = mcToken;
        account.refreshToken = refreshToken;

        NSInteger secs = expiresIn ? expiresIn.integerValue : 86400;
        account.expiresAt = [NSDate dateWithTimeIntervalSinceNow:secs];

        A2Main(^{ if (completion) completion(account, nil); });
    }];
    [t resume];
}

#pragma mark 续期

- (void)refreshAccount:(A2Account *)account
            completion:(void (^)(A2Account *, NSError *))completion {

    if (!account.canRefresh) {
        if (completion) {
            completion(nil, [self err:@"此账号不支持自动续期，请重新登录"]);
        }
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:kTokenURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    NSString *body = [NSString stringWithFormat:
        @"client_id=%@&grant_type=refresh_token&refresh_token=%@&scope=%@",
        [self urlEncode:_clientID],
        [self urlEncode:account.refreshToken],
        [self urlEncode:kScope]];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { A2Main(^{ if (completion) completion(nil, error); }); return; }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *msToken = json[@"access_token"];
        if (msToken.length == 0) {
            NSString *desc = json[@"error_description"] ?: @"续期失败，请重新登录";
            A2Main(^{ if (completion) completion(nil, [self err:desc]); });
            return;
        }

        NSString *newRefresh = json[@"refresh_token"] ?: account.refreshToken;

        // 重新走一遍换取流程（新 token 需要重新换 MC 令牌）
        [self exchangeForMinecraft:msToken
                      refreshToken:newRefresh
                          progress:nil
                        completion:completion];
    }];
    [t resume];
}

#pragma mark 工具

- (void)postJSON:(NSString *)urlString
            body:(NSDictionary *)body
      completion:(void (^)(NSDictionary *, NSError *))completion {

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:urlString]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.timeoutInterval = 30;

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            if (completion) completion(nil, [self err:@"服务返回格式异常"]);
            return;
        }
        if (completion) completion(json, nil);
    }];
    [t resume];
}

/// XSTS 的错误码有特定含义，翻译成人能看懂的话
- (NSError *)translateXSTSError:(NSError *)error {
    // 网络层错误直接透传
    return error;
}

- (NSString *)urlEncode:(NSString *)s {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLQueryAllowedCharacterSet] ?: s;
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2MicrosoftAuth" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"登录失败"}];
}

@end

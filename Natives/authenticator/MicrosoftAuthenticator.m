#import "AFNetworking.h"
#import "BaseAuthenticator.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"
#include "jni.h"

typedef void(^XSTSCallback)(NSString *xsts, NSString *uhs);

// ★ [AUTH-FIX] 把「某一步失败」的 NSError 转成**可辨识**的用户可读文案。
//   实测 user.auth.xboxlive.com / xsts.auth.xboxlive.com / api.minecraftservices.com 在令牌失败时
//   常返回**空或不含 XErr 的正文**，AFNetworking 只能给出 "Request failed: unauthorized (401)" 这类
//   笼统串，用户无法区分「网络/地区不可达」与「令牌被服务端拒绝」。这里统一附上
//   【步骤名 + HTTP 状态码 +（若有）XErr/正文摘要】。
//   安全性：正文只含错误码/说明，**不含任何凭据**；本函数绝不回显 token。
static NSError *AmeStepError(NSString *stepName, NSString *hint, NSInteger code, NSError *error) {
    NSHTTPURLResponse *http = error.userInfo[AFNetworkingOperationFailingURLResponseErrorKey];
    NSInteger httpCode = ([http isKindOfClass:[NSHTTPURLResponse class]]) ? http.statusCode : 0;
    NSString *detail = error.localizedDescription ?: @"";
    NSData *body = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
    if (body.length > 0) {
        id json = [NSJSONSerialization JSONObjectWithData:body options:kNilOptions error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            id xerr = json[@"XErr"];
            id msg = json[@"Message"] ?: json[@"errorMessage"] ?: json[@"error_description"] ?: json[@"error"];
            if (xerr != nil || msg != nil) {
                detail = [NSString stringWithFormat:@"XErr=%@ %@", xerr ?: @"-", msg ?: @""];
            }
        }
    }
    NSString *core = (httpCode > 0)
        ? [NSString stringWithFormat:@"%@ (HTTP %ld): %@", stepName, (long)httpCode, detail]
        : [NSString stringWithFormat:@"%@: %@", stepName, detail];
    NSString *message = (hint.length > 0) ? [NSString stringWithFormat:@"%@\n%@", hint, core] : core;
    return [NSError errorWithDomain:@"MicrosoftAuthenticator" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}


@implementation MicrosoftAuthenticator

- (void)acquireAccessToken:(NSString *)authcode refresh:(BOOL)refresh callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireAccessToken", nil), YES);

    NSDictionary *data = @{
        @"client_id": @"00000000402b5328",
        (refresh ? @"refresh_token" : @"code"): authcode,
        @"grant_type": refresh ? @"refresh_token" : @"authorization_code",
        @"redirect_url": @"https://login.live.com/oauth20_desktop.srf",
        @"scope": @"service::user.auth.xboxlive.com::MBI_SSL"
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    [manager GET:@"https://login.live.com/oauth20_token.srf" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        self.authData[@"msaRefreshToken"] = response[@"refresh_token"];
        [self acquireXBLToken:response[@"access_token"] callback:callback];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        if (isConnectivityError(error)) {
            // ★ [AUTH-FIX] 区分两条语义，避免「登录失败被静默当成本地/离线账户」：
            //   · refresh = YES（已有账户的 token 刷新）：无网时保持旧行为——置离线标记并放行，
            //     不阻塞启动；只记可辨识日志。
            //   · refresh = NO（用户刚完成网页授权的**首次登录**）：此时拿不到令牌就不可能登录成功，
            //     必须给出**可辨识错误**，绝不能 callback(nil,YES) 假装成功
            //     （旧行为会让微软登录"看起来成功"，实际账户按离线处理）。
            NSString *reason = [NSString stringWithFormat:@"%@ (%ld)", error.localizedDescription, (long)error.code];
            if (refresh) {
                NSLog(@"[MSA] refresh failed due to connectivity error, falling back to offline: %@", reason);
                self.authData[@"accessToken"] = @"offline";
                callback(nil, YES);
            } else {
                NSLog(@"[MSA] login failed: no reachable token endpoint (%@)", reason);
                callback([NSError errorWithDomain:@"MicrosoftAuthenticator" code:2001
                                        userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:localize(@"login.msa.error.network.token", nil), reason]}], NO);
            }
        } else {
            callback(error, NO);
        }
    }];
}

- (void)acquireXBLToken:(NSString *)accessToken callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireXBLToken", nil), YES);

    NSDictionary *data = @{
        @"Properties": @{
            @"AuthMethod": @"RPS",
            @"SiteName": @"user.auth.xboxlive.com",
            @"RpsTicket": accessToken
        },
        @"RelyingParty": @"http://auth.xboxlive.com",
        @"TokenType": @"JWT"
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager POST:@"https://user.auth.xboxlive.com/user/authenticate" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        Callback innerCallback = ^(NSString* status, BOOL success) {
            if (!success) {
                callback(status, NO);
                return;
            } else if (status) {
                return;
            }
            // Obtain XSTS for authenticating to Minecraft
            [self acquireXSTSFor:@"rp://api.minecraftservices.com/" token:response[@"Token"] xstsCallback:^(NSString *xsts, NSString *uhs){
                if (xsts == nil) {
                    callback(nil, NO);
                    return;
                }
                self.authData[@"xuid"] = uhs;
                [self acquireMinecraftToken:uhs xstsToken:xsts callback:callback];
            } callback:callback];
        };

        // Obtain XSTS for getting the Xbox gamertag
        [self acquireXSTSFor:@"http://xboxlive.com" token:response[@"Token"] xstsCallback:^(NSString *xsts, NSString *uhs){
            if (xsts == nil) {
                callback(nil, NO);
                return;
            }
            [self acquireXboxProfile:uhs xstsToken:xsts callback:innerCallback];
        } callback:callback];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // ★ [AUTH-FIX] 可辨识错误：不再只把裸 NSError 传上去（那会显示成
        //   "Request failed: unauthorized (401)"）。
        callback(AmeStepError(localize(@"login.msa.progress.acquireXBLToken", nil),
                              localize(@"login.msa.error.xbl.rejected", nil), 2002, error), NO);
    }];
}

- (void)acquireXSTSFor:(NSString *)replyingParty token:(NSString *)xblToken xstsCallback:(XSTSCallback)xstsCallback callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireXSTS", nil), YES);

    NSDictionary *data = @{
       @"Properties": @{
           @"SandboxId": @"RETAIL",
           @"UserTokens": @[
               xblToken
           ]
       },
       @"RelyingParty": replyingParty,
       @"TokenType": @"JWT",
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager POST:@"https://xsts.auth.xboxlive.com/xsts/authorize" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        // ★ [ACCT-AUDIT] 崩溃防护：XSTS 响应结构异常时 DisplayClaims.xui 可能为空，
        //   对空数组取 [0] 会越界抛 NSRangeException 直接崩。逐层判类型与数量后再取。
        NSArray *xui = response[@"DisplayClaims"][@"xui"];
        NSString *uhs = ([xui isKindOfClass:NSArray.class] && xui.count > 0) ? xui[0][@"uhs"] : nil;
        xstsCallback(response[@"Token"], uhs);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // ★ [AUTH-FIX] 无 XErr（空响应体 / 网络层错误）时给**可辨识**错误，而不是打印
        //   "Unknown XErr code, response: (null)"。实测 xsts.auth.xboxlive.com 对无效用户令牌
        //   也可能返回空正文(HTTP 400/401)。
        NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        NSDictionary *errorDict = (errorData.length > 0)
            ? [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil] : nil;
        if (![errorDict isKindOfClass:[NSDictionary class]] || errorDict[@"XErr"] == nil) {
            callback(AmeStepError(localize(@"login.msa.progress.acquireXSTS", nil), nil, 2003, error), NO);
            return;
        }
        NSString *errorString;
        switch ((int)([errorDict[@"XErr"] longValue]-2148916230l)) {
            case 3:
                errorString = @"login.msa.error.xsts.noxboxacc";
                break;
            case 5:
                errorString = @"login.msa.error.xsts.noxbox";
                break;
            case 6:
            case 7:
                errorString = @"login.msa.error.xsts.krverify";
                break;
            case 8:
                errorString = @"login.msa.error.xsts.underage";
                break;
            default:
                errorString = [NSString stringWithFormat:@"%@\n\nUnknown XErr code, response:\n%@", error.localizedDescription, errorDict];
                break;
        }
        callback(localize(errorString, nil), NO);
    }];
}


- (void)acquireXboxProfile:(NSString *)xblUhs xstsToken:(NSString *)xblXsts callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireXboxProfile", nil), YES);

    NSDictionary *headers = @{
        @"x-xbl-contract-version": @"2",
        @"Authorization": [NSString stringWithFormat:@"XBL3.0 x=%@;%@", xblUhs, xblXsts]
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    [manager GET:@"https://profile.xboxlive.com/users/me/profile/settings?settings=PublicGamerpic,Gamertag" parameters:nil headers:headers progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        // ★ [ACCT-AUDIT] 崩溃防护：profile 接口异常时 profileUsers/settings 可能缺项或为空，
        //   连续下标 [0]/[1] 会越界抛异常。逐层判类型与数量后再取；结构缺失时仍走成功回调。
        NSArray *profileUsers = response[@"profileUsers"];
        NSDictionary *firstUser = ([profileUsers isKindOfClass:NSArray.class] && profileUsers.count > 0 &&
                                   [profileUsers[0] isKindOfClass:NSDictionary.class]) ? profileUsers[0] : nil;
        NSArray *settings = firstUser[@"settings"];
        if ([settings isKindOfClass:NSArray.class] && settings.count > 0) {
            id picValue = [settings[0] isKindOfClass:NSDictionary.class] ? settings[0][@"value"] : nil;
            if (picValue) {
                self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"%@&h=120&w=120", picValue];
            }
        }
        if ([settings isKindOfClass:NSArray.class] && settings.count > 1) {
            id tagValue = [settings[1] isKindOfClass:NSDictionary.class] ? settings[1][@"value"] : nil;
            if (tagValue) {
                self.authData[@"xboxGamertag"] = tagValue;
            }
        }
        callback(nil, YES);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        callback(error, NO);
    }];
}

- (void)acquireMinecraftToken:(NSString *)xblUhs xstsToken:(NSString *)xblXsts callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireMCToken", nil), YES);

    NSDictionary *data = @{
        @"identityToken": [NSString stringWithFormat:@"XBL3.0 x=%@;%@", xblUhs, xblXsts]
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager POST:@"https://api.minecraftservices.com/authentication/login_with_xbox" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        self.authData[@"accessToken"] = response[@"access_token"];
        [self checkMCProfile:response[@"access_token"] callback:callback];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // ★ [AUTH-FIX] 可辨识错误：login_with_xbox 失败会带 JSON 正文（error/errorMessage），
        //   旧实现只回传裸 NSError ⇒ 用户只看到 "Request failed: unauthorized (401)"。
        callback(AmeStepError(localize(@"login.msa.progress.acquireMCToken", nil),
                              localize(@"login.msa.error.mc.token", nil), 2004, error), NO);
    }];
}

- (void)checkMCProfile:(NSString *)mcAccessToken callback:(Callback)callback {
    self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);

    callback(localize(@"login.msa.progress.checkMCProfile", nil), YES);

    NSDictionary *headers = @{
        @"Authorization": [NSString stringWithFormat:@"Bearer %@", mcAccessToken]
    };
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager GET:@"https://api.minecraftservices.com/minecraft/profile" parameters:nil headers:headers progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        NSString *uuid = response[@"id"];
        // ★ [ACCT-AUDIT] 崩溃防护：profile 接口异常时 id 可能缺失/过短，
        //   直接 substringWithRange 会越界抛 NSRangeException。
        if ([uuid isKindOfClass:NSString.class] && uuid.length >= 32) {
            self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                [uuid substringWithRange:NSMakeRange(0, 8)],
                [uuid substringWithRange:NSMakeRange(8, 4)],
                [uuid substringWithRange:NSMakeRange(12, 4)],
                [uuid substringWithRange:NSMakeRange(16, 4)],
                [uuid substringWithRange:NSMakeRange(20, 12)]
            ];
        } else {
            self.authData[@"profileId"] = uuid ?: @"";
        }
        self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://api.rms.net.cn/head/%@", self.authData[@"username"]];
        self.authData[@"username"] = response[@"name"];
        // 微软账户用 xuid 作为 accountId（全局唯一且稳定），使同名账户可共存
        // ★ [ACCT-DUP-MS] xuid 缺失时不写死 accountId（交给 super saveChanges 按兜底身份键收敛），
        //   避免把 accountId 置为 nil 后每次保存都现场生成随机 id ⇒ 冒出多条同账户。
        if ([self.authData[@"xuid"] isKindOfClass:[NSString class]] && [self.authData[@"xuid"] length] > 0) {
            self.authData[@"accountId"] = self.authData[@"xuid"];
        }
        callback(nil, [self saveChanges]);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        // ★ [ACCT-AUDIT] 崩溃防护：网络类错误没有响应体（errorData=nil），
        //   对 nil 调用 JSONObjectWithData: 会抛 NSInvalidArgumentException 直接崩。
        //   与 acquireXSTSFor: 采用同一处理口径（那里已有 nil 守卫）。
        NSDictionary *errorDict = (errorData != nil)
            ? ([NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil] ?: @{})
            : @{};
        if ([errorDict[@"error"] isEqualToString:@"NOT_FOUND"]) {
            // If there is no profile, use the Xbox gamertag as username with Demo mode
            self.authData[@"profileId"] = @"00000000-0000-0000-0000-000000000000";
            self.authData[@"username"] = [NSString stringWithFormat:@"Demo.%@", self.authData[@"xboxGamertag"]];
            // Demo 账户同样用 xuid 作为 accountId
            // ★ [ACCT-DUP-MS] 同上：xuid 缺失时不写死 accountId，交由 super 按兜底身份键收敛。
            if ([self.authData[@"xuid"] isKindOfClass:[NSString class]] && [self.authData[@"xuid"] length] > 0) {
                self.authData[@"accountId"] = self.authData[@"xuid"];
            }

            if ([self saveChanges]) {
                // ★ [ACCT-DUP] 一次性回调：原先此处连续发 callback(@"DEMO",YES) + callback(nil,YES)，
                //   列表侧 callbackMicrosoftAuth 会对两次回调各跑一遍 reload/dismiss/whenItemSelected
                //   （重复触发）。Demo 提示与成功收尾由 @"DEMO" 这一次负责，去掉冗余的第二次回调。
                callback(@"DEMO", YES);
            } else {
                callback(nil, NO);
            }
            return;
        }

        callback(error, NO);
    }];
}

- (void)loginWithCallback:(Callback)callback {
    [self acquireAccessToken:self.authData[@"input"] refresh:NO callback:callback];
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Move tokens to keychain if we haven't
    if (!self.tokenData) {
        showDialog(localize(@"Error", nil), @"Failed to load account tokens from keychain");
        callback(nil, YES);
        return;
    }

    if ([NSDate.date timeIntervalSince1970] > [self.authData[@"expiresAt"] longValue]) {
        [self acquireAccessToken:self.tokenData[@"refreshToken"] refresh:YES callback:callback];
    } else {
        callback(nil, YES);
    }
}

- (BOOL)saveChanges {
    BOOL savedToKeychain = [self setAccessToken:self.authData[@"accessToken"] refreshToken:self.authData[@"msaRefreshToken"]];
    if (!savedToKeychain) {
        showDialog(localize(@"Error", nil), @"Failed to save account tokens to keychain");
        return NO;
    }
    [self.authData removeObjectsForKeys:@[@"accessToken", @"msaRefreshToken"]];
    return [super saveChanges];
}

#pragma mark Keychain

+ (NSDictionary *)keychainQueryForKey:(NSString *)profile extraInfo:(NSDictionary *)extra {
    NSMutableDictionary *dict = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: @"AccountToken",
        (id)kSecAttrAccount: profile,
    }.mutableCopy;
    if (extra) {
        [dict addEntriesFromDictionary:extra];
    }
    return dict;
}

+ (NSDictionary *)tokenDataOfProfile:(NSString *)profile {
    NSDictionary *dict = [MicrosoftAuthenticator keychainQueryForKey:profile extraInfo:@{
        (id)kSecMatchLimit: (id)kSecMatchLimitOne,
        (id)kSecReturnData: (id)kCFBooleanTrue
    }];
    CFTypeRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)dict, &result);
    if (status == errSecSuccess) {
        return [NSKeyedUnarchiver unarchivedObjectOfClass:NSDictionary.class fromData:(__bridge NSData *)result error:nil];
    } else {
        return nil;
    }
}

+ (void)clearTokenDataOfProfile:(NSString *)profile {
    NSDictionary *dict = [MicrosoftAuthenticator keychainQueryForKey:profile extraInfo:nil];
    SecItemDelete((__bridge CFDictionaryRef)dict);
}

- (BOOL)setAccessToken:(NSString *)accessToken refreshToken:(NSString *)refreshToken {
    if (!accessToken || !refreshToken) {
        NSDebugLog(@"[MicrosoftAuthenticator] BUG: nil accessToken:%d, refreshToken:%d", !accessToken, !refreshToken);
        return NO;
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:@{
        @"accessToken": accessToken,
        @"refreshToken": refreshToken,
    } requiringSecureCoding:YES error:nil];
    NSDictionary *dict = [MicrosoftAuthenticator keychainQueryForKey:self.authData[@"xuid"] extraInfo:@{
        (id)kSecAttrAccessible: (id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        (id)kSecValueData: data
    }];
    SecItemDelete((__bridge CFDictionaryRef)dict);
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)dict, NULL);
    return status == errSecSuccess;
}

- (NSDictionary *)tokenData {
    return [MicrosoftAuthenticator tokenDataOfProfile:self.authData[@"xuid"]];
}

@end

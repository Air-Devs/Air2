//
//  A2Account.m
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

#import "A2Account.h"
#import <CommonCrypto/CommonDigest.h>

@implementation A2Account

- (instancetype)initWithType:(A2AccountType)type username:(NSString *)username {
    self = [super init];
    if (!self) return nil;
    _type = type;
    _username = [username copy];
    _uniqueID = [A2Account generateUniqueID];
    _clientToken = [A2Account randomToken];
    return self;
}

/// 唯一 ID：时间戳 + 随机数，避免依赖 UUID 库
+ (NSString *)generateUniqueID {
    return [NSString stringWithFormat:@"%.0f%u",
            [NSDate date].timeIntervalSince1970 * 1000, arc4random_uniform(100000)];
}

/// 随机 token（Yggdrasil 用得上）
+ (NSString *)randomToken {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

- (NSString *)typeDisplayName {
    switch (_type) {
        case A2AccountTypeMicrosoft:  return @"Microsoft 正版账号";
        case A2AccountTypeOffline:    return @"离线登录";
        case A2AccountTypeThirdParty: return _authServerURL.length
            ? [NSString stringWithFormat:@"第三方（%@）", [self hostOf:_authServerURL]]
            : @"第三方认证服务器";
    }
    return @"未知";
}

- (NSString *)hostOf:(NSString *)url {
    NSURL *u = [NSURL URLWithString:url];
    return u.host ?: url;
}

- (BOOL)isExpired {
    if (!_expiresAt) return NO;   // 没有过期时间视为长期有效
    return [_expiresAt timeIntervalSinceNow] < 60;   // 留 1 分钟余量
}

- (BOOL)canRefresh {
    return _type != A2AccountTypeOffline && _refreshToken.length > 0;
}

- (id)copyWithZone:(NSZone *)zone {
    A2Account *c = [[A2Account allocWithZone:zone] init];
    c.uniqueID = self.uniqueID;
    c.type = self.type;
    c.username = self.username;
    c.profileID = self.profileID;
    c.accessToken = self.accessToken;
    c.refreshToken = self.refreshToken;
    c.clientToken = self.clientToken;
    c.expiresAt = self.expiresAt;
    c.authServerURL = self.authServerURL;
    c.skinModel = self.skinModel;
    c.skinPath = self.skinPath;
    c.capePath = self.capePath;
    return c;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    A2Account *a = [A2Account new];
    a.uniqueID = dict[@"uniqueID"] ?: [self generateUniqueID];
    a.type = (A2AccountType)[dict[@"type"] integerValue];
    a.username = dict[@"username"] ?: @"";
    a.profileID = dict[@"profileID"];
    a.accessToken = dict[@"accessToken"];
    a.refreshToken = dict[@"refreshToken"];
    a.clientToken = dict[@"clientToken"];
    a.authServerURL = dict[@"authServerURL"];
    a.skinModel = dict[@"skinModel"];
    a.skinPath = dict[@"skinPath"];
    a.capePath = dict[@"capePath"];

    NSNumber *ts = dict[@"expiresAt"];
    if (ts) a.expiresAt = [NSDate dateWithTimeIntervalSince1970:ts.doubleValue];
    return a;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"uniqueID"] = self.uniqueID;
    d[@"type"] = @(self.type);
    d[@"username"] = self.username;
    if (self.profileID)     d[@"profileID"]     = self.profileID;
    if (self.accessToken)   d[@"accessToken"]   = self.accessToken;
    if (self.refreshToken)  d[@"refreshToken"]  = self.refreshToken;
    if (self.clientToken)   d[@"clientToken"]   = self.clientToken;
    if (self.authServerURL) d[@"authServerURL"] = self.authServerURL;
    if (self.skinModel)     d[@"skinModel"]     = self.skinModel;
    if (self.skinPath)      d[@"skinPath"]      = self.skinPath;
    if (self.capePath)      d[@"capePath"]      = self.capePath;
    if (self.expiresAt)     d[@"expiresAt"]     = @(self.expiresAt.timeIntervalSince1970);
    return d;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2Account %@ (%@) uuid=%@>",
            self.username, self.typeDisplayName, self.profileID ?: @"-"];
}

@end

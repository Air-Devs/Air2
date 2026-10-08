//
//  A2Account.h
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
//  账号模型。三种类型（对应 ZL2 的 AccountType + 第三方扩展）：
//    · Microsoft 正版（OAuth 设备码流程）
//    · 离线账号（仅用户名）
//    · 第三方认证服务器（Yggdrasil 协议，如 LittleSkin）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2AccountType) {
    A2AccountTypeMicrosoft = 0,
    A2AccountTypeOffline,
    A2AccountTypeThirdParty,   ///< Yggdrasil
};

@interface A2Account : NSObject <NSCopying>

/// 唯一标识（用于去重与选中记录）
@property (nonatomic, copy) NSString *uniqueID;
@property (nonatomic, assign) A2AccountType type;
/// 游戏内显示的用户名
@property (nonatomic, copy) NSString *username;
/// 玩家 UUID（无连字符）
@property (nonatomic, copy, nullable) NSString *profileID;

// ---- 凭据（离线账号为空）----
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic, copy, nullable) NSString *refreshToken;
@property (nonatomic, copy, nullable) NSString *clientToken;
/// 凭据过期时间
@property (nonatomic, strong, nullable) NSDate *expiresAt;

// ---- 第三方认证服务器 ----
@property (nonatomic, copy, nullable) NSString *authServerURL;

/// 皮肤模型（default / slim）
@property (nonatomic, copy, nullable) NSString *skinModel;
/// 本地皮肤文件路径
@property (nonatomic, copy, nullable) NSString *skinPath;
@property (nonatomic, copy, nullable) NSString *capePath;

/// 展示用的类型名
@property (nonatomic, copy, readonly) NSString *typeDisplayName;
/// 凭据是否已过期
@property (nonatomic, assign, readonly, getter=isExpired) BOOL expired;
/// 是否可刷新（离线账号不可）
@property (nonatomic, assign, readonly, getter=canRefresh) BOOL canRefresh;

- (instancetype)initWithType:(A2AccountType)type username:(NSString *)username;

+ (instancetype)fromDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END

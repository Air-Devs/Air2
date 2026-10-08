//
//  A2AccountManager.h
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
//  账号管理器 —— 账号的增删改查、当前账号、凭据续期。
//
//  另含 Yggdrasil 第三方认证（对应 ZL2 的 AuthServerApi）。
//

#import <Foundation/Foundation.h>
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

/// 账号列表变更通知
extern NSNotificationName const A2AccountsDidChangeNotification;

#pragma mark - Yggdrasil 第三方认证

/**
 * Yggdrasil 协议客户端（第三方认证服务器，如 LittleSkin）。
 *
 * 协议要点（对照 ZL2 的 AuthServerApi）：
 *   POST /authserver/authenticate  登录
 *   POST /authserver/refresh       续期
 *   POST /authserver/validate      校验
 * 请求体里的 agent.name 固定为 "Minecraft"，version 为 1。
 */
@interface A2YggdrasilAuth : NSObject

/// 登录
- (void)authenticateWithServer:(NSString *)serverURL
                      username:(NSString *)username
                      password:(NSString *)password
                    completion:(void (^)(A2Account * _Nullable account,
                                         NSError * _Nullable error))completion;

/// 校验令牌是否有效
- (void)validateAccount:(A2Account *)account
             completion:(void (^)(BOOL valid, NSError * _Nullable error))completion;

/// 续期
- (void)refreshAccount:(A2Account *)account
            completion:(void (^)(A2Account * _Nullable account,
                                 NSError * _Nullable error))completion;

@end

#pragma mark - 账号管理

@interface A2AccountManager : NSObject

+ (instancetype)shared;

/// 所有已保存的账号（只读，增删请用 addAccount: / removeAccount:）
@property (nonatomic, copy, readonly) NSArray<A2Account *> *accounts;
/// 当前账号（只读，切换请用 selectCurrentAccount:）
@property (nonatomic, strong, readonly, nullable) A2Account *currentAccount;

/// 从磁盘重新加载
- (void)reload;

/// 添加账号（重复的会替换）
- (void)addAccount:(A2Account *)account;

/// 移除账号
- (void)removeAccount:(A2Account *)account;

/// 切换当前账号。
/// 命名同 selectCurrentVersion: —— 不用 set 开头，
/// 因为它可能失败且返回 BOOL，而 setter 必须返回 void。
- (BOOL)selectCurrentAccount:(A2Account *)account;

/// 创建离线账号（仅需用户名）
- (A2Account *)createOfflineAccountWithName:(NSString *)name;

/// 当前账号凭据过期时自动续期
- (void)refreshCurrentAccountIfNeeded:(nullable void (^)(BOOL success,
                                                         NSError * _Nullable error))completion;

/// 按需获取账号皮肤 —— 供头像展示调用。
///
/// 已有本地皮肤文件时直接回调，不联网；否则拉取远端材质并写回账号
/// （无需调用方再保存）。离线账号无远端材质，直接回调。
/// 完成块在主线程回调，参数即传入的 account（skinPath 可能已更新）。
- (void)ensureSkinForAccount:(A2Account *)account
                  completion:(nullable void (^)(A2Account *account))completion;

/// 生成离线模式下的玩家 UUID（基于用户名，与官方算法一致）
+ (NSString *)offlineUUIDForName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END

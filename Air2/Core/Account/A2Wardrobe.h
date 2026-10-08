//
//  A2Wardrobe.h
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
//  皮肤/披风获取 —— 纯 Foundation，不碰 UIKit。
//
//  设计决策（参考 ZL2 wardrobe，不照抄实现）：
//    · 材质走 Yggdrasil 会话 profile：{host}/session/minecraft/profile/{uuid}，
//      取 properties[0].value（base64）解出 textures.SKIN.url / CAPE.url /
//      SKIN.metadata.model（slim 与 classic 之分）。
//    · 下载失败非致命：保留旧文件，只记日志不上抛（ZL2 同款语义）。
//    · 离线账号无远端材质，直接返回 nil，由调用方用本地占位。
//    · 落盘目录收敛一处：Library/Caches/A2Wardrobe/{uuid}/skin.png、cape.png。
//      游戏路径归 A2GamePath，这里是启动器缓存，不混用。
//

#import <Foundation/Foundation.h>
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

/// 皮肤模型取值（存 A2Account.skinModel，与历史字符串兼容）。
FOUNDATION_EXPORT NSString *const A2SkinModelClassic; // classic / default / wide
FOUNDATION_EXPORT NSString *const A2SkinModelSlim;    // slim

/// 纯解析结果（可单测，不碰网络与文件）。
@interface A2WardrobeTextures : NSObject
@property (nonatomic, copy, nullable) NSString *skinURL;
@property (nonatomic, copy, nullable) NSString *capeURL;
/// 取值见上方常量；无 metadata 时按 classic 处理。
@property (nonatomic, copy, nullable) NSString *skinModel;
@end

@interface A2Wardrobe : NSObject

/// 会话 profile 地址。Microsoft 走 Mojang 官方，第三方走自建 Yggdrasil。
+ (nullable NSString *)sessionProfileURLForAccount:(A2Account *)account;

/// 纯解析：profile JSON -> base64 textures -> 三个 URL/模型字段。
/// profileJSON 为 session profile 原文；失败返回 nil 并填 error。
+ (nullable A2WardrobeTextures *)parseSessionProfileJSON:(NSString *)profileJSON
                                                  error:(NSError **)error;

/// 拉取并落盘：解析远端材质，下载 skin/cape（非致命），回填 account 的
/// skinModel/skinPath/capePath。完成块在主线程回调。
/// 离线账号或无 UUID 直接完成（success=YES 但无变更）。
- (void)refreshWardrobeForAccount:(A2Account *)account
                       completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

//
//  A2ModLoaderAPI.h
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
//  模组加载器的版本查询与安装。
//
//  支持的加载器（对应 ZL2 的 addons/modloader 四类）：
//    FabricLike   Fabric / Quilt / LegacyFabric
//    ForgeLike    Forge / NeoForge
//    OptiFine     （需从官方页面解析）
//
//  数据源：
//    Fabric 系  https://meta.fabricmc.net/v2
//              https://bmclapi2.bangbang93.com/fabric-meta/v2（国内镜像）
//    Forge      https://maven.minecraftforge.net
//    NeoForge   https://maven.neoforged.net
//
//  国内镜像只在国内网络时优先，海外网络用官方源更快。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 加载器类型。对照 ZL2 的 ModLoader 枚举，逐个对齐。
///
/// 其中带 _API 后缀的是「前置模组」而非加载器本身 ——
/// 装完 Fabric 后通常还要装 Fabric API，否则多数模组跑不起来。
/// ZL2 把它们区分开（isLoader / isApiMod），我们保持同样语义。
typedef NS_ENUM(NSInteger, A2ModLoaderType) {
    // ---- 加载器 ----
    A2ModLoaderTypeFabric = 0,
    A2ModLoaderTypeQuilt,
    A2ModLoaderTypeLegacyFabric,
    A2ModLoaderTypeBabric,          ///< 给 Beta 1.7.3 用的 Fabric 分支
    A2ModLoaderTypeForge,
    A2ModLoaderTypeNeoForge,
    A2ModLoaderTypeCleanroom,       ///< Forge 1.12.2 的社区延续版
    A2ModLoaderTypeLiteLoader,
    A2ModLoaderTypeOptiFine,
    A2ModLoaderTypeRift,            ///< 1.13 时代的轻量加载器

    // ---- 前置模组（不是加载器，但安装流程相同）----
    A2ModLoaderTypeFabricAPI,
    A2ModLoaderTypeQuiltAPI,
    A2ModLoaderTypeLegacyFabricAPI,
    A2ModLoaderTypeBabricAPI,

    A2ModLoaderTypeUnknown = 99,
};

/// 该类型是否是真正的加载器（而非前置模组）
FOUNDATION_EXPORT BOOL A2ModLoaderIsLoader(A2ModLoaderType type);
/// 该类型是否是前置模组
FOUNDATION_EXPORT BOOL A2ModLoaderIsAPIMod(A2ModLoaderType type);
/// 是否支持自动安装（对照 ZL2 的 autoDownloadable）
FOUNDATION_EXPORT BOOL A2ModLoaderSupportsAutoInstall(A2ModLoaderType type);
/// 该加载器对应的前置模组（没有则返回 Unknown）
FOUNDATION_EXPORT A2ModLoaderType A2ModLoaderCompanionAPIFor(A2ModLoaderType loader);

/// 一个加载器版本
@interface A2ModLoaderVersion : NSObject
/// 加载器版本号（如 0.16.10）
@property (nonatomic, copy) NSString *version;
/// 是否为稳定版
@property (nonatomic, assign) BOOL stable;
/// 对应的加载器类型
@property (nonatomic, assign) A2ModLoaderType type;
/// 展示名（含类型前缀）
@property (nonatomic, copy, readonly) NSString *displayName;
+ (instancetype)version:(NSString *)v stable:(BOOL)stable type:(A2ModLoaderType)type;
@end

@interface A2ModLoaderAPI : NSObject

+ (instancetype)shared;

/// 查询指定加载器在某 MC 版本下的可用版本。
///
/// 会先检查该 MC 版本是否被这个加载器支持（不支持直接回调空数组）。
/// 国内网络会自动优先使用镜像源。
- (void)versionsForLoader:(A2ModLoaderType)type
              mcVersion:(NSString *)mcVersion
             completion:(void (^)(NSArray<A2ModLoaderVersion *> * _Nullable versions,
                                  NSError * _Nullable error))completion;

/// 加载器的显示名
+ (NSString *)displayNameForType:(A2ModLoaderType)type;
/// 加载器的标识（用于版本命名，如 fabric）
+ (NSString *)identifierForType:(A2ModLoaderType)type;
/// 全部支持的加载器
+ (NSArray<NSNumber *> *)allLoaderTypes;

@end

NS_ASSUME_NONNULL_END

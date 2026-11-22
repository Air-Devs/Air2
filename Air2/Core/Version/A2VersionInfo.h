//
//  A2VersionInfo.h
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
//  版本身份解析 —— 从版本 json 里拆出 MC 版本与加载器列表。
//
//  为什么独立成文件：
//    扫描、排序、列表展示都要读同一份解析结果，放在 A2Version 里会让它
//    同时管路径、配置、解析三件事；抽出来后 A2Version 只做拼装，解析可单测。
//
//  解析顺序（先写为什么这样排）：
//    · patches / clientVersion / launchFor 是整合包导出的常见位置，先看它们
//      能认出重打包的版本，不用猜文件名
//    · 再看 net.minecraft 库版本，这是 Mojang 原生记录，最可信
//    · 有 inheritsFrom 说明是继承版本，直接取被继承名
//    · 最后才从版本名正则兜底，认不出就原样返回
//    · 加载器看 libraries 的 group:artifact，不看版本名子串
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 加载器种类
typedef NS_ENUM(NSInteger, A2VersionLoaderKind) {
    A2VersionLoaderKindUnknown = 0,
    A2VersionLoaderKindForge,
    A2VersionLoaderKindNeoForge,
    A2VersionLoaderKindFabric,
    A2VersionLoaderKindLegacyFabric,
    A2VersionLoaderKindBabric,
    A2VersionLoaderKindQuilt,
    A2VersionLoaderKindLiteLoader,
    A2VersionLoaderKindCleanroom,
    A2VersionLoaderKindOptiFine,
};

/// 加载器展示名（单个词，便于列表行排版）。
FOUNDATION_EXPORT NSString *A2VersionLoaderDisplayName(A2VersionLoaderKind kind);

/// 单个加载器及其版本
@interface A2VersionLoaderInfo : NSObject

@property (nonatomic, assign, readonly) A2VersionLoaderKind kind;
/// 加载器版本，未知时为空串（不用 nil，避免展示层到处判空）。
@property (nonatomic, copy, readonly) NSString *version;

- (instancetype)initWithKind:(A2VersionLoaderKind)kind version:(nullable NSString *)version;

@end

/// 版本身份：MC 版本 + 加载器列表
@interface A2VersionInfo : NSObject

/// MC 版本（如 1.21.5），解析不到时回落到版本文件夹名。
@property (nonatomic, copy, readonly) NSString *minecraftVersion;
/// 已按加载器优先级排好序，同一加载器只保留一项。
@property (nonatomic, copy, readonly) NSArray<A2VersionLoaderInfo *> *loaderInfos;

/// 从版本 json 解析。json 非字典或取不到任何版本标识时返回 nil。
+ (nullable instancetype)infoFromJSONDictionary:(nullable NSDictionary *)json
                                     versionID:(NSString *)versionID;

/// 完整展示串（如「1.21.5, Fabric - 0.16.10」）。
- (NSString *)infoString;

/// 仅加载器部分（如「Fabric 0.16.10」，无加载器时返回 nil）。
- (nullable NSString *)loaderDisplayString;

@end

NS_ASSUME_NONNULL_END

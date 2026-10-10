//
//  A2LocalMod.h
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
//  本地模组身份 —— mods 目录里一个文件的解析结果。
//
//  只描述数据形状，不读文件、不改文件（扫描与开关在 A2ModScanner）。
//  不可变：开关启用态后文件名变了，调用方重扫拿新模型，不原地改。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 模组所属加载器（由命中哪份元数据决定）。
///
/// 与 A2ModLoaderType（加载器安装类型）不是同一个东西，那个管“装什么”，
/// 这个管“这个文件是什么”。两者分属不同域，不共用枚举；
/// 与版本身份解析的加载器枚举也不共用 —— 共用就得让 Addons 反向依赖
/// Version（那边已经依赖 Addons），环必须断在这里。
/// Legacy/Babric 不在此列：它们是游戏库概念，模组文件层分不出来，
/// 有 fabric.mod.json 的一律按 Fabric 认。
typedef NS_ENUM(NSInteger, A2ModLoaderKind) {
    A2ModLoaderKindUnknown = 0,
    A2ModLoaderKindFabric,
    A2ModLoaderKindForge,
    A2ModLoaderKindQuilt,
    A2ModLoaderKindNeoForge,
    A2ModLoaderKindOptiFine,
};

/// 加载器展示名（单个词，便于列表行排版）。
FOUNDATION_EXPORT NSString *A2ModLoaderKindDisplayName(A2ModLoaderKind kind);

/// 一个已解析（或明确解析失败）的本地模组文件。
@interface A2LocalMod : NSObject

/// 磁盘文件名（含 .disabled 后缀，用于开关与删除）。
@property (nonatomic, copy, readonly) NSString *fileName;
/// 展示名（元数据名；解析失败时为去后缀去扩展的文件名）。
@property (nonatomic, copy, readonly) NSString *displayName;
/// 模组 ID；解析失败时为空串。
@property (nonatomic, copy, readonly) NSString *modID;
/// 模组版本；解析失败或缺失时为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *version;
/// 作者列表（已去空）；解析失败时为空数组。
@property (nonatomic, copy, readonly) NSArray<NSString *> *authors;
/// 简介；缺失时为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *summary;
/// 所属加载器；解析失败时为 Unknown。
@property (nonatomic, assign, readonly) A2ModLoaderKind loaderKind;
/// 文件字节数。
@property (nonatomic, assign, readonly) long long fileSize;
/// 是否启用（无 .disabled 后缀）。
@property (nonatomic, assign, readonly, getter=isEnabled) BOOL enabled;
/// 是否解析失败（照常列出、照常可开关删，不因坏包崩列表）。
@property (nonatomic, assign, readonly, getter=isNotMod) BOOL notMod;

- (instancetype)initWithFileName:(NSString *)fileName
                    displayName:(NSString *)displayName
                          modID:(nullable NSString *)modID
                        version:(nullable NSString *)version
                        authors:(nullable NSArray<NSString *> *)authors
                        summary:(nullable NSString *)summary
                     loaderKind:(A2ModLoaderKind)loaderKind
                       fileSize:(long long)fileSize
                        enabled:(BOOL)enabled
                         notMod:(BOOL)notMod NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

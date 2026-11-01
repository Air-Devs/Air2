//
//  A2PluginPackageExtractor.h
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
//  `.air2plugin` 的字节层：中央目录预检 → 解压 → manifest 校验 → 完整性 → 内容摘要。
//
//  ## 为什么单独一层
//
//  安装器要管的是「版本规则、目录切换、注册表」这类**状态**问题；
//  「这个 zip 能不能落地」是**字节**问题。两件事混在一个文件里，
//  以后改上限就要在版本判定的函数旁边改数字，谁都不敢动。
//
//  ## 预检必须在解压之前
//
//  所有上限与路径规则都先对**中央目录**跑一遍（`A2ZipReader.entryInfos`），
//  一条不通过就一个字节都不落盘。解压后再对实际落盘路径复核一遍 ——
//  这是防「中央目录老实、本地文件头使坏」的第二道门（第一道在 zip 读取器里：
//  本地头名字必须与中央目录一致）。
//
//  ## 落盘之后的两个校验
//
//  · 完整性：`manifest.files` 每条都要在盘上存在、字节数一致、SHA-256 一致；
//    `ui/` `pages/` `assets/` `locales/` `schematics/` 下的文件必须全部在清单里
//    （PLUGIN-SYSTEM 3.2 第 4 条的双向严格相等）。
//  · 内容摘要：给注册表 `packageHash` 用，逐文件排序后拼接再取 SHA-256。
//
//  两步都要，因为它们回答的是不同问题：完整性问「盘上这堆字节是不是作者声明的那堆」，
//  摘要问「两个包是不是同一份内容」。
//

#import <Foundation/Foundation.h>

#import "A2PluginManifest.h"

NS_ASSUME_NONNULL_BEGIN

/// 一次成功解包的结果。
@interface A2PluginPackage : NSObject

/// 解压落地的根目录（manifest.json 就在这一层）。
@property (nonatomic, copy, readonly) NSString *rootDirectory;

/// 已通过 schema + 语义 + 宿主能力门校验的 manifest。
@property (nonatomic, strong, readonly) A2PluginManifest *manifest;

/// 内容摘要：64 位小写 hex，**不带** `sha256:` 前缀。
/// 算法（改它就是改注册表里所有历史哈希的含义）：
/// 把包内所有文件按路径的 UTF-8 字节序排序，逐个喂给 SHA-256：
/// `<路径>\0<字节数>\0<该文件 SHA-256 的 64 位 hex>\n`
@property (nonatomic, copy, readonly) NSString *contentHash;

@end

@interface A2PluginPackageExtractor : NSObject

/// @param limits 用 `A2PluginDefaultLimits()` 起步，别自己摆字段（0 会被当成「上限为零」）。
- (instancetype)initWithLimits:(A2PluginLimits)limits NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, assign, readonly) A2PluginLimits limits;

/// 校验并解压到 `destination`（不存在就建）。
/// 失败时 `destination` 里可能留下半截文件 —— 调用方负责删掉它（安装器删的是上一层 staging）。
- (nullable A2PluginPackage *)extractPackageAtURL:(NSURL *)url
                                    intoDirectory:(NSString *)destination
                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

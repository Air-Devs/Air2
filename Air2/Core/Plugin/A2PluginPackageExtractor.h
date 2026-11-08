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
//  · 完整性：`manifest.files` 每条都要在盘上存在、字节数一致、SHA-256 一致（分块算，
//    不整文件读进内存）；反过来，盘上除 `manifest.json` 外的每个文件也必须写在清单里
//    —— 双向严格相等（`plugin.schema.json` 的 `files` 描述 / `PLUGIN-AUTHORING` 第二节
//    第 2 条）。多一个文件是夹带，少一个文件是清单说谎。
//  · 内容摘要：给注册表 `packageHash` 用，逐文件排序后拼接再取 SHA-256。
//
//  两步都要，因为它们回答的是不同问题：完整性问「盘上这堆字节是不是作者声明的那堆」，
//  摘要问「两个包是不是同一份内容」。
//
//  ## 贡献点校验（P2）也在这里做，而且只做一次
//
//  manifest 解析成功之后先跑 `A2PluginContributionSet`（slot / component / token 词表、
//  贡献点之间的冲突、权限配套、宿主版本区间、里程碑门），**再**去算哈希：
//  · 语义不成立的包不该先花一遍 SHA-256；
//  · 校验结果就是 `A2PluginPackage.contributionSet` —— 安装器直接把它接进贡献点注册表，
//    「一个包能贡献什么」在整条安装链上只解析一次（安装器不再重读 manifest）。
//  失败沿用 P1 的错误结构：同一个 domain、同一个 `A2PluginErrorCodeKey`，不另造一套码。
//
//  ## 仅测试用的解压节流
//
//  环境变量 `A2_PLUGIN_TEST_SLOW_MS`（毫秒）：解压每个文件**前后各一次**、逐文件校验每文件一次，
// 各 sleep 指定毫秒，好让验收能在解压中途杀进程、看暂存目录与 registry 的原子性。默认不设 = 0，
//  生产路径只多一次 `if (0 == 0) return;`。不要把它做成配置项或 UI 开关。
//

#import <Foundation/Foundation.h>

#import "A2PluginContribution.h"
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

/// 已通过 P2 贡献点深校验的贡献集（slot / 主题 token / 版本装饰）。
///
/// 安装成功时由 `A2PluginInstaller` 直接接进 `A2PluginContributionRegistry` ——
/// 安装链上不再重读 manifest，也就不会出现「校验过的」和「接进注册表的」两份不同结果。
@property (nonatomic, strong, readonly, nullable) A2PluginContributionSet *contributionSet;

@end

@interface A2PluginPackageExtractor : NSObject

/// @param limits 用 `A2PluginDefaultLimits()` 起步，别自己摆字段（0 会被当成「上限为零」）。
- (instancetype)initWithLimits:(A2PluginLimits)limits NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, assign, readonly) A2PluginLimits limits;

/// 宿主版本（`x.y.z`）：贡献点校验拿它比 `air2.host.minHostVersion` / `maxHostVersion`。
///
/// 取值**只有这一处**：`CFBundleShortVersionString`（打包脚本把 `MARKETING_VERSION` 写进
/// Info.plist，所以它就是发布版本的真相）；拿不到、或不是 `x.y.z` 形式时回落到 `0.0.0`
/// （单测二进制没有 Info.plist）。**回落值必须是合法 semver**：拿 `0` 去比，
/// 每个声明了 `minHostVersion` 的包都会被判成「宿主太旧」—— 那是把装配问题伪装成包的问题。
@property (nonatomic, copy, readonly) NSString *hostVersion;

/// 宿主里程碑：决定 `type: js` 与 `formatVersion: 3` 能不能装（见 `A2PluginHostMilestone`）。
///
/// 默认 `A2PluginHostMilestoneP2`（只有纯 JSON 声明）。`A2PluginInstaller` 按自己的
/// `allowsJSPlugins` 把它抬到 `A2PluginHostMilestoneP3a` —— 两个门必须是同一个答案，
/// 否则同一个 js 包会被「能力门」放行、被「贡献点校验」拒装（或反过来）。
@property (nonatomic, assign) A2PluginHostMilestone hostMilestone;

/// 校验并解压到 `destination`（不存在就建）。
/// 失败时 `destination` 里可能留下半截文件 —— 调用方负责删掉它（安装器删的是上一层 staging）。
- (nullable A2PluginPackage *)extractPackageAtURL:(NSURL *)url
                                    intoDirectory:(NSString *)destination
                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

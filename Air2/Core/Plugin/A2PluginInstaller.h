//
//  A2PluginInstaller.h
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
//  插件安装器：把 `.air2plugin` 变成一个可被加载的安装，以及卸载与回退。
//
//  ## 只做「状态」，不做「字节」
//
//  zip 的安全校验、解压、manifest 校验、完整性、内容摘要都在
//  `A2PluginPackageExtractor`；本层管的是：版本规则（PLUGIN-SYSTEM 4.5）、
//  目录切换（4.3 的原子性）、注册表写入（4.2 的 ⑥⑦）、卸载与回退（4.6 / 4.5）。
//
//  ## 目录布局
//
//    <Plugins>/<pluginId>/<version>/            当前版本（registry 指向的这一版）
//    <Plugins>/<pluginId>/<oldVersion>/         升级前的那一版（换目录后短暂存在）
//    <Plugins>/packages/<pluginId>@<hash>/      保留下来的上一版（回退的来源）
//    <Plugins>/.staging/<uuid>/root/            解压暂存（失败即删）
//
//  为什么保留版放在 `packages/` 而不是 `<pluginId>/` 下：加载器按
//  `<pluginId>/<registry.version>` 拼路径，目录里多出来的版本不该被它看到；
//  用内容哈希命名还能一眼看出「保留的是哪一份内容」。
//
//  ## 崩溃窗口
//
//  换目录与新版本目录的建立都是同卷 `rename(2)`，注册表是原子替换。
//  顺序是「新目录就位 → 写注册表 → 把旧目录收进 packages/」，任何时刻中断，
//  注册表指向的目录都在（这正是 4.3 的保证）。反过来先搬旧目录的话，
//  中断会留下「注册表指向一个已经不存在的目录」—— 那是最糟的状态。
//

#import <Foundation/Foundation.h>

#import "A2PluginManifest.h"

@class A2PluginRegistry;
@class A2PluginRegistryEntry;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 来源

/// 安装来源（v3 的 `source{kind, detail, installedAt}`）。
/// 只陈述事实：不做好坏判断、不挂徽标（ADR-024）。
@interface A2PluginInstallSource : NSObject

/// `local-import` / `url` / `share-sheet` / `dev-dir`。
@property (nonatomic, copy, readonly) NSString *kind;

/// 文件名或域名，可为空。
@property (nonatomic, copy, readonly, nullable) NSString *detail;

/// 本次安装时间（ISO-8601，UTC）。
@property (nonatomic, copy, readonly) NSString *installedAt;

/// 校验 kind 并盖上「现在」的时间戳；kind 不在枚举内返回 nil 并给 `E_FIELD`。
+ (nullable instancetype)sourceWithKind:(NSString *)kind
                                 detail:(nullable NSString *)detail
                                  error:(NSError **)error;

/// 时间戳自己给（单测固定时间用；正式代码走上面那个）。
+ (instancetype)sourceWithKind:(NSString *)kind
                        detail:(nullable NSString *)detail
                   installedAt:(NSString *)installedAt;

@end

#pragma mark - 结果

/// 一次安装的结果。
@interface A2PluginInstallResult : NSObject

/// 落盘后的注册表条目。
@property (nonatomic, strong, readonly) A2PluginRegistryEntry *entry;

/// 包内容摘要（64 位小写 hex，不带 `sha256:` 前缀）。
@property (nonatomic, copy, readonly) NSString *contentHash;

/// YES = 同 id 同版本同内容，本次只做了校验、没动磁盘（4.5 的幂等重装）。
@property (nonatomic, assign, readonly) BOOL reusedExisting;

@end

#pragma mark - 安装器

@interface A2PluginInstaller : NSObject

/// @param registry 注册表实例（由装配处注入，本类不持有单例 —— 单例会让单测互相污染）。
- (instancetype)initWithRegistry:(A2PluginRegistry *)registry NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, strong, readonly) A2PluginRegistry *registry;

/// 安装期上限，默认 `A2PluginDefaultLimits()`。
@property (nonatomic, assign) A2PluginLimits limits;

/// 开发者模式：允许降级安装（4.5）。默认 NO。
/// 放行后 UI 要标「降级」并额外确认 —— 那是界面的事，这里只负责不拒。
@property (nonatomic, assign) BOOL allowsDowngrade;

/// 宿主阶段是否支持 `type: js`。P1/P2 为 NO（4.2 ③ 的宿主能力门），P3a 起由装配处打开。
@property (nonatomic, assign) BOOL allowsJSPlugins;

/// 随 App 打包、不允许卸载的插件 id（装配处传入）。
/// 安装器**不猜**：猜错的后果是把用户自己装的插件当成内置，卸载永远失败。
@property (nonatomic, copy) NSSet<NSString *> *builtinPluginIds;

/// 日志出口，默认走 `A2Log`。单测塞一个收集器来断言关键步骤各有一行。
@property (nonatomic, copy, nullable) void (^logSink)(NSString *line);

/// 安装一个包。
/// 前置条件：调用方已拿到本地文件 URL（网络包由下载层先落地）。
/// @param source 来源事实；kind 不在枚举内会以 `E_FIELD` 拒装
- (nullable A2PluginInstallResult *)installPackageAtURL:(NSURL *)url
                                                 source:(A2PluginInstallSource *)source
                                                  error:(NSError **)error;

/// 卸载：先删注册表条目（注册表是唯一事实来源，条目没了就不再被加载），再删目录。
/// 删目录失败**不算失败**（4.6 第 3 条：下次启动按孤儿目录清理），但会写一行日志。
- (BOOL)uninstallPluginId:(NSString *)pluginId error:(NSError **)error;

/// 回退到保留的上一版：把 `packages/<id>@<hash>` 换回 `<id>/<version>`，注册表跟着改。
/// 不受降级拒装规则限制（4.5：这是本地已有版本，不是新装一个低版本包）。
- (BOOL)rollbackPluginId:(NSString *)pluginId error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

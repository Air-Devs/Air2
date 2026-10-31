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

/// 启动链闸门：安装期的 10 次免责确认挂在这里（判据见 `A2PluginLaunchChainRisk`）。
///
/// 调用时机由安装器决定：**校验 + 版本规则都通过之后、换目录和写 registry 之前**，
/// 且**只对「会修改启动链的插件」调用一次**（其余插件根本不进闸门）。
/// 入参 `permissions` = 命中判据的权限 id（固定顺序，非空）。
///
/// 返回 YES = 用户确认通过，安装继续；NO = 取消（安装器清暂存、不写 registry、
/// 以 `A2PluginErrorUserCancelled` 失败返回）。
///
/// ★实现里可以阻塞★：10 次弹窗本来就要等用户点完，闸门是同步返回的。
/// 因此**安装必须在非主线程执行**（弹窗自己跳主线程，见 `A2PluginLaunchChainConfirm`）。
/// ★不要在闸门里做别的判断★（「要不要弹」只由安装器 + 判据集合决定）。
typedef BOOL (^A2PluginLaunchChainGate)(A2PluginManifest *manifest,
                                        NSArray<NSString *> *permissions);

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

/// 安装一个包。**必须**在非主线程调用（会修改启动链的插件要在这里等用户点 10 次确认）。
/// 前置条件：调用方已拿到本地文件 URL（网络包由下载层先落地）。
/// @param source 来源事实；kind 不在枚举内会以 `E_FIELD` 拒装
/// @param launchChainGate 启动链闸门（见 `A2PluginLaunchChainGate`）。
///        ★会修改启动链的插件传 nil ⇒ 以 `E_LAUNCH_CHAIN_UNCONFIRMED` 拒装★（不静默放行）；
///        不修改启动链的插件永不调用它。
- (nullable A2PluginInstallResult *)installPackageAtURL:(NSURL *)url
                                                 source:(A2PluginInstallSource *)source
                                       launchChainGate:(nullable A2PluginLaunchChainGate)launchChainGate
                                                  error:(NSError **)error;

/// 不带启动链闸门的安装（等价于 `launchChainGate:nil`）。
///
/// 只给「确定不会修改启动链的调用方」用：单测、离线迁移、内置插件装配。
/// ★会修改启动链的包在这里一定被拒★（`E_LAUNCH_CHAIN_UNCONFIRMED`）——
/// 少传一个参数就能跳过 10 次确认的话，那道确认门等于不存在。
- (nullable A2PluginInstallResult *)installPackageAtURL:(NSURL *)url
                                                 source:(A2PluginInstallSource *)source
                                                  error:(NSError **)error;

/// 读取该插件**当前已安装这一版**的 manifest（`<Plugins>/<id>/<registry.version>/manifest.json`）。
///
/// 管理页 / 授权页需要它来显示名字、作者（自述）、申请的权限集与主版本号；
/// 目录布局的知识只在安装器里留一份，UI 不自己拼路径（ARCHITECTURE：View 不拼路径）。
///
/// 读之前先 `loadWithError:` 重读注册表：返回的 manifest 必须与磁盘上的
/// `registry.version` 一致，拿旧条目的版本号去拼路径会读到已经不存在的目录。
/// 失败原因：没装（注册表里没有这个条目）/ 注册表读不出来 / 目录里没有 manifest.json /
/// manifest 校验不过（被改过或损坏）。调用方按「这个插件现在不可用」处理。
- (nullable A2PluginManifest *)installedManifestForPluginId:(NSString *)pluginId
                                                     error:(NSError **)error;

/// 写 registry 的 `enabled`（用户开关）。注册表负责原子写，本方法只做两件事：
/// 改字段、盖 `updatedAt`，写失败时把内存拨回去（失败后 registry 仍是磁盘上的状态）。
///
/// 为什么放在这里而不是让管理页直接改条目：`updatedAt` 属于写入规则，
/// 界面上改 registry 字段等于把一条写入规则抄进 View（ARCHITECTURE：View 不内嵌实现）。
///
/// 已知缺口：PLUGIN-SECURITY 3.4 补充规则 7 要求用户动配置时 `userSeq + 1`，
/// 但 `A2PluginRegistry.userSeq` 目前只有只读属性、没有自增入口（与 ③ 同一个缺口），
/// 所以这里不写一个假的 `userSeq`。
- (BOOL)applyEnabled:(BOOL)enabled forPluginId:(NSString *)pluginId error:(NSError **)error;

/// 卸载：先删注册表条目（注册表是唯一事实来源，条目没了就不再被加载），再删目录。
/// 删目录失败**不算失败**（4.6 第 3 条：下次启动按孤儿目录清理），但会写一行日志。
- (BOOL)uninstallPluginId:(NSString *)pluginId error:(NSError **)error;

/// 回退到保留的上一版：把 `packages/<id>@<hash>` 换回 `<id>/<version>`，注册表跟着改。
/// 不受降级拒装规则限制（4.5：这是本地已有版本，不是新装一个低版本包）。
- (BOOL)rollbackPluginId:(NSString *)pluginId error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

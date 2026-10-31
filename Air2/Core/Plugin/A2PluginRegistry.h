//
//  A2PluginRegistry.h
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
//  插件注册表（`Plugins/registry.json`）—— 插件系统唯一的**事实来源**。
//
//  ## 位置
//
//    <App 容器>/Library/Application Support/Air2/Plugins/registry.json
//
//  为什么放 Application Support 而不是 Documents：Documents 在开文件共享时
//  对第三方文件 App 可见可写，用户手改插件目录后哈希校验就只能「要么拒载、
//  要么信任篡改」，两头都不对（PLUGIN-SYSTEM 4.1）。
//
//  ## 原子写
//
//  写临时文件 → `fsync(文件)` → `rename` → `fsync(目录)`。
//  崩溃后读到的永远是某一个完整版本，不会读到半截 JSON；
//  目录切换本身（`.staging` → `<id>/<version>`）也靠同卷 rename。
//
//  ## 读失败**不覆写**
//
//  `loadWithError:` 解析失败时只返回错误，**一个字节都不动原文件**。
//  「损坏就重建空表」是启动流程（Phase A 第 4 条）的决定，要先把原文件改名成
//  `registry.json.corrupt-<时间戳>` 再做 —— 放在这一层做等于把用户数据
//  在没有任何副本的情况下抹掉，无法接受。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 注册表错误的错误域（与安装期 manifest 错误分开：一个是「包不合格」，
/// 一个是「表写不下去」，管理页展示的位置也不同）。
extern NSString *const A2PluginRegistryErrorDomain;

typedef NS_ENUM(NSInteger, A2PluginRegistryError) {
    /// 文件存在但读不出来（权限 / IO）。
    A2PluginRegistryErrorRead = 1,
    /// 内容不是合法注册表（解析失败 / 结构不符）。原文件保持不动。
    A2PluginRegistryErrorFormat,
    /// 写盘失败（建目录 / 写临时文件 / fsync / rename）。
    A2PluginRegistryErrorWrite,
    /// 条目本身不合法（缺 id、哈希格式错、source.kind 不在枚举内）。
    A2PluginRegistryErrorInvalidEntry,
};

/// `approvedHashes` 保留的最近内容版本数（PLUGIN-SECURITY 3.4：最多 5 个）。
FOUNDATION_EXPORT const NSUInteger A2PluginRegistryMaxApprovedHashes;

/// 注册表自身的结构版本（**不是**包的 formatVersion，同名不共义）。
FOUNDATION_EXPORT const NSInteger A2PluginRegistryFormatVersion;

/// 一条 critical 权限的授权记录。主键是 `(pluginId, permissionId)`；
/// **不记也不比对** packageHash —— v3 的授权绑定权限集，不绑定包字节（ADR-024）。
@interface A2PluginCriticalGrant : NSObject

/// 权限 id（如 `launch.args`）。
@property (nonatomic, copy, readonly) NSString *permissionId;

/// 授权时间（ISO-8601，UTC）。
@property (nonatomic, copy, readonly) NSString *grantedAt;

/// 授权方式：`three-step`（三次 5 秒确认）/ `migrated`（从 v2 注册表迁移）。
@property (nonatomic, copy, readonly) NSString *method;

/// 授权时的宿主版本。
@property (nonatomic, copy, readonly) NSString *hostVersion;

/// 授权时插件的主版本号（跨 major 升级要重确认，靠它判定）。
@property (nonatomic, assign, readonly) NSInteger majorVersion;

/// 从 JSON 字典还原；缺关键字段返回 nil。
+ (nullable instancetype)grantWithDictionary:(NSDictionary<NSString *, id> *)dictionary;

/// 落盘用的字典。
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

@end

/// registry.json 里 `plugins[]` 的一条。
@interface A2PluginRegistryEntry : NSObject

@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *version;

/// 全量内容摘要（`sha256:<64 hex>` 或裸 64 hex）。用于完整性、重装幂等与展示，
/// **不是**授权绑定键。
@property (nonatomic, copy) NSString *packageHash;

/// 来源种类：`local-import` / `url` / `share-sheet` / `dev-dir`。
/// 只陈述事实，不做好坏判断、不挂徽标（ADR-024）。
@property (nonatomic, copy) NSString *sourceKind;

/// 来源细节（文件名 / 域名），可为空。
@property (nonatomic, copy, nullable) NSString *sourceDetail;

/// 本次安装时间（ISO-8601）。升级也更新它（首次安装时间看 `installedAt`）。
@property (nonatomic, copy) NSString *sourceInstalledAt;

/// 用户实际授予的低/中权限（可能少于 manifest 申请集）。
@property (nonatomic, copy) NSArray<NSString *> *permissionsGranted;

/// critical 权限的逐项授权记录（主键 `(pluginId, permissionId)`）。
@property (nonatomic, copy) NSArray<A2PluginCriticalGrant *> *criticalGrants;

/// 上一版 manifest 的规范化权限集：`id:risk` 按 id 排序、`\n` 连接。
/// 用途：升级时不必保留旧目录就能判定「权限集是否变了」。
@property (nonatomic, copy) NSString *permissionSet;

/// 用户同意过的内容版本白名单（最多 5 个，新值前插）。
/// 只取证、不授权：清空它不影响授权有效性，塞哈希也拿不到能力。
@property (nonatomic, copy, readonly) NSArray<NSString *> *approvedHashes;

/// 授权变更序号：授予 / 撤销 / 审查都 +1；加载时用它判断「能力面是否变过」。
@property (nonatomic, assign) NSInteger grantRevision;

/// 用户开关。
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 首次安装时间（升级不改）。
@property (nonatomic, copy) NSString *installedAt;

/// 本条记录最后写入时间。
@property (nonatomic, copy) NSString *updatedAt;

/// 记一次「用户在这个内容版本上点过同意」：规范化后前插、去重、最多留 5 个。
/// 哈希格式不合法（非 64 位小写 hex）时返回 NO，不动现有列表。
- (BOOL)noteApprovedHash:(NSString *)packageHash;

/// 写前校验（注册表 save 时逐条跑）。失败时给出具体字段。
- (BOOL)validateWithError:(NSError **)error;

/// 从 JSON 字典还原；结构不合法返回 nil。
+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error;

/// 落盘用的字典。
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

@end

/// 注册表：整表读、整表原子写。**只有宿主写**，插件 API 里没有任何写入口。
@interface A2PluginRegistry : NSObject

/// @param pluginsDirectory `.../Air2/Plugins`；传 nil 用容器内的默认路径。
///        单测传临时目录，因此这里不提供单例 —— 单例会让测试互相污染。
- (instancetype)initWithPluginsDirectory:(nullable NSString *)pluginsDirectory
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// 默认的 `.../Air2/Plugins` 目录（Application Support 下，不进备份）。
@property (class, nonatomic, copy, readonly, nullable) NSString *defaultPluginsDirectory;

/// 本实例使用的 Plugins 目录。
@property (nonatomic, copy, readonly) NSString *pluginsDirectory;

/// `.../registry.json`。
@property (nonatomic, copy, readonly) NSString *registryPath;

/// 单调递增写计数（每次成功写 +1），用于诊断「注册表是否被外部改过」。
@property (nonatomic, assign, readonly) NSInteger seq;

/// 用户配置序号：用户装/卸/开关/改授权时 +1；宿主自动禁用**不** +1。
@property (nonatomic, assign, readonly) NSInteger userSeq;

/// 按 pluginId 升序的全部条目。
- (NSArray<A2PluginRegistryEntry *> *)allEntries;

/// 按 id 查一条。
- (nullable A2PluginRegistryEntry *)entryForPluginId:(NSString *)pluginId;

/// 读表。文件不存在视为空表（返回 YES，不建文件）；内容损坏返回 NO 且**不覆写**。
- (BOOL)loadWithError:(NSError **)error;

/// 全量原子重写（seq +1）。
- (BOOL)saveWithError:(NSError **)error;

/// 插入或替换一条并落盘（先校验条目）。写盘失败时内存回滚，保持「内存 == 磁盘」。
- (BOOL)upsertEntry:(A2PluginRegistryEntry *)entry error:(NSError **)error;

/// 删一条并落盘。
- (BOOL)removeEntryForPluginId:(NSString *)pluginId error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

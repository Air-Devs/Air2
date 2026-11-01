//
//  A2PluginPermissionStore.h
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
//  权限存储 + 权限目录（PLUGIN-SECURITY v3 §2 / §3.1 / §3.3 / §3.4 / §9）。
//
//  ## 这一层是什么
//
//  1. **registry 里那四个字段的唯一读写入口**：
//     `permissionsGranted`（低/中）、`criticalGrants`（critical 逐项）、
//     `approvedHashes`（取证白名单）、`grantRevision`（能力面序号）。
//     谁能授予、什么时候失效，全部由 §3.4 那张表决定，判定只写在这里 ——
//     UI 不允许自己拼「这条算不算已授权」。
//
//  2. **权限目录的静态表**（24 项）：风险级、后果分组、人话名称、§9 人话后果整句、
//     一句话定义、允许的操作、硬边界、危害场景（critical 才需要）、生效里程碑。
//     UI 只能从这里取文案：§9 的硬要求是「凡是出现权限的地方都显示同一句人话后果」，
//     文案一旦在 UI 里另抄一份，两处早晚不一致（改文档的人只改一处）。
//
//  ## 为什么授权不绑定 packageHash
//
//  v3（ADR-024）把 critical 的绑定对象从「包字节」改成「权限集」：主键恒为
//  `(pluginId, permissionId)`，`packageHash` 只写进 `approvedHashes` 取证。
//  所以只改图标 / README 的更新不会让用户把 3～10 个 critical 的三次确认连点一遍 ——
//  那会把三次确认变成纯仪式，比不重确认更危险。
//
//  ## 安装期的低/中默认值不在这里
//
//  「低/中默认开启」的写入点在 `A2PluginInstaller`（安装 / 回退时按
//  「曾申请过且用户没关」的规则写 `permissionsGranted`）。本类只处理**安装之后**的
//  逐项变更与重确认判定 —— 同一套默认值规则只留一份实现，避免两处漂移。
//  `grantPermission:` 因此只用于「用户把某个低/中权限从关切回开」。
//
//  ## 已知缺口（不在本单范围）
//
//  §3.4 补充规则 7 还要求改动授权时 registry 的 `userSeq + 1`（崩溃归因用它判断
//  「用户动过插件配置」）。`userSeq` 是注册表的写入口字段，本类只 +`grantRevision`；
//  `userSeq` 的自增属于注册表 / 崩溃归因那一单。

#import <Foundation/Foundation.h>

#import "A2PluginManifest.h"

@class A2PluginRegistry;
@class A2PluginRegistryEntry;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 错误

/// 权限存储的错误域（与安装期的 `A2PluginErrorDomain` 分开：
/// 一个是「包不合格」，一个是「授权这件事没做成」，管理页展示的位置也不同）。
extern NSString *const A2PluginPermissionStoreErrorDomain;

typedef NS_ENUM(NSInteger, A2PluginPermissionStoreError) {
    /// 权限目录里没有这个 id。
    A2PluginPermissionStoreErrorUnknownPermission = 1,
    /// registry 里没有这个插件（没装，或 id 写错）。
    A2PluginPermissionStoreErrorNotInstalled,
    /// 调用方没给 manifest，或 manifest 的 pluginId 为空（装配错误）。
    A2PluginPermissionStoreErrorInvalidManifest,
    /// manifest 没申请这个权限 —— 授予一个没申请的能力是没有意义的。
    A2PluginPermissionStoreErrorNotRequested,
    /// critical 权限被一次性调用授予：必须走三次确认（§3.3）。
    A2PluginPermissionStoreErrorCriticalNeedsConfirmation,
    /// `packageHash` 格式不合法（不是 64 位 hex）。
    A2PluginPermissionStoreErrorInvalidHash,
    /// 落盘失败（注册表写不下去）。内存已回滚，`registry` 仍是磁盘上的状态。
    A2PluginPermissionStoreErrorWrite,
};

/// 构造一条权限存储错误：域 + 一句话原因。
FOUNDATION_EXPORT NSError *A2PluginPermissionErrorMake(A2PluginPermissionStoreError code,
                                                       NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);

#pragma mark - 权限分组（§3.2.1）

/// 后果分组。顺序固定、不随插件申请集变化 —— 用户第二次打开时位置必须一致。
typedef NS_ENUM(NSInteger, A2PluginPermissionGroup) {
    /// 改游戏文件 —— 能修改游戏内容（等同直接装 mod，可执行代码）
    A2PluginPermissionGroupGameFiles = 0,
    /// 联网 —— 能把数据发到网上 / 从网上下载东西
    A2PluginPermissionGroupNetwork,
    /// 读你的数据 —— 能查看你的游戏文件与配置
    A2PluginPermissionGroupReadData,
    /// 启动参数 —— 能改游戏如何启动（可注入代码）
    A2PluginPermissionGroupLaunch,
    /// 改界面 —— 能改启动器看起来的样子
    A2PluginPermissionGroupInterface,
    A2PluginPermissionGroupCount,
};

/// 组标题。写后果，不写「启动类 / 文件类 / 界面类」这类权限分类名，也不写「权限」二字。
FOUNDATION_EXPORT NSString *A2PluginPermissionGroupTitle(A2PluginPermissionGroup group);

/// 组标题后面那句解释（折叠态用副标题展示）。
FOUNDATION_EXPORT NSString *A2PluginPermissionGroupConsequence(A2PluginPermissionGroup group);

#pragma mark - 生效里程碑

/// 权限生效的插件系统里程碑（`PLUGIN-SECURITY` 第二节「生效」列的取值）。
/// 比较按枚举值大小：宿主里程碑 < 权限里程碑 ⇒ 「当前版本不可用」，开关禁用。
typedef NS_ENUM(NSInteger, A2PluginMilestone) {
    /// 本单所处的阶段：只有安装器 / 注册表 / 权限存储，**没有任何权限对应的 API 面**。
    A2PluginMilestoneP1 = 1,
    A2PluginMilestoneP2,
    A2PluginMilestoneP3a,
    A2PluginMilestoneP3b,
    A2PluginMilestoneP4,
    A2PluginMilestoneP5,
};

/// 里程碑的展示名（`P3a` / `P4` …）。
FOUNDATION_EXPORT NSString *A2PluginMilestoneName(A2PluginMilestone milestone);

#pragma mark - 目录条目

/// 权限目录的一条。只读：构造完不再改，UI 可以随意传递。
@interface A2PluginPermissionInfo : NSObject

/// 权限 id（如 `launch.args`）。
@property (nonatomic, copy, readonly) NSString *permissionId;

/// 风险级（来自 `A2PluginRiskForPermission`，目录里不再写第二份）。
@property (nonatomic, assign, readonly) A2PluginRisk risk;

/// 后果分组（§3.2.1，24 项全覆盖且互斥）。
@property (nonatomic, assign, readonly) A2PluginPermissionGroup group;

/// 生效里程碑。
@property (nonatomic, assign, readonly) A2PluginMilestone milestone;

/// 人话名称（确认页标题「高危权限：<人话名称>」用它）。
@property (nonatomic, copy, readonly) NSString *shortName;

/// §9 的人话后果整句（**原文**，展示处一律用它）。
@property (nonatomic, copy, readonly) NSString *consequence;

/// 一句话定义（确认页第 1 次）。
@property (nonatomic, copy, readonly) NSString *definition;

/// 允许的具体操作（逐条，最多 5 条）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *allowedOperations;

/// 硬边界：这个权限**不能**做什么。
@property (nonatomic, copy, readonly) NSString *boundary;

/// 危害场景（确认页第 2 次，至少 2 条；非 critical 为空数组）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *harmScenarios;

@end

/// 风险级的展示名：`低` / `中` / `高危`。
FOUNDATION_EXPORT NSString *A2PluginRiskDisplayName(A2PluginRisk risk);

/// 整个权限目录（24 项，按 `A2PluginPermissionGroup` 分组顺序排列）。
FOUNDATION_EXPORT NSArray<A2PluginPermissionInfo *> *A2PluginPermissionCatalog(void);

/// 按 id 查目录条目；目录外的 id 返回 nil。
FOUNDATION_EXPORT A2PluginPermissionInfo *_Nullable A2PluginPermissionInfoForId(
    NSString *permissionId);

#pragma mark - 存储

/// 读写 registry 里的授权字段。**只有宿主 UI 能调**，插件 API 里没有写入口。
@interface A2PluginPermissionStore : NSObject

/// @param registry 注册表实例（由装配处注入；单例会让单测互相污染）。
- (instancetype)initWithRegistry:(A2PluginRegistry *)registry NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, strong, readonly) A2PluginRegistry *registry;

#pragma mark 授予 / 撤销

/// 授予一个**低 / 中**权限（用户把开关从关切回开）。
/// critical 走 `grantCriticalPermission:` —— 这里直接以
/// `A2PluginPermissionStoreErrorCriticalNeedsConfirmation` 失败，
/// 保证「一次点击授予高危」在类型层面就不存在。
/// 已经授予过是幂等的：不写盘、不动 `grantRevision`。
- (BOOL)grantPermission:(NSString *)permissionId
              forPlugin:(A2PluginManifest *)manifest
                  error:(NSError **)error;

/// 授予一个 critical 权限。**调用方必须是三次确认的第 3 步**
/// （`A2PluginCriticalConfirmFlow`）；本方法只负责落库：
/// 写 `criticalGrants`（`grantedAt` / `method:"three-step"` / `hostVersion` / `majorVersion`）、
/// `grantRevision + 1`，并把当前 `packageHash` 追加进 `approvedHashes`。
- (BOOL)grantCriticalPermission:(NSString *)permissionId
                      forPlugin:(A2PluginManifest *)manifest
                          error:(NSError **)error;

/// 撤销一项授权（低/中从 `permissionsGranted` 移除，critical 从 `criticalGrants` 移除）。
/// 未授予过是幂等的：不写盘、不动 `grantRevision`。
- (BOOL)revokePermission:(NSString *)permissionId
               forPlugin:(A2PluginManifest *)manifest
                   error:(NSError **)error;

#pragma mark 查询

/// 这一项现在是不是已授权（低/中看 `permissionsGranted`，critical 看 `criticalGrants`）。
- (BOOL)isGranted:(NSString *)permissionId forPlugin:(NSString *)pluginId;

/// 这次安装 / 更新里**需要重走三次确认**的 critical 权限（§3.4 的判定结果，逐项）。
/// 判定只看两件事：这一项还没被授予过，或授予时的 `majorVersion` 与当前 `major` 不等。
/// 权限集缩小 / critical 降级为中风险不在结果里 —— 那两个方向不弹窗。
- (NSArray<NSString *> *)criticalPermissionsAwaitingConfirmationForManifest:
                                (A2PluginManifest *)manifest
                                                                     error:(NSError **)error;

/// 这次安装 / 更新到底要不要弹三次确认。
/// 等价于「`criticalPermissionsAwaitingConfirmationForManifest:error:` 非空」，
/// 单独存在是因为调用方常只需要一个 BOOL（更新页那一行文案）。
/// @param packageHash 只用于诊断日志与格式校验（v3 的判定**不**看它，见 ADR-024）；
///                    传 nil 表示「本次不知道内容哈希」，判定照常进行
- (BOOL)needsReconfirmForManifest:(A2PluginManifest *)manifest
                      packageHash:(nullable NSString *)packageHash
                            error:(NSError **)error;

#pragma mark 取证

/// 记一次「用户在这个内容版本上点过同意」：规范化后前插、去重、最多留 5 个。
/// **它不授予任何东西**：清空它不影响授权有效性，塞哈希也拿不到能力。
/// 调用点：授权页「完成」时（内容更新但权限集未变的那种情况，见 §3.4 上表第 1 行）。
- (BOOL)noteApprovedHash:(NSString *)packageHash
               forPlugin:(NSString *)pluginId
                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

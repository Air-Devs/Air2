//
//  A2PluginContribution.h
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
//  插件贡献点（P2 第一步）：manifest v2 的**纯 JSON 声明**深校验 + 纯内存注册表。
//
//  ## 这一层在整条链里的位置
//
//    zip 层（A2PluginPackageExtractor）
//      → ① manifest 浅校验 / 宿主能力门（A2PluginManifest，P1 已完成）
//      → ② **贡献点深校验**（本文件：slot / theme / versionDecorate / settings）
//      → ③ 完整性哈希 → ④ 授权 → ⑤ 换目录 → ⑥ 写 registry
//      → 运行时 Phase A：把 ② 的结果装进 `A2PluginContributionRegistry`
//
//  P1 的 `A2PluginManifest` 对 `ui` / `contributes` 只做到「键名在白名单、类型对、
//  v2 里没有 v3 字段」。**它不认识 slot 词表、不认识 token、不知道谁要独占什么** ——
//  这些是本层的职责。反过来，本层**不重复**做 P1 的字段校验（id / name / version /
//  platforms / files 全归 P1），两层的分工是「结构」对「语义」。
//
//  ## 硬约束：P2 只有声明，没有代码
//
//  `type: js` 的包在 P2 宿主上**拒装**（`E_TYPE_UNSUPPORTED`，ADR-019）。这一条必须
//  在**安装期**拦，而不是「装上了不加载」—— 装一个永远不会执行的插件，用户只会以为是
//  插件坏了。等到 P3a 有了 JSCore，把 `milestone` 传成 `A2PluginHostMilestoneP3a` 即可。
//
//  ## 错误码
//
//  本层的 NSError 与 P1 **同一套 userInfo 契约**：`A2PluginErrorDomain` +
//  `A2PluginErrorCodeKey`（`E_*` 字符串）+ 可选 `A2PluginErrorFieldKey` + 人话原因。
//  有两处直接复用 P1 的码，保证字符串逐字相同：
//    · `E_TYPE_UNSUPPORTED` —— P2 宿主读到 `type: js`（由 `A2PluginErrorMake` 产出）
//    · `E_FORMAT_VERSION`   —— v3 包 / formatVersion 越界（同上）
//  其余为本层新增，逐条在 `A2PluginContributionErrorCodeString()` 里列出，
//  并已写进 `docs/PLUGIN-AUTHORING.md` 第十二节的机器码对照表。
//
//  ## 实现约定
//
//  · 本文件**不持有 block**：需要排序的地方用 `sortedArrayUsingFunction:context:`。
//    排序键是 C 函数，调用点一眼可见，也不会把 block 捕获的对象生命周期搅进来。
//  · 结构字段名、词表、错误码全部来自 `docs/plugin.schema.json` / `PLUGIN-COMPAT.md` / `ADR-018`，
//    代码里不另立一套名字 —— 三处（schema、文档、代码）不一致时以文档为准。
//

#import <Foundation/Foundation.h>

#import "A2PluginManifest.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 错误码

/// 贡献点校验的错误码。字符串形式见 `A2PluginContributionErrorCodeString()`。
typedef NS_ENUM(NSInteger, A2PluginContributionError) {
    A2PluginContributionErrorNone = 0,
    /// manifest 整体不是 JSON / 根节点不是对象 / 空数据。码：`E_FORMAT`。
    A2PluginContributionErrorFormat,
    /// 字段层不成立：缺必填、类型不符、取值越界、未知字段、label 形状错。
    /// 码：`E_FIELD`（与 P1 的 `E_SCHEMA` 同一族）。
    A2PluginContributionErrorField,
    /// 出现白名单外的**贡献点**（`ui.foo` / `contributes.foo`），或该贡献点属于更晚的里程碑。
    /// 码：`E_CONTRIB_UNKNOWN`。
    A2PluginContributionErrorContribUnknown,
    /// `slot` 不在宿主词表里（`PLUGIN-COMPAT.md` 2.2）。码：`E_SLOT_UNKNOWN`。
    A2PluginContributionErrorSlotUnknown,
    /// `component` 不在宿主词表里（`PLUGIN-COMPAT.md` 2.3 的 v2 叶子组件）。
    /// 码：`E_COMPONENT_UNKNOWN`。
    A2PluginContributionErrorComponentUnknown,
    /// 同一插件对同一 `(slot, id)` 声明了两份**内容不同**的贡献 —— 宿主无法替作者选一份。
    /// 码：`E_CONTRIB_DUPLICATE`。
    A2PluginContributionErrorDuplicate,
    /// 独占占位已被别的插件占用（当前唯一可独占的是 `settings.section` 的设置项键）。
    /// 码：`E_SLOT_CONFLICT`。
    A2PluginContributionErrorSlotConflict,
    /// 声明了贡献点却没申请对应权限（`ui.slots`/`ui.theme` → `ui.contribute`，
    /// `contributes.versionDecorate` → `version.decorate`）。宿主不会渲染没授权的贡献，
    /// 所以这是**作者的错误**，不是「装上了但看不到」。
    /// 码：`E_CONTRIB_PERM`。
    A2PluginContributionErrorContribPermission,
    /// `air2.host.minHostVersion` 高于当前宿主版本。码：`E_HOST_VERSION_MIN`。
    A2PluginContributionErrorHostVersionMin,
    /// `air2.host.maxHostVersion` 低于当前宿主版本。码：`E_HOST_VERSION_MAX`。
    A2PluginContributionErrorHostVersionMax,
};

/// 错误码的字符串形式（`E_FIELD` / `E_SLOT_UNKNOWN` / …）。
FOUNDATION_EXPORT NSString *A2PluginContributionErrorCodeString(A2PluginContributionError code);

/// 构造一条贡献点错误。userInfo 与 `A2PluginErrorMake()` 完全一致 ——
/// 管理页不需要知道这条错误是哪一层发现的。
/// @param field 出错的字段路径（如 `ui.slots[3].slot`），没有具体字段时传 nil
FOUNDATION_EXPORT NSError *A2PluginContributionErrorMake(A2PluginContributionError code,
                                                         NSString *_Nullable field,
                                                         NSString *format, ...)
    NS_FORMAT_FUNCTION(3, 4);

#pragma mark - 宿主里程碑与层

/// 宿主当前处在哪个里程碑。**不是**插件版本，也**不是**包格式版本。
/// 只有「本宿主能不能执行 / 能不能画页面」这类判定用它。
typedef NS_ENUM(NSInteger, A2PluginHostMilestone) {
    /// P2：纯 JSON 声明（无 JSCore）⇒ `type: js` 拒装，v3 包拒装。
    A2PluginHostMilestoneP2 = 2,
    /// P3a：有 JSCore 运行时 ⇒ 允许 `type: js`；v3 页面仍未实现。
    A2PluginHostMilestoneP3a = 3,
    /// P3b：v3 页面模型 + 覆盖 ⇒ 同时接受 formatVersion 2 / 3。
    A2PluginHostMilestoneP3b = 4,
};

/// 贡献层级（`PLUGIN-SYSTEM.md` 2.2）。**由申请的能力推导，不由作者填写** ——
/// 作者写什么不影响判定，避免「自称 L0 实际做 L2 的事」。
typedef NS_ENUM(NSInteger, A2PluginContributionLayer) {
    /// L0 数据层：只读声明（本阶段由 `versionDecorate` 命中）。
    A2PluginContributionLayerData = 0,
    /// L1 装饰层：slot、主题 token。失败只丢弃该贡献。
    A2PluginContributionLayerDecor = 1,
    /// L2 覆盖层：`ui.override`。可能让界面「变空」，安全模式优先禁。
    A2PluginContributionLayerOverride = 2,
};

/// 按 manifest 申请的权限推导层：申请了 `ui.override` → L2；
/// 否则申请了 `ui.contribute` → L1；否则 L0。
FOUNDATION_EXPORT A2PluginContributionLayer
A2PluginContributionLayerForPermissions(NSArray<NSString *> *_Nullable permissions);

/// 层的字符串形式（`L0` / `L1` / `L2`），排序键与诊断日志共用。
FOUNDATION_EXPORT NSString *A2PluginContributionLayerName(A2PluginContributionLayer layer);

#pragma mark - 词表白名单

/// `slot` 是否在 v2 词表里（`PLUGIN-COMPAT.md` 2.2 / `plugin.schema.json` 的 `v2SlotName`）。
/// v3 的两个 slot（`home.page` / `versions.list.page`）**不在** v2 词表里。
FOUNDATION_EXPORT BOOL A2PluginIsKnownSlotName(NSString *_Nullable slot);

/// `component` 是否是 v2 叶子组件（`PLUGIN-COMPAT.md` 2.3 的第一张表）。
/// 容器（`column` / `row` / …）与 v3 叶子（`text.field` / `progress.linear` / …）都不算。
FOUNDATION_EXPORT BOOL A2PluginIsKnownComponentName(NSString *_Nullable component);

/// 某个 slot 的容量上限；0 表示不限（`PLUGIN-COMPAT.md` 2.2：
/// `home.toolbar.action` 4 个、`home.card.badge` 1 个，其余不限）。
/// **超容不是错误**：按排序键取前 N 个，被挤掉的只记一条诊断。
FOUNDATION_EXPORT NSUInteger A2PluginSlotCapacity(NSString *_Nullable slot);

/// 主题 token 是否在词表里。未知 token 由宿主**忽略 + 诊断**，不拒装（ADR-018 决策 5）——
/// 宿主以后加 token 不能反过来让旧包失效。
/// 词表形状：`color.<MD3 语义角色，按词用 . 分隔>`，全小写；
/// `color.accent` 是 `color.primary` 的别名（`PLUGIN-AUTHORING.md` 的示例用它）。
FOUNDATION_EXPORT BOOL A2PluginIsKnownThemeToken(NSString *_Nullable token);

/// 主题 token 对应的 MD3 语义角色名（`A2ColorScheme` 的属性名，如 `primaryContainer`）。
/// 未知 token 返回 nil —— 调用方据此走「忽略 + 诊断」。UI 接线时用它落到色板。
FOUNDATION_EXPORT NSString *_Nullable A2PluginThemeTokenRole(NSString *_Nullable token);

#pragma mark - 单条 slot 贡献

/// 一条 slot 贡献（`ui.slots[]` 的一条）。也用来表示 `settings.section` 里的**设置项**：
/// 设置项就是「slot = settings.section 且带 id 的 slot 条目」，不是第二种 manifest 结构
/// （ADR-023：设置项由 `ui.contribute` + slot 覆盖，不新增字段 ⇒ 不升 formatVersion）。
@interface A2PluginSlotContribution : NSObject

/// 贡献者插件 id。
@property (nonatomic, copy, readonly) NSString *pluginId;

/// 贡献者插件版本（诊断用，比「哪个插件」更具体）。
@property (nonatomic, copy, readonly) NSString *pluginVersion;

/// 宿主预留位置（已在白名单内）。
@property (nonatomic, copy, readonly) NSString *slot;

/// 语义组件名（已在白名单内）。
@property (nonatomic, copy, readonly) NSString *component;

/// 插件内唯一标识。`settings.section` 的条目**必填**（宿主拿它持久化开关值），
/// 其余 slot 可空。
@property (nonatomic, copy, readonly, nullable) NSString *identifier;

/// 语义图标 ID（不是图片路径）。未知 ID 渲染成 info 图标，不拒装。
@property (nonatomic, copy, readonly, nullable) NSString *icon;

/// `label` 的 i18n 键（与 `labelText` 二选一）。
@property (nonatomic, copy, readonly, nullable) NSString *labelI18n;

/// `label` 的字面量（与 `labelI18n` 二选一）。
@property (nonatomic, copy, readonly, nullable) NSString *labelText;

/// 动作 id。纯 JSON 插件只能用宿主内置动作，宿主在 `onAction` 侧再校验。
@property (nonatomic, copy, readonly, nullable) NSString *actionId;

/// 条目自身的排序权重（`ui.slots[].priority`，缺省 0，范围 -1000…1000）。
/// **只决定同一个插件内部的先后**；跨插件排序的第一级是 `pluginPriority`。
@property (nonatomic, assign, readonly) NSInteger priority;

/// 插件级排序权重（manifest 的 `ui.priority`，缺省 0）。
/// 它就是 `PLUGIN-SYSTEM.md` 5.2 那个三元组里的 `priority` —— 插件先按它排队，
/// 同一个插件内部再按条目自己的 `priority` 排队。
@property (nonatomic, assign, readonly) NSInteger pluginPriority;

/// 条目所属插件推导出的层（L0/L1/L2）。
@property (nonatomic, assign, readonly) A2PluginContributionLayer layer;

/// 在 manifest `ui.slots` 里的下标 —— 排序最后一级，保证「同一份注册表每次启动顺序一致」。
@property (nonatomic, assign, readonly) NSUInteger declarationIndex;

/// 两条声明是否**逐字段相同**（注册表去重判据）。只看内容，不看 pluginId。
- (BOOL)isIdenticalDeclaration:(A2PluginSlotContribution *)other;

@end

#pragma mark - 版本行装饰

/// `contributes.versionDecorate` 的解。只影响**展示**：宿主仍保存并比较「真实名」，
/// 装饰值不参与任何版本判定（`PLUGIN-AUTHORING.md` 3.5）。
@interface A2PluginVersionDecoration : NSObject

@property (nonatomic, copy, readonly) NSString *pluginId;
@property (nonatomic, copy, readonly) NSString *pluginVersion;

/// 标题模板（≤64 字符），可空。模板里的占位符由宿主替换，插件拿不到原始字符串以外的能力。
@property (nonatomic, copy, readonly, nullable) NSString *titleTemplate;

/// 副标题模板（≤64 字符），可空。
@property (nonatomic, copy, readonly, nullable) NSString *subtitleTemplate;

/// 徽标文案（i18n 键或字面量，二选一）。
@property (nonatomic, copy, readonly, nullable) NSString *badgeI18n;
@property (nonatomic, copy, readonly, nullable) NSString *badgeText;

/// 语义图标 ID。
@property (nonatomic, copy, readonly, nullable) NSString *icon;

/// 插件级排序权重（沿用 `ui.priority`）。
@property (nonatomic, assign, readonly) NSInteger priority;

/// 推导出的层（只申请 `version.decorate` 的插件是 L0）。
@property (nonatomic, assign, readonly) A2PluginContributionLayer layer;

@end

#pragma mark - 一个插件的贡献集

/// 一个插件在 manifest 里声明的**全部贡献**（校验过、已规范化）。不可变。
///
/// 校验通过之后宿主只跟这个对象打交道：注册表存它，UI 从注册表取它。
/// 因此「一个包能贡献什么」在**安装期**就定了，运行期没有第二条路径能加贡献。
@interface A2PluginContributionSet : NSObject

/// 插件 id（与 manifest 的 `id` 一致）。
@property (nonatomic, copy, readonly) NSString *pluginId;

/// 插件版本。
@property (nonatomic, copy, readonly) NSString *pluginVersion;

/// 插件级排序权重（`ui.priority`，缺省 0）。
@property (nonatomic, assign, readonly) NSInteger priority;

/// 由权限推导的层。
@property (nonatomic, assign, readonly) A2PluginContributionLayer layer;

/// 全部 slot 贡献（含 `settings.section` 的条目），按 `ui.slots` 原序；
/// 完全重复的声明已合并（只留第一条）。
@property (nonatomic, copy, readonly) NSArray<A2PluginSlotContribution *> *slotContributions;

/// 通过校验的主题 token（未知 token 已被丢弃并记诊断）。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *themeTokens;

/// 版本行装饰；没声明时为 nil。
@property (nonatomic, strong, readonly, nullable) A2PluginVersionDecoration *versionDecoration;

/// 降级诊断：未知 token / 未知图标 / 合并掉的重复声明。
/// **诊断不是失败** —— 拒装才走 error。每条形如「未知主题 token「x」已忽略」。
@property (nonatomic, copy, readonly) NSArray<NSString *> *diagnostics;

/// 从 `manifest.json` 的**原始字节**校验并构造。安装链的接线点用这个
/// （`A2PluginPackageExtractor` 手里就是这份 NSData）。
/// @param hostVersion 当前宿主版本（`x.y.z`），与 `air2.host.min/maxHostVersion` 比对
/// @param milestone 宿主里程碑：决定 `type: js` 与 v3 包能不能装
+ (nullable instancetype)setWithManifestData:(NSData *)manifestData
                                 hostVersion:(NSString *)hostVersion
                                   milestone:(A2PluginHostMilestone)milestone
                                       error:(NSError **)error;

/// 从**已解析**的 manifest 字典校验并构造（调用方已经为展示解析过一次时用这个）。
/// 契约：这份字典必须已经过 `A2PluginManifest` 的校验；本层只读它需要的键，
/// 不替 P1 补做字段校验。
+ (nullable instancetype)setWithManifestDictionary:(NSDictionary<NSString *, id> *)dictionary
                                       hostVersion:(NSString *)hostVersion
                                         milestone:(A2PluginHostMilestone)milestone
                                             error:(NSError **)error;

/// 本插件在某个 slot 的贡献（保序，即 `ui.slots` 原序）。
- (NSArray<A2PluginSlotContribution *> *)contributionsForSlot:(NSString *)slot;

/// 设置项（`slot == settings.section`，且必有 `identifier`）。顺序即声明顺序。
- (NSArray<A2PluginSlotContribution *> *)settingsItems;

@end

#pragma mark - 贡献点注册表（纯内存）

/// 已装插件贡献的纯内存索引。Phase A 建、Phase B 读；**不碰磁盘、不碰 UI**。
///
/// 四条不变量（每一条都有单测）：
///  1. **顺序确定**：`(priority ↑, layer ↑, pluginId ↑, declarationIndex ↑)` 全升序。
///     同一份注册表每次启动顺序一致，否则「今天能起、明天不能起」无法复现。
///  2. **重复贡献去重**：同一插件重复接入 = 幂等替换；同插件内逐字段相同的声明合并成一条；
///     同一 `(slot, id)` 内容不同 → 安装期就拒（`E_CONTRIB_DUPLICATE`），不进注册表。
///  3. **卸载/禁用幂等**：`removeContributionsForPlugin:` 把该插件的所有贡献一次摘干净，
///     注册表状态回到**它接入之前**（`stateSnapshot` 逐字相同）；重复移除不改变任何东西。
///  4. **跨线程安全**：内部一条串行队列。写在队列上串行执行；读在队列上只取一份字典快照，
///     排序/拼装回到调用线程。因此安装（后台线程）/ 七处宿主插入点（主线程）可以同时用
///     同一个实例 —— 见 `.m` 末尾【线程】一节的理由。
@interface A2PluginContributionRegistry : NSObject

/// 接入（或替换）一个插件的贡献集。
///
/// 失败**不改动**注册表（先检查后写入）：
///  · `E_SLOT_CONFLICT` —— 该插件的设置项键已被另一个插件占用
/// @return 成功返回 YES；失败返回 NO 并给出 error。
- (BOOL)applyContributionSet:(A2PluginContributionSet *)set error:(NSError **)error;

/// 摘掉一个插件的全部贡献（卸载 / 禁用 / 回退版本都走这里）。
/// @return 该插件此前在册返回 YES；本来就不在册返回 NO（且不改动任何状态）。
- (BOOL)removeContributionsForPlugin:(NSString *)pluginId;

/// 该插件当前的贡献是否在册。
- (BOOL)isPluginAttached:(NSString *)pluginId;

/// 该插件在册的贡献条数：slot 条目 + 主题 token + 版本装饰（未接入为 0）。
///
/// 只给诊断日志与「移除之后确实空了」的断言用 —— 不代表任何排序、容量或渲染语义
/// （容量要用 `effectiveEntriesForSlot:`，那个才是唯一实现）。
- (NSUInteger)contributionCountForPlugin:(NSString *)pluginId;

/// 在册插件 id（字典序，便于诊断与测试断言）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *attachedPluginIds;

/// 某个 slot 上的全部贡献，按 `(priority, layer, pluginId, declarationIndex)` 升序。
- (NSArray<A2PluginSlotContribution *> *)slotEntriesForSlot:(NSString *)slot;

/// 同上，但按该 slot 的容量截断（`home.card.badge` 只留 1 个、`home.toolbar.action` 只留 4 个）。
/// UI 只用这一个 —— 容量规则只有一处实现。
- (NSArray<A2PluginSlotContribution *> *)effectiveEntriesForSlot:(NSString *)slot;

/// 全部插件的设置项（每个插件内按 (priority, layer, pluginId, declarationIndex) 升序）。
- (NSArray<A2PluginSlotContribution *> *)settingsItems;

/// 解析某个主题 token 的最终取值；`ownerPluginId` 回传胜出插件（可传 NULL）。
/// 多个插件声明同一 token 时取排序键最靠前的那个（ADR-018：插件互相覆盖时顺序必须确定）。
- (nullable NSString *)themeTokenValue:(NSString *)token ownerPluginId:(NSString *_Nullable *_Nullable)owner;

/// 某个插件**自己**声明的主题 token（token → 值；未接入 / 没声明 ⇒ 空字典）。
///
/// 与 `resolvedThemeTokens` 的区别：那个是「多插件合并后的唯一结果」，
/// 只能回答「现在界面该用哪个色」；要按插件列出、逐套切换
/// （设置 → 外观 → 颜色主题 的「插件主题」分组）就必须知道每一套各是什么。
/// 只读，不改动注册表，也不参与排序/去重规则。
- (NSDictionary<NSString *, NSString *> *)themeTokensForPlugin:(NSString *)pluginId;

/// 全部已解析 token（token → 值）。顺序无关，供 UI 一次取完。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *resolvedThemeTokens;

/// 全部版本行装饰，按排序键升序（多个插件同时装饰时宿主按此顺序叠加）。
@property (nonatomic, copy, readonly) NSArray<A2PluginVersionDecoration *> *versionDecorations;

/// 全部降级诊断（带插件前缀），按 pluginId 字典序。
@property (nonatomic, copy, readonly) NSArray<NSString *> *diagnostics;

/// 注册表内容快照（可 `isEqualToDictionary:` 比较）。
/// 用途：证明「移除后状态回到接入前」—— 靠比快照，而不是靠数个数。
- (NSDictionary<NSString *, id> *)stateSnapshot;

@end

NS_ASSUME_NONNULL_END

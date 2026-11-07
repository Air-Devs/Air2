//
//  A2HomeCardSource.h
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
//  自定义主页 —— **卡片来源解析**（结构层用户 / 内容层插件之间的那一道判定）。
//
//  ## 为什么要有这一层
//
//  主页布局文档（`A2HomeLayout`）只知道「这张卡是什么种类、多大、指向谁」；
//  插件贡献点（`A2PluginContribution`）只知道「我声明了哪些 slot 条目」。
//  两边都不该知道对方：布局文档不能被插件污染（用户拥有结构），
//  插件注册表也不能反过来决定布局里有哪些卡（否则卸载插件会删用户的卡）。
//  所以中间必须有一处**纯判定**：这张卡的内容现在从哪来？
//
//  三种答案（本文件是它们的唯一实现点）：
//
//    ① 内置卡   —— kind 映射到现有卡片种类，内容由内核数据源给（`A2HomeRuntime`）。
//    ② 插件卡   —— 卡片带着 (pluginId, contributionId)，且这两者在**已安装且已启用**
//                  的插件贡献里对得上 ⇒ 内容是那条贡献。
//    ③ 不可用   —— 插件被停用 / 已卸载 / 不再提供该贡献；或 kind 属于本版未接通、
//                  未知的类型。**返回占位描述，卡片一张都不删**
//                  （`docs/HOME-DESIGN.md` §4.5 软失败：删卡是用户没授权的布局变更，
//                  而且他可能就是「过两天我要把这个插件装回来」）。
//
//  ## 依赖方向
//
//  本层只依赖 `A2HomeLayout`（同目录 Core）与 Foundation。**不认识**
//  插件注册表 / 安装器 / 权限库，也不碰磁盘 —— 那些是
//  `A2PluginContribution`（Core/Plugin）与宿主装配层（UI/Plugin）的事。
//  两侧通过下面的 `A2HomePluginCardCatalog` 快照对接：谁装配它、从注册表怎么映射，
//  是接线层（主页 VC，Step 3/6）的责任，不是本层的。
//
//  ## 边界（不要越）
//
//  · 纯逻辑：不建视图、不碰 UIViewController、不写盘、不改布局文档。
//  · 每次解析**不改动入参卡片**（不删卡、不改 kind/size/target），
//    调用方拿到的只是「这张卡现在该显示什么」。
//  · 不做容量裁剪（「每插件默认 1 张」是编辑态加卡面板的规则，Step 6），也不排序。
//  · **不写日志**：它会被「每张卡 × 每次渲染」调用，逐次打判据行只会淹掉日志页。
//    判据行归渲染方，一行一次渲染（照 `[A2-PLUGIN-UI]` 的既有格式，Step 3 接）。
//

#import <Foundation/Foundation.h>

#import "A2HomeLayout.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 三态

/// 一张卡的内容来源。**只有这三种**，没有第四种「未知」——
/// 未知一律落到 `Unavailable`（软失败），因为渲染层只需要知道「画不出内容」，
/// 不需要区分「为什么画不出」的每一种细节（细节在 `unavailableReason` 里）。
typedef NS_ENUM(NSInteger, A2HomeCardSourceState) {
    /// 内置卡：kind 有效且本版已接通数据源。
    A2HomeCardSourceStateBuiltin = 0,
    /// 插件卡：(pluginId, contributionId) 在已安装且已启用的插件贡献里对上了。
    A2HomeCardSourceStatePlugin,
    /// 不可用：占位。卡还在布局里，位置与尺寸都不变。
    A2HomeCardSourceStateUnavailable,
};

/// 插件卡查不到内容时的具体原因。**这是诊断用的细分**，
/// 对渲染层而言都属于「不可用」——所以它不是第三态，是第三态的原因。
typedef NS_ENUM(NSInteger, A2HomePluginCardAvailability) {
    A2HomePluginCardAvailabilityAvailable = 0,
    /// 插件装着、但被用户停用（停用是用户可见的状态，不是「坏了」）。
    A2HomePluginCardAvailabilityPluginDisabled,
    /// 插件不在已安装列表里：从没装过，或已卸载。
    A2HomePluginCardAvailabilityPluginMissing,
    /// 插件在、也在启用状态，但它这一版不再声明这张卡对应的贡献（插件升级删掉了它）。
    A2HomePluginCardAvailabilityContributionMissing,
};

/// 原因的字符串形式（`disabled` / `missing` / `contribution`），判据行与测试共用。
FOUNDATION_EXPORT NSString *A2HomePluginCardAvailabilityName(A2HomePluginCardAvailability availability);

#pragma mark - 插件卡片内容快照

/// 一条「可以当卡片用」的插件贡献内容。**纯数据**，不含插件运行时对象。
///
/// `contributionId` 是插件内唯一标识（取自 slot 条目的 `id`）：
/// 宿主只用它定位「是哪一条贡献」，不解释它的含义。
@interface A2HomePluginCardContent : NSObject

@property (nonatomic, copy, readonly) NSString *pluginId;
/// 插件版本（诊断用，比「哪个插件」更具体）；未知时为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *pluginVersion;
@property (nonatomic, copy, readonly) NSString *contributionId;
/// 该贡献声明在哪个 slot（如 `home.section`）；只为诊断，渲染不依赖它。
@property (nonatomic, copy, readonly, nullable) NSString *slot;
/// 卡片标题（已在装配层做过 i18n 解析）；空则渲染层回落到 pluginId。
@property (nonatomic, copy, readonly, nullable) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *subtitle;
/// SF Symbol 名（装配层已把插件的语义图标 ID 映射过来）；空则用兜底图标。
@property (nonatomic, copy, readonly, nullable) NSString *symbolName;

+ (instancetype)contentWithPluginId:(NSString *)pluginId
                      pluginVersion:(nullable NSString *)pluginVersion
                     contributionId:(NSString *)contributionId
                               slot:(nullable NSString *)slot
                              title:(nullable NSString *)title
                           subtitle:(nullable NSString *)subtitle
                         symbolName:(nullable NSString *)symbolName;

@end

#pragma mark - 已安装插件快照（三态判定的唯一输入）

/// 「已安装插件现在能提供哪些卡片」的一份**不可变快照**。
///
/// 为什么不直接读注册表：注册表在 Core/Plugin（还带一条串行队列与写侧约束），
/// 而本层要能被纯 Foundation 单测钉住。快照化之后，
/// 「装了 / 停了 / 卸了 / 贡献没了」四种输入可以逐个构造，判定逻辑只有一份。
///
/// 构造时做三件事（都在 init 里，调用方不需要记得）：
///  · 丢掉 pluginId / contributionId 为空的内容条目（查不到，留着只会被误命中）；
///  · 同一 (pluginId, contributionId) 重复 → 保留**第一条**（先声明者优先，顺序确定）；
///  · 三个入参都去重保序，方便诊断日志逐条打印。
@interface A2HomePluginCardCatalog : NSObject

+ (instancetype)catalogWithInstalledPluginIds:(NSArray<NSString *> *)installedPluginIds
                            disabledPluginIds:(NSArray<NSString *> *)disabledPluginIds
                                     contents:(NSArray<A2HomePluginCardContent *> *)contents;

/// 已安装插件 id（去重保序）。
@property (nonatomic, copy, readonly) NSArray<NSString *> *installedPluginIds;
/// 已停用插件 id（去重保序）。停用但未安装 ⇒ 仍按「未安装」判定。
@property (nonatomic, copy, readonly) NSArray<NSString *> *disabledPluginIds;
/// 规范化后的内容条目（去重保序）。
@property (nonatomic, copy, readonly) NSArray<A2HomePluginCardContent *> *contents;

/// 查一张插件卡。判定顺序是**固定的**：
///   未安装 → `PluginMissing`（卸载优先于停用标记）
///   已停用 → `PluginDisabled`
///   贡献对不上 → `ContributionMissing`
///   否则   → `Available` 并回传内容
/// @param outContent 命中时回传那条内容；未命中不改动它（可传 NULL）
- (A2HomePluginCardAvailability)availabilityForPluginId:(NSString *)pluginId
                                        contributionId:(NSString *)contributionId
                                               content:(A2HomePluginCardContent *_Nullable *_Nullable)outContent;

@end

#pragma mark - 解析结果

/// 一张卡的来源判定结果。**不可变**，由 `A2HomeCardSourceResolver` 产出。
@interface A2HomeCardSource : NSObject

/// 对应的卡片 id（入参卡片为 nil 时为 nil）。
@property (nonatomic, copy, readonly, nullable) NSString *cardID;

@property (nonatomic, assign, readonly) A2HomeCardSourceState state;

/// 内置卡有效时是卡片种类，也是「该用哪个内置卡片视图」的唯一依据。
/// 插件卡 / 不可用时**无意义**（插件卡带回入参卡片的原值便于诊断，卡片为 nil 时为 0）。
@property (nonatomic, assign, readonly) A2HomeCardKind kind;

/// 插件卡 / 插件不可用时的插件标识。
@property (nonatomic, copy, readonly, nullable) NSString *pluginId;
/// 命中时的插件版本。
@property (nonatomic, copy, readonly, nullable) NSString *pluginVersion;
@property (nonatomic, copy, readonly, nullable) NSString *contributionId;
/// 命中时该贡献声明的 slot。
@property (nonatomic, copy, readonly, nullable) NSString *slot;

/// ---- 展示用（三态都有值，渲染层不需要再自己拼文案）----
/// 内置卡 = 类型名；插件卡 = 贡献标题（空则 pluginId）；
/// 不可用 = 占位标题（存卡时的名字快照 `fallbackLabel` → pluginId → 类型名 → 「卡片」）。
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *subtitle;
/// SF Symbol 名，永远非空（不可用态也有图标，占位框才画得出来）。
@property (nonatomic, copy, readonly) NSString *symbolName;

/// ---- 仅不可用态 ----
/// 一句中文原因（「插件「x」已停用，卡片保留」）。内置卡命中时恒为 nil。
@property (nonatomic, copy, readonly, nullable) NSString *unavailableReason;
/// 这一态下具体是什么原因（内置卡命中 / 插件卡命中时为 `Available`）。
@property (nonatomic, assign, readonly) A2HomePluginCardAvailability pluginAvailability;
/// 是否建议给用户「重新指定」入口：插件侧不可用 ⇒ YES（内容没了，可以指到别处）；
/// 内置类型未接通 / 未知 kind ⇒ NO（不是用户指错了，是他改不了）。
@property (nonatomic, assign, readonly) BOOL allowsRetarget;

- (BOOL)isBuiltin;
- (BOOL)isPlugin;
- (BOOL)isUnavailable;

@end

#pragma mark - 解析器

/// 两处入口（Step 3 起由主页卡片渲染逐张调用）：
///  · `+sourceForCard:`              —— 内置卡
///  · `+sourceForCard:pluginId:…`    —— 插件卡（卡片带插件引用时）
@interface A2HomeCardSourceResolver : NSObject

/// 内置卡解析。
///
/// · kind 在枚举范围内且 `A2HomeKindIsAvailable` 为真 ⇒ `Builtin`；
///   （白名单、档位、target 这些仍是 `A2HomeLayout` 的职责，本方法不重复判。）
/// · kind 在范围内但本版没接通数据源（收藏存档 / 收藏服务器）⇒ `Unavailable`，
///   原因取 `A2HomeKindSummary`（「此版本暂不可用（存档钉选未接入）」）；
/// · kind 越界（低版本读到高版本写的卡、或调用方传错）⇒ `Unavailable`，原因「未知的卡片类型」。
///
/// 三条都不改卡片：卡片留在布局里，位置与尺寸照旧。
+ (A2HomeCardSource *)sourceForCard:(A2HomeCard *)card;

/// 插件卡解析。
/// @param card 对应的卡片实例，**可空**：模型层不要求卡片先存在
///             （编辑态预览一张插件卡时还没有实例）。有卡时取它的 `cardID`
///             与 `fallbackLabel` 做占位标题。
/// @param catalog 已安装插件快照；nil（宿主还没装配）⇒ `Unavailable`，
///                宁可显示占位也不要画一张没有内容的卡。
+ (A2HomeCardSource *)sourceForCard:(nullable A2HomeCard *)card
                           pluginId:(NSString *)pluginId
                     contributionId:(NSString *)contributionId
                            catalog:(nullable A2HomePluginCardCatalog *)catalog;

@end

NS_ASSUME_NONNULL_END

//
//  A2RendererCatalog.h
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
//  Core/Renderer —— ★「有哪些渲染后端可被选中」的唯一真相源★（候选表 + 包内可用性）。
//
//  职责边界（与既有两件不重叠）：
//    · 本类 = **静态候选表 + 包内存在性判定**（纯数据 + 一次 fileExistsAtPath，无 UIKit、无 dlopen）；
//    · `A2Renderers`（同目录，既有）= **注册表 + 标识解析**（去重 / 版本级覆盖 > 全局 > 首个）；
//      本类把候选登记进去，而不是另造一套解析（★不重复造轮子★）；
//    · `Natives/Renderer/a2_renderer.*` = **真正 dlopen 的地方**（那一步只能在 Natives）。
//
//  标识 = **dylib 文件名**（与老线 `runtime_native/Natives/utils.h` 的 `RENDERER_NAME_*`
//  逐字同表；取值即 `A2SelectedRendererPrefKey` 存进 NSUserDefaults 的值）。
//
//  ★调用点★：
//    · `Air2/UI/Screens/Settings/A2RuntimeSettings.m`（渲染器行的候选表 + 「未内置」标记）
//    · `Air2/Player/A2LaunchSession.m`（解析用户选择 ⇒ 交给 Bridge 的 dylib 名 / 阻断判据）
//
//  ★显示名的语言归属★：候选的**展示文案**放 Player 的四语表 `A2RuntimeStrings`
//  （Core 在 Player 之下，不能反向依赖）⇒ 本类只给**稳定的文案 key**，
//  由 UI 侧 `A2RuntimeStrings stringForKey:` 取词。缺 key 时 UI 回退到 `identifier`（技术名）。
//

#import <Foundation/Foundation.h>

#import "A2Renderer.h"

NS_ASSUME_NONNULL_BEGIN

/// 候选档位（用于 UI 分组与排序，也用于报告里区分「主推 / 兼容底 / 实验」）。
typedef NS_ENUM(NSInteger, A2RendererTier) {
    A2RendererTierRecommended = 0,  ///< ★主推★（自研 Metal）
    A2RendererTierCompat      = 1,  ///< ★兼容底★（老版本 MC 的转译层）
    A2RendererTierExperimental= 2,  ///< 实验 / 尚未内置（保留入口，选中会如实阻断）
};

@interface A2RendererCatalog : NSObject

/// 全部候选（★稳定顺序★：主推 → 兼容底 → 实验）。
/// 每一项的 `identifier` = dylib 文件名，`displayName` = 技术名（回退用），`dylibName` = 同名。
+ (NSArray<A2Renderer *> *)allCandidates;

/// 主推候选（默认项）。
+ (A2Renderer *)defaultCandidate;

/// 按标识取候选；未登记返回 nil。
+ (nullable A2Renderer *)candidateForIdentifier:(NSString *)identifier;

/// 档位（未登记的标识按「实验」处理，不猜成主推）。
+ (A2RendererTier)tierForIdentifier:(NSString *)identifier;

/// 档位 / 展示名的四语文案 key（交给 Player 的 A2RuntimeStrings 取词；本类不取词）。
+ (NSString *)tierLocalizationKeyForTier:(A2RendererTier)tier;
+ (NSString *)nameLocalizationKeyForIdentifier:(NSString *)identifier;

/// 包内是否已内置该渲染后端（`<frameworksPath>/<dylibName>` 存在且是普通文件）。
/// frameworksPath 为空 ⇒ NO（未内置，不猜）。
+ (BOOL)isBundled:(A2Renderer *)candidate frameworksPath:(nullable NSString *)frameworksPath;

/// 把全部候选登记进既有注册表（幂等：已登记的返回 NO 不影响结果）。
+ (void)registerAllCandidatesIntoRegistry:(A2Renderers *)registry;

@end

NS_ASSUME_NONNULL_END

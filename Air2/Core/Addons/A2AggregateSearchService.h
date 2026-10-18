//
//  A2AggregateSearchService.h
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
//
//  聚合搜索 —— 一次检索同时打 Modrinth 与 CurseForge，两源结果交错合并后返回。
//
//  为什么单独一层，而不塞进 A2ContentSource：
//    · A2ContentSource 的语义是「**一个**平台」，`platform` 是只读属性、
//      `searchWithFilter:` 只打一路；让它变成「多路」会让那个类的每个分支
//      都要问一次「我是哪个源」，等于把平台差异又摊回调用方。
//    · 本类只做「扇出 + 合并 + 降级」，**不碰网络、不碰平台差异**：
//      每一路仍是既有 A2ContentSource/A2ModrinthAPI/A2CurseForgeAPI（不重复造轮子）。
//    · 结果条目仍是 A2ContentItem（`platform` 字段标明来源），于是搜索行
//      A2ResourceResultCell/A2ResourceCard 的 MODRINTH / CURSEFORGE 药丸
//      直接说明每条来自哪个源 —— UI 不需要为聚合模式另做一套行。
//
//  ★谁调它★：Air2/UI/Screens/Download/A2AggregateSearchViewController.m
//    （`-reload` 内唯一调用点；聚合/单源由 A2AggregateSourceMode 决定）。
//
//  ★合并口径为什么不是「简单拼接」★：
//    同一个工程常常两边都有（Sodium、Fabric API…）。直接拼接会让一页里
//    出现两条同名项目，用户无法判断该点哪个。逐条交错 + 同名折叠后，
//    同一工程只留一条，来源由行内药丸体现。
//

#import <Foundation/Foundation.h>

#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

/// 检索范围。聚合 = 两路同时打；另两档是「单源」，UI 上仍用同一套列表与分页。
typedef NS_ENUM(NSInteger, A2AggregateSourceMode) {
    A2AggregateSourceModeBoth = 0,   ///< Modrinth + CurseForge 同时检索
    A2AggregateSourceModeModrinth,   ///< 只打 Modrinth
    A2AggregateSourceModeCurseForge, ///< 只打 CurseForge
};

/// 一次聚合检索的结果。
@interface A2AggregateSearchOutcome : NSObject

/// 合并后的条目（已按来源交错、同名折叠）。★主线程回调时已就绪★。
@property (nonatomic, copy, readonly) NSArray<A2ContentItem *> *items;

/// 两路各自的原始条数（折叠前）—— 分页「还有下一页吗」由它判定：
/// 任一路取满 limit 就还可能有下一页（`>= limit`）。
@property (nonatomic, assign, readonly) NSInteger modrinthCount;
@property (nonatomic, assign, readonly) NSInteger curseForgeCount;

/// 只有「本次请求的所有源都失败」时才非 nil。
@property (nonatomic, copy, readonly, nullable) NSError *error;

/// 单源降级说明（如 CurseForge 未配置 Key，或其中一路网络失败）。
/// nil 表示本次两路都正常（单源模式则恒为 nil）。
@property (nonatomic, copy, readonly, nullable) NSString *degradedReason;

/// 本次实际参与的源（供 UI 显示「共 N 条（Modrinth + CurseForge）」）。
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *engagedPlatforms;

@end

@interface A2AggregateSearchService : NSObject

+ (instancetype)shared;

/// 同名折叠的下载量容差。默认 0（同名即折叠，保留下载量更高的一条）。
/// ★为什么没有「时间窗口」★：统一模型 A2ContentItem 目前不带 slug/dateModified，
///   拿不到可比的更新时间；宁可退化成「同名 + 下载量取高」，也不去猜一个时间。
///   若后续 A2ContentItem 补上这两个字段，再把窗口口径加进来（改动点只在本类）。
@property (nonatomic, assign) long long mergeDownloadTolerance;

/// 该资源大类是否支持聚合。Modrinth 不提供存档（World）⇒ 存档只能单源 CurseForge。
+ (BOOL)supportsAggregateForContentClass:(A2ContentClass)contentClass;

/// 检索。completion 恒在主线程回调，且一定回调一次（不会既不给结果也不给错误）。
/// @param filter       统一筛选条件（offset/limit 由调用方按页给）
/// @param contentClass 资源大类
/// @param mode         检索范围
- (void)searchWithFilter:(A2ContentFilter *)filter
            contentClass:(A2ContentClass)contentClass
                    mode:(A2AggregateSourceMode)mode
              completion:(void (^)(A2AggregateSearchOutcome *outcome))completion;

@end

NS_ASSUME_NONNULL_END

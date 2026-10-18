//
//  A2AggregateSearchViewController.h
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
//  聚合搜索页 —— 一个界面、两个源（Modrinth + CurseForge）。
//
//  与 A2ResourceSearchViewController 的关系：
//    · 那个页面是「单源搜索 + 右侧筛选栏」，它的平台切换是**互斥单选**；
//    · 本页是「多源同搜」：顶部 MD3 分段按钮选**检索范围**（聚合 / 只 Modrinth /
//      只 CurseForge），结果列表两种来源混排，来源由行内药丸说明。
//    · 结果行、详情页、分页控件全部复用既有组件（A2ResourceResultCell /
//      A2ResourceDetailViewController / A2PaginationBar），本页只负责
//      「筛选条件 → A2AggregateSearchService → 列表」这一段。
//
//  ★为什么不做成既有搜索页的第三个平台胶囊★：
//    那个页面的 `platform` 字段贯穿筛选面板（分类标识两家不通用、切平台清分类），
//    再塞一个「聚合」进去会让每个分支都要特判；独立的页面把这段特判收敛在一处。
//
//  ★谁调它★：Air2/UI/Screens/Download/A2DownloadViewController.m
//    `-makeContentViewControllerForIndex:` 的 case 11（"聚合" 分类）。
//

#import "A2BaseViewController.h"

#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

/// 聚合搜索页。模组 / 整合包 / 资源包 / 光影 / 数据包 五类共用，靠 contentClass 区分；
/// 存档（World）只有 CurseForge 一家，故本页对它会退化成「单源」并如实提示。
@interface A2AggregateSearchViewController : A2BaseViewController

- (instancetype)initWithContentClass:(A2ContentClass)contentClass;

@end

NS_ASSUME_NONNULL_END

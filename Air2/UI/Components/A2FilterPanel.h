//
//  A2FilterPanel.h
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
//
//  A2FilterPanel.h
//  Air2
//
//  可折叠的筛选面板 —— 对应 ZL2 的 DownloadFilterCard。
//
//  为什么做可折叠：
//    ZL2 的筛选面板点标题栏可以收起。搜索时用户往往只需要看结果，
//    不想让筛选占着半屏。收起后只剩一条摘要栏（如「Modrinth · 相关度 · 筛选 2」）。
//
//  收起态：一条标题栏，显示当前筛选摘要 + 展开箭头
//  展开态：完整筛选内容（平台/排序/加载器/版本/分类/重置）
//

#import <UIKit/UIKit.h>
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2FilterPanel : UIView

/// 容器（往这里加筛选组）
@property (nonatomic, strong, readonly) UIStackView *contentStack;

/// 摘要文字（收起时显示，如「Modrinth · 相关度 · 筛选 2」）
@property (nonatomic, copy, nullable) NSString *summaryText;

/// 当前是否展开
@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;

/// 展开状态变化
@property (nonatomic, copy, nullable) void (^onExpansionChange)(BOOL expanded);

/// 重置按钮回调
@property (nonatomic, copy, nullable) void (^onReset)(void);

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

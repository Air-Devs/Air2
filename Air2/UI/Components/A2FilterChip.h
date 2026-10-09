//
//  A2FilterChip.h
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
//  MD3 筛选胶囊 —— 资源列表的筛选/排序维度统一用它。
//
//  filterValue 携带**真实筛选值**（加载器标识如 legacy-fabric、游戏版本号如 1.21.5，
//  @"" 表示「全部」），不靠展示文案反推 —— 「Legacy Fabric」小写化后是
//  「legacy fabric」，与接口要的「legacy-fabric」对不上。
//
//  状态用 UIControl 自带的 selected，配合语义色自动切换底色与文字色。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2FilterChip : UIButton

/// 真实筛选值。@"" 表示「全部」。
@property (nonatomic, copy) NSString *filterValue;

/// 创建一枚胶囊。走 alloc/init 而非 buttonWithType:，
/// 确保命中我们的初始化（样式与主题监听都挂在 init 里）。
+ (instancetype)chip;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

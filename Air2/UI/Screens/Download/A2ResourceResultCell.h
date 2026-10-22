//
//  A2ResourceResultCell.h
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
//  A2ResourceResultCell.h
//  Air2
//
//  搜索结果行 —— 从 A2ResourceSearchViewController 抽出来。
//
//  抽出的理由：搜索结果页原本有 1037 行，承担了
//  「结果行 / 筛选栏 / 分栏布局 / 数据加载 / 分页」五个职责。
//  结果行是最独立的一块（只依赖 A2ResourceCard 与两个数据源），
//  且收藏页也用它，放在独立文件里便于复用。
//

#import <UIKit/UIKit.h>
#import "A2ContentSource.h"
@class A2ResourceCard;

NS_ASSUME_NONNULL_BEGIN

@interface A2ResourceResultCell : UITableViewCell

@property (nonatomic, strong) A2ResourceCard *card;

/// 配置内容（含已安装与收藏状态）
- (void)configureWithItem:(A2ContentItem *)item;

@end

NS_ASSUME_NONNULL_END

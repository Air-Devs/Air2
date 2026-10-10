//
//  A2ResourceSearchViewController.h
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
//  共用资源搜索页 —— 搜索栏 + 可展开筛选卡 + 分页结果列表。
//  模组 / 资源包 / 光影 / 存档 / 数据包 五类共用，靠 contentClass 区分：
//  平台支持、可选分类、可用筛选维度都据此推导，不各写一份页面。
//

#import "A2BaseViewController.h"
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

/// 共用资源搜索页。模组 / 资源包 / 光影 / 存档 / 数据包 五类共用，靠 contentClass 区分。
@interface A2ResourceSearchViewController : A2BaseViewController

- (instancetype)initWithContentClass:(A2ContentClass)contentClass;

@end

NS_ASSUME_NONNULL_END

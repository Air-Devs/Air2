//
//  A2ResourceDetailViewController.h
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
//  共用资源详情页 —— 模组 / 资源包 / 光影 / 存档 / 数据包 共用。
//  头卡（图标 + 元信息 + 主按钮）+ 简介卡 + 适配当前版本的社区资源 + 版本列表。
//  版本下载统一走下载任务中心。
//

#import "A2BaseViewController.h"
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

/// 共用资源详情页。模组 / 资源包 / 光影 / 存档 / 数据包 共用。
@interface A2ResourceDetailViewController : A2BaseViewController

/// gameVersion 是列表页当前选中的游戏版本，用于在简介下方列出适配资源；
/// 没有选择（收藏页 / ID 搜索）时传 nil，相关资源区自动隐藏。
- (instancetype)initWithProject:(A2ContentItem *)project
                   contentClass:(A2ContentClass)contentClass
                    gameVersion:(nullable NSString *)gameVersion;

@end

NS_ASSUME_NONNULL_END

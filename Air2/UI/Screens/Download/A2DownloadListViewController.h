//
//  A2DownloadListViewController.h
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
//  资源下载列表 —— 带搜索、筛选、排序的列表页。
//  游戏版本、模组、光影、资源包、整合包、存档共用这一个页面，
//  靠 category 区分数据源与筛选维度。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2DownloadCategory) {
    A2DownloadCategoryGame = 0,    ///< 游戏版本
    A2DownloadCategoryMod,         ///< 模组
    A2DownloadCategoryShader,      ///< 光影包
    A2DownloadCategoryResourcePack,///< 资源包
    A2DownloadCategoryModpack,     ///< 整合包
    A2DownloadCategoryWorld,       ///< 存档
};

@interface A2DownloadListViewController : A2BaseViewController

@property (nonatomic, assign) A2DownloadCategory category;

@end

NS_ASSUME_NONNULL_END

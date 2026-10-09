//
//  A2DownloadHomeViewController.h
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
//  下载中心首屏 —— 某个分类的落地内容与它的入口路由。
//
//  为什么与 A2DownloadViewController 分成两个文件：
//  容器只负责「常驻左侧分类边栏 + 右侧子页面导航栈」这一件事；
//  本页只负责「某个分类落地显示什么、点进去跳到哪」。
//  两组关注点不相干，混在一个文件里就变成石山。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadHomeViewController : A2BaseViewController

/// 显示某个分类的落地内容。索引与 A2DownloadViewController 的边栏一致：
/// 0 游戏 / 1 整合包 / 2 模组 / 3 资源包 / 4 存档 / 5 光影 / 6 按 ID / 7 收藏。
- (void)showCategoryAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END

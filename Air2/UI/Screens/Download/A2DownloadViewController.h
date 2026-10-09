//
//  A2DownloadViewController.h
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
//  下载中心容器 —— 启动器内容获取的总入口。
//
//  只做两件事：
//    · 左侧分类边栏常驻（游戏 / 整合包 / 模组 / 资源包 / 存档 / 光影 / 按 ID / 收藏）
//    · 右侧挂一条内层导航栈，下载区内的所有子页面都活在它上面
//
//  选中分类即把该分类的内容页设为栈底（直达，无中间落地页）；
//  分类 → 内容页的映射写在实现里的 makeContentViewControllerForIndex:。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadViewController : A2BaseViewController

@end

NS_ASSUME_NONNULL_END

//
//  A2ModPackImportViewController.h
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
//  A2ModPackImportViewController.h
//  Air2
//
//  整合包导入 —— 从本地文件安装整合包。
//
//  与「从平台下载整合包」的区别：这里用户已经有文件了
//  （从网盘、群聊、U 盘拿到的 zip）。
//
//  流程：
//    1. 选文件（系统文件选择器）
//    2. 探测格式（Modrinth / CurseForge）
//    3. 展示清单信息（名称、游戏版本、加载器、文件数）
//    4. 确认后进安装进度页
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ModPackImportViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END

//
//  A2FilesViewController.h
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
//  版本游戏目录浏览 —— 只列目录、进子目录、建文件夹、改名、删除。
//  不做文本预览/解压/压缩（那是整合包导入导出的范围，另起任务）。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2FilesViewController : A2BaseViewController

/// 以版本游戏目录为根。rootPath 不存在则页面直接提示无法打开。
- (instancetype)initWithRootPath:(NSString *)rootPath
                     displayName:(NSString *)displayName;

/// 子目录用：rootPath 不变，relativePath 深入一级。
- (instancetype)initWithRootPath:(NSString *)rootPath
                    relativePath:(NSString *)relativePath
                     displayName:(NSString *)displayName;

@end

NS_ASSUME_NONNULL_END

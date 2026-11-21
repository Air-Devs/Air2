//
//  A2VersionExportViewController.h
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
//  A2VersionExportViewController.h
//  Air2
//
//  版本导出 —— 把已安装的版本打包成整合包。
//
//  对照 ZL2 的 VersionExportScreen（三步页面）：
//    1. 选格式（Modrinth / CurseForge）
//    2. 填信息（名称、简介、作者、版本号 —— 各格式要求的字段不同）
//    3. 选文件（勾选要打包的内容）
//
//  我们合并成单页 —— 横屏下三步骤分页反而繁琐。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionExportViewController : A2BaseViewController

- (instancetype)initWithVersionName:(NSString *)versionName
                        versionPath:(NSString *)versionPath;

@end

NS_ASSUME_NONNULL_END

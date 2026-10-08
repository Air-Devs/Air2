//
//  A2InstallingViewController.h
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
//  安装进度页 —— 从一个版本开始安装到完成的全过程展示。
//
//  视觉核心是环形进度 + 分步清单：
//    环形进度给一个"整体完成度"的直觉
//    下面按步骤列出（下载清单 / 校验 / 下载 jar / 下载依赖库 / 下载资源 / 完成）
//    每步有独立状态点，让用户知道卡在哪一步
//

#import "A2BaseViewController.h"
#import "A2ProgressView.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2InstallingViewController : A2BaseViewController

- (instancetype)initWithVersionName:(NSString *)versionName loader:(nullable NSString *)loader;

@end

NS_ASSUME_NONNULL_END

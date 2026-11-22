//
//  A2VersionSettingsViewController.h
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
//  单版本设置 —— 覆盖全局设置。
//
//  重点：版本隔离
//    隔离类型：跟随全局 / 开启 / 关闭
//    自定义游戏目录（未隔离时生效）
//    五个可隔离目录的入口：mods / resourcepacks / saves / shaderpacks / screenshots
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionSettingsViewController : A2BaseViewController

- (instancetype)initWithVersionName:(NSString *)versionName;

@end

NS_ASSUME_NONNULL_END

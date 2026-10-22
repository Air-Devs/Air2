//
//  A2RendererSettingsViewController.h
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
//  A2RendererSettingsViewController.h
//  Air2
//
//  渲染器选择页 —— 对照 ZL2 的 RendererSettingsScreen.kt。
//
//  ZL2 的结构：
//    ┌──────────────────────────────────────┐
//    │ 全局渲染器                        ⚙ ⬇ │  ← 齿轮=配置，下载=插件下载
//    │ 全局默认的渲染器…                     │
//    │ 当前选择项：NG-GL4ES                  │
//    ├──────────────────────────────────────┤
//    │ 渲染器列表（点开是单选列表）           │
//    │  · NG-GL4ES   内置                    │
//    │  · Zink       内置                    │
//    │  · MyGL       来自插件 xxx            │
//    └──────────────────────────────────────┘
//
//  ⚙ 只在选中的渲染器有可配置项时出现（对应 ZL2 的 v2 插件）
//  ⬇ 打开插件导入（我们的对应物，ZL2 是打开 GitHub 下载页）
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2RendererSettingsViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END

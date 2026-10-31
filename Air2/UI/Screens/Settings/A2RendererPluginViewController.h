//
//  A2RendererPluginViewController.h
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
//  A2RendererPluginViewController.h
//  Air2
//
//  渲染器插件管理页 —— 导入、查看、卸载。
//
//  对照 FCL 的「渲染器来自插件」体验，但改用 zip 导入：
//    FCL: 装个 APK → 自动出现
//    Air2: 导入 zip → 自动出现
//
//  ★入口★：设置 → 渲染 → 「导入渲染器…」（`A2RuntimeSettings` 的那一行）。
//
//  页面结构：
//    ┌──────────────────────────────┐
//    │ 说明                          │
//    │ [导入渲染器…]                 │  .air2plugin / .zip
//    ├──────────────────────────────┤
//    │ 内置渲染器                     │  只读，不可卸载
//    │ [Metal (metallum)]  包内已内置 │
//    │ [GL4ES]             包内未内置 │
//    ├──────────────────────────────┤
//    │ 已导入（2）                    │
//    │ ┌────────────────────────┐  │
//    │ │ [图标] MyGL      ✓ 可用 │  │
//    │ │  v1.0 · 作者 · 合并库  卸载 │  │
//    │ └────────────────────────┘  │
//    │ ┌────────────────────────┐  │
//    │ │ [图标] VirGL  ⚠ 架构不符 │  │
//    │ └────────────────────────┘  │
//    └──────────────────────────────┘
//
//  ★本页只做「管理」★：选哪个渲染器在「设置 → 渲染」的渲染器行里，
//  这里不提供第二个选择入口（两个入口 = 两套状态）。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2RendererPluginViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END

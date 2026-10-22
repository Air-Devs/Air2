//
//  A2JREManageViewController.h
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
//  A2JREManageViewController.h
//  Air2
//
//  JRE 管理页 —— 参考 ZL2 的 Java 管理。
//
//  ## 页面结构
//
//    ┌────────────────────────────────────┐
//    │ 已安装的 Java 运行时                │
//    │  ┌──────────────────────────────┐  │
//    │  │ Java 17      内置  arm64     │  │
//    │  │ java-17-openjdk           ✓  │  │
//    │  └──────────────────────────────┘  │
//    │  ┌──────────────────────────────┐  │
//    │  │ Java 21      内置  arm64     │  │
//    │  └──────────────────────────────┘  │
//    ├────────────────────────────────────┤
//    │ [导入 JRE]                          │
//    └────────────────────────────────────┘
//
//  ## 与 ZL2 的差异
//
//  ZL2 的 Java 管理还要下载 JRE（它的 JRE 不随 APK 打包）。
//  我们的 4 个 JRE 已经打包进 IPA，所以这个页面只做
//  「查看 / 导入自定义 / 删除导入的 / 给版本指定」。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2JREManageViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END

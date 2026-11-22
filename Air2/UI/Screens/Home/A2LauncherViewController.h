//
//  A2LauncherViewController.h
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
//  主界面 —— 横屏三区布局。
//
//  ┌────────────────────────────────────────────────────────────┐
//  │  Air2                                   [账户] [下载] [设置] │  顶栏
//  ├──────────────────────────────┬─────────────────────────────┤
//  │                              │  账户卡                      │
//  │   自定义背景 / 主题渐变        │  版本卡（含启动按钮）          │
//  │                              │  快捷入口网格                 │
//  │   62%                        │  38%                        │
//  └──────────────────────────────┴─────────────────────────────┘
//
//  横屏理由：Java 版本身是横屏游戏，启动器横屏后到游戏画面出现之间
//  不会有方向切换的黑屏与旋转，体验连续。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2LauncherViewController : UIViewController

@end

NS_ASSUME_NONNULL_END

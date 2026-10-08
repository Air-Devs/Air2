//
//  A2ColorThemeDialog.h
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
//  颜色主题弹窗。
//
//  布局（对应 ZL2 的「颜色主题」对话框）：
//    ┌──────────────────────────────────────────┐
//    │              颜色主题                      │
//    ├────────────────┬─────────────────────────┤
//    │  配色风格        │      ┌─────────┐        │
//    │  ◉ TonalSpot   │      │  二维色盘 │        │
//    │  ○ Neutral     │      └─────────┘        │
//    │  ○ Vibrant     │      ▬▬▬▬▬ 明度条        │
//    │  ○ Expressive  │      #FF6B35            │
//    ├────────────────┴─────────────────────────┤
//    │     [ 取消 ]        [   确认   ]           │
//    └──────────────────────────────────────────┘
//
//  「配色风格」是 MD3 的 PaletteStyle：用同一个种子色推导出不同风格的
//  完整色板（TonalSpot 最中性、Vibrant 高饱和、Expressive 更活泼）。
//

#import <UIKit/UIKit.h>
#import "A2PaletteStyle.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ColorThemeDialog : UIViewController

/// 确认时回调：返回选中的种子色与配色风格
+ (void)presentFrom:(UIViewController *)host
          seedColor:(nullable UIColor *)seedColor
              style:(A2PaletteStyle)style
         onComplete:(void (^)(UIColor *color, A2PaletteStyle style))onComplete;

@end

NS_ASSUME_NONNULL_END

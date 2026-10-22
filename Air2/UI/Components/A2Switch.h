//
//  A2Switch.h
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
//  A2Switch.h
//  Air2
//
//  MD3 风格开关 —— 对应 ZL2 的 DefaultSwitch。
//
//  为什么不用系统 UISwitch：
//    ZL2 用的是 MD3 的 Switch + 自定义 thumbContent：
//      · 轨道是药丸形，开=主色，关=表面容器色
//      · 滑块里带图标：开 = 对勾，关 = 叉
//      · 切换时图标旋转 180°（用 Crossfade 交叉淡入）
//    系统 UISwitch 的外观与 MD3 差别明显，会破坏整体设计语言。
//
//  规格（对齐 MD3）：
//    轨道 52×32，圆角 16
//    滑块 24×24，圆角 12
//    图标 16pt
//    滑块位移 20pt
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Switch : UIControl

/// 开关状态（带动画）
@property (nonatomic, assign, getter=isOn) BOOL on;

/// 状态变化回调
@property (nonatomic, copy, nullable) void (^onChange)(BOOL isOn);

/// 无回弹地设置状态（用于从设置恢复初值）
- (void)setOn:(BOOL)on animated:(BOOL)animated;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

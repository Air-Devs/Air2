//
//  A2ColorWheel.h
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
//  颜色选择器 —— 二维大色盘 + 色相条 + 明度条 + 十六进制输入。
//
//  为什么用二维色盘而不是三条独立滑条：
//  二维盘能一眼看到「色相 → 饱和度」的完整分布，拖动时颜色变化是连续的、
//  可预期的。三条滑条需要用户自己脑内组合，选色效率低得多。
//  明度单独一条，因为它是一维的、且需要精确控制。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ColorWheel;

@protocol A2ColorWheelDelegate <NSObject>
@optional
/// 颜色变化（拖动过程中持续触发）
- (void)colorWheel:(A2ColorWheel *)wheel didChangeColor:(UIColor *)color;
/// 拖动结束
- (void)colorWheel:(A2ColorWheel *)wheel didFinishWithColor:(UIColor *)color;
@end

@interface A2ColorWheel : UIView

@property (nonatomic, weak, nullable) id<A2ColorWheelDelegate> delegate;

/// 当前颜色
@property (nonatomic, strong) UIColor *color;
/// 设置颜色（不触发回调）
- (void)setColor:(UIColor *)color animated:(BOOL)animated;

/// 是否显示明度条，默认 YES
@property (nonatomic, assign) BOOL showsBrightnessSlider;

@end

NS_ASSUME_NONNULL_END

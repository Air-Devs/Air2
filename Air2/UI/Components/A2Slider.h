//
//  A2Slider.h
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
//  A2Slider.h
//  Air2
//
//  MD3 风格滑杆 —— 对应 ZL2 那套「滑轨 + 数值胶囊 + 微调箭头」的形态。
//
//  视觉（从 ZL2 截图读出）：
//    ▬▬▬▬▬▬▬▬▬▬●────────────   ┌─────────────┐
//      已选部分：主色             │ 100%  ◀  ▶  │  ← 数值胶囊，两侧微调
//      未选部分：主色低透明        └─────────────┘
//      滑块：细长竖条（不是圆点）
//      轨道两端：圆头
//
//  为什么用胶囊 + 箭头而不是纯滑杆：
//    精确调整时手指会挡住数值，箭头可以点按微调。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Slider : UIView

/// 取值范围
@property (nonatomic, assign) CGFloat minimumValue;
@property (nonatomic, assign) CGFloat maximumValue;
/// 当前值
@property (nonatomic, assign) CGFloat value;
/// 步进（点箭头时每次增减多少）
@property (nonatomic, assign) CGFloat step;
/// 数值显示格式（如 @"%.0f%%"）；nil 则直接显示数字
@property (nonatomic, copy, nullable) NSString *valueFormat;

/// 值变化回调
@property (nonatomic, copy, nullable) void (^onValueChange)(CGFloat value);

/// 无动画设置初值
- (void)setValue:(CGFloat)value animated:(BOOL)animated;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

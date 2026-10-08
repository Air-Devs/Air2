//
//  A2SettingsSection.h
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
//  设置分组 —— 一组设置行拼成一张卡。
//
//  排版对齐 ZL2 的 SettingsCardColumn：
//    行间距    2
//    首行      上圆角 28 / 下圆角 4
//    中间行    四角都是 4
//    末行      上圆角 4 / 下圆角 28
//
//  也就是说视觉上是「一张卡片被分成若干行」，
//  而不是「一堆独立的小卡片」—— 这是 MD3 设置页的标准形态。
//

#import <UIKit/UIKit.h>
#import "A2SettingsRow.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2SettingsSection : UIView

- (instancetype)initWithTitle:(nullable NSString *)title;

@property (nonatomic, copy, nullable) NSString *sectionTitle;
/// 分组底部的说明文字
@property (nonatomic, copy, nullable) NSString *footerText;

/// 添加一行（自动处理首/中/末位置与分隔线）
- (void)addRow:(A2SettingsRow *)row;
/// 添加自定义视图
- (void)addCustomView:(UIView *)view;

@property (nonatomic, strong, readonly) NSArray<A2SettingsRow *> *rows;

@end

NS_ASSUME_NONNULL_END

//
//  A2SettingsRow.h
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
//  设置行 —— 设置页与配置页的通用单元。
//
//  排版规格对齐 ZL2 的 SettingsCard：
//    内边距      16
//    行间距      2（由 A2SettingsSection 负责）
//    标题        titleSmall  15pt Medium
//    副标题      labelSmall  12pt Regular
//    右侧        valueText / 箭头 / 开关 / 自定义视图
//
//  圆角由分组决定：本行是分组的首/中/末行，
//  只有首末行需要大圆角（28），中间行用 4。
//

#import <UIKit/UIKit.h>
#import "A2CardPosition.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2SettingsRowAccessory) {
    A2SettingsRowAccessoryNone = 0,
    A2SettingsRowAccessoryDisclosure,   ///< 右箭头
    A2SettingsRowAccessorySwitch,       ///< 开关
    A2SettingsRowAccessoryCheckmark,    ///< 选中勾
    A2SettingsRowAccessoryCustom,       ///< 自定义右侧视图
};

@interface A2SettingsRow : UIControl

/// 图标（SF Symbol 名），可选
@property (nonatomic, copy, nullable) NSString *symbolName;
/// 图标底色
@property (nonatomic, strong, nullable) UIColor *symbolColor;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *valueText;

@property (nonatomic, assign) A2SettingsRowAccessory accessory;
@property (nonatomic, strong, nullable) UIView *customAccessoryView;

/// 开关状态
@property (nonatomic, assign, getter=isOn) BOOL on;
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL isOn);
@property (nonatomic, copy, nullable) void (^onTap)(void);

/// 危险样式（红色文字）
@property (nonatomic, assign, getter=isDestructive) BOOL destructive;

/// 在分组中的位置，决定圆角
@property (nonatomic, assign) A2CardPosition cardPosition;

/// 是否显示行间分隔线（末行不显示）
@property (nonatomic, assign) BOOL showsSeparator;

/// 背景层级
@property (nonatomic, assign) BOOL useHighContainer;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

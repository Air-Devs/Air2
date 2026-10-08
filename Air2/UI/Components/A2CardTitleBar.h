//
//  A2CardTitleBar.h
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
//  卡片顶栏 —— 参考 ZL2 的 CardTitleLayout。
//  半透明表面 + 标题 + 右侧可选操作按钮。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CardTitleBar : UIView

- (instancetype)initWithTitle:(NSString *)title;

@property (nonatomic, copy) NSString *title;

/// 右侧操作按钮。设置后显示在标题右侧。
@property (nonatomic, strong, nullable) UIButton *accessoryButton;

/// 副标题（可选），显示在标题下方
@property (nonatomic, copy, nullable) NSString *subtitle;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

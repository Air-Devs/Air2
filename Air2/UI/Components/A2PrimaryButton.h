//
//  A2PrimaryButton.h
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
//  主按钮 —— "开始游戏"这类核心操作的视觉焦点。
//  渐变填充 + 弹簧按压 + 可选加载态。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ButtonStyle) {
    A2ButtonStylePrimary = 0,  ///< 渐变主色 —— 核心操作
    A2ButtonStyleSecondary,    ///< 描边透明 —— 次要操作
    A2ButtonStyleDanger,       ///< 危险操作
};

@interface A2PrimaryButton : UIControl

- (instancetype)initWithTitle:(NSString *)title style:(A2ButtonStyle)style;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) A2ButtonStyle style;

/// 加载态：显示菊花并禁用交互
@property (nonatomic, assign, getter=isLoading) BOOL loading;

/// 按钮展开为全宽胶囊的最小高度
@property (nonatomic, assign) CGFloat minHeight;

/// 图标（可选），显示在标题左侧
@property (nonatomic, strong, nullable) UIImage *icon;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

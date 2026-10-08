//
//  A2TextField.h
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
//  MD3 填充式文本输入框（filled text field）。
//
//  形态：surfaceContainerHighest 填充 + 上两角小圆角 + 底部 1dp 下划线。
//  标签在空且未聚焦时位于输入行内，聚焦或有内容时上浮到顶部 —— 即 MD3
//  的 floating label。错误态下整条下划线与标签转为 error 色，并在下方
//  显示一行支持文本（supporting text）。
//
//  为什么自己写而不是直接用 UITextField：
//    UITextField 本身没有 MD3 形态，靠外部拼背景 + 标签会散落在每个
//    页面里。收敛成一个组件后，登录页等只需要描述「标签 / 是否密码」。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2TextField : UIView

- (instancetype)initWithLabel:(NSString *)label;

/// 浮动标签文字
@property (nonatomic, copy) NSString *labelText;
/// 输入内容
@property (nonatomic, copy) NSString *text;
/// 是否密码输入（掩码显示）
@property (nonatomic, assign, getter=isSecure) BOOL secure;
/// 键盘类型
@property (nonatomic, assign) UIKeyboardType keyboardType;
/// 自动大写策略
@property (nonatomic, assign) UITextAutocapitalizationType autocapitalizationType;

/// 非空的错误文案。设置后进入错误态并在下方显示；传 nil 清除。
@property (nonatomic, copy, nullable) NSString *errorText;
/// 非错误态的支持文本（说明文字），可选。
@property (nonatomic, copy, nullable) NSString *supportText;

/// 内部输入框。需要主动唤起键盘时可对它调用 becomeFirstResponder。
@property (nonatomic, strong, readonly) UITextField *textField;

/// 文本变化回调
@property (nonatomic, copy, nullable) void (^onTextChange)(NSString *text);
/// 键盘回车回调
@property (nonatomic, copy, nullable) void (^onReturn)(void);

/// 清除错误态（用户重新编辑时自动调用）
- (void)clearError;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

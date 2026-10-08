//
//  A2Typography.h
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
//  字体阶梯。用系统字体 + 明确的字号/字重组合，
//  不引入自定义字体（首包体积与中文字重覆盖都不划算）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Typography : NSObject

/// 大标题 —— 页面主标题，如"版本管理"
+ (UIFont *)titleLarge;
/// 卡片标题
+ (UIFont *)titleCard;
/// 卡片副标题 / 次要信息
+ (UIFont *)subtitleCard;
/// 正文
+ (UIFont *)body;
/// 说明文字
+ (UIFont *)caption;
/// 按钮文字
+ (UIFont *)button;
/// 数字强调（进度、大小、时长）—— 等宽数字，避免跳动
+ (UIFont *)numeric;

@end

NS_ASSUME_NONNULL_END

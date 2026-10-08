//
//  A2Toast.h
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
//  轻提示 —— 短暂显示一句话，不打断操作。
//  用途限于「操作已触发」这类即时反馈；需要用户确认的一律用弹窗，不要用 Toast。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Toast : NSObject

/// 在指定视图上显示提示，1.4 秒后自动消失
+ (void)show:(NSString *)message inView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END

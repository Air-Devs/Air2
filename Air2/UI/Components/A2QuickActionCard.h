//
//  A2QuickActionCard.h
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
//  主页快捷操作卡片 —— 图标 + 标题的方形玻璃卡。
//

#import "A2GlassCard.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2QuickActionCard : A2GlassCard

- (instancetype)initWithTitle:(NSString *)title symbolName:(NSString *)symbolName;

@property (nonatomic, copy) NSString *title;
/// SF Symbol 名
@property (nonatomic, copy) NSString *symbolName;

/// 点击回调
@property (nonatomic, copy, nullable) void (^onSelect)(void);

@end

NS_ASSUME_NONNULL_END

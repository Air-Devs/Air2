//
//  A2AccountRowView.h
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
//  账号列表的一行。
//
//  布局对齐 ZL2 的 AccountItem：
//    ○  [头像 46]  Steve        🔄   ⋮
//                  Microsoft 正版账号
//
//  左侧单选表示「当前使用的账号」，右侧是刷新与更多操作。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2AccountRowView : UIControl

- (instancetype)initWithName:(NSString *)name type:(NSString *)type;

@property (nonatomic, copy) NSString *accountName;
@property (nonatomic, copy) NSString *accountType;

/// 账号皮肤文件路径；有值时头像显示皮肤头，无值时显示账号名首字母
@property (nonatomic, copy, nullable) NSString *skinPath;

/// 是否为当前账号
@property (nonatomic, assign, getter=isCurrent) BOOL current;

/// 是否可刷新（离线账号不可刷新）
@property (nonatomic, assign) BOOL refreshable;

@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onRefresh)(void);
@property (nonatomic, copy, nullable) void (^onMore)(void);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

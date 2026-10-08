//
//  A2VersionRowView.h
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
//  版本列表的一行。
//
//  布局对齐 ZL2 的 VersionItemLayout：
//    ○  [图标] 版本名          📌  ⚙️  ⋯
//              加载器信息
//
//  左侧单选按钮表示「当前正在使用的版本」，
//  右侧三个图标按钮：置顶、版本设置、更多操作。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionRowView : UIControl

- (instancetype)initWithVersionName:(NSString *)name meta:(nullable NSString *)meta;

@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy, nullable) NSString *meta;

/// 是否为当前选中的版本（左侧单选按钮的选中态）
@property (nonatomic, assign, getter=isCurrent) BOOL current;

/// 是否置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;

/// 版本是否有效（无效时右侧按钮置灰）
@property (nonatomic, assign, getter=isValid) BOOL valid;

@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onPin)(void);
@property (nonatomic, copy, nullable) void (^onSettings)(void);
@property (nonatomic, copy, nullable) void (^onMore)(void);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

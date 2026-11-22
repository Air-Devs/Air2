//
//  A2SegmentedControl.h
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
//  MD3 分段按钮（segmented button）。
//
//  整条是一个全圆角描边胶囊，选中项用 secondaryContainer 高亮。
//  用于在同一页里切换互斥的几种模式（如登录方式）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2SegmentedControl : UIView

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles;

/// 当前选中下标。设置后不会触发 onSegmentChange。
@property (nonatomic, assign) NSInteger selectedIndex;

/// 用户点击切换时回调
@property (nonatomic, copy, nullable) void (^onSegmentChange)(NSInteger index);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

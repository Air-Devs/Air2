//
//  A2CategoryNavView.h
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
//  左侧分类导航 —— 设置页与下载页共用。
//
//  视觉规格对齐 ZL2 的 TabMenu / settings 的 TabMenu：
//    · 竖排：图标在上（24pt）、文字在下（labelMedium 11pt）
//    · 左内边距 8
//    · 项间距 8
//    · 分组分隔线：40% 宽、透明度 0.4、上下 12 间距
//    · 选中态：secondaryContainer 背景 + onSecondaryContainer 文字
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 导航项
@interface A2NavCategory : NSObject
@property (nonatomic, copy) NSString *title;
/// SF Symbol 名
@property (nonatomic, copy) NSString *symbol;
/// 该项之前是否插入分隔线（分组）
@property (nonatomic, assign) BOOL divisionBefore;
+ (instancetype)title:(NSString *)t symbol:(NSString *)s;
+ (instancetype)title:(NSString *)t symbol:(NSString *)s division:(BOOL)division;
@end

@interface A2CategoryNavView : UIView

/// 固定宽度，默认 88
@property (nonatomic, assign) CGFloat navWidth;

/// 选中索引变化回调
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);

@property (nonatomic, assign, readonly) NSInteger selectedIndex;

- (instancetype)initWithCategories:(NSArray<A2NavCategory *> *)categories;
- (void)selectIndex:(NSInteger)index animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END

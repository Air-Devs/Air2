//
//  A2VersionCard.h
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
//  版本卡片 —— 用于「最近游玩」横滑列表和版本管理网格。
//  参考 ZL2 的 VersionCardContent，视觉上是：
//    [版本图标] 版本名
//               附加信息（加载器 / 上次游玩）
//               可选：置顶角标、状态点
//

#import <UIKit/UIKit.h>
#import "A2GlassCard.h"

NS_ASSUME_NONNULL_BEGIN

/// 版本卡片状态，对应 ZL2 的 VersionCardStatus
typedef NS_ENUM(NSInteger, A2VersionCardStatus) {
    A2VersionCardStatusLoading = 0,   ///< 尚未完成首次检查
    A2VersionCardStatusAvailable,     ///< 可用
    A2VersionCardStatusDeleted,       ///< 目录可访问但版本已不存在
    A2VersionCardStatusInaccessible,  ///< 路径不可访问
};

@interface A2VersionCard : A2GlassCard

- (instancetype)initWithVersionName:(NSString *)name meta:(nullable NSString *)meta;

@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy, nullable) NSString *meta;

@property (nonatomic, assign) A2VersionCardStatus status;

/// 置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;

/// 版本图标。为空时用首字母占位。
@property (nonatomic, strong, nullable) UIImage *versionIcon;

/// 选中态（当前默认版本）
@property (nonatomic, assign, getter=isSelected) BOOL selected;

/// 点击回调
@property (nonatomic, copy, nullable) void (^onSelect)(void);

/// 长按回调
@property (nonatomic, copy, nullable) void (^onLongPress)(void);

@end

NS_ASSUME_NONNULL_END

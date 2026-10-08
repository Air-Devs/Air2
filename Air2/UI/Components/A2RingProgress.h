//
//  A2RingProgress.h
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
//  环形进度 —— 单任务的总进度展示（如版本安装）。
//  环上带进度弧，中心显示百分比与说明文字。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2RingProgress : UIView

/// 进度 0.0~1.0
@property (nonatomic, assign) CGFloat progress;
/// 环宽，默认 6
@property (nonatomic, assign) CGFloat lineWidth;
/// 中心显示的大字（如百分比）
@property (nonatomic, copy, nullable) NSString *centerText;
/// 中心下方的小字（如"下载中"）
@property (nonatomic, copy, nullable) NSString *captionText;

/// 平滑动画到目标进度
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

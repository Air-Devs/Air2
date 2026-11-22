//
//  A2ProgressBar.h
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
//  线性进度条 —— 进度 + 已下载/总量 + 实时速度。
//  进度条头部带光晕，让推进有个明显的"亮头"。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ProgressBar : UIView

@property (nonatomic, assign) CGFloat progress;             ///< 0.0~1.0
@property (nonatomic, copy, nullable) NSString *speedText;  ///< 如 "2.4 MB/s"
@property (nonatomic, copy, nullable) NSString *detailText; ///< 如 "1.2 GB / 2.0 GB"

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

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
//  头部带光晕，让进度推进有个明显的"亮头"。
//  总大小未知（chunked）时切「不确定态」：轨道上有一段指示器来回滑动。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ProgressBar : UIView

@property (nonatomic, assign) CGFloat progress;             ///< 0.0~1.0
@property (nonatomic, copy, nullable) NSString *speedText;  ///< 如 "2.4 MB/s"
@property (nonatomic, copy, nullable) NSString *detailText; ///< 如 "1.2 GB / 2.0 GB"

/// 不确定态：不表达比例，轨道上只有一段来回滑动的指示器。
/// 用于总大小未知（chunked / 服务端不给 Content-Length）的下载。
@property (nonatomic, assign) BOOL indeterminate;

/// 指示器颜色。nil 时取语义主色（cPrimary）；
/// 调用方按语义角色解析后传入（暂停 = outline 系、失败 = error…）。
@property (nonatomic, strong, nullable) UIColor *indicatorColor;

/// 只要轨道：不画「已下/总量」与「速度」这两行文字。
/// 用于外层自己排版这些文字的场合（如 A2DownloadProgressRow），
/// 否则空标签仍会撑出一段高度，进度条下方留一条莫名的空白。
@property (nonatomic, assign) BOOL trackOnly;

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

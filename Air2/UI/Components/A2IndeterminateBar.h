//
//  A2IndeterminateBar.h
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
//
//  A2IndeterminateBar.h
//  Air2
//
//  不确定进度条 —— 对应 Material 的 LinearProgressIndicator() 无参形式。
//
//  ZL2 的用法：taskProgress < 0 时表示"不知道还要多久"，
//  显示一条来回滑动的短条，而不是停在某个百分比。
//
//  为什么需要它：
//    「统计下载任务」「解析安装包」这类阶段耗时不确定，
//    给个假百分比（比如一直 0%）比不给更糟 —— 用户会以为卡住了。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2IndeterminateBar : UIView

@property (nonatomic, assign) CGFloat barWidthRatio;   ///< 滑动条占轨道宽度的比例，默认 0.3

- (void)startAnimating;
- (void)stopAnimating;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

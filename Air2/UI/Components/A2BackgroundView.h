//
//  A2BackgroundView.h
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
//  自定义背景 —— 主界面左侧「个性化区」。
//
//  三种来源，优先级从高到低：
//    1. 用户设置的图片
//    2. 当前主题的渐变
//
//  图片处理链（顺序重要）：
//    原图 → 缩放到填充 → 可选模糊 → 暗色遮罩 → 右侧渐隐
//
//  右侧渐隐是必须的：用户可能选一张花哨的图，不加渐隐的话
//  右侧操作栏的卡片与背景对比度不受控，文字会看不清。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2BackgroundView : UIView

/// 右侧渐隐区域宽度占比，默认 0.35。
/// 设为 0 表示不做渐隐（用户明确要全图无遮挡时）。
@property (nonatomic, assign) CGFloat fadeRatio;

/// 重新套用（背景图或主题变化时调用）
- (void)applyBackground;

/// 切换背景时做一个交叉淡入
- (void)applyBackgroundAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END

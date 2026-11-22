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
//  自定义背景 —— 所有页面共用。
//
//  两种状态：
//    1. 用户设置的图片 / 视频（模糊/遮罩/渐隐全链路生效）
//    2. 无媒体即主题纯色（MD3 surface，无装饰渐变）
//
//  媒体处理链（顺序重要）：
//    原图/视频首帧 → 缩放到填充 → 可选模糊 → 暗色遮罩 → 右侧渐隐
//
//  视频：静音循环、AspectFill，进后台自动暂停、回前台恢复；
//  解码失败先回落到首帧海报，再回落到纯色，不会黑屏。
//
//  右侧渐隐是必须的：用户可能选一张花哨的图，不加渐隐的话
//  右侧操作栏的卡片与背景对比度不受控，文字会看不清。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2BackgroundView : UIView

/// 右侧渐隐区域宽度占比，默认 0.35。
/// 设为 0 表示不做渐隐（二级页面全屏内容用 0）。
@property (nonatomic, assign) CGFloat fadeRatio;

/// 重新套用（背景图或主题变化时调用）
- (void)applyBackground;

/// 切换背景时做一个交叉淡入
- (void)applyBackgroundAnimated:(BOOL)animated;

/// 暂停 / 恢复视频背景（页面不可见、App 进后台时调用）。
/// 没有视频背景时是空操作。
- (void)pausePlayback;
- (void)resumePlayback;

@end

NS_ASSUME_NONNULL_END

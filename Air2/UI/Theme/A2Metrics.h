//
//  A2Metrics.h
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
//  尺寸与动效常量。
//
//  数值参考 Material Design 3 规范，并与 ZalithLauncher2 的实际取值对齐
//  （它是 Android 上成熟落地的 MD3 启动器，这些值是经过真机验证的）：
//    · 操作区 : 内容区 = 3 : 7
//    · 卡片外边距 12dp
//    · 卡片圆角用 MD3 的 extraLarge 一档
//    · 卡片内边距 12dp
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 间距（MD3 的 4dp 网格）

UIKIT_EXTERN const CGFloat A2SpaceXS;    // 4
UIKIT_EXTERN const CGFloat A2SpaceS;     // 8
UIKIT_EXTERN const CGFloat A2SpaceM;     // 12  ← MD3 卡片内边距的常用值
UIKIT_EXTERN const CGFloat A2SpaceL;     // 16
UIKIT_EXTERN const CGFloat A2SpaceXL;    // 24
UIKIT_EXTERN const CGFloat A2SpaceXXL;   // 32

/// 卡片内边距。MD3 的卡片默认 12dp，不是 16。
UIKIT_EXTERN const CGFloat A2CardPadding;

/// 卡片之间的间距，同样 12
UIKIT_EXTERN const CGFloat A2CardSpacing;

/// 操作区相对屏幕的外边距
UIKIT_EXTERN const CGFloat A2PanelOuterPadding;

/// 页面内容左右安全边距（二级页面的通用边距）
UIKIT_EXTERN const CGFloat A2PageMargin;

/// 二级页面内容的最大宽度。
///
/// 横屏下必须限制：iPad 横屏有 1000pt+ 宽，如果卡片撑满，
/// 一行文字会横跨半个屏幕，阅读时视线要来回扫，非常累。
/// 680pt 接近纸质文档的舒适行宽。
/// 窄屏（iPhone 横屏约 850pt）减去边距后小于该值，不生效。
UIKIT_EXTERN const CGFloat A2ContentMaxWidth;

#pragma mark - 圆角（MD3 Shape Scale）

UIKIT_EXTERN const CGFloat A2RadiusXS;    // 4   extraSmall
UIKIT_EXTERN const CGFloat A2RadiusS;     // 8   small
UIKIT_EXTERN const CGFloat A2RadiusM;     // 12  medium
UIKIT_EXTERN const CGFloat A2RadiusL;     // 16  large
UIKIT_EXTERN const CGFloat A2RadiusXL;    // 28  extraLarge  ← 卡片用这档

#pragma mark - 高度

UIKIT_EXTERN const CGFloat A2TopBarHeight;    // 52
UIKIT_EXTERN const CGFloat A2ButtonHeight;    // 52  MD3 的按钮高度
UIKIT_EXTERN const CGFloat A2MinTouchTarget;  // 44

#pragma mark - 头像

/// 头像尺寸。大卡用 64，小行用 48 —— 对齐 ZL2 的两种形态。
UIKIT_EXTERN const CGFloat A2AvatarSizeLarge;
UIKIT_EXTERN const CGFloat A2AvatarSizeSmall;

#pragma mark - 布局划分

/// 操作区宽度占屏幕的比例（3 : 7）
UIKIT_EXTERN const CGFloat A2PanelWidthRatio;

/// 屏幕高度达到该值时可使用「更宽松」的布局（多展示一块区域）
UIKIT_EXTERN const CGFloat A2TallLayoutThreshold;

#pragma mark - 动效（MD3 Expressive MotionScheme）

/// 标准过渡
UIKIT_EXTERN const NSTimeInterval A2AnimDuration;
/// 快速反馈（按压、高亮）
UIKIT_EXTERN const NSTimeInterval A2AnimDurationFast;
/// 慢速（页面切换、背景）
UIKIT_EXTERN const NSTimeInterval A2AnimDurationSlow;
/// 卡片入场
UIKIT_EXTERN const NSTimeInterval A2AnimDurationCard;

/// 弹簧阻尼比
UIKIT_EXTERN const CGFloat A2SpringDamping;
UIKIT_EXTERN const CGFloat A2SpringVelocity;

/// 卡片入场时的逐个延迟
UIKIT_EXTERN const NSTimeInterval A2CardStaggerDelay;

#pragma mark - 动画器

UIViewPropertyAnimator *A2SpringAnimator(NSTimeInterval duration);
UIViewPropertyAnimator *A2StandardSpring(void);
/// 更"软"的弹簧，适合大面积元素
UIViewPropertyAnimator *A2SoftSpring(NSTimeInterval duration);

/// MD3 Expressive 风格的弹性动画（回弹更明显，用于强调操作）
UIViewPropertyAnimator *A2ExpressiveSpring(NSTimeInterval duration);

#pragma mark - 卡片入场

UIViewPropertyAnimator *A2AnimateCardEntrance(NSArray<UIView *> *views,
                                              CGFloat staggerDelay,
                                              void (^ _Nullable completion)(void));

NS_ASSUME_NONNULL_END

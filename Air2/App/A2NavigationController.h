//
//  A2NavigationController.h
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
//  自定义导航控制器 —— 承载页面转场动画。
//
//  为什么不用系统默认转场：
//  默认的「从右侧推入」在启动器这种卡片化界面里显得生硬，
//  且横向位移在横屏大屏上视觉跨度太大。
//  这里提供三种转场，按页面性质选用。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2TransitionStyle) {
    /// 缩放淡入（默认）—— 新页从 94% 展开，适合同级页面切换
    A2TransitionStyleScaleFade = 0,
    /// 从底部滑入 —— 适合模态性质较强的页面（如安装流程）
    A2TransitionStyleSheet,
    /// 右侧推入 —— 适合层级较深的钻取（如设置 → 子设置）
    A2TransitionStylePush,
    /// 从来源放大展开 —— 像 iOS 桌面点图标开 App（主页五个入口用这个）
    A2TransitionStyleZoom,
};

@interface A2NavigationController : UINavigationController

/// ★转场样式偏好（设置 → 外观 → 转场动画）★
///   落盘键 `ui.transitionStyle`；只作用于普通页面，主页五个入口固定 Zoom。
+ (A2TransitionStyle)preferredTransitionStyle;
+ (void)setPreferredTransitionStyle:(A2TransitionStyle)style;

/// ★下一次 Zoom 转场的圆心（窗口坐标）★
///   传给 nil/不设时，退回「来源视图中心」。主页在 push 前用实际触摸点调用它。
+ (void)setNextZoomOrigin:(CGPoint)pointInWindow;
+ (BOOL)consumeNextZoomOrigin:(CGPoint *)outPoint;

/// ★动画速度偏好★ 0=慢 1=标准 2=快；返回时长倍率（慢 1.4 / 标准 1.0 / 快 0.72）
+ (NSInteger)preferredTransitionSpeed;
+ (void)setPreferredTransitionSpeed:(NSInteger)speed;
+ (CGFloat)transitionSpeedMultiplier;

/// 以指定转场样式推入页面
- (void)pushViewController:(UIViewController *)viewController
                transition:(A2TransitionStyle)style
                  animated:(BOOL)animated;

/// ★从来源视图发起（iOS 桌面那种"从图标长出来"）★
///   sourceView 传被点的那个卡片/图标；转场会以它的位置和大小作为起始态。
///   传 nil 等价于上一条（从屏幕中心）。
- (void)pushViewController:(UIViewController *)viewController
                transition:(A2TransitionStyle)style
                  fromView:(UIView *)sourceView
                  animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END

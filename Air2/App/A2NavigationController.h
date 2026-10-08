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
};

@interface A2NavigationController : UINavigationController

/// 以指定转场样式推入页面
- (void)pushViewController:(UIViewController *)viewController
                transition:(A2TransitionStyle)style
                  animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END

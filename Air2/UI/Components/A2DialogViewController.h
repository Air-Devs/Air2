//
//  A2DialogViewController.h
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
//  MD3 弹窗基类 —— 本项目所有弹窗的统一样式来源。
//
//  为什么不用 UIAlertController：
//    系统弹窗跟随的是 iOS 的外观，不是我们的 MD3 语义色板，
//    在自定义主题下会「一个界面两套风格」；
//    且系统输入弹窗（addTextFieldWithConfigurationHandler:）在本项目被明令禁止。
//    所以弹窗全部自研，配色/圆角/动效一律走 A2Metrics 与 A2ColorScheme。
//
//  视觉规格（对齐 MD3 对话框）：
//    · 遮罩    黑色 45%，点击可关闭
//    · 卡片    A2GlassCard + A2CardElevationHighest（surfaceContainerHighest）
//    · 圆角    A2RadiusXL（28）
//    · 内边距  A2SpaceXL（24）
//    · 宽度    min(maxCardWidth, 屏宽 × 0.92)，内容超长时内部滚动
//    · 入场    弹簧：缩放 0.94 + 下移 8pt + 淡入
//
//  子类用法：
//    在 viewDidLoad 里 [super viewDidLoad] 之后，往 contentStack 追加内容；
//    标题与底部按钮行用基类提供的方法生成，配色由基类统一维护。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2DialogViewController : UIViewController

/// 弹窗内容区（纵向栈）。子类往这里追加子视图。
@property (nonatomic, strong, readonly) UIStackView *contentStack;

/// 标题文字（基类负责配色与字号）。nil / 空串则不显示标题。
@property (nonatomic, copy, nullable) NSString *titleText;

/// 卡片最大宽度，默认 460
@property (nonatomic, assign) CGFloat maxCardWidth;

/// 点遮罩是否关闭，默认 YES
@property (nonatomic, assign) BOOL dismissOnBackdropTap;

/// 覆盖在 host 上展示（OverFullScreen + 自绘弹簧入场，不走系统转场）
- (void)presentOver:(UIViewController *)host;

/// 关闭弹窗
- (void)dismissDialog;

/// 关闭弹窗并在完全关掉后回调
- (void)dismissDialogWithCompletion:(nullable void (^)(void))completion;

/// 追加底部按钮行。两个标题都传 nil 则不加。
/// 取消按钮为次要样式，确认按钮为主样式；只有一个按钮时占满整行。
/// 两个按钮都会先关闭弹窗，再执行对应回调。
- (void)addButtonRowWithCancelTitle:(nullable NSString *)cancelTitle
                       cancelAction:(nullable void (^)(void))cancelAction
                       confirmTitle:(nullable NSString *)confirmTitle
                      confirmAction:(nullable void (^)(void))confirmAction;

/// 触发确认（等价于点「确认」按钮，也会被输入框的回车调用）。
/// 子类可重写以插入校验：校验不过就直接 return，留在弹窗里。
- (void)confirmDialog;

/// 触发取消（等价于点「取消」按钮）。子类可重写，在关闭前处理自己的收尾逻辑。
- (void)cancelDialog;

/// 主题变化时刷新颜色。子类重写时必须先调用 [super applyTheme]。
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

//
//  A2InputDialog.h
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
//  自研 MD3 输入弹窗。
//
//  布局：
//    ┌──────────────────────────────┐
//    │          标题                 │
//    │     可选说明文字（居中）        │
//    │  ┌────────────────────────┐  │
//    │  │ 浮动标签 + 输入框        │  │
//    │  └────────────────────────┘  │
//    ├──────────────────────────────┤
//    │   [ 取消 ]     [   确认   ]   │
//    └──────────────────────────────┘
//
//  为什么自研：系统输入弹窗（UIAlertController + addTextField…）
//  不跟随主题 / 材料包，横屏下样式割裂，也无法承载 MD3 语义色、
//  圆角与弹簧动效。见 docs/UI-DESIGN.md 第七节、DECISIONS.md ADR-006。
//
//  输入本体复用 A2TextField（MD3 填充式），本类只负责弹窗外壳、
//  按钮、键盘避让与「同步校验 + 异步提交」流程。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 异步提交回调。调用 done(YES, nil) 关闭弹窗；done(NO, 文案) 保留弹窗并显示错误。
typedef void (^A2InputDialogCommitBlock)(NSString *text,
                                         void (^done)(BOOL success,
                                                      NSString * _Nullable errorMessage));

/// 结束回调。committed = NO 表示用户取消。
typedef void (^A2InputDialogFinishBlock)(BOOL committed, NSString *text);

@interface A2InputDialog : UIViewController

/// 构建一个可配置的输入弹窗（改完属性后调 presentFrom:）
+ (instancetype)dialogWithTitle:(NSString *)title
                        message:(nullable NSString *)message
                          label:(nullable NSString *)label
                    initialText:(nullable NSString *)initialText;

#pragma mark - 配置（presentFrom: 之前设置）

@property (nonatomic, copy) NSString *titleText;
/// 标题下方的说明文字，可选
@property (nonatomic, copy, nullable) NSString *messageText;
/// 输入框浮动标签
@property (nonatomic, copy, nullable) NSString *fieldLabel;
/// 初始内容
@property (nonatomic, copy, nullable) NSString *initialText;
/// 是否密码输入
@property (nonatomic, assign, getter=isSecure) BOOL secure;
@property (nonatomic, assign) UIKeyboardType keyboardType;
@property (nonatomic, assign) UITextAutocapitalizationType autocapitalizationType;

@property (nonatomic, copy) NSString *confirmTitle;   ///< 默认「确认」
@property (nonatomic, copy) NSString *cancelTitle;    ///< 默认「取消」

/// 同步校验：返回非 nil 文案即不通过（弹窗内显示错误、阻止提交）。可选。
@property (nonatomic, copy, nullable) NSString * _Nullable (^validator)(NSString *text);

/// 异步提交：适合「保存前需服务端验证」这类场景。可选，未设置即直接成功。
@property (nonatomic, copy, nullable) A2InputDialogCommitBlock onCommit;

/// 结束回调。可选。
@property (nonatomic, copy, nullable) A2InputDialogFinishBlock onFinish;

#pragma mark - 呈现

- (void)presentFrom:(UIViewController *)host;

/// 简单场景一步到位（取消 / 确认，无异步验证）
+ (void)presentFrom:(UIViewController *)host
              title:(NSString *)title
              label:(nullable NSString *)label
        initialText:(nullable NSString *)initialText
           onFinish:(nullable A2InputDialogFinishBlock)onFinish;

@end

NS_ASSUME_NONNULL_END

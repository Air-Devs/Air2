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
//  MD3 单行输入弹窗 —— 标题 + 输入框 + 校验态说明 + 按钮行。
//
//  本项目禁用系统输入弹窗（UIAlertController + addTextFieldWithConfigurationHandler:），
//  凡是「让用户输一行字」的场景都走这里。
//
//  校验模型：调用方给一个 validator，返回错误文案（nil 表示通过）。
//  确认时先校验——不通过则停在弹窗里、把错误显示在输入框下方，而不是先关窗再报错。
//

#import <UIKit/UIKit.h>
#import "A2DialogViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 返回错误文案；返回 nil 表示校验通过
typedef NSString * _Nullable (^A2InputDialogValidator)(NSString *text);
/// 确认回调，text 为最终输入内容
typedef void (^A2InputDialogConfirm)(NSString *text);

@interface A2InputDialog : A2DialogViewController

- (instancetype)initWithTitle:(nullable NSString *)title
                  placeholder:(nullable NSString *)placeholder
                  initialText:(nullable NSString *)initialText
                     validate:(nullable A2InputDialogValidator)validate;

/// 一步展示输入弹窗并拿到结果。
/// confirmTitle 为 nil 时只显示取消。
+ (void)presentOver:(UIViewController *)host
              title:(nullable NSString *)title
        placeholder:(nullable NSString *)placeholder
        initialText:(nullable NSString *)initialText
           validate:(nullable A2InputDialogValidator)validate
        cancelTitle:(nullable NSString *)cancelTitle
       confirmTitle:(nullable NSString *)confirmTitle
          onConfirm:(nullable A2InputDialogConfirm)onConfirm;

@end

NS_ASSUME_NONNULL_END

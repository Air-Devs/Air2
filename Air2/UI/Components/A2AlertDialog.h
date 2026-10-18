//
//  A2AlertDialog.h
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
//  MD3 提示弹窗 —— 一段标题 + 若干段说明 + 按钮行。
//
//  用途：导入前的免责说明、导入成功/失败的结果提示。
//  替代 UIAlertController —— 系统弹窗的配色不跟随本项目的 MD3 色板。
//
//  说明文字按段落绘制，段间 8pt，整块与标题间距 16pt；
//  正文用 onSurfaceVariant，标题用 onSurface，主色只出现在按钮上。
//

#import <UIKit/UIKit.h>
#import "A2DialogViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^A2AlertDialogAction)(void);

@interface A2AlertDialog : A2DialogViewController

- (instancetype)initWithTitle:(nullable NSString *)title paragraphs:(NSArray<NSString *> *)paragraphs;

/// 一步展示提示弹窗。
/// confirmTitle 为 nil 时只显示取消；cancelTitle 为 nil 时只显示确认。
+ (void)presentOver:(UIViewController *)host
              title:(nullable NSString *)title
         paragraphs:(NSArray<NSString *> *)paragraphs
        cancelTitle:(nullable NSString *)cancelTitle
       confirmTitle:(nullable NSString *)confirmTitle
          onConfirm:(nullable A2AlertDialogAction)onConfirm;

@end

NS_ASSUME_NONNULL_END

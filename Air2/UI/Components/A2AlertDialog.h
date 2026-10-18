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
//
//  自研 MD3 消息弹窗 —— 标题 + 正文 + 按钮，不含输入框。
//
//  布局：
//    ┌──────────────────────────────┐
//    │          标题                 │
//    │  正文（可滚动，超长不撑破卡片）  │
//    ├──────────────────────────────┤
//    │   [ 取消 ]     [   确定   ]   │
//    └──────────────────────────────┘
//
//  为什么与 A2InputDialog 分开：外壳相似但职责不同 ——
//  输入弹窗承载「编辑 + 校验」，消息弹窗承载「告知 / 二次确认」。
//  硬把两者合成一个组件，会让调用方纠结要不要传空 label，
//  名字也说不清它到底是哪一个（见 docs/ARCHITECTURE.md 命名即文档）。
//
//  按钮形态：cancelTitle 为 nil 时只有一个确认按钮，占满整行。
//
//  为什么自研：系统 UIAlertController 不跟随主题 / 材料包，
//  横屏与 iPad 下样式割裂，也承载不了 MD3 语义色与弹簧动效。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 结束回调。confirmed = NO 表示点了取消或点遮罩关闭。
typedef void (^A2AlertDialogFinishBlock)(BOOL confirmed);

@interface A2AlertDialog : UIViewController

/// 构建一个可配置的消息弹窗（改完属性后调 presentFrom:）
+ (instancetype)dialogWithTitle:(NSString *)title
                        message:(nullable NSString *)message;

#pragma mark - 配置（presentFrom: 之前设置）

@property (nonatomic, copy) NSString *titleText;
/// 正文，可选；超长时正文区可滚动
@property (nonatomic, copy, nullable) NSString *messageText;
@property (nonatomic, copy) NSString *confirmTitle;          ///< 默认「确定」
/// 取消按钮标题；为 nil 时不显示取消按钮（单按钮形态）
@property (nonatomic, copy, nullable) NSString *cancelTitle;

/// 结束回调。可选。
@property (nonatomic, copy, nullable) A2AlertDialogFinishBlock onFinish;

#pragma mark - 呈现

- (void)presentFrom:(UIViewController *)host;

/// 一步到位（取消标题传 nil 即单按钮）
+ (void)presentFrom:(UIViewController *)host
              title:(NSString *)title
            message:(nullable NSString *)message
       confirmTitle:(nullable NSString *)confirmTitle
        cancelTitle:(nullable NSString *)cancelTitle
           onFinish:(nullable A2AlertDialogFinishBlock)onFinish;

@end

NS_ASSUME_NONNULL_END

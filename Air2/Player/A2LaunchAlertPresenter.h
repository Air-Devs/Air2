//
//  A2LaunchAlertPresenter.h
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
//  Player —— 启动链里「找一个能承载模态的宿主控制器」的唯一实现。
//
//  ## ★已弃用：启动侧的 10 次免责确认★（撤销于 2026-10-31）
//
//  本类此前（e6a21f7）带着「实验性启动链（MG / EAGL / KW）逐次弹 10 次免责确认」的实现。
//  用户澄清那段确认**不是给选渲染器用的**：真正需要 10 次确认的是
//  「安装一个会修改启动链的插件」⇒ 10 次确认整体迁到插件侧安装流程
//  （`A2PluginLaunchChainRisk` 判定 + `A2PluginLaunchChainConfirm` 弹窗）。
//
//  所以本类**只保留** `+topViewController`：
//    · 启动失败页要宿主 —— 删掉它就得在 `A2LaunchSession` 里再手写一份
//      「key window → 沿 presentedViewController 下钻」，两份拷贝迟早不一致；
//    · 插件安装侧的 10 次确认同样需要宿主查找，下一个弹窗类可以直接复用。
//  ★启动链里不再有任何确认门★：点启动 ⇒ 完整性核对 → 后台链（①→②→③）→ 建 VM。
//
//  ★为什么用 alert 而不是 ActionSheet★：`scripts/check_no_glass.py` 判据 E 规定
//    Air2/ 内不得出现 `UIAlertControllerStyleActionSheet`（系统半透明材质、不跟主题）。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2LaunchAlertPresenter : NSObject

/// 可承载模态的顶层控制器（key window 根 → 沿 presentedViewController 逐层下钻）。
/// 无可用窗口 / 根控制器为空 ⇒ nil（调用方须按「呈现不了」处理，不许静默当成已确认）。
+ (nullable UIViewController *)topViewController;

@end

NS_ASSUME_NONNULL_END

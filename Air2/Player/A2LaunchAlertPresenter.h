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
//  Player —— 启动链「要用户读完才放行」的确认弹窗呈现（UIAlertController · alert 样式）。
//
//  职责边界：
//    · 本类只做「弹窗 + 用户逐次确认」的交互，不解析渲染器、不写计划、不建 VM
//      （取值在 A2LaunchSession，计划在 Core）；
//    · 「哪些渲染器属于实验性启动链」的判据在 Core 的
//      `+[A2RendererCatalog isExperimentalLaunchChainIdentifier:]`，本类只消费结论。
//
//  ★为什么用 alert 而不是 ActionSheet★：`scripts/check_no_glass.py` 判据 E 规定
//    Air2/ 内不得出现 `UIAlertControllerStyleActionSheet`（系统半透明材质、不跟主题）；
//    alert 样式是「危险操作确认」的合法形态（与启动失败页同一口径）。
//
//  ★调用点★：
//    · `Air2/Player/A2LaunchSession.m`  — 实验性启动链的 10 次免责确认门 + 失败页的宿主查找
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2LaunchAlertPresenter : NSObject

/// 可承载模态的顶层控制器（key window 根 → 沿 presentedViewController 逐层下钻）。
/// 无可用窗口 / 根控制器为空 ⇒ nil（调用方须按「呈现不了」处理，不许静默当成已确认）。
+ (nullable UIViewController *)topViewController;

/// ★实验性启动链（MG / EAGL / KW）的 10 次免责确认★。
///
/// · 逐个弹、点了才弹下一个（★不阻塞主线程、不用 sleep★）；
/// · 非实验性渲染器（metallum / 内置 gl4es）⇒ 直接以 `proceed = YES` 回调，不打扰用户；
/// · `proceed == NO` 表示用户在任意一次点了「取消」（启动侧据此终止，且不建 VM）；
/// · completion 在**主线程**回调。
///
/// ★每次调用都从头弹满 10 次★：本类不记录、不缓存「已同意」，同一会话内重复启动
/// 也要重新走完 10 次（用户明令，不要为了「体验」加记住状态）。
+ (void)confirmExperimentalChainForRendererIdentifier:(NSString *)rendererIdentifier
                                           completion:(nullable void (^)(BOOL proceed))completion;

@end

NS_ASSUME_NONNULL_END

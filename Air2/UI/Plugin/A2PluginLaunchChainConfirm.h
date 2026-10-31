//
//  A2PluginLaunchChainConfirm.h
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
//  ★「安装一个会修改启动链的插件」时的 10 次免责确认★（UI 层，只负责弹窗交互）。
//
//  ## 为什么是 10 次、为什么挂在安装上
//
//  启动链被插件改动后，游戏起的失败（启动不了 / 黑屏 / 闪退 / 存档损坏）无法与
//  「插件本身的问题」区分；用户要求把责任边界在**装之前**说到位，而且要逐次确认 ——
//  一次总同意挡不住习惯性连点。
//  ★不是给「选渲染器」用的★：那条渲染器侧的确认已在主树撤销（ADR-014 撤销记录）。
//
//  ## 触发条件（不在本类判定）
//
//  「这个插件会改启动链」= manifest 申请了 `A2PluginLaunchChainRisk` 判据集合里的权限，
//  由 `A2PluginInstaller` 在**校验通过、写 registry 之前**调闸门；
//  本类只消费「已经命中 + 命中哪几项」，不自己看权限表（两处判据迟早不一致）。
//
//  ## 硬规则
//
//  · 形式：标准 `UIAlertController`（alert 样式，**不用 ActionSheet** —— 与主树
//    `check_no_glass.py` 判据 E 同一口径；插件 tree 的 lint 也按同一形态扫描）；
//  · 逐个弹、点了才弹下一个（不阻塞主线程、不 sleep）；
//  · 每次都完整显示免责声明（不写「同上」），第 10 次追加一句后果承担；
//  · ★不缓存同意★：没有 NSUserDefaults 键、没有进程内标志 —— 每次安装都重新走完 10 次；
//  · 任意一次「取消」⇒ `proceed = NO`，安装器据此终止安装（清暂存、不写 registry）。

#import <UIKit/UIKit.h>

#import "A2PluginManifest.h"

NS_ASSUME_NONNULL_BEGIN

/// 结果：YES = 10 次全部点过「继续」；NO = 中途取消（或呈现不了窗口）。
typedef void (^A2PluginLaunchChainConfirmResult)(BOOL proceed);

@interface A2PluginLaunchChainConfirm : NSObject

/// 异步版：逐个弹 10 次，全部通过才以 `proceed = YES` 回调（回调在**主线程**）。
/// @param manifest    本次安装的 manifest（插件名取自 `name`，空则回退 `pluginId`）
/// @param permissions 命中判据的权限 id（`A2PluginLaunchChainRisk` 给出，非空；空则直接放行）
/// @param presenter   当前最前面的控制器（弹窗挂在它上面）
+ (void)presentForManifest:(A2PluginManifest *)manifest
               permissions:(NSArray<NSString *> *)permissions
                      from:(UIViewController *)presenter
                completion:(nullable A2PluginLaunchChainConfirmResult)completion;

/// 同步版：给 `A2PluginInstaller` 的闸门用（闸门是同步 BOOL 返回的）。
///
/// ★只能在非主线程调用★：10 次弹窗必须在主线程呈现，主线程在这里等自己 ⇒ 死锁。
/// 主线程调用直接返回 NO 并写一行判据（宁可拒装，也不要死锁）。
/// `presenter` 只在主线程解引用（本方法内部跳主线程后再用它）。
+ (BOOL)confirmSynchronouslyForManifest:(A2PluginManifest *)manifest
                            permissions:(NSArray<NSString *> *)permissions
                                   from:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END

//
//  A2PluginLaunchChainRisk.h
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
//  ★「这个插件会不会改启动链」的唯一判据★（安装期 10 次免责确认的触发条件）。
//
//  ## 为什么要有这一层（而不是在安装器/界面各写一遍）
//
//  10 次确认的触发条件必须只有一处：写在安装器里，界面就不知道「为什么弹」；
//  写在界面里，安装器就无法在「没确认就落盘」时拒绝（安全边界会挂在 UI 的自觉上）。
//  所以：判据 = 本文件；消费点两处 —— `A2PluginInstaller`（何时调用闸门）、
//  `A2PluginLaunchChainConfirm`（弹窗正文里的人话名单）。
//
//  ## 判据集合（用户明令，逐字照抄）
//
//    launch.args / launch.gameArgs / launch.classpath / launch.env.code /
//    java.agent / native.code
//
//  ★判据不按风险级推导★：`files.game.write.content`、`version.patch`、`native.module`
//  也是 critical，但它们改的是游戏内容 / 版本文件 / 原生模块，不改「游戏怎么被启动」
//  —— 那些有各自的三次确认（`A2PluginCriticalConfirmFlow`）。把 critical 一股脑算进来
//  只会让 10 次确认变成每次都弹，等于取消告警。
//
//  ★`native.code` 尚未在权限目录里登记★（目录目前 24 项，P5 才生效的 `native.module` 在前）：
//  它命中判据时，人话名单回退显示权限 id 本身 —— 不编一个不存在的名字；
//  目录将来登记它，这里的文案自动跟上（判据集合不依赖目录）。

#import <Foundation/Foundation.h>

#import "A2PluginManifest.h"

NS_ASSUME_NONNULL_BEGIN

/// 判据集合（6 项，只读副本）。申请了其中任意一项 ⇒ 插件「会修改启动链」。
FOUNDATION_EXPORT NSSet<NSString *> *A2PluginLaunchChainPermissionIds(void);

/// 这份 manifest 里**命中判据**的权限 id。
///
/// ★顺序固定 = 判据集合的声明顺序★（不跟着 manifest 里 permissions 的书写顺序走）：
/// 同一个包每次弹窗的名单顺序必须一致，否则用户会以为「这次申请的权限变了」。
/// 没命中 ⇒ 空数组（不是 nil）。
FOUNDATION_EXPORT NSArray<NSString *> *A2PluginLaunchChainPermissionsForManifest(
    A2PluginManifest *manifest);

/// 人话名单（「、」连接）：取权限目录的 `shortName`；目录里没有的 id 原样输出 id。
/// 空数组 ⇒ 空串（调用方不必再判 nil）。
FOUNDATION_EXPORT NSString *A2PluginLaunchChainPermissionNames(
    NSArray<NSString *> *permissionIds);

NS_ASSUME_NONNULL_END

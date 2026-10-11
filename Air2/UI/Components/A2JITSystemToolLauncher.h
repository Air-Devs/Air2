//
//  A2JITSystemToolLauncher.h
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
//  UI/Components —— ★Player 的拉起缝的真机实现★（UIApplication URL scheme）。
//
//  为什么在 UI：`canOpenURL:` / `openURL:` 属 UIKit，Player 不许碰（ADR-002 单向分层）。
//  Player 侧只认协议 A2JITExternalToolLauncher，真机在这里落地。
//
//  ★前置★：被探测的 scheme 必须登记在 Air2/Info.plist 的 LSApplicationQueriesSchemes
//  （否则 canOpenURL: 恒为 NO，且系统只记一笔失败，不会报错）。scheme 清单的
//  唯一真相源是 A2JITExternalToolProvider.registeredToolSchemes（单测逐项比对 Info.plist）。
//

#import <Foundation/Foundation.h>
#import "A2JITExternalToolLauncher.h"

NS_ASSUME_NONNULL_BEGIN

/// 真机拉起器（UIApplication）。
@interface A2JITSystemToolLauncher : NSObject <A2JITExternalToolLauncher>
@end

NS_ASSUME_NONNULL_END

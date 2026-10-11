//
//  A2JITEnvironmentProbe.h
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
//  Bridge —— ★真调判据内核★：把 Natives/Support/A2JITEnvironment 接到 Player 的
//  A2JITReadinessProbe 缝上。
//
//  为什么在 Bridge（而不是 Player）：依赖严格单向 App → UI → Player → Core →
//  Bridge → Natives（ADR-002）。★Bridge 是唯一与 Natives 相邻的层★，所以「跨到
//  Natives 去取判据」这件事只能发生在这里；Player 侧只见协议（A2JITReadinessProbe），
//  于是纯逻辑单测不会被 mach / 裸 brk / 信号安全网拖进来。
//
//  ★判据语义一字不改★：本类不新增加任何判定条件，`ensureJITUsableWithinBudget:reason:`
//  逐字转发同名方法，verdict / 取证直接读 A2JITEnvironment 的最近一次结果。
//  这层只做两件事：转发 + 枚举映射（A2JITRegionVerdict → A2JITReadinessVerdict）。
//
//  合规：零第三方；只用仓内 Natives/Support 的自研实现。
//

#import <Foundation/Foundation.h>
#import "A2JITReadinessProbe.h"

NS_ASSUME_NONNULL_BEGIN

/// JIT 判据的真实实现（转发 Natives/Support/A2JITEnvironment）。
@interface A2JITEnvironmentProbe : NSObject <A2JITReadinessProbe>
@end

NS_ASSUME_NONNULL_END

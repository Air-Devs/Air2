//
//  A2JITAutoPairingEngineBridge.h
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
//  Bridge —— 设备内自动配对（RPPairing）引擎的【接线点】。
//
//  为什么在 Bridge：依赖严格单向 App → UI → Player → Core → Bridge → Natives（ADR-002）。
//  ★Bridge 是唯一与 Natives 相邻的层★，所以「真发 Bonjour / 连 RSD / pair-verify / 建 TLS-PSK」
//  只能发生在 Bridge → Natives；Player 侧只认协议 A2JITAutoPairingEngine。
//
//  ★[JIT-AUTOPAIR-1] 本类当前是【骨架】★：真实现（RSD host + pair-verify + TLS-PSK 隧道）
//  属下一阶段（docs/JIT-PROVISIONING.md §4.2，估算 10–15 人日，需自研、不得抄 SideInstaller）。
//  骨架★必须如实报「未接入」★（isEngineAvailable=NO / readPreconditions 全 Unknown /
//  generate 返回 EngineUnavailable）—— 绝不假成功，也绝不把「没探测到」报成「已满足」。
//
//  下一阶段的落点（本单只定调用点与错误码，不实现）：
//    1. Natives/Support 新增 RPPairing 最小实现（BSD socket + Bonjour(NWBrowser) + pair-verify + PSK）；
//    2. 本类 readPreconditions 改为真读（Developer Mode / 本地网络 / get-task-allow / DDI）；
//    3. 本类 generatePairingFileWithinBudget:reason:blocker: 逐字转发到 Natives 实现，
//       并把写出的配对材料交给注入的 A2JITPairingFileStore 落盘（与 ②导入 同一约定位置）。
//
//  合规：零第三方；★不引入 / 不搬运 SideInstaller 代码★（自定义许可：非商业 + 禁止再分发）。
//

#import <Foundation/Foundation.h>
#import "A2JITAutoPairing.h"

NS_ASSUME_NONNULL_BEGIN

/// 自动配对引擎的 Bridge 骨架（RPPairing 真实现经 Bridge → Natives 落地）。
@interface A2JITAutoPairingEngineBridge : NSObject <A2JITAutoPairingEngine>
@end

NS_ASSUME_NONNULL_END

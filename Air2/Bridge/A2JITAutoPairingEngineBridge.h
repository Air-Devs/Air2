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
//  ★[JIT-AUTOPAIR-2] 本类的状态（比骨架进了一步，但仍如实，不假成功）★：
//    1. readPreconditions —— 已从「全 Unknown 骨架」改为【真读】：
//         · Developer Mode：sysctl(security.mac.amfi.developer_mode_status)，取不到 ⇒ Unknown；
//         · get-task-allow ：SecTaskCopyValueForEntitlement(self)，读不到 ⇒ Unknown；
//         · 本地网络权限   ：iOS 无公开查询 API ⇒ **如实 Unknown**（不猜）；
//         · DDI            ：交由 Provider 注入的 A2JITDDIProbe 真三态覆盖（此处 Unknown）。
//    2. isEngineAvailable / generate —— 真跑 Natives/Support 的 `a2_rppairing`【握手完成度自检】，
//       ★首个受阻步骤就如实点名★（本阶段 = Ed25519 签名原语未落地）。仍未接入 ⇒ 返回 NO。
//    3. RPPairing 的【线上编解码 + X25519/HKDF 内核】已落地（Natives/Support/a2_rppairing*），
//       由自检真实驱动；★pair-setup(SRP-3072)/pair-verify 消息机 + TLS-PSK 隧道 仍未落地★
//       —— 缺口与判据见 docs/JIT-PROVISIONING.md §4.2-a。
//
//  ★绝不假成功，也绝不把「没探测到」报成「已满足」★。
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

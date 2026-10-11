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
//  ★[JIT-AUTOPAIR-2] 本类的状态（真接线，仍如实，不假成功）★：
//    1. readPreconditions —— 真读：
//         · Developer Mode：sysctl(security.mac.amfi.developer_mode_status)，取不到 ⇒ Unknown；
//         · get-task-allow ：★iOS 无公开 API★（SecTask.h 只在 macOS SDK）⇒ **如实 Unknown**；
//         · 本地网络权限   ：iOS 无公开查询 API ⇒ **如实 Unknown**（不猜）；
//         · DDI            ：交由 Provider 注入的 A2JITDDIProbe 真三态覆盖（此处 Unknown）。
//    2. isEngineAvailable —— 本地握手链路（原语 + pair-verify 本体）全绿 ⇒ YES。
//    3. generatePairingFileWithinBudget: —— ★真跑★：
//         自检 → Bonjour 发现（`_remotepairing._tcp` / `_remoted._tcp`）→ 连接 → hostOptions
//         → pair-verify(M1..M4，真 X25519/Ed25519/ChaCha20-Poly1305/HKDF) → 新身份 → 写入注入的存储。
//       每一步失败都按语义分类：DiscoveryFailed / PairVerifyFailed / WriteFailed / EngineUnavailable，
//       ★并点名卡在哪一步★。没落盘就【不】返回成功。
//    4. ★仍未落地★：pair-setup(SRP-3072)（真正的「首次自配对」需要它）、
//       TLS-PSK 隧道（§12 要的两个套件不在公开 TLS API 的枚举里 —— 见 a2_rppairing_rsd.h 的实测证据）、
//       RemoteXPC 那条连接路径（§2a/2b）。缺口与判据见 docs/JIT-PROVISIONING.md §4.2-a。
//
//  ★绝不假成功，也绝不把「没探测到」报成「已满足」★。
//
//  合规：零第三方；★不引入 / 不搬运 SideInstaller 代码★（自定义许可：非商业 + 禁止再分发）。
//

#import <Foundation/Foundation.h>
#import "A2JITAutoPairing.h"

NS_ASSUME_NONNULL_BEGIN

/// 自动配对引擎的 Bridge（RPPairing 真实现经 Bridge → Natives 落地）。
@interface A2JITAutoPairingEngineBridge : NSObject <A2JITAutoPairingEngine>

/// ★配对材料的落盘目标★（容器约定位置；由装配处注入，见 A2JITSettings 的装配段）。
/// ★没注入 ⇒ 即使握手成功也【不】返回成功★（不假成功：没落盘就等于没有配对文件）。
@property (nonatomic, strong, nullable) A2JITPairingFileStore *pairingFileStore;

/// 设备侧 Ed25519 公钥（来自既有配对记录 / 设备证书）。
/// ★公开规格 §8 Step 6 明确写着设备那份证明「可不解」★ ⇒ 允许为 nil：
/// 此时握手仍会做完密钥交换与 AEAD 认证，但不做设备身份签名校验（会如实写进日志与原因）。
@property (nonatomic, copy, nullable) NSData *devicePublicKey;

/// 最近一次成功生成的配对文件字节（诊断 / 自证用；nil = 还没成功过）。
@property (nonatomic, readonly, copy, nullable) NSData *lastGeneratedPairingFile;

@end

NS_ASSUME_NONNULL_END

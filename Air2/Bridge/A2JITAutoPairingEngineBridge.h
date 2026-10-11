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
//    4. [JIT-AUTOPAIR-3] pair-setup（SRP-3072，真正的「首次自配对」）★消息机已落地★
//       （Natives/Support/a2_rppairing_pairsetup.[hm]，PS-Msg01..06）：
//         · 自检阶段真跑一次进程内自握手自证（A2RPPairingPreflight.pairSetupOK/summary）；
//         · generate 里：★注入 pairSetupTransport 时★先跑 pair-setup（设备不认识本机时的唯一路径），
//           成功即落盘并返回；未注入 ⇒ ★如实点名「缺 pair-setup 传输」并回落 pair-verify★（不谎报）。
//         · ★传输仍缺★：真机上 pair-setup 走 §2a/§2b RemoteXPC，本仓只接了 §2c 裸 socket（规格明确它
//           **不支持 pair-setup**）⇒ 生产上 pairSetupTransport 为 nil，该步在真机上仍不能真正首配。
//    5. ★仍未落地★：TLS-PSK 隧道（§12 要的两个套件不在公开 TLS API 的枚举里 —— 见 a2_rppairing_rsd.h 的实测证据）、
//       RemoteXPC 那条连接路径（§2a/2b）。缺口与判据见 docs/JIT-PROVISIONING.md §4.2-a。
//
//  ★绝不假成功，也绝不把「没探测到」报成「已满足」★。
//
//  合规：零第三方；★不引入 / 不搬运 SideInstaller 代码★（自定义许可：非商业 + 禁止再分发）。
//

#import <Foundation/Foundation.h>
#import "A2JITAutoPairing.h"
#import "a2_rppairing_pairsetup.h"   // [JIT-AUTOPAIR-3] Bridge 唯一相邻 Natives 层 ⇒ 直接引用其传输缝/配对码缝

NS_ASSUME_NONNULL_BEGIN

@class A2JITPairingFileStore;   // ★只前向声明★：头文件不引入 Player 的实现头（.m 里才 import）

#pragma mark - [JIT-AUTOPAIR-4] 设备发起档（iOS 27）的阶段

/// 「设备发起档」的可观测阶段（设置页的状态文字直接由它上来；★四语文案在 UI 侧★）。
typedef NS_ENUM(NSInteger, A2JITDeviceInitiatedPairingStage) {
    A2JITDeviceInitiatedPairingStageIdle        = 0,  ///< 未开始
    A2JITDeviceInitiatedPairingStagePreparing   = 1,  ///< 生成本轮主机身份 / 码
    A2JITDeviceInitiatedPairingStageAdvertising = 2,  ///< 已起广告，★等设备连入★（用户此刻去系统设置）
    A2JITDeviceInitiatedPairingStageConnected   = 3,  ///< ★设备已连入★
    A2JITDeviceInitiatedPairingStageVerifying   = 4,  ///< 正在验码（PS-Msg01..06）
    A2JITDeviceInitiatedPairingStageSucceeded   = 5,  ///< 配对成功（配对文件已落盘）
    A2JITDeviceInitiatedPairingStageFailed      = 6,  ///< 失败（原因在 detail）
    A2JITDeviceInitiatedPairingStageCancelled   = 7,  ///< 已取消
};
/// 阶段稳定英文名（日志可搜）。
NSString *A2JITDeviceInitiatedPairingStageName(A2JITDeviceInitiatedPairingStage stage);

/// 自动配对引擎的 Bridge（RPPairing 真实现经 Bridge → Natives 落地）。
@interface A2JITAutoPairingEngineBridge : NSObject <A2JITAutoPairingEngine>

/// ★配对材料的落盘目标★（容器约定位置；由装配处注入，见 A2JITSettings 的装配段）。
/// ★没注入 ⇒ 即使握手成功也【不】返回成功★（不假成功：没落盘就等于没有配对文件）。
@property (nonatomic, strong, nullable) A2JITPairingFileStore *pairingFileStore;

/// 设备侧 Ed25519 公钥（来自既有配对记录 / 设备证书）。
/// ★公开规格 §8 Step 6 明确写着设备那份证明「可不解」★ ⇒ 允许为 nil：
/// 此时握手仍会做完密钥交换与 AEAD 认证，但不做设备身份签名校验（会如实写进日志与原因）。
@property (nonatomic, copy, nullable) NSData *devicePublicKey;

/// [JIT-AUTOPAIR-3] pair-setup（SRP-3072）的【消息传输】。
/// ★真机上必须走 §2a/§2b 的 RemoteXPC（§2c 裸 socket 按规格不支持 pair-setup）★ ——
/// 本仓尚未实现 RemoteXPC 传输 ⇒ 生产上此属性为 nil，generate 会如实点名「缺 pair-setup 传输」并回落 pair-verify。
/// 单测 / 自证里注入进程内传输即可把「首次配对」这条链真正跑通（谁调它：generatePairingFileWithinBudget:）。
@property (nonatomic, strong, nullable) id<A2RPPairSetupMessageTransport> pairSetupTransport;

/// [JIT-AUTOPAIR-3] 配对码来源（★可注入★；未注入 / 返回空 ⇒ pair-setup 如实拒绝，不猜不默认）。
@property (nonatomic, copy, nullable) A2RPPairSetupPinProvider pairSetupPinProvider;

/// 最近一次成功生成的配对文件字节（诊断 / 自证用；nil = 还没成功过）。
@property (nonatomic, readonly, copy, nullable) NSData *lastGeneratedPairingFile;

#pragma mark - [JIT-AUTOPAIR-4] 设备发起档（iOS 27）★唯一驱动入口★

/// 是否正在跑一轮「设备发起配对」。
@property (nonatomic, readonly) BOOL deviceInitiatedPairingRunning;

/// ★[JIT-AUTOPAIR-4] 设备发起档的★唯一驱动入口★★（谁调它：设置页的「开始配对」按钮那一条链）。
///
/// 做什么（按顺序，全部在这一处）：
///   ② 起 `_remotepairing-pairable-host._tcp` 广告并等系统连入（Natives: A2RPPairableHostAdvertiser）；
///   ③ 用被接受的字节通道建 pair-setup 消息传输（RemoteXPC，originatedBy=device）；
///   ④ 用★device/accessory 侧★会话驱动 PS-Msg01..06（★先收后发★）；
///   ⑤ 成功后把配对文件写进注入的 `pairingFileStore`（沿用既有落盘）；
///   ⑥ 失败按类分流（failureNameOut 给出稳定的失败类名；原因串在 reason）。
///
/// ①（生成 6 位码并交给已有 UI/持久化）★不在这里★：它由既有的 `A2JITPairingCodeSession`（Player 层）
/// 承担，调用方把**正在显示的码**经 displayedCode 传进来 —— Bridge 不得反向依赖 Player（ADR-002）。
///
/// ★阻塞★：整段是同步的（广告等待最长 budget 秒）⇒ 调用方必须在后台队列调用，
/// 并在 stageHandler 里回主线程刷新 UI。
/// @param displayedCode 本机正在显示的 6 位码（★空 ⇒ 立即失败，不猜不默认★）。
/// @param stageHandler  阶段回调（可在任意线程被调用；实现方自行回主线程）。可为 nil。
/// @return 成功（配对文件已落盘）YES；否则 NO 并回填 reason / failureNameOut。
- (BOOL)startDeviceInitiatedPairingWithHostName:(NSString *)hostName
                                  displayedCode:(NSString *)displayedCode
                                         budget:(NSTimeInterval)budget
                                   stageHandler:(nullable void (^)(A2JITDeviceInitiatedPairingStage stage,
                                                                   NSString *detail))stageHandler
                                         reason:(NSString *_Nullable *_Nullable)whyOut
                                    failureName:(NSString *_Nullable *_Nullable)failureNameOut;

/// 请求取消正在跑的那一轮（★协作式★：置标志；当前阻塞的广告等待会在其预算内返回后停下 —— 
/// 不声称能瞬间中断系统调用，也不跨线程去拆正在等待的 listener，那会踩 use-after-stop）。
- (void)cancelDeviceInitiatedPairing;

@end

NS_ASSUME_NONNULL_END

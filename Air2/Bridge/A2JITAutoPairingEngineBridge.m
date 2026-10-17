//
//  A2JITAutoPairingEngineBridge.m
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
//  [JIT-AUTOPAIR-2/3] Bridge 真接线：前置条件真读 + RPPairing 握手完成度真自检。
//  握手消息机：★pair-verify 与 pair-setup(SRP-3072) 均已落地★（Natives/Support）；
//  TLS-PSK 隧道仍未打通（见 a2_rppairing_rsd.h 的实测证据）⇒ 不谎报，未就绪项一律点名。
//

#import "A2JITAutoPairingEngineBridge.h"
#import "a2_rppairing.h"          // [JIT-AUTOPAIR-2] Natives/Support：RPPairing 握手内核 / 完成度自检
#import "a2_rppairing_verify.h"   // [JIT-AUTOPAIR-2] pair-verify 握手本体（消息流 + 密钥交换）
#import "a2_rppairing_rsd.h"      // [JIT-AUTOPAIR-2] Bonjour 发现 / 连接 / JSON 帧 / TLS-PSK 口径
#import "a2_tlspsk_tunnel.h"      // [A2-INTEGRATION] TLS-PSK 隧道门面（可替换后端 / 默认关）
#import "a2_tlspsk_mbedtls.h"     // [A2-INTEGRATION] mbedTLS 后端注册入口（第三方，Apache-2.0）
// ★[A2-RXPC] 本单新增：传输层判据行（只加一行调用点，见下；不改既有逻辑）★
#import "a2_rppairing_pairable_host.h"
#import "a2_local_network_probe.h"   // [PAIRWIRE-NETPROBE] 本地网络权限自检
// ★[JIT-AUTOPAIR-4] 设备发起档（iOS 27）的★唯一驱动函数★：广告 → 连入 → 建传输 → accessory 侧 PS-Msg01..06
#import "a2_rppairing_pairsetup_accessory.h"
#import "A2JITPairingFileStore.h" // ★配对材料的落盘目标★（同层已有的类，见 docs/ARCHITECTURE.md）
#import "A2Log.h"                 // [A2Log criterion:]：判据行的统一出口（控制台 + 会话日志文件）

#import <sys/sysctl.h>

// ★构建阻塞修复（非本线代码，仅补类型/原型声明，行为不变）★
//   iPhoneOS SDK 里【没有】SecTask.h（SecTask 是 macOS 公开、iOS 未导出头），
//   但 Security.framework 的 Security.tbd 里确实有 SecTaskCreateFromSelf /
//   SecTaskCopyValueForEntitlement 的导出符号（可链接）⇒ 按 macOS SecTask.h 的签名
//   自行声明，使本文件在 `-sdk iphoneos` 下也能编过。
//   行为不变：函数取不到值/报错时，下面的代码仍按本文件契约回 Unknown（绝不猜）。
#if __has_include(<Security/SecTask.h>)
#import <Security/SecTask.h>
#else
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement,
                                                CFErrorRef *error);
#endif

#pragma mark - 前置条件真读（取不到一律 Unknown，绝不猜）

/// Developer Mode：sysctl `security.mac.amfi.developer_mode_status`（非 0 = 已开）。
/// ★取不到（键不存在 / 被沙盒拒）一律 Unknown★ —— 不把「没探测到」报成「已满足」或「未满足」。
static A2JITAutoPairingPreconditionState A2RPReadDeveloperModeState(void) {
    int enabled = 0;
    size_t size = sizeof(enabled);
    if (sysctlbyname("security.mac.amfi.developer_mode_status", &enabled, &size, NULL, 0) != 0) {
        return A2JITAutoPairingPreconditionStateUnknown;
    }
    return enabled != 0 ? A2JITAutoPairingPreconditionStateSatisfied
                        : A2JITAutoPairingPreconditionStateUnsatisfied;
}

/// get-task-allow：★iOS 无公开 API★ —— `SecTask.h`（`SecTaskCreateFromSelf` /
/// `SecTaskCopyValueForEntitlement`）**只在 macOS SDK 提供**，iOS 侧属私有符号。
/// 为「读一项前置条件」而再引入一个私有 API 不划算 ⇒ ★如实回 Unknown★（不猜、不谎报满足）。
static A2JITAutoPairingPreconditionState A2RPReadGetTaskAllowState(void) {
    return A2JITAutoPairingPreconditionStateUnknown;
}

static NSString *A2RPStateName(A2JITAutoPairingPreconditionState state) {
    switch (state) {
        case A2JITAutoPairingPreconditionStateSatisfied:   return @"满足";
        case A2JITAutoPairingPreconditionStateUnsatisfied: return @"未满足";
        case A2JITAutoPairingPreconditionStateUnknown:
        default:                                           return @"未知";
    }
}

/// [JIT-AUTOPAIR-4] 设备发起档的阶段稳定名（日志可搜；★四语文案在 UI 侧★）。
NSString *A2JITDeviceInitiatedPairingStageName(A2JITDeviceInitiatedPairingStage stage) {
    switch (stage) {
        case A2JITDeviceInitiatedPairingStageIdle:        return @"idle";
        case A2JITDeviceInitiatedPairingStagePreparing:   return @"preparing";
        case A2JITDeviceInitiatedPairingStageAdvertising: return @"advertising";
        case A2JITDeviceInitiatedPairingStageConnected:   return @"connected";
        case A2JITDeviceInitiatedPairingStageVerifying:   return @"verifying";
        case A2JITDeviceInitiatedPairingStageSucceeded:   return @"succeeded";
        case A2JITDeviceInitiatedPairingStageFailed:      return @"failed";
        case A2JITDeviceInitiatedPairingStageCancelled:   return @"cancelled";
    }
    return @"unknown";
}

@interface A2JITAutoPairingEngineBridge ()
/// 惰性缓存（自检只跑一次；读取无副作用）。
@property (nonatomic, strong, nullable) A2RPPairingPreflight *preflight;
@property (nonatomic, strong, nullable) A2JITAutoPairingPreconditions *cachedPreconditions;
@property (nonatomic, readwrite, copy, nullable) NSData *lastGeneratedPairingFile;
/// [JIT-AUTOPAIR-4] 设备发起档：运行标志 + 协作式取消标志（★原子★：取消可能从主线程置位）。
@property (nonatomic, readwrite) BOOL deviceInitiatedPairingRunning;
@property (atomic) BOOL deviceInitiatedCancelled;
@end

@implementation A2JITAutoPairingEngineBridge

#pragma mark - 能力

- (A2RPPairingPreflight *)preflightResult {
    if (self.preflight == nil) {
        self.preflight = [A2RPPairingPreflight run];
        NSLog(@"[A2JIT] autopair engine: %@", self.preflight.summary);
        NSLog(@"[A2JIT] autopair engine: pair-verify 自握手自证 ⇒ %@", self.preflight.pairVerifySummary);
        NSLog(@"[A2JIT] autopair engine: pair-setup 自握手自证 ⇒ %@", self.preflight.pairSetupSummary);
    }
    return self.preflight;
}

- (BOOL)isEngineAvailable {
    // ★本地握手链路（原语 + pair-verify + pair-setup 本体）全绿 ⇒ 引擎【已接入】★；
    // 剩下的卡点是「真 RSD 端点」（Bonjour 发现/连接），那属于运行时环境，不是「未接入」——
    // 所以本方法如实回 YES，由 generate 按步骤点名 DiscoveryFailed / PairVerifyFailed 等。
    return self.preflightResult.firstBlockedStep == A2RPPairingBlockedStepRsdEndpoint
        || self.preflightResult.firstBlockedStep == A2RPPairingBlockedStepNone;
}

- (A2JITAutoPairingPreconditions *)readPreconditions {
    if (self.cachedPreconditions != nil) {
        return self.cachedPreconditions;
    }
    // ★以「全 Unknown」为底★（没探测到 ≠ 已满足），再逐项覆盖真读到的结果。
    A2JITAutoPairingPreconditions *base = [A2JITAutoPairingPreconditions unknownPreconditions];
    A2JITAutoPairingPreconditionState devMode   = A2RPReadDeveloperModeState();
    A2JITAutoPairingPreconditionState taskAllow = A2RPReadGetTaskAllowState();
    // 本地网络权限：iOS 不提供公开查询 API ⇒ 如实 Unknown（不猜；见 §4.2-b「行为式判据」建议）。
    // DDI：这里的答案不做数 —— Provider 会用注入的 A2JITDDIProbe 真三态覆盖（effectivePreconditions）。
    A2JITAutoPairingPreconditionState localNet =
        [base stateForPrecondition:A2JITAutoPairingPreconditionLocalNetwork];
    A2JITAutoPairingPreconditionState ddi =
        [base stateForPrecondition:A2JITAutoPairingPreconditionDDI];

    self.cachedPreconditions =
        [A2JITAutoPairingPreconditions preconditionsWithDeveloperMode:devMode
                                                         localNetwork:localNet
                                                         getTaskAllow:taskAllow
                                                                  ddi:ddi];
    NSLog(@"[A2JIT] autopair engine: 前置条件真读 ⇒ DeveloperMode=%@ "
          @"get-task-allow=未知（iOS 无公开 API） LocalNetwork=未知（iOS 无公开 API） "
          @"DDI=未知（由 ddiProbe 覆盖）",
          A2RPStateName(devMode));
    return self.cachedPreconditions;
}

#pragma mark - 生成（★真跑；每一步失败都按语义分类，绝不假成功★）

- (BOOL)generatePairingFileWithinBudget:(NSTimeInterval)budget
                                 reason:(NSString *_Nullable *_Nullable)whyOut
                                blocker:(A2JITAutoPairingBlocker *_Nullable)blockerOut {
    A2RPPairingPreflight *pf = [self preflightResult];
    NSLog(@"[A2JIT] autopair engine: 尝试生成 ⇒ 自检 %@（budget=%.1fs）", pf.summary, budget);
    NSLog(@"[A2JIT] autopair engine: pair-verify 自握手自证 ⇒ %@", pf.pairVerifySummary);

    // ---- ① 本地握手链路是否就绪（原语 + pair-verify 本体）----
    if (pf.firstBlockedStep != A2RPPairingBlockedStepNone
        && pf.firstBlockedStep != A2RPPairingBlockedStepRsdEndpoint) {
        NSString *blockedName = [A2RPPairingPreflight displayNameForBlockedStep:pf.firstBlockedStep];
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:
                       @"RPPairing 本地握手链路在第【%@】步受阻；%@（自检：%@）",
                       blockedName, A2RPHandshakeCryptoUnavailableReason(), pf.summary];
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerEngineUnavailable;
        }
        return NO;
    }

    // ---- ② TLS-PSK 隧道的【如实口径】（只记录；产配对文件不需要隧道，隧道另有去向）----
    NSString *pskWhy = nil;
    BOOL pskOK = A2RPRSDPublicTLSPSKPathSufficient(&pskWhy);
    NSLog(@"[A2JIT] autopair engine: TLS-PSK(§12) 公开路径可用=%@ ⇒ %@",
          pskOK ? @"是" : @"否", pskWhy);

    // ---- ②b [A2-INTEGRATION] TLS-PSK 隧道：★真后端★如实口径 ----
    //  本单接入：可替换门面（a2_tlspsk_tunnel）+ mbedTLS（Apache-2.0）后端（a2_tlspsk_mbedtls）。
    //  ★默认关★：即便后端就绪，隧道也不会自动启用（enabled 默认 NO）。
    //  谁调它：此处（生产诊断路径）——注册入口与门面见 Natives/Support/a2_tlspsk_{mbedtls,tunnel}.[hm]。
    A2TLSPskMbedTLSEnsureRegistered();
    NSLog(@"[A2JIT] autopair engine: TLS-PSK 隧道（可替换后端）%@",
          [A2TLSPskTunnel statusLine]);

    // ---- ②c [A2-RXPC] 传输层就绪度 + 有界自证（★只加不改：无网络动作、无副作用、不做等待★）----
    //  谁调它：A2RXPCReportLayerReadiness（Natives/Support/a2_rppairing_pairable_host.m）——
    //  输出判据行 [RXPC]：§2a/§2b/§2c/pairable-host 盘点 + 帧/HPACK/XPC/authTag 的有界自证。
    A2RXPCReportLayerReadiness();

    // ---- ③ 发现（Bonjour）----
    NSArray<NSString *> *types = A2RPRSDDefaultServiceTypes();
    NSTimeInterval discoverBudget = MAX(1.0, budget * 0.6);
    A2RPRSDDiscovery *discovery = [[A2RPRSDDiscovery alloc] initWithServiceTypes:types];
    NSString *discWhy = nil;
    id endpoint = [discovery waitForEndpointWithTimeout:discoverBudget reason:&discWhy];
    NSLog(@"[A2JIT] autopair engine: Bonjour 发现（%@，≤%.1fs）⇒ %@",
          [types componentsJoinedByString:@","], discoverBudget,
          endpoint ? [A2RPRSDDiscovery describeEndpoint:endpoint] : discWhy);
    if (endpoint == nil) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"RPPairing 本地握手已就绪（%@），但%@",
                       pf.pairVerifySummary, discWhy ?: @"未发现设备端点"];
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerDiscoveryFailed;
        }
        return NO;
    }

    // ---- ④ 连上 + hostOptions + pair-verify（真跑消息流 M1..M4）----
    NSError *idErr = nil;
    NSString *hostName = NSProcessInfo.processInfo.hostName ?: @"air2-rppairing";
    // ★规格 §7：identifier = uuid_v3(NAMESPACE_DNS, hostname)★
    A2RPPairingIdentity *localIdentity =
        [A2RPPairingIdentity identityWithHostName:hostName error:&idErr];
    if (localIdentity == nil) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"本地身份生成失败：%@",
                       idErr.localizedDescription ?: @"未知"];
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerPairVerifyFailed;
        }
        return NO;
    }

    // ---- ④a [JIT-AUTOPAIR-3] pair-setup（首次配对；设备不认识本机时的唯一路径）----
    //  ★谁调它★：就在这里 —— 且只有注入了能承载 pair-setup 的消息传输时才走（真机上是 §2a/§2b RemoteXPC）。
    //  未注入 ⇒ 如实点名并回落 pair-verify（不谎报：本仓只接了 §2c 裸 socket，而规格明确它不支持 pair-setup）。
    if (self.pairSetupTransport != nil) {
        NSData *psKey = nil;
        NSString *psWhy = nil;
        BOOL psOK = [A2RPPairSetupSession runHostOverTransport:self.pairSetupTransport
                                                      identity:localIdentity
                                                   pinProvider:self.pairSetupPinProvider
                                                        reason:&psWhy
                                                    sessionKey:&psKey];
        NSLog(@"[A2JIT] autopair engine: pair-setup ⇒ %@（%@；会话密钥 %lu 字节）",
              psOK ? @"完成" : @"失败", psWhy ?: @"-", (unsigned long)psKey.length);
        if (psOK) {
            NSData *psFile = [localIdentity pairingFileData];
            if (psFile.length == 0) {
                if (whyOut) { *whyOut = @"pair-setup 成功但产不出配对文件字节"; }
                if (blockerOut) { *blockerOut = A2JITAutoPairingBlockerWriteFailed; }
                return NO;
            }
            if (self.pairingFileStore == nil) {
                if (whyOut) { *whyOut = @"pair-setup 成功，但未注入配对文件存储 ⇒ 不落盘、不报成功"; }
                if (blockerOut) { *blockerOut = A2JITAutoPairingBlockerWriteFailed; }
                return NO;
            }
            NSError *psErr = nil;
            NSString *psWritten = [self.pairingFileStore importData:psFile
                                                         sourceName:@"RPPairing(pair-setup 首次配对)"
                                                              error:&psErr];
            if (psWritten.length == 0) {
                if (whyOut) {
                    *whyOut = [NSString stringWithFormat:@"pair-setup 配对文件落盘失败：%@",
                               psErr.localizedDescription ?: @"未知"];
                }
                if (blockerOut) { *blockerOut = A2JITAutoPairingBlockerWriteFailed; }
                return NO;
            }
            self.lastGeneratedPairingFile = psFile;
            NSLog(@"[A2JIT] autopair engine: ★pair-setup 成功★ ⇒ 配对文件已落盘 path=%@ (%lu 字节) "
                  @"identifier=%@", psWritten, (unsigned long)psFile.length, localIdentity.identifier);
            if (blockerOut) { *blockerOut = A2JITAutoPairingBlockerNone; }
            if (whyOut) {
                *whyOut = [NSString stringWithFormat:@"pair-setup 成功（%@）；配对文件已写入 %@",
                           self.preflightResult.pairSetupSummary, psWritten];
            }
            return YES;
        }
        // pair-setup 未完成：记下原因，继续试 pair-verify（设备也许其实认识本机）。
        NSLog(@"[A2JIT] autopair engine: pair-setup 未完成 ⇒ 回落 pair-verify（%@）", psWhy ?: @"-");
    } else {
        NSLog(@"[A2JIT] autopair engine: ★pair-setup 传输未注入★ ⇒ 跳过首次配对"
              @"（真机需 §2a/§2b RemoteXPC 传输；§2c 裸 socket 不支持 pair-setup，本仓未实现）");
    }

    if (self.devicePublicKey == nil) {
        NSLog(@"[A2JIT] autopair engine: ★未持有设备 Ed25519 公钥 ⇒ 按规格 §8 Step 6「设备证明可不解」"
              @"跳过身份签名校验★（AEAD 认证与密钥交换仍照做）");
    }

    NSString *pvWhy = nil;
    NSTimeInterval pvBudget = MAX(1.0, budget - discoverBudget);
    A2RPPairingIdentity *freshIdentity =
        [A2RPRSDPairVerifyClient pairVerifyWithEndpoint:endpoint
                                          localIdentity:localIdentity
                                        devicePublicKey:self.devicePublicKey
                                                timeout:pvBudget
                                                 reason:&pvWhy];
    if (freshIdentity == nil) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"已发现 %@，但 pair-verify 未完成：%@",
                       [A2RPRSDDiscovery describeEndpoint:endpoint], pvWhy ?: @"原因未记录"];
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerPairVerifyFailed;
        }
        return NO;
    }

    // ---- ⑤ 落盘（写不进注入的存储 ⇒ 不算成功）----
    NSData *fileData = [freshIdentity pairingFileData];
    if (fileData.length == 0) {
        if (whyOut) {
            *whyOut = @"握手成功但产不出配对文件字节";
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerWriteFailed;
        }
        return NO;
    }
    if (self.pairingFileStore == nil) {
        // ★没注入存储就不落盘 ⇒ 不返回成功★（不假成功：没落盘 = 没有配对文件）
        if (whyOut) {
            *whyOut = @"握手成功，但未注入配对文件存储（pairingFileStore=nil）⇒ 不落盘、不报成功";
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerWriteFailed;
        }
        return NO;
    }
    NSError *impErr = nil;
    NSString *written = [self.pairingFileStore importData:fileData
                                               sourceName:@"RPPairing(设备内自配对)"
                                                    error:&impErr];
    if (written.length == 0) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"配对文件落盘失败：%@",
                       impErr.localizedDescription ?: @"未知"];
        }
        if (blockerOut) {
            *blockerOut = A2JITAutoPairingBlockerWriteFailed;
        }
        return NO;
    }

    self.lastGeneratedPairingFile = fileData;
    NSLog(@"[A2JIT] autopair engine: ★pair-verify 成功★ ⇒ 配对文件已落盘 path=%@ (%lu 字节) "
          @"identifier=%@", written, (unsigned long)fileData.length, freshIdentity.identifier);
    if (blockerOut) {
        *blockerOut = A2JITAutoPairingBlockerNone;
    }
    if (whyOut) {
        *whyOut = [NSString stringWithFormat:@"pair-verify 成功（%@）；配对文件已写入 %@",
                   pf.pairVerifySummary, written];
    }
    return YES;
}

#pragma mark - [JIT-AUTOPAIR-4] 设备发起档（iOS 27）：★唯一驱动入口★

- (void)cancelDeviceInitiatedPairing {
    self.deviceInitiatedCancelled = YES;
    NSLog(@"[A2JIT] 设备发起档：已请求取消（★协作式★；当前阻塞的等待会在其预算内返回后才停下）");
}

- (BOOL)startDeviceInitiatedPairingWithHostName:(NSString *)hostName
                                  displayedCode:(NSString *)displayedCode
                                         budget:(NSTimeInterval)budget
                                   stageHandler:(void (^)(A2JITDeviceInitiatedPairingStage, NSString *))stageHandler
                                         reason:(NSString *_Nullable *_Nullable)whyOut
                                    failureName:(NSString *_Nullable *_Nullable)failureNameOut {
    if (failureNameOut) { *failureNameOut = nil; }

    // ---- ① 前置校验：码必须是本机【正在显示】的 6 位码（★不猜、不默认★）----
    //  ①「生成 6 位码并交给已有 UI/持久化」由既有的 A2JITPairingCodeSession（Player 层）在做 ——
    //  Bridge 不得反向依赖 Player（ADR-002），所以这里消费它显示出来的那一个码。
    if (hostName.length == 0) {
        if (whyOut) { *whyOut = @"主机名为空 ⇒ 设备在系统设置列表里认不出本机，拒绝开始"; }
        if (failureNameOut) {
            *failureNameOut = A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailurePublishFailed);
        }
        return NO;
    }
    NSString *code = displayedCode ?: @"";
    BOOL sixDigits = (code.length == 6);
    for (NSUInteger i = 0; sixDigits && i < code.length; i++) {
        unichar c = [code characterAtIndex:i];
        if (c < '0' || c > '9') { sixDigits = NO; }
    }
    if (!sixDigits) {
        if (whyOut) {
            *whyOut = @"本机尚未显示 6 位码 ⇒ 先在「配对码来源」里选设备发起档，让码显示出来";
        }
        if (failureNameOut) {
            *failureNameOut = A2RPPairSetupAccessoryFailureName(A2RPPairSetupAccessoryFailurePinMissing);
        }
        return NO;
    }
    if (self.deviceInitiatedPairingRunning) {
        if (whyOut) { *whyOut = @"已有一轮设备发起配对在跑 ⇒ 先取消或等它结束"; }
        if (failureNameOut) { *failureNameOut = @"AlreadyRunning"; }
        return NO;
    }

    // ---- ★[PAIRWIRE-NETPROBE] 先确认「本地网络」权限已给✗★ ----
    //   iOS 没有公开 API 查这个权限；不给的话广告只会以 PublishFailed 失败、用户看到笼统报错。
    //   这里先跑一次自检（自建 Bonjour 探针），给可判据的结论与可读的失败原因。
    {
        NSString *probeWhy = nil;
        BOOL probeOK = A2LocalNetworkProbeRun(5.0, &probeWhy);
        [A2Log criterion:@"%@", A2LocalNetworkProbeCriterionLine(probeOK ? @"ok" : @"denied", probeWhy)];
        if (!probeOK) {
            if (whyOut) {
                *whyOut = [NSString stringWithFormat:
                           @"本地网络权限未授予（或环境异常）⇒ 配对无法开始：%@",
                           probeWhy ?: @"-"];
            }
            if (failureNameOut) { *failureNameOut = @"NoLocalNetworkPermission"; }
            return NO;
        }
    }

    self.deviceInitiatedCancelled = NO;
    self.deviceInitiatedPairingRunning = YES;

    A2JITDeviceInitiatedPairingStage (^stageForPhase)(A2RPPairSetupAccessoryPhase) =
        ^A2JITDeviceInitiatedPairingStage(A2RPPairSetupAccessoryPhase p) {
        switch (p) {
            case A2RPPairSetupAccessoryPhaseStarting:    return A2JITDeviceInitiatedPairingStagePreparing;
            case A2RPPairSetupAccessoryPhaseAdvertising: return A2JITDeviceInitiatedPairingStageAdvertising;
            case A2RPPairSetupAccessoryPhaseConnected:   return A2JITDeviceInitiatedPairingStageConnected;
            case A2RPPairSetupAccessoryPhaseVerifying:   return A2JITDeviceInitiatedPairingStageVerifying;
            case A2RPPairSetupAccessoryPhaseSucceeded:   return A2JITDeviceInitiatedPairingStageSucceeded;
            case A2RPPairSetupAccessoryPhaseFailed:      return A2JITDeviceInitiatedPairingStageFailed;
            case A2RPPairSetupAccessoryPhaseCancelled:   return A2JITDeviceInitiatedPairingStageCancelled;
        }
        return A2JITDeviceInitiatedPairingStageIdle;
    };

    NSLog(@"[A2JIT] 设备发起档：开始（主机名=%@ 码长=%lu 位 budget=%.1fs）",
          hostName, (unsigned long)code.length, budget);

    // ---- ②③④⑤⑥ 全在 Natives 的★唯一驱动函数★里（本处是它唯一的生产调用点）----
    A2RPPairSetupAccessoryRun *run =
        [A2RPPairSetupAccessory runWithHostName:hostName
                                            pin:code
                                         budget:budget
                                       observer:^(A2RPPairSetupAccessoryPhase phase,
                                                  A2RPPairSetupStep step, NSString *line) {
        (void)step;
        if (stageHandler) { stageHandler(stageForPhase(phase), line ?: @""); }
    }
                                    isCancelled:^BOOL { return self.deviceInitiatedCancelled; }];

    self.deviceInitiatedPairingRunning = NO;

    if (!run.succeeded) {
        if (failureNameOut) { *failureNameOut = A2RPPairSetupAccessoryFailureName(run.failure); }
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"设备发起配对未成（class=%@）：%@",
                       A2RPPairSetupAccessoryFailureName(run.failure), run.detail ?: @"原因未记录"];
        }
        NSLog(@"[A2JIT] 设备发起档：失败 class=%@ detail=%@",
              A2RPPairSetupAccessoryFailureName(run.failure), run.detail ?: @"-");
        return NO;
    }

    // ---- ⑤ 落盘（★沿用既有 store★；没注入 store 就不返回成功 —— 不假成功）----
    if (self.pairingFileStore == nil) {
        if (whyOut) { *whyOut = @"配对成功，但未注入配对文件存储（pairingFileStore=nil）⇒ 不落盘、不报成功"; }
        if (failureNameOut) { *failureNameOut = @"WriteFailed"; }
        return NO;
    }
    NSError *importErr = nil;
    NSString *written = [self.pairingFileStore importData:run.pairingFileData
                                               sourceName:@"RPPairing(设备发起配对，accessory 侧 pair-setup)"
                                                    error:&importErr];
    if (written.length == 0) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"配对文件落盘失败：%@",
                       importErr.localizedDescription ?: @"未知"];
        }
        if (failureNameOut) { *failureNameOut = @"WriteFailed"; }
        return NO;
    }
    self.lastGeneratedPairingFile = run.pairingFileData;
    NSLog(@"[A2JIT] 设备发起档：★成功★ 配对文件已落盘 path=%@（%lu 字节）identifier=%@",
          written, (unsigned long)run.pairingFileData.length, run.identifier ?: @"-");
    if (whyOut) {
        *whyOut = [NSString stringWithFormat:@"设备发起配对成功；配对文件已写入 %@", written];
    }
    if (failureNameOut) { *failureNameOut = nil; }
    return YES;
}

@end

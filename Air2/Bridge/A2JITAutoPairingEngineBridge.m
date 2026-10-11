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
//  [JIT-AUTOPAIR-2] Bridge 真接线：前置条件真读 + RPPairing 握手完成度真自检。
//  ★仍如实★：握手消息机（pair-setup SRP-3072 / pair-verify）与 TLS-PSK 隧道未落地 ⇒
//  isEngineAvailable 返回 NO，generate 返回 EngineUnavailable 并【点名受阻步骤】—— 绝不假成功。
//

#import "A2JITAutoPairingEngineBridge.h"
#import "a2_rppairing.h"          // [JIT-AUTOPAIR-2] Natives/Support：RPPairing 握手内核 / 完成度自检

#import <Security/Security.h>
#import <sys/sysctl.h>

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

/// get-task-allow：读【本进程自己的】entitlement（SecTask）。
/// ★只有确实读到了值才给 Satisfied/Unsatisfied；读取本身报错 ⇒ Unknown★。
static A2JITAutoPairingPreconditionState A2RPReadGetTaskAllowState(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (task == NULL) {
        return A2JITAutoPairingPreconditionStateUnknown;
    }
    CFErrorRef err = NULL;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), &err);
    CFRelease(task);

    A2JITAutoPairingPreconditionState state;
    if (value != NULL && CFGetTypeID(value) == CFBooleanGetTypeID()) {
        state = CFBooleanGetValue((CFBooleanRef)value)
                    ? A2JITAutoPairingPreconditionStateSatisfied
                    : A2JITAutoPairingPreconditionStateUnsatisfied;
    } else if (value == NULL && err == NULL) {
        // 读取没报错、但没有该 entitlement ⇒ 明确未满足。
        state = A2JITAutoPairingPreconditionStateUnsatisfied;
    } else {
        // 读取失败 ⇒ ★Unknown★（不猜）。
        state = A2JITAutoPairingPreconditionStateUnknown;
    }
    if (value != NULL) {
        CFRelease(value);
    }
    if (err != NULL) {
        CFRelease(err);
    }
    return state;
}

static NSString *A2RPStateName(A2JITAutoPairingPreconditionState state) {
    switch (state) {
        case A2JITAutoPairingPreconditionStateSatisfied:   return @"满足";
        case A2JITAutoPairingPreconditionStateUnsatisfied: return @"未满足";
        case A2JITAutoPairingPreconditionStateUnknown:
        default:                                           return @"未知";
    }
}

@interface A2JITAutoPairingEngineBridge ()
/// 惰性缓存（自检只跑一次；读取无副作用）。
@property (nonatomic, strong, nullable) A2RPPairingPreflight *preflight;
@property (nonatomic, strong, nullable) A2JITAutoPairingPreconditions *cachedPreconditions;
@end

@implementation A2JITAutoPairingEngineBridge

#pragma mark - 能力

- (A2RPPairingPreflight *)preflightResult {
    if (self.preflight == nil) {
        self.preflight = [A2RPPairingPreflight run];
        NSLog(@"[A2JIT] autopair engine: %@", self.preflight.summary);
    }
    return self.preflight;
}

- (BOOL)isEngineAvailable {
    // ★只有握手链路全部就绪（含 Ed25519 / ChaCha20-Poly1305 / 消息机）才算「已接入」★。
    // 本阶段首个受阻步骤 = Ed25519 ⇒ 如实回 NO（让 Provider 如实报「未接入」并降级到 ②导入）。
    return self.preflightResult.firstBlockedStep == A2RPPairingBlockedStepNone;
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
    NSLog(@"[A2JIT] autopair engine: 前置条件真读 ⇒ DeveloperMode=%@ get-task-allow=%@ "
          @"LocalNetwork=未知（iOS 无公开 API） DDI=未知（由 ddiProbe 覆盖）",
          A2RPStateName(devMode), A2RPStateName(taskAllow));
    return self.cachedPreconditions;
}

#pragma mark - 生成（★如实点名受阻步骤，绝不假成功★）

- (BOOL)generatePairingFileWithinBudget:(NSTimeInterval)budget
                                 reason:(NSString *_Nullable *_Nullable)whyOut
                                blocker:(A2JITAutoPairingBlocker *_Nullable)blockerOut {
    A2RPPairingPreflight *pf = [self preflightResult];
    NSLog(@"[A2JIT] autopair engine: 尝试生成 ⇒ 自检 %@（budget=%.1fs）", pf.summary, budget);

    // 本阶段必然走到这里（Ed25519 未落地）。即便将来原语齐了，pair-setup/pair-verify 消息机
    // 仍是未落地的一环 ⇒ 本方法【永不】返回 YES：没有真握手就没有真配对文件（不假成功）。
    NSString *blockedName = [A2RPPairingPreflight displayNameForBlockedStep:pf.firstBlockedStep];
    NSString *detail = (pf.firstBlockedStep == A2RPPairingBlockedStepNone)
        ? @"RPPairing 原语已齐，但 pair-setup(SRP-3072)/pair-verify 消息机与 TLS-PSK 隧道尚未落地"
        : A2RPHandshakeCryptoUnavailableReason();

    if (whyOut) {
        *whyOut = [NSString stringWithFormat:@"RPPairing 握手在第【%@】步受阻；%@（自检：%@）",
                   blockedName, detail, pf.summary];
    }
    if (blockerOut) {
        // 「机制尚未接入」语义（映射 AutoPairingNotBuilt），与「真实执行失败」分开。
        *blockerOut = A2JITAutoPairingBlockerEngineUnavailable;
    }
    return NO;
}

@end

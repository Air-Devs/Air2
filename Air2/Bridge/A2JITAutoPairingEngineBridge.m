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
//  [JIT-AUTOPAIR-1] 骨架实现：★如实报「未接入」，绝不假成功★。
//  RPPairing（RSD + pair-verify + TLS-PSK）属下一阶段（docs/JIT-PROVISIONING.md §4.2）。
//

#import "A2JITAutoPairingEngineBridge.h"

@implementation A2JITAutoPairingEngineBridge

- (BOOL)isEngineAvailable {
    // 真实现未落地 ⇒ 明确回答「不可用」，让 Provider 如实报「未接入」并降级到 ② 导入。
    return NO;
}

- (A2JITAutoPairingPreconditions *)readPreconditions {
    // ★探测未接入 ⇒ 四项全 Unknown★（三态语义：Unknown ≠ 已满足；绝不谎报为满足）。
    return [A2JITAutoPairingPreconditions unknownPreconditions];
}

- (BOOL)generatePairingFileWithinBudget:(NSTimeInterval)budget
                                 reason:(NSString *_Nullable *_Nullable)whyOut
                                blocker:(A2JITAutoPairingBlocker *_Nullable)blockerOut {
    (void)budget;
    NSLog(@"[A2JIT] autopair engine: RPPairing 未接入（骨架）⇒ 不尝试生成配对文件（不假成功）");
    if (whyOut) {
        *whyOut = @"RPPairing 引擎未接入（骨架）：真实现经 Bridge → Natives 落地（docs/JIT-PROVISIONING.md §4.2）";
    }
    if (blockerOut) {
        *blockerOut = A2JITAutoPairingBlockerEngineUnavailable;
    }
    return NO;
}

@end

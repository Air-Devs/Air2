//
//  A2JITEnvironmentProbe.m
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
//  [JIT-IMPL-2] ★这里就是「真调判据」的那一行★：
//      [A2JITEnvironment ensureVerifiedWithinBudget:… reason:…]
//  以及失败分流用的 lastRegionVerdict / regionEvidence 实时读取。
//  ★不改 A2JITEnvironment 的判据语义★（它已与老树 feat/runtime-native 对齐）。
//

#import "A2JITEnvironmentProbe.h"

// Bridge → Natives 的唯一跨界：头搜索路径由 scripts/gen_xcodeproj.py 的
// NATIVES_INCLUDE_DIRS 提供（含 $(SRCROOT)/Natives/Support）。
#import "A2JITEnvironment.h"

@interface A2JITEnvironmentProbe ()
/// 跨层枚举映射（唯一允许的加工；switch 穷尽，加档时编译期报警）。
+ (A2JITReadinessVerdict)mapRegionVerdict:(A2JITRegionVerdict)verdict;
@end

// ---------------------------------------------------------------------------
// ★编译期防线★：A2JITReadinessVerdict 必须与 A2JITRegionVerdict 逐值相等。
//  两边任一处改了值（或加了新档），这里立刻编不过 —— 保证「跨层镜像」不会静默漂移。
//  单测 tests/JIT/jit_logic_tests.m 里还有一份运行期断言（双保险）。
// ---------------------------------------------------------------------------
_Static_assert((int)A2JITReadinessVerdictUnknown        == (int)A2JITRegionVerdictUnknown,
               "A2JITReadinessVerdict.Unknown 与 A2JITRegionVerdict 不一致");
_Static_assert((int)A2JITReadinessVerdictUsable         == (int)A2JITRegionVerdictUsable,
               "A2JITReadinessVerdict.Usable 与 A2JITRegionVerdict 不一致");
_Static_assert((int)A2JITReadinessVerdictNotServiced    == (int)A2JITRegionVerdictNotServiced,
               "A2JITReadinessVerdict.NotServiced 与 A2JITRegionVerdict 不一致");
_Static_assert((int)A2JITReadinessVerdictLegacySentinel == (int)A2JITRegionVerdictLegacySentinel,
               "A2JITReadinessVerdict.LegacySentinel 与 A2JITRegionVerdict 不一致");
_Static_assert((int)A2JITReadinessVerdictNoMapping      == (int)A2JITRegionVerdictNoMapping,
               "A2JITReadinessVerdict.NoMapping 与 A2JITRegionVerdict 不一致");
_Static_assert((int)A2JITReadinessVerdictZeroSize       == (int)A2JITRegionVerdictZeroSize,
               "A2JITReadinessVerdict.ZeroSize 与 A2JITRegionVerdict 不一致");
_Static_assert((int)A2JITReadinessVerdictNotExecutable  == (int)A2JITRegionVerdictNotExecutable,
               "A2JITReadinessVerdict.NotExecutable 与 A2JITRegionVerdict 不一致");

@implementation A2JITEnvironmentProbe

#pragma mark - 枚举映射（跨层唯一允许的加工）

+ (A2JITReadinessVerdict)mapRegionVerdict:(A2JITRegionVerdict)verdict {
    // switch 穷尽 ⇒ 将来 A2JITRegionVerdict 加档时，这里会出 -Wswitch 警告，
    // 逼着人回来补映射（而不是让新档静默落到 default）。
    switch (verdict) {
        case A2JITRegionVerdictUnknown:        return A2JITReadinessVerdictUnknown;
        case A2JITRegionVerdictUsable:         return A2JITReadinessVerdictUsable;
        case A2JITRegionVerdictNotServiced:    return A2JITReadinessVerdictNotServiced;
        case A2JITRegionVerdictLegacySentinel: return A2JITReadinessVerdictLegacySentinel;
        case A2JITRegionVerdictNoMapping:      return A2JITReadinessVerdictNoMapping;
        case A2JITRegionVerdictZeroSize:       return A2JITReadinessVerdictZeroSize;
        case A2JITRegionVerdictNotExecutable:  return A2JITReadinessVerdictNotExecutable;
    }
    return A2JITReadinessVerdictUnknown;
}

#pragma mark - A2JITReadinessProbe

- (BOOL)ensureJITUsableWithinBudget:(NSTimeInterval)budget
                             reason:(NSString *_Nullable *_Nullable)whyOut {
    NSString *why = nil;
    // ★真调判据★（Natives/Support，逐字转发；语义一字不改）。
    BOOL ok = [A2JITEnvironment ensureVerifiedWithinBudget:budget reason:&why];
    A2JITReadinessVerdict verdict = [A2JITEnvironmentProbe mapRegionVerdict:[A2JITEnvironment lastRegionVerdict]];
    // 与 Natives 日志同流（[A2JIT] 前缀，进 latestlog.txt），便于真机一眼判成败。
    a2_jit_log("[A2JIT] probe: ensureVerified budget=%.2fs ok=%d verdict=%ld evidence=%s",
               budget, (int)ok, (long)verdict,
               ([A2JITEnvironment regionEvidence] ?: @"(无取证)").UTF8String);
    if (whyOut) {
        *whyOut = why ?: [A2JITEnvironment regionEvidence];
    }
    return ok;
}

- (A2JITReadinessVerdict)lastVerdict {
    return [A2JITEnvironmentProbe mapRegionVerdict:[A2JITEnvironment lastRegionVerdict]];
}

- (nullable NSString *)lastEvidence {
    return [A2JITEnvironment regionEvidence];
}

- (void)invalidateCache {
    [A2JITEnvironment invalidateCache];
}

@end

//
//  A2JITDDIGuidance.m
//  Air2
//
//  [JIT-DDI-1] DDI 分流表实现：只有 switch + 常量，无任何平台调用。
//  ★每种判定的原因 / 动作 key 必须互不相同★（单测断言），
//  否则「按原因分流」就退化成一句万能文案。
//

#import "A2JITDDIGuidance.h"

// ★编译期防漂移★：判定 → 前置条件三态的取值约定必须与 A2JITAutoPairing 的枚举一致。
_Static_assert(A2JITAutoPairingPreconditionStateUnknown == 0,
               "DDI 判定取值约定：Unknown 必须是 0");
_Static_assert(A2JITAutoPairingPreconditionStateSatisfied == 1,
               "DDI 判定取值约定：Satisfied 必须是 1");
_Static_assert(A2JITAutoPairingPreconditionStateUnsatisfied == 2,
               "DDI 判定取值约定：Unsatisfied 必须是 2");

@implementation A2JITDDIGuidance

+ (NSArray<NSNumber *> *)allVerdicts {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSInteger v = A2JITDDIVerdictUnknown; v <= A2JITDDIVerdictStale; v++) {
        [out addObject:@(v)];
    }
    return out;
}

/// 判定 → key token（稳定；表在 A2JITStrings）。
static NSString *A2DDIToken(A2JITDDIVerdict verdict) {
    switch (verdict) {
        case A2JITDDIVerdictUnknown:         return @"unknown";
        case A2JITDDIVerdictPresent:         return @"present";
        case A2JITDDIVerdictMissing:         return @"missing";
        case A2JITDDIVerdictVersionMismatch: return @"versionMismatch";
        case A2JITDDIVerdictStale:           return @"stale";
        default:                             return @"unknown";
    }
}

+ (A2JITAutoPairingPreconditionState)preconditionStateForVerdict:(A2JITDDIVerdict)verdict {
    // 取值约定集中在 A2JITDDI（唯一实现），这里只做类型转换；
    // 上面的 _Static_assert 保证两侧枚举不会漂移。
    NSInteger v = [A2JITDDI preconditionStateValueForVerdict:verdict];
    return (A2JITAutoPairingPreconditionState)v;
}

+ (NSString *)statusKeyForVerdict:(A2JITDDIVerdict)verdict {
    return [NSString stringWithFormat:@"jit.ddi.status.%@", A2DDIToken(verdict)];
}

+ (NSString *)reasonKeyForVerdict:(A2JITDDIVerdict)verdict {
    return [NSString stringWithFormat:@"jit.ddi.verdict.%@.reason", A2DDIToken(verdict)];
}

+ (NSString *)nextActionKeyForVerdict:(A2JITDDIVerdict)verdict fetchEnabled:(BOOL)fetchEnabled {
    switch (verdict) {
        case A2JITDDIVerdictPresent:
            return @"jit.ddi.next.ready";
        case A2JITDDIVerdictMissing:
            // 默认关 ⇒ 指引「去开开关」；开了 ⇒ 指引「去联网取」。
            return fetchEnabled ? @"jit.ddi.next.fetch" : @"jit.ddi.next.enableFetch";
        case A2JITDDIVerdictVersionMismatch:
        case A2JITDDIVerdictStale:
            return @"jit.ddi.next.reimport";
        case A2JITDDIVerdictUnknown:
        default:
            return @"jit.ddi.next.unconfirmed";
    }
}

+ (NSString *)logLineWithProvider:(NSString *)providerName
                          verdict:(A2JITDDIVerdict)verdict
                         evidence:(nullable NSString *)evidence {
    return [NSString stringWithFormat:
            @"[A2JIT] ddi provider=%@ verdict=%@(%ld) evidence=%@",
            providerName,
            [A2JITDDI displayNameForVerdict:verdict],
            (long)verdict,
            evidence.length ? evidence : @"(无取证记录)"];
}

#pragma mark - 机制阻塞文案 key

// ★[PAIRFIX-DDI]★ 原 fetchDisabledReasonKey / fetchDisabledActionKey 已删：
//   「联网取 DDI」的开关去掉后这两句永远不可达（无调用点 ⇒ 死文案）。
+ (NSString *)fetchUnsupportedReasonKey {
    return @"jit.ddi.fetch.unsupported.reason";
}

+ (NSString *)fetchUnsupportedActionKey {
    return @"jit.ddi.fetch.unsupported.action";
}

+ (NSString *)mountUnavailableReasonKey {
    return @"jit.ddi.mount.unavailable.reason";
}

+ (NSString *)mountUnavailableActionKey {
    return @"jit.ddi.mount.unavailable.action";
}

@end

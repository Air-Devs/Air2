//
//  A2JITVerdictGuidance.m
//  Air2
//
//  [JIT-IMPL-2] 判据分流表实现：只有 switch + 常量，无任何平台调用。
//  ★每个 verdict 的原因 / 动作 key 必须互不相同★（单测断言），
//  否则「四种原因四种动作」就退化成一句万能文案。
//

#import "A2JITVerdictGuidance.h"
#import "A2JITStrategySelector.h"

@implementation A2JITVerdictGuidance

+ (BOOL)isUsable:(A2JITReadinessVerdict)verdict {
    return verdict == A2JITReadinessVerdictUsable;
}

+ (A2JITFailureReason)failureReasonForVerdict:(A2JITReadinessVerdict)verdict {
    switch (verdict) {
        case A2JITReadinessVerdictUsable:
            return A2JITFailureReasonNone;
        case A2JITReadinessVerdictUnknown:
        case A2JITReadinessVerdictNotServiced:
        case A2JITReadinessVerdictLegacySentinel:
        case A2JITReadinessVerdictNoMapping:
        case A2JITReadinessVerdictZeroSize:
        case A2JITReadinessVerdictNotExecutable:
        default:
            // 粗粒度一律 ActivationFailed（状态机词汇不扩枚举）；
            // 细粒度分流由 reasonKey/actionKey 承担。
            return A2JITFailureReasonActivationFailed;
    }
}

+ (NSString *)displayNameForVerdict:(A2JITReadinessVerdict)verdict {
    switch (verdict) {
        case A2JITReadinessVerdictUnknown:        return @"Unknown";
        case A2JITReadinessVerdictUsable:         return @"Usable";
        case A2JITReadinessVerdictNotServiced:    return @"NotServiced";
        case A2JITReadinessVerdictLegacySentinel: return @"LegacySentinel";
        case A2JITReadinessVerdictNoMapping:      return @"NoMapping";
        case A2JITReadinessVerdictZeroSize:       return @"ZeroSize";
        case A2JITReadinessVerdictNotExecutable:  return @"NotExecutable";
        default:                                  return @"Unknown";
    }
}

+ (NSString *)diagnosticForVerdict:(A2JITReadinessVerdict)verdict {
    switch (verdict) {
        case A2JITReadinessVerdictUnknown:
            return @"尚未探测";
        case A2JITReadinessVerdictUsable:
            return @"区域可用（非哨兵 + 已映射 + size>0 + max 含 X）";
        case A2JITReadinessVerdictNotServiced:
            return @"brk #0x69 无人服务（无调试器应答）";
        case A2JITReadinessVerdictLegacySentinel:
            return @"回 legacy 哨兵 0xE0000069（脚本未接管）";
        case A2JITReadinessVerdictNoMapping:
            return @"返回地址在进程内无映射（哨兵变体/垃圾）";
        case A2JITReadinessVerdictZeroSize:
            return @"区域 size=0";
        case A2JITReadinessVerdictNotExecutable:
            return @"max_protection 不含 EXECUTE（该页永不可执行）";
        default:
            return @"未知判据";
    }
}

+ (NSString *)reasonKeyForVerdict:(A2JITReadinessVerdict)verdict {
    switch (verdict) {
        case A2JITReadinessVerdictUsable:         return @"jit.verdict.usable.reason";
        case A2JITReadinessVerdictNotServiced:    return @"jit.verdict.notserviced.reason";
        case A2JITReadinessVerdictLegacySentinel: return @"jit.verdict.legacysentinel.reason";
        case A2JITReadinessVerdictNoMapping:      return @"jit.verdict.nomapping.reason";
        case A2JITReadinessVerdictZeroSize:       return @"jit.verdict.zerosize.reason";
        case A2JITReadinessVerdictNotExecutable:  return @"jit.verdict.notexecutable.reason";
        case A2JITReadinessVerdictUnknown:
        default:                                  return @"jit.verdict.unknown.reason";
    }
}

+ (NSString *)actionKeyForVerdict:(A2JITReadinessVerdict)verdict {
    switch (verdict) {
        case A2JITReadinessVerdictUsable:         return @"jit.verdict.usable.action";
        case A2JITReadinessVerdictNotServiced:    return @"jit.verdict.notserviced.action";
        case A2JITReadinessVerdictLegacySentinel: return @"jit.verdict.legacysentinel.action";
        case A2JITReadinessVerdictNoMapping:      return @"jit.verdict.nomapping.action";
        case A2JITReadinessVerdictZeroSize:       return @"jit.verdict.zerosize.action";
        case A2JITReadinessVerdictNotExecutable:  return @"jit.verdict.notexecutable.action";
        case A2JITReadinessVerdictUnknown:
        default:                                  return @"jit.verdict.unknown.action";
    }
}

+ (NSString *)logLineWithProvider:(NSString *)providerName
                         strategy:(A2JITStrategy)strategy
                          verdict:(A2JITReadinessVerdict)verdict
                         evidence:(nullable NSString *)evidence {
    // 一行定成败：Provider / 版本档 / verdict / 取证摘要。
    return [NSString stringWithFormat:
            @"[A2JIT] provider=%@ strategy=%@ verdict=%@(%ld) %@ evidence=%@",
            providerName,
            [A2JITStrategySelector displayNameForStrategy:strategy],
            [self displayNameForVerdict:verdict],
            (long)verdict,
            [self diagnosticForVerdict:verdict],
            evidence.length ? evidence : @"(无取证记录)"];
}

@end

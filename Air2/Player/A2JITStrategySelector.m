//
//  A2JITStrategySelector.m
//  Air2
//
//  [JIT-IMPL] 分级表在这里【只有一处】实现（文档/代码同口径，避免两处漂移）。
//            并给出失败原因（decisionForFacts:），供 UI 按原因分流。
//

#import "A2JITStrategySelector.h"
#import "A2JITFacts.h"

@implementation A2JITStrategyDecision

+ (instancetype)decisionWithStrategy:(A2JITStrategy)strategy
                       failureReason:(A2JITFailureReason)failureReason {
    A2JITStrategyDecision *d = [A2JITStrategyDecision new];
    d->_strategy = strategy;
    d->_failureReason = failureReason;
    return d;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<JITStrategy %@ reason=%ld>",
            [A2JITStrategySelector displayNameForStrategy:self.strategy],
            (long)self.failureReason];
}

@end

@implementation A2JITStrategySelector

+ (A2JITStrategyDecision *)decisionForFacts:(A2JITFacts *)facts {
    NSParameterAssert(facts);

    // ① 内核级优先：越狱 / TrollStore / dynamic-codesigning ⇒ 不靠外部调试器（含 iOS 16- 的越狱机）。
    if ([facts hasKernelJITEnvironment]) {
        return [A2JITStrategyDecision decisionWithStrategy:A2JITStrategyKernel
                                             failureReason:A2JITFailureReasonNone];
    }

    // ② 纯签名 iOS 16 及更早：远程调试式 JIT 需 17.4+，只能归入内核级这一档
    //    （其 Provider 自报不可用 ⇒ 编排层落到 Unavailable）。原因如实标 KernelJITUnavailable。
    if (facts.osMajorVersion <= 16) {
        return [A2JITStrategyDecision decisionWithStrategy:A2JITStrategyKernel
                                             failureReason:A2JITFailureReasonKernelJITUnavailable];
    }

    // ③ iOS 27+：设备内自动配对。
    if ([facts supportsAutomaticPairing]) {
        return [A2JITStrategyDecision decisionWithStrategy:A2JITStrategyAutomatic
                                             failureReason:A2JITFailureReasonNone];
    }

    // ④ iOS 26：内置手动（导入配对 → 连 LocalDevVPN → 内置开启；★不开自动配对★）。
    if ([facts supportsBuiltInHelper]) {
        return [A2JITStrategyDecision decisionWithStrategy:A2JITStrategyBuiltInManual
                                             failureReason:A2JITFailureReasonNone];
    }

    // ⑤ iOS 17.4–25：导入配对文件 + 外部工具。
    if ([facts supportsRemoteDebugJIT]) {
        return [A2JITStrategyDecision decisionWithStrategy:A2JITStrategyImportedExternal
                                             failureReason:A2JITFailureReasonNone];
    }

    // ⑥ iOS 17.0–17.3：无可用路径。
    return [A2JITStrategyDecision decisionWithStrategy:A2JITStrategyUnavailable
                                         failureReason:A2JITFailureReasonSystemTooOld];
}

+ (A2JITStrategy)strategyForFacts:(A2JITFacts *)facts {
    return [self decisionForFacts:facts].strategy;
}

+ (NSArray<NSNumber *> *)orderedProviderKindsForStrategy:(A2JITStrategy)strategy {
    switch (strategy) {
        case A2JITStrategyKernel:
            return @[ @(A2JITProviderKindKernel) ];

        case A2JITStrategyAutomatic:
            // 自动为主；未接入/失败时逐级降级到导入、外部。
            return @[ @(A2JITProviderKindAutomaticPairing),
                      @(A2JITProviderKindImportedPairing),
                      @(A2JITProviderKindExternalTool) ];

        case A2JITStrategyBuiltInManual:
            // iOS 26 手动：★不含自动配对★（用户拍板）。
            return @[ @(A2JITProviderKindImportedPairing),
                      @(A2JITProviderKindExternalTool) ];

        case A2JITStrategyImportedExternal:
            return @[ @(A2JITProviderKindImportedPairing),
                      @(A2JITProviderKindExternalTool) ];

        case A2JITStrategyUnavailable:
        default:
            return @[];
    }
}

+ (NSString *)displayNameForStrategy:(A2JITStrategy)strategy {
    switch (strategy) {
        case A2JITStrategyBuiltInManual:    return @"iOS 26 内置手动（导入配对 + 内置开启）";
        case A2JITStrategyAutomatic:        return @"iOS 27+ 设备内自动配对";
        case A2JITStrategyImportedExternal: return @"iOS 17.4–25 导入配对 + 外部工具";
        case A2JITStrategyKernel:           return @"内核级 JIT（越狱 / TrollStore / iOS 16-）";
        case A2JITStrategyUnavailable:
        default:                            return @"无可用路径";
    }
}

@end

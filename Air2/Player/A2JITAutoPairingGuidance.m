//
//  A2JITAutoPairingGuidance.m
//  Air2
//
//  [JIT-AUTOPAIR-1] 自动配对分流表实现：只有 switch + 常量，无任何平台调用。
//  ★每个 blocker 的原因 / 动作 key 必须互不相同★（单测断言），
//  否则「按原因分流」就退化成一句万能文案。
//

#import "A2JITAutoPairingGuidance.h"

@implementation A2JITAutoPairingGuidance

+ (NSArray<NSNumber *> *)allBlockers {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSInteger b = A2JITAutoPairingBlockerNone; b <= A2JITAutoPairingBlockerStalePairingFile; b++) {
        [out addObject:@(b)];
    }
    return out;
}

+ (NSString *)displayNameForBlocker:(A2JITAutoPairingBlocker)blocker {
    switch (blocker) {
        case A2JITAutoPairingBlockerNone:                    return @"None";
        case A2JITAutoPairingBlockerSystemTooOld:            return @"SystemTooOld";
        case A2JITAutoPairingBlockerDeveloperModeOff:        return @"DeveloperModeOff";
        case A2JITAutoPairingBlockerLocalNetworkDenied:      return @"LocalNetworkDenied";
        case A2JITAutoPairingBlockerGetTaskAllowMissing:     return @"GetTaskAllowMissing";
        case A2JITAutoPairingBlockerDDIMissing:              return @"DDIMissing";
        case A2JITAutoPairingBlockerPreconditionUnconfirmed: return @"PreconditionUnconfirmed";
        case A2JITAutoPairingBlockerEngineUnavailable:       return @"EngineUnavailable";
        case A2JITAutoPairingBlockerDiscoveryFailed:         return @"DiscoveryFailed";
        case A2JITAutoPairingBlockerRSDConnectFailed:        return @"RSDConnectFailed";
        case A2JITAutoPairingBlockerPairVerifyFailed:        return @"PairVerifyFailed";
        case A2JITAutoPairingBlockerTunnelFailed:            return @"TunnelFailed";
        case A2JITAutoPairingBlockerWriteFailed:             return @"WriteFailed";
        case A2JITAutoPairingBlockerStalePairingFile:        return @"StalePairingFile";
        default:                                             return @"Unknown";
    }
}

+ (A2JITFailureReason)failureReasonForBlocker:(A2JITAutoPairingBlocker)blocker {
    switch (blocker) {
        case A2JITAutoPairingBlockerNone:
            return A2JITFailureReasonNone;
        case A2JITAutoPairingBlockerSystemTooOld:
            return A2JITFailureReasonSystemTooOld;
        case A2JITAutoPairingBlockerEngineUnavailable:
            // 「机制尚未接入」与「真实执行失败」必须分开（见 A2JITProvider.h）。
            return A2JITFailureReasonAutoPairingNotBuilt;
        case A2JITAutoPairingBlockerTunnelFailed:
            return A2JITFailureReasonTunnelUnreachable;
        case A2JITAutoPairingBlockerDeveloperModeOff:
        case A2JITAutoPairingBlockerLocalNetworkDenied:
        case A2JITAutoPairingBlockerGetTaskAllowMissing:
        case A2JITAutoPairingBlockerDDIMissing:
        case A2JITAutoPairingBlockerPreconditionUnconfirmed:
        case A2JITAutoPairingBlockerDiscoveryFailed:
        case A2JITAutoPairingBlockerRSDConnectFailed:
        case A2JITAutoPairingBlockerPairVerifyFailed:
        case A2JITAutoPairingBlockerWriteFailed:
        case A2JITAutoPairingBlockerStalePairingFile:
        default:
            return A2JITFailureReasonPairingMissing;
    }
}

/// blocker → 本地化 key 前缀（稳定；表在 A2JITStrings）。
static NSString *A2BlockerKeyToken(A2JITAutoPairingBlocker blocker) {
    switch (blocker) {
        case A2JITAutoPairingBlockerNone:                    return @"none";
        case A2JITAutoPairingBlockerSystemTooOld:            return @"systemTooOld";
        case A2JITAutoPairingBlockerDeveloperModeOff:        return @"developerMode";
        case A2JITAutoPairingBlockerLocalNetworkDenied:      return @"localNetwork";
        case A2JITAutoPairingBlockerGetTaskAllowMissing:     return @"getTaskAllow";
        case A2JITAutoPairingBlockerDDIMissing:              return @"ddi";
        case A2JITAutoPairingBlockerPreconditionUnconfirmed: return @"precondUnknown";
        case A2JITAutoPairingBlockerEngineUnavailable:       return @"engineUnavailable";
        case A2JITAutoPairingBlockerDiscoveryFailed:         return @"discovery";
        case A2JITAutoPairingBlockerRSDConnectFailed:        return @"rsd";
        case A2JITAutoPairingBlockerPairVerifyFailed:        return @"pairVerify";
        case A2JITAutoPairingBlockerTunnelFailed:            return @"tunnel";
        case A2JITAutoPairingBlockerWriteFailed:             return @"write";
        case A2JITAutoPairingBlockerStalePairingFile:        return @"stale";
        default:                                             return @"unknown";
    }
}

+ (NSString *)reasonKeyForBlocker:(A2JITAutoPairingBlocker)blocker {
    return [NSString stringWithFormat:@"jit.autopair.blocker.%@.reason", A2BlockerKeyToken(blocker)];
}

+ (NSString *)actionKeyForBlocker:(A2JITAutoPairingBlocker)blocker {
    return [NSString stringWithFormat:@"jit.autopair.blocker.%@.action", A2BlockerKeyToken(blocker)];
}

+ (NSString *)displayNameForStep:(A2JITAutoPairingStep)step {
    switch (step) {
        case A2JITAutoPairingStepIdle:       return @"Idle";
        case A2JITAutoPairingStepDiscovery:  return @"Discovery";
        case A2JITAutoPairingStepRSDConnect: return @"RSDConnect";
        case A2JITAutoPairingStepPairVerify: return @"PairVerify";
        case A2JITAutoPairingStepTunnel:     return @"Tunnel";
        case A2JITAutoPairingStepWriteFile:  return @"WriteFile";
        case A2JITAutoPairingStepDone:       return @"Done";
        default:                             return @"Unknown";
    }
}

/// 前置条件 → 本地化 key token（稳定；表在 A2JITStrings）。
static NSString *A2PreconditionKeyToken(A2JITAutoPairingPrecondition precondition) {
    switch (precondition) {
        case A2JITAutoPairingPreconditionDeveloperMode: return @"developerMode";
        case A2JITAutoPairingPreconditionLocalNetwork:  return @"localNetwork";
        case A2JITAutoPairingPreconditionGetTaskAllow:  return @"getTaskAllow";
        case A2JITAutoPairingPreconditionDDI:           return @"ddi";
        default:                                        return @"unknown";
    }
}

+ (NSString *)nameKeyForPrecondition:(A2JITAutoPairingPrecondition)precondition {
    return [NSString stringWithFormat:@"jit.autopair.precond.%@", A2PreconditionKeyToken(precondition)];
}

+ (NSString *)stateKeyForPreconditionState:(A2JITAutoPairingPreconditionState)state {
    switch (state) {
        case A2JITAutoPairingPreconditionStateSatisfied:   return @"jit.autopair.precond.satisfied";
        case A2JITAutoPairingPreconditionStateUnsatisfied: return @"jit.autopair.precond.unsatisfied";
        case A2JITAutoPairingPreconditionStateUnknown:
        default:                                           return @"jit.autopair.precond.unknown";
    }
}

+ (NSString *)logLineWithProvider:(NSString *)providerName
                             step:(A2JITAutoPairingStep)step
                          blocker:(A2JITAutoPairingBlocker)blocker
                         evidence:(nullable NSString *)evidence {
    // 一行定成败：Provider / 步骤 / blocker / 取证摘要。
    return [NSString stringWithFormat:
            @"[A2JIT] autopair provider=%@ step=%@ blocker=%@(%ld) reasonCode=%ld evidence=%@",
            providerName,
            [self displayNameForStep:step],
            [self displayNameForBlocker:blocker],
            (long)blocker,
            (long)[self failureReasonForBlocker:blocker],
            evidence.length ? evidence : @"(无取证记录)"];
}

@end

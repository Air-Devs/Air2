//
//  A2JITStateMachine.m
//  Air2
//
//  [JIT-IMPL] 纯迁移表实现：只有集合判定与赋值，无任何平台/网络调用。
//

#import "A2JITStateMachine.h"

@implementation A2JITStateMachine

- (instancetype)init {
    return [self initWithState:A2JITStateUnavailable];
}

- (instancetype)initWithState:(A2JITState)state {
    self = [super init];
    if (self) {
        _state = state;
        _failureReason = A2JITFailureReasonNone;
        _statusDetail = @"";
    }
    return self;
}

+ (BOOL)canTransitionFrom:(A2JITState)from to:(A2JITState)to {
    // 自迁移恒合法：只更新原因/说明（refreshState 的探测抖动不应被判非法）。
    if (from == to) {
        return YES;
    }
    switch (from) {
        case A2JITStateUnavailable:
            // 环境变好后重评估：进入等待配对，或直接已配对（内核级无需配对）。
            return (to == A2JITStateWaitingPairing) || (to == A2JITStatePaired);

        case A2JITStateWaitingPairing:
            // 取到配对升到 Paired；路径消失则回 Unavailable。★不得越过 Paired 直接 Enabled★。
            return (to == A2JITStatePaired) || (to == A2JITStateUnavailable);

        case A2JITStatePaired:
            // 开启 → WaitingActivation；重评估发现配对材料丢失 → WaitingPairing / Unavailable。
            return (to == A2JITStateWaitingActivation) ||
                   (to == A2JITStateWaitingPairing) ||
                   (to == A2JITStateUnavailable);

        case A2JITStateWaitingActivation:
            // 成功 → Enabled；开启失败停留本态（自迁移）；重评估可回落。
            return (to == A2JITStateEnabled) ||
                   (to == A2JITStatePaired) ||
                   (to == A2JITStateWaitingPairing) ||
                   (to == A2JITStateUnavailable);

        case A2JITStateEnabled:
        default:
            // ★终态★：JIT 一旦拿到不撤销，探测抖动不复位。
            return NO;
    }
}

- (BOOL)transitionTo:(A2JITState)to
              reason:(A2JITFailureReason)reason
              detail:(nullable NSString *)detail {
    if (![A2JITStateMachine canTransitionFrom:_state to:to]) {
        return NO;
    }
    _state = to;
    _failureReason = reason;
    _statusDetail = [detail copy] ?: @"";
    return YES;
}

+ (NSString *)displayNameForState:(A2JITState)state {
    switch (state) {
        case A2JITStateUnavailable:       return @"不可用";
        case A2JITStateWaitingPairing:    return @"等待配对";
        case A2JITStatePaired:            return @"已配对";
        case A2JITStateWaitingActivation: return @"等待开启";
        case A2JITStateEnabled:           return @"已启用";
        default:                          return @"未知";
    }
}

+ (NSString *)displayNameForFailureReason:(A2JITFailureReason)reason {
    switch (reason) {
        case A2JITFailureReasonNone:                 return @"无";
        case A2JITFailureReasonSystemTooOld:         return @"系统过低";
        case A2JITFailureReasonNoProvider:           return @"无可用取得路径";
        case A2JITFailureReasonPairingMissing:       return @"缺配对材料";
        case A2JITFailureReasonAutoPairingNotBuilt:  return @"自动配对未接入";
        case A2JITFailureReasonExternalToolMissing:  return @"未检测到外部工具";
        case A2JITFailureReasonTunnelUnreachable:    return @"隧道不可达";
        case A2JITFailureReasonActivationFailed:     return @"开启失败";
        case A2JITFailureReasonKernelJITUnavailable: return @"内核级 JIT 环境不具备";
        default:                                     return @"未知";
    }
}

@end

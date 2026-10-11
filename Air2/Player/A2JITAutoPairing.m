//
//  A2JITAutoPairing.m
//  Air2
//
//  [JIT-AUTOPAIR-1] 前置条件值对象实现（纯逻辑、无平台调用）。
//  ★不引入第三方、不发网络、不建隧道★：真正的 RPPairing 在 Bridge → Natives（下一阶段）。
//

#import "A2JITAutoPairing.h"

const NSInteger A2JITAutoPairingPreconditionCount = A2JIT_AUTOPAIR_PRECONDITION_COUNT;

@implementation A2JITAutoPairingPreconditions {
    // 固定大小数组（用编译期常量，避免 VLA 扩展警告）；数量见 A2JIT_AUTOPAIR_PRECONDITION_COUNT。
    A2JITAutoPairingPreconditionState _states[A2JIT_AUTOPAIR_PRECONDITION_COUNT];
}

+ (instancetype)preconditionsWithDeveloperMode:(A2JITAutoPairingPreconditionState)developerMode
                                  localNetwork:(A2JITAutoPairingPreconditionState)localNetwork
                                  getTaskAllow:(A2JITAutoPairingPreconditionState)getTaskAllow
                                           ddi:(A2JITAutoPairingPreconditionState)ddi {
    A2JITAutoPairingPreconditions *p = [A2JITAutoPairingPreconditions new];
    p->_states[A2JITAutoPairingPreconditionDeveloperMode] = developerMode;
    p->_states[A2JITAutoPairingPreconditionLocalNetwork]  = localNetwork;
    p->_states[A2JITAutoPairingPreconditionGetTaskAllow]  = getTaskAllow;
    p->_states[A2JITAutoPairingPreconditionDDI]           = ddi;
    return p;
}

+ (instancetype)unknownPreconditions {
    return [self preconditionsWithDeveloperMode:A2JITAutoPairingPreconditionStateUnknown
                                   localNetwork:A2JITAutoPairingPreconditionStateUnknown
                                   getTaskAllow:A2JITAutoPairingPreconditionStateUnknown
                                            ddi:A2JITAutoPairingPreconditionStateUnknown];
}

+ (instancetype)allSatisfiedPreconditions {
    return [self preconditionsWithDeveloperMode:A2JITAutoPairingPreconditionStateSatisfied
                                   localNetwork:A2JITAutoPairingPreconditionStateSatisfied
                                   getTaskAllow:A2JITAutoPairingPreconditionStateSatisfied
                                            ddi:A2JITAutoPairingPreconditionStateSatisfied];
}

- (A2JITAutoPairingPreconditionState)stateForPrecondition:(A2JITAutoPairingPrecondition)precondition {
    if (precondition < 0 || precondition >= A2JITAutoPairingPreconditionCount) {
        return A2JITAutoPairingPreconditionStateUnknown;
    }
    return _states[precondition];
}

- (nullable NSNumber *)firstUnsatisfiedPrecondition {
    for (NSInteger i = 0; i < A2JITAutoPairingPreconditionCount; i++) {
        if (_states[i] == A2JITAutoPairingPreconditionStateUnsatisfied) {
            return @(i);
        }
    }
    return nil;
}

- (nullable NSNumber *)firstUnconfirmedPrecondition {
    for (NSInteger i = 0; i < A2JITAutoPairingPreconditionCount; i++) {
        if (_states[i] == A2JITAutoPairingPreconditionStateUnknown) {
            return @(i);
        }
    }
    return nil;
}

- (BOOL)allSatisfied {
    for (NSInteger i = 0; i < A2JITAutoPairingPreconditionCount; i++) {
        if (_states[i] != A2JITAutoPairingPreconditionStateSatisfied) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)description {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSString *> *names = @[ @"developerMode", @"localNetwork", @"getTaskAllow", @"ddi" ];
    NSArray<NSString *> *stateNames = @[ @"unknown", @"satisfied", @"unsatisfied" ];
    for (NSInteger i = 0; i < A2JITAutoPairingPreconditionCount; i++) {
        NSInteger s = _states[i];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", names[i],
                          (s >= 0 && s < 3) ? stateNames[s] : @"?"]];
    }
    return [NSString stringWithFormat:@"<AutoPairingPreconditions %@>",
            [parts componentsJoinedByString:@" "]];
}

@end

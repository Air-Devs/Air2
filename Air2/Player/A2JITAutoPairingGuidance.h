//
//  A2JITAutoPairingGuidance.h
//  Air2
//
//  Player —— 【自动配对分流表】：把 A2JITAutoPairingBlocker 翻成
//  「现有失败原因 + 下一步动作（本地化 key）+ 稳定诊断名」。
//
//  为什么单独一件：自动配对的失败形态有 14 种（前置条件 4 + 探测未接入 + 5 个步骤落点 + 过期 + 无阻塞），
//  每种对应的用户动作【完全不同】（开 Developer Mode / 授本地网络权限 / 重签带 get-task-allow /
//  联网取 DDI / 装下一阶段引擎 / 重试 / 换路径）。docs/JIT-PROVISIONING.md §2.1 明确
//  「失败提示条按原因分流，严禁一句万能文案」。
//
//  ★纯逻辑、无平台调用、可单测★；★不改状态机词汇（A2JITFailureReason 不扩枚举）★——
//  细粒度分流由 blocker 级本地化 key 承担，粗粒度归入现有 8 个失败原因。
//

#import <Foundation/Foundation.h>
#import "A2JITAutoPairing.h"
#import "A2JITStateMachine.h"

NS_ASSUME_NONNULL_BEGIN

/// 自动配对的判据分流表（★唯一实现★）。
@interface A2JITAutoPairingGuidance : NSObject

/// 全部 blocker（稳定顺序：None → … → StalePairingFile，共 14 项）。
+ (NSArray<NSNumber *> *)allBlockers;

/// 稳定英文名（日志 / 诊断用，非本地化）：None / DeveloperModeOff / …
+ (NSString *)displayNameForBlocker:(A2JITAutoPairingBlocker)blocker;

/// 该 blocker 映射到的【现有状态机失败原因】（粗粒度）。
+ (A2JITFailureReason)failureReasonForBlocker:(A2JITAutoPairingBlocker)blocker;

/// 本地化 key：失败原因（A2JITStrings 里的 key）。
+ (NSString *)reasonKeyForBlocker:(A2JITAutoPairingBlocker)blocker;

/// 本地化 key：下一步动作（A2JITStrings 里的 key）。
+ (NSString *)actionKeyForBlocker:(A2JITAutoPairingBlocker)blocker;

/// 稳定英文名（步骤）：Idle / Discovery / RSDConnect / pair-verify / Tunnel / WriteFile / Done。
+ (NSString *)displayNameForStep:(A2JITAutoPairingStep)step;

/// 本地化 key：前置条件名（A2JITStrings 里的 key）。
+ (NSString *)nameKeyForPrecondition:(A2JITAutoPairingPrecondition)precondition;

/// 本地化 key：前置条件判定态（satisfied / unsatisfied / unknown）。
+ (NSString *)stateKeyForPreconditionState:(A2JITAutoPairingPreconditionState)state;

/// ★统一日志行★（默认可见）：Provider / 步骤 / blocker / 取证摘要。
+ (NSString *)logLineWithProvider:(NSString *)providerName
                             step:(A2JITAutoPairingStep)step
                          blocker:(A2JITAutoPairingBlocker)blocker
                         evidence:(nullable NSString *)evidence;

@end

NS_ASSUME_NONNULL_END

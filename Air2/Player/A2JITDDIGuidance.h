//
//  A2JITDDIGuidance.h
//  Air2
//
//  Player —— DDI 判定的【分流表】：verdict → 前置条件三态 / 本地化 key / 稳定诊断名 / 日志行。
//
//  为什么单独一件：DDI 的判定有 5 种（就位 / 缺失 / 版本不符 / 过期 / 无法确认），
//  每种对应的用户动作【完全不同】（去导入 / 去联网取 / 重新导入 / 先把探测接线 /
//  什么都不用做）。docs/JIT-PROVISIONING.md §2.1 明确「失败提示条按原因分流，严禁一句万能文案」。
//
//  ★纯逻辑、无平台调用、可单测★；★不改状态机词汇（A2JITFailureReason 不扩枚举）★——
//  细粒度分流由 DDI 级本地化 key 承担。
//

#import <Foundation/Foundation.h>
#import "A2JITDDI.h"
#import "A2JITAutoPairing.h"

NS_ASSUME_NONNULL_BEGIN

/// DDI 判定的判据分流表（★唯一实现★）。
@interface A2JITDDIGuidance : NSObject

/// 全部判定（稳定顺序：Unknown → Present → Missing → VersionMismatch → Stale，共 5 项）。
+ (NSArray<NSNumber *> *)allVerdicts;

/// 稳定英文名（日志 / 诊断用，非本地化）。
+ (NSString *)displayNameForVerdict:(A2JITDDIVerdict)verdict;

/// ★判定 → 自动配对的 DDI 前置条件三态★（Unknown 只由 Unknown 判定产生）。
+ (A2JITAutoPairingPreconditionState)preconditionStateForVerdict:(A2JITDDIVerdict)verdict;

/// 本地化 key：行状态短文案（如「已就位」「缺失」「无法确认」）。
+ (NSString *)statusKeyForVerdict:(A2JITDDIVerdict)verdict;
/// 本地化 key：失败 / 异常原因。
+ (NSString *)reasonKeyForVerdict:(A2JITDDIVerdict)verdict;
/// 本地化 key：下一步动作（就位时的说明 / 重导入 / 联网取 …）。
+ (NSString *)actionKeyForVerdict:(A2JITDDIVerdict)verdict;

/// 本地化 key：设置页「下一步动作」行（按判定 + 偏好开关取值）。
/// @param fetchEnabled 「联网取 DDI」开关是否已打开（默认关）。
+ (NSString *)nextActionKeyForVerdict:(A2JITDDIVerdict)verdict fetchEnabled:(BOOL)fetchEnabled;

/// ★统一日志行★（默认可见）。
+ (NSString *)logLineWithProvider:(NSString *)providerName
                          verdict:(A2JITDDIVerdict)verdict
                         evidence:(nullable NSString *)evidence;

// ---------------------------------------------------------------------------
// 机制阻塞（联网取 / 挂载）的文案 key —— 未接线或缺特权时【如实报】
// ---------------------------------------------------------------------------
+ (NSString *)fetchDisabledReasonKey;      ///< 「联网取 DDI」默认关
+ (NSString *)fetchDisabledActionKey;
+ (NSString *)fetchUnsupportedReasonKey;   ///< 机制未接入 / 缺能力
+ (NSString *)fetchUnsupportedActionKey;
+ (NSString *)mountUnavailableReasonKey;   ///< 挂载缺特权 / 未接线
+ (NSString *)mountUnavailableActionKey;

@end

NS_ASSUME_NONNULL_END

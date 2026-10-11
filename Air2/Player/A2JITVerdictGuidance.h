//
//  A2JITVerdictGuidance.h
//  Air2
//
//  Player —— 【判据分流】：把 A2JITReadinessVerdict 翻成「原因 + 下一步动作」。
//
//  为什么单独一件：A2JITEnvironment 的区域判据有 7 种取值（usable + 6 种失败形态），
//  每种对应的用户动作**完全不同**（无人服务=先启用 JIT；legacy 哨兵=指派脚本；
//  无映射/零长/不可执行=重试或换路径）。docs/JIT-PROVISIONING.md §2.1 明确
//  「失败提示条按原因分流，严禁一句万能文案」。
//
//  ★纯逻辑、无平台调用、可单测★：本类只做 verdict → (状态机原因 / 本地化 key /
//  日志短语) 的映射；文案本体在 A2JITStrings（四语）。★不改状态机的词汇★
//  （A2JITFailureReason 不扩枚举），细粒度分流由 verdict 级 key 承担。
//

#import <Foundation/Foundation.h>
#import "A2JITReadinessProbe.h"
#import "A2JITStateMachine.h"
#import "A2JITProvider.h"       // A2JITStrategy（日志行用的「版本档」）

NS_ASSUME_NONNULL_BEGIN

/// 判据分流表（★唯一实现★，与 A2JITReadinessVerdict 一一对应）。
@interface A2JITVerdictGuidance : NSObject

/// 该判据是否表示「JIT 真的可用」。★只有 Usable 为真★。
+ (BOOL)isUsable:(A2JITReadinessVerdict)verdict;

/// 该判据映射到的【状态机失败原因】（粗粒度，供状态机/提示条分流）。
/// Usable → None；其余 → ActivationFailed（细粒度原因见 reasonKey）。
+ (A2JITFailureReason)failureReasonForVerdict:(A2JITReadinessVerdict)verdict;

/// 日志 / 诊断用的紧凑英文名（稳定、非本地化）：Unknown / Usable / NotServiced / …
+ (NSString *)displayNameForVerdict:(A2JITReadinessVerdict)verdict;

/// 日志 / 取证行用的稳定中文短语（非本地化，便于一眼判成败）。
+ (NSString *)diagnosticForVerdict:(A2JITReadinessVerdict)verdict;

/// 本地化 key：失败原因（A2JITStrings 里的 key）。
+ (NSString *)reasonKeyForVerdict:(A2JITReadinessVerdict)verdict;

/// 本地化 key：下一步动作（A2JITStrings 里的 key）。
+ (NSString *)actionKeyForVerdict:(A2JITReadinessVerdict)verdict;

/// ★统一日志行★（默认可见）：Provider 名 / 版本档 / verdict / 取证摘要。
+ (NSString *)logLineWithProvider:(NSString *)providerName
                         strategy:(A2JITStrategy)strategy
                          verdict:(A2JITReadinessVerdict)verdict
                         evidence:(nullable NSString *)evidence;

@end

NS_ASSUME_NONNULL_END

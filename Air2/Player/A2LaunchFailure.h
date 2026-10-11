//
//  A2LaunchFailure.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— ★启动链失败分类的单一实现（纯逻辑、无平台调用、可单测）★。
//
//  为什么要有这一件：启动链的失败分四类，每一类的「谁能建 VM / 用户该做什么」完全不同。
//  若各调用点各写各的 if/else（并在局部变量里记 JIT 状态），就会出现
//  「同一失败在不同路径被判成不同东西」——历史缺陷 `jitExtEarlyOk` 就是这一类。
//  ⇒ 分类只在这里一处；调用方（A2LaunchSession）只做「读 chain.stage + 查表 + 打印」。
//
//  与既有件的关系（★不重复造轮子★）：
//    · ② 的细粒度分流（7 档 verdict → 原因 / 动作 key）已有 `A2JITVerdictGuidance`；
//      本类**只调用它**，不重写映射表。
//    · 用户可见文案取 `A2JITStrings`（四语，按系统语言）。
//    · ③ 的返回码语义照 `Natives/Context/a2_launch.h` 的契约（注释里的 rc 表）。
//

#import <Foundation/Foundation.h>
#import "A2LaunchChain.h"          // A2LaunchChainStage（分类输入）
#import "A2JITReadinessProbe.h"    // A2JITReadinessVerdict（② 的分流输入）

NS_ASSUME_NONNULL_BEGIN

/// 启动链失败分类（★与「停在哪一步」一一对应★）。
typedef NS_ENUM(NSInteger, A2LaunchFailureClass) {
    A2LaunchFailureClassNone = 0,         ///< 未失败
    A2LaunchFailureClassSwitchOff = 1,    ///< 开关关：零副作用返回（不算失败，属旧行为）
    A2LaunchFailureClassMissingInput = 2, ///< 输入不全（版本 / entryJar / JRE / lwjgl / 计划产出）
    A2LaunchFailureClassJITBlocked = 3,   ///< ② 探测不合格 ⇒ 如实阻断、绝不建 VM
    A2LaunchFailureClassVMFailed = 4,     ///< ③ 建 VM 返回非 0
};

@interface A2LaunchFailure : NSObject

/// 分类：由「停在哪一步」决定（stage 为 A2LaunchChainStage）。
+ (A2LaunchFailureClass)classForChainStage:(A2LaunchChainStage)stage;

/// 稳定的日志标记（可 grep；非本地化）。
+ (NSString *)diagnosticTagForClass:(A2LaunchFailureClass)cls;

/// ② 的判据行（默认可见；含 verdict / 判据 / 取证）——★失败分类的分流落点★。
+ (NSString *)diagnosticForJITVerdict:(A2JITReadinessVerdict)verdict
                             evidence:(nullable NSString *)evidence;

/// ② 的用户文案（四语，按 verdict 分流：原因 + 下一步怎么做）。
+ (NSString *)userMessageForJITVerdict:(A2JITReadinessVerdict)verdict;

/// ③ 的用户文案（按 `a2_launch.h` 的返回码契约释义）。
+ (NSString *)userMessageForVMFailureCode:(NSInteger)rc;

@end

NS_ASSUME_NONNULL_END

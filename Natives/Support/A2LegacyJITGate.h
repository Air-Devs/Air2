//
//  A2LegacyJITGate.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— ★老 Air（tree510）的 JIT 判定 / 闰门：原样移植★
// ----------------------------------------------------------------------------
//  为什么另立一个文件：Air2 之前自己写的判据（Natives/Support/A2JITEnabler.m 的
//  「放行优先四条」+ A2JITEnvironment 的自创口径）与老 Air 的判据互相打架，真机
//  表现为「先死后放 / 开了 JIT 也不继续 / 放行了却闪退」。老 Air 那一套是**唯一在
//  真机上被验证过不崩**的组合，故这里逐字移植，Air2 侧只保留这一个真相源。
//
//  移植来源（行号即 tree510 当前树）：
//    ① Natives/utils.m  L43–L81     getEntitlementValue          → A2JITGetEntitlementValue
//    ② Natives/utils.m  L279–L294   isJITEnabled                 → A2JITIsEnabled
//    ③ Natives/utils.m  L1359–L1417 三方调试器探针                → A2JIT26DebuggerAttachedViaPtrace /
//                                                                  A2JIT26DebuggerViaExceptionPorts /
//                                                                  A2JIT26IsLikelyDebuggerKeepAttached
//    ④ Natives/utils.m  L1437–L1497 AMEJITVerifyWritableJITRegion → A2AMEJITVerifyWritableJITRegion
//                                   AMEJITWaitReadyVerified       → A2AMEJITWaitReadyVerified
//    ⑤ Natives/JavaLauncher.m L1384–L1544 建 JVM 之前的闰门        → A2LegacyJITGateOpen
//
//  ★不改逻辑、不改顺序、不改日志文案★：函数名加 A2 前缀只为避免与 Air2 既有符号
//  撞名。真机取证按老 Air 的原文 grep：
//      [JIT-FLOW] verified: debugger serviced brk #0x69 -> JIT region @…
//      [JIT-FLOW] false-positive guard triggered (#n): brk #0x69 NOT serviced …
//      [JIT26] JIT26CreateRegionLegacy returned NULL -- JIT26 debugger not servicing brk …
//
//  ★关键事实（Air2 之前判反了，这里按老 Air 的原文）★
//    UniversalJIT26.js 的 **基础脚本** 对 `brk #0x69` 只回哨兵 `0xE0000069`
//    （寄存器回读字节序翻转后是 `0x690000E0`）——它表示「脚本是 Universal 版、
//    还没装 Extension」。老 Air 的闰门正是**要求**拿到这个值，然后再下发
//    UniversalJIT26Extension.js（它把 legacyCommands[0x69] 换成真建区），
//    最后设 detachAfterFirstBr。所以：
//      · `(uint32_t)region == 0x690000E0` ⇒ **正确**（Universal 脚本在岗）⇒ 放行；
//      · 其它非 NULL 值（真指针）        ⇒ legacy 脚本 ⇒ 中止并提示换 Universal。
//    Air2 曾经把这两个判反（把哨兵当失败、把真指针当成功）——那是「先死后放」的根因。

#import <Foundation/Foundation.h>
#import <stddef.h>

NS_ASSUME_NONNULL_BEGIN

/// 建 VM 之前闰门的结论（对齐老 Air launchJVM 里的 `return 1` 分支）。
typedef NS_ENUM(NSInteger, A2LegacyJITGateOutcome) {
    A2LegacyJITGateOutcomeOpen         = 0,  ///< 放行：可以调 JNI_CreateJavaVM
    A2LegacyJITGateOutcomeNoRegion     = 1,  ///< brk #0x69 无人服务（本进程没有可用的调试器/JIT）
    A2LegacyJITGateOutcomeLegacyScript = 2,  ///< 回的是真指针 ⇒ 设备上装的是 legacy 脚本，需换 Universal
};

#pragma mark - ①② 老 Air 的就绪判据

/// 移植自 tree510 `isJITEnabled(BOOL checkCSFlags)`：
/// `dynamic-codesigning` entitlement（checkCSFlags==NO 时才算）或内核 `CS_DEBUGGED`。
BOOL A2JITIsEnabled(BOOL checkCSFlags);

/// 移植自 tree510 `getEntitlementValue(NSString *)`（读自签名的 entitlement）。
BOOL A2JITGetEntitlementValue(NSString *key);

#pragma mark - ③ 调试器存活三探针

/// 移植自 tree510 `JIT26DebuggerAttachedViaPtrace`：内核 P_TRACED（调试器附加期间恒置位）。
BOOL A2JIT26DebuggerAttachedViaPtrace(void);

/// 移植自 tree510 `JIT26DebuggerViaExceptionPorts`：任务级 BREAKPOINT/SOFTWARE 异常端口非空
/// （lldb/debugserver 在 PT_DETACH 之后仍靠它服务 brk #0x69）。
BOOL A2JIT26DebuggerViaExceptionPorts(void);

/// 移植自 tree510 `JIT26IsLikelyDebuggerKeepAttached`：ppid≠1 / P_TRACED / 异常端口任一命中。
BOOL A2JIT26IsLikelyDebuggerKeepAttached(void);

#pragma mark - ④ 真能力判据（brk #0x69 被服务）

/// 移植自 tree510 `AMEJITVerifyWritableJITRegion`：真的发一发 `brk #0x69`，
/// **只要调试器应答了**（拿到区，含 Universal 脚本的哨兵 0x690000E0）就算真能力；
/// 无人服务 ⇒ NO。成功一次即缓存（legacy 脚本只服务一次断点）。
BOOL A2AMEJITVerifyWritableJITRegion(void);

/// 移植自 tree510 `AMEJITWaitReadyVerified`：
///   · 非镜像设备（< iOS 26）：执行式探针真的跑过才算；
///   · 镜像设备（iOS 26+）：先要求调试器在岗，再要求 brk #0x69 真的被服务。
BOOL A2AMEJITWaitReadyVerified(void);

/// 移植自 tree510 `DeviceNeedsDebugJITMapping()`（= JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED）。
/// Air2 侧的等价实现见 A2JITEnvironment.needsDebuggerMapping（iOS 主版本 ≥ 26）。
BOOL A2LegacyJITGateRequiresDebugMapping(void);

/// ★启动闸门唯一判据（供 A2JITEnabler 转调）★：
///   · 非镜像设备 ⇒ YES（老 Air 的 `if (requiresDebugJITMapping)` 整块被跳过，不闸）；
///   · 镜像设备   ⇒ `A2AMEJITWaitReadyVerified()`（调试器在岗 + brk #0x69 被服务）。
/// whyOut = 可读原因（凭哪一条放行 / 为什么不成）。
BOOL A2LegacyJITGateReadyNow(NSString *_Nullable *_Nullable whyOut);

#pragma mark - ⑤ 建 JVM 之前的闰门（老 Air JavaLauncher.m 原样）

/// 移植自 tree510 `JavaLauncher.m` L1384–L1544（`if (requiresDebugJITMapping) { … }` 整块）：
///   1. 发一发 `brk #0x69`（安全网版本，无人服务返回 NULL 不致死）；
///   2. NULL ⇒ 判「本进程没有 JIT」，调用方必须**不建 VM**并给可读提示；
///      回真指针（非 0x690000E0）⇒ 判「设备上是 legacy 脚本」，同样不建 VM；
///   3. 正确（哨兵）⇒ 下发 `UniversalJIT26Extension.js`（把 legacyCommands[0x69]
///      换成真建区）+ `JIT26SetDetachAfterFirstBr(!alwaysAttached)` +
///      清 EXC_MASK_BAD_ACCESS 的任务异常端口；
///   4. 返回 Open ⇒ 调用方才可以调 `JNI_CreateJavaVM`。
///
/// ★调用方必须把它放在唯一建 VM 处（A2LaunchSession 的 createJVM 块）之前★：
/// 老 Air 的顺序就是「闰门 → 之后才建 JVM」，中间不许插别的启动动作。
A2LegacyJITGateOutcome A2LegacyJITGateOpen(NSString *_Nullable *_Nullable whyOut);

NS_ASSUME_NONNULL_END

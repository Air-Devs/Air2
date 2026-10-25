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
//      · `(uint32_t)region == 0x690000E0` ⇒ **Universal 基础脚本在岗**（可以下发 Extension）；
//      · 其它非 NULL 值（真指针）        ⇒ 老 Air 判 legacy 脚本 ⇒ 中止并提示换 Universal。
//    Air2 曾经把这两个判反（把哨兵当失败、把真指针当成功）——那是「先死后放」的根因。
//
//  ★判据（方案 A，对齐老 Air）★：哨兵只是「握手」，**不是 JIT 区**。真机 lastlog-64 曾把
//  `0xcccccccc690000e0 / 16384 bytes / writable=0` 当成功放行 ⇒ 没区却建 VM ⇒ 首帧 SIGBUS；
//  Air2 随后又反向踩坑：要求本进程先拿到 size≥64MB 的真区才放行，而闸门自己那发 brk 用的是
//  固定小页长度（getpagesize），64MB 是 libjvm 建 VM 时按 -XX:ReservedCodeCacheSize 才要的
//  ⇒ 真机 lastlog.old-6 表现为「重试 2 次后仍未拿到真区 ⇒ 未就绪」的**假失败**。
//  现在的判据：哨兵 ⇒ 下发 Extension ⇒ ★握手完成（哨兵 + Extension 已下发 + brk #0x69 被服务）就放行★；
//  region 的 size / 期望 / 保护位★只打日志、不参与判定★，真区由 libjvm 建 VM 时自己取。

#import <Foundation/Foundation.h>
#import <stddef.h>

NS_ASSUME_NONNULL_BEGIN

/// 建 VM 之前闰门的结论（对齐老 Air launchJVM 里的 `return 1` 分支）。
typedef NS_ENUM(NSInteger, A2LegacyJITGateOutcome) {
    A2LegacyJITGateOutcomeOpen         = 0,  ///< 放行：可以调 JNI_CreateJavaVM
    A2LegacyJITGateOutcomeNoRegion     = 1,  ///< brk #0x69 无人服务 / 没有交付真区（本进程没有 JIT）
    A2LegacyJITGateOutcomeLegacyScript = 2,  ///< 直回真指针且 Extension 收不到 ⇒ 设备上装的是 legacy 脚本
    A2LegacyJITGateOutcomeSentinelOnly = 3,  ///< 见到握手哨兵 0x690000E0 但 Extension 没下发成功（握手没完成）
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

/// 移植自 tree510 `AMEJITVerifyWritableJITRegion`，★判据 = 握手完成★（方案 A）：
/// 真的发一发 `brk #0x69`；只要被调试器服务（返回值非 NULL —— 哨兵 `0x690000E0` /
/// `0xcccccccc690000e0` / 一页 / 大区 都算）且哨兵那条路 Extension 已下发成功 ⇒ YES。
/// ★不比 size、不比期望、不要求 64MB★：闸门发的是 getpagesize 的小页 brk，
/// 64MB 的真区是 libjvm 建 VM 时自己发 brk 才向调试器要的（见 `A2LegacyJITGateOpen`）。
/// 成功一次即按进程缓存结论，不再重发 brk。
BOOL A2AMEJITVerifyJITHandshake(void);

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

/// 移植自 tree510 `JavaLauncher.m` L1384–L1544（`if (requiresDebugJITMapping) { … }` 整块），
/// ★判据（方案 A）= 握手完成★（老 Air 口径）：
///   1. 发 `brk #0x69`（安全网版本，无人服务返回 NULL 不致死），讨**一页**（getpagesize()；老 Air 同长）；
///   2. 分类（仅日志）：哨兵 / 无映射 / 偏小 / 只读 / 真指针（见 .m ④' 段的 `a2gate_classify`）；
///   3. 哨兵（0x690000E0 / 0xcccccccc690000e0 / 一页不可写）⇒ 下发
///      `UniversalJIT26Extension.js`（把 legacyCommands[0x69] 换成真建区）；有界 3 发 × 2s；
///   4. ★握手完成就放行★：哨兵已识别 + Extension 下发成功 + 至少一发 brk 被服务
///      ⇒ `JIT26SetDetachAfterFirstBr(!alwaysAttached)` + 清 EXC_MASK_BAD_ACCESS ⇒ `Open`；
///      只有「无人应答」或「哨兵但 Extension 发不出去」才不建 VM（`NoRegion` / `SentinelOnly`）。
///      ★region 的 size / 期望(默认 64MB) / 保护位只进日志，不参与判定★ ——
///      64MB 的真区由 libjvm 建 VM 时按 -XX:ReservedCodeCacheSize 自己发 brk 取；
///      拿不到时由 libjvm 自己报错，闸门不替它验收、也不拦。
///
/// ★调用方必须把它放在唯一建 VM 处（A2LaunchSession 的 createJVM 块）之前★：
/// 老 Air 的顺序就是「闰门 → 之后才建 JVM」，中间不许插别的启动动作。
A2LegacyJITGateOutcome A2LegacyJITGateOpen(NSString *_Nullable *_Nullable whyOut);

NS_ASSUME_NONNULL_END

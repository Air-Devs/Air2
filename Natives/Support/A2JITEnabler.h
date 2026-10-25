//
//  A2JITEnabler.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/Support —— ★启动前 JIT 使能：判据 → 申请 → 等待 → 回调★
// ----------------------------------------------------------------------------
//  单一职责：回答并解决一个问题 ——「本次进程**现在**能不能用 JIT；不能就把它拿到手」。
//  启动链只调本模块，不再各自拼 URL / 各自轮询 / 各自猜判据。
//
//  为什么需要它（真机事实，不是设想）：
//    · SideStore + StikDebug 环境里，点「启动游戏」时进程往往还没有 JIT；
//      没有 JIT 就建 VM ⇒ HotSpot 首帧取指 SIGBUS（直接闪退，无失败页）。
//    · 老 Air 的这套机制（DownloadViewController.m 的 invokeAfterJITEnabled:
//      + JavaLauncher.m 的使能器 URL 选择 + utils.m 的 AMEJIT*/JIT26* 判据）
//      是**唯一**在真机上被验证过不崩的组合；Air2 之前只有零碎补丁，导致
//      「判据不认 JIT → 跳转 → 使能器重拉 App → 再判据 → 再跳转」的死循环。
//
//  四条铁律（顺序即实现顺序，改动必须保持）：
//    ① **判据只有一个：老 Air（tree510）那一套**，实现落在
//       Natives/Support/A2LegacyJITGate（原样移植 isJITEnabled /
//       AMEJITVerifyWritableJITRegion / JIT26IsLikelyDebuggerKeepAttached /
//       JavaLauncher 的建 VM 前闰门）。本模块只负责「什么时候问、拿不到怎么申请」。
//       ★Air2 曾自创「放行优先四条」（entitlement / CS_DEBUGGED / verifiedRegion /
//       exec-probe 任一即放行）——真机证明它是错的（先死后放、放行后仍闪退）：
//         · Air2 那条 CS_DEBUGGED 读的是 0x100（= CS_HARD），老 Air 读 0x10000000；
//         · iOS 26+ 的 JIT 区是建 VM 时 libjvm 自己发 brk #0x69 才到手 ⇒ 建 VM 前
//           verifiedRegion 几乎永远为空，把「能力声明」当「已验证」就会放行后 SIGBUS。
//       这些判据已删除，不再有第二套判据参与启动决策。
//    ② **防死循环**：同一进程最多跳一次；被使能器重拉起来的进程（getppid()≠1）也算
//       「已跳过一次」⇒ 只做短等待、绝不再拉起使能器，跳转↔重拉 的无限循环由此断开。
//    ③ **不许闪退**：拿不到就回调 NO，由调用方出可读失败页；绝不带着「未就绪」
//       的状态去建 VM（建 VM 前的最后校验由 A2LegacyJITGateOpen 承担）。
//    ④ **顺序**：先弹「正在等待 JIT」→ 本次启动到此为止（调用方 return）→ 再 openURL
//       拉起使能器 → 才轮询。调换任意两步都会让用户「点一下就被踢走」或「弹窗看不见」。
//
//  分层：本模块属 Natives/Support（JIT 环境层），只依赖 A2JITEnvironment 的判据与
//  日志出口；不认识版本 / 账号 / 下载 / 启动链，也不替上层决定「失败页怎么写」。
//
//  ★为什么没有「用哪个使能器」的偏好键★：老 Air 的 debug.jit_enabler 有设置页
//  写入点，Air2 的设置页由既有 JIT 供给面板（A2JITExternalToolProvider）承担。
//  本模块若自带一个没人写的键，就是死配置 ⇒ 改为按「本机已安装能力」探测选择，
//  回退顺序写死在实现里（见 A2JITEnabler.m 的 a2jit_pick_tool 注释）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A2JITEnabler —— 启动前的 JIT 判据 + 申请 + 有界等待。
 *
 * 典型用法（启动链的 JIT 闸门；调用方在主线程）：
 * @code
 *   if ([A2JITEnabler isJITReadyNow]) {
 *       // 已就绪（内核级 entitlement / 已验证 JIT 区）⇒ 照旧往下启动，零额外副作用
 *   } else {
 *       [A2JITEnabler ensureJITThen:^(BOOL ok) {
 *           if (ok) { / * 重新进入启动链 * / } else { / * 出失败页，不建 VM * / }
 *       }];
 *       return;   // ★回调不在这条调用栈里发生★
 *   }
 * @endcode
 */
@interface A2JITEnabler : NSObject

/// 本进程**现在**能否安全建 VM（同步）。
/// ★判据只有一个来源★：老 Air（tree510）那套，见 Natives/Support/A2LegacyJITGate 的
/// `A2LegacyJITGateReadyNow()`（= AMEJITWaitReadyVerified：非镜像设备直接放行；
/// 镜像设备要求「调试器真在岗 + brk #0x69 真被服务」）。
/// 不通过时 NO，并给出可读原因（`lastFailureReason` / 日志里的 `ready=0(原因: …)`）。
+ (BOOL)isJITReadyNow;

/// 与 `isJITReadyNow` **同一判据**，另回传可读原因（供失败页 / 判据行 / 诊断）。
/// ★不要另写一份判定★：两者都直接转调 A2LegacyJITGateReadyNow。
+ (BOOL)isJITReadyNowWithReason:(NSString *_Nullable *_Nullable)whyOut;

/// 打一行区域验收快照（`[A2JIT] region=… size=… (X MB) expected=… enough=0|1 tag=…`）。
/// 启动链在建 VM 前 / 建 VM 返回后各打一次 —— 拿不到区**不是错误**
/// （iOS 26+ 的区由 libjvm 建 VM 时自己发 brk #0x69 取），本接口只如实报数、不拦路。
+ (void)logRegionSnapshot:(NSString *)tag;

/// ★建 VM 之前的唯一闰门（老 Air `JavaLauncher.m` L1384–L1544 原样移植）★
///
/// 语义（逐条对齐老 Air，不许在此加任何新判据）：
///   1. 非镜像设备（< iOS 26）⇒ 直接 YES（老 Air 的 `if (requiresDebugJITMapping)` 整块跳过）；
///   2. 发一发 `brk #0x69`（安全网版本，无人服务返回 NULL 不致死）：
///        · NULL                    ⇒ NO，`whyOut` 说明「JIT 调试器没有应答」；
///        · 非哨兵（真指针）        ⇒ NO，`whyOut` 说明「设备上是 legacy 脚本」；
///        · 哨兵 0x690000E0         ⇒ 继续；
///   3. 下发 `UniversalJIT26Extension.js`（把 legacyCommands[0x69] 换成真建区）
///      + `SetDetachAfterFirstBr(!A2JITAlwaysAttached)` + 清 EXC_MASK_BAD_ACCESS 异常端口；
///   4. YES ⇒ 调用方**此刻才允许**调 `JNI_CreateJavaVM`。
///
/// ★调用点只有一个★：A2LaunchSession 的 createJVM 块（唯一建 VM 处），必须在
/// `A2LaunchRunner launchWithPlanPath:` 之前。返回 NO 时**绝对不许建 VM**（否则首帧 SIGBUS）。
+ (BOOL)openLegacyGateBeforeVMBuild:(NSString *_Nullable *_Nullable)whyOut;

/// 入口：判据 → 申请（拉起使能器）→ 等待（≤120s）→ 回调。
///
/// ★回调契约★：
///   · 永远**异步**发生（主线程），不会在调用栈内同步回调 ⇒ 调用后请 return；
///   · 同一时刻只有一次申请在途：并发调用会挂到同一次等待上（不叠加、不二次跳转）；
///   · 返回 NO 表示「本次没拿到 JIT」——此时**绝不能**继续建 VM（会 SIGBUS）。
+ (void)ensureJITThen:(void (^_Nonnull)(BOOL ok))done
    NS_SWIFT_UNAVAILABLE("启动链内部接口");

/// 最近一次失败 / 超时的可读原因（成功或尚未跑过时为 nil）。
/// 供调用方拼失败页文案；★本模块不自己弹失败页★（分层：UI 归上层）。
+ (nullable NSString *)lastFailureReason;

@end

NS_ASSUME_NONNULL_END

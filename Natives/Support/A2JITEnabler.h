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
//    ① **判据是「放行优先」：下面四条任一成立即放行**（2026-10-25 真机修正）：
//       (a) 内核级 JIT entitlement（TrollStore / 越狱装机的 dynamic-codesigning /
//           com.apple.private.cs.debugger）—— 装机自带 JIT，直接放行；
//       (b) CS_DEBUGGED（有位调试器 attach 着本进程）—— 它会应答 brk #0x69，
//           **包括 libjvm 建 VM 时自己发的那一发**；
//       (c) verifiedRegion != NULL —— 本进程此前真拿到过调试器交付的、已映射且
//           max 含 EXECUTE 的区；
//       (d) 非镜像设备（< iOS 26）的匿名页执行式探针**真的跑过**（真 mmap + 写指令 + 执行）。
//       ★为什么不再要求 (c)★：iOS 26+ 的 JIT 区是**建 VM 时 libjvm 自己发 brk #0x69**
//       才由调试器交付的 ⇒ 建 VM 之前本进程永远不会有 region。把 (c) 当唯一判据 = 死锁
//       （真机症状：在 StikDebug 里开完 JIT 后启动不再往下走）。
//       ★但「凭 (b) 放行」≠「区域已验证」★：日志必须写清凭哪一条
//       （`ready=1(原因: debugger-attached)`），不许把 (b) 写成 (c)。
//       ★(getppid()≠1) 仍然不算就绪★：它只影响「要不要再跳一次」（见铁律 ②）。
//       四条都不成立才返回未就绪，并给出可读原因（不闪退）。
//    ② **防死循环**：同一进程最多跳一次；被使能器重拉起来的进程（getppid()≠1）也算
//       「已跳过一次」⇒ 只做短等待、绝不再拉起使能器，跳转↔重拉 的无限循环由此断开。
//    ③ **不许闪退**：拿不到就回调 NO，由调用方出可读失败页；绝不带着「四条都不成立」
//       的状态去建 VM。
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

/// 本进程**现在**能否安全建 VM（同步、有界：最坏一次区域尝试 ≈2.5s）。
/// 判据见头文件「四条铁律 ①」：**放行优先** —— entitlement / CS_DEBUGGED /
/// verifiedRegion / 非镜像设备的执行式探针，**任一成立即 YES**；
/// 四条都不成立才 NO，并给出可读原因（`lastFailureReason` / 日志里的 `ready=0(原因: …)`）。
+ (BOOL)isJITReadyNow;

/// 打一行区域验收快照（`[A2JIT] region=… size=… (X MB) expected=… enough=0|1 tag=…`）。
/// 启动链在建 VM 前 / 建 VM 返回后各打一次 —— 拿不到区**不是错误**
/// （iOS 26+ 的区由 libjvm 建 VM 时自己发 brk #0x69 取），本接口只如实报数、不拦路。
+ (void)logRegionSnapshot:(NSString *)tag;

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

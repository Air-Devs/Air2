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
//    ① **判据**只认「真能用」：entitlement(dynamic-codesigning / cs.debugger) 只是**能力声明**；
//       本机需要调试映射（iOS 26+）时，光有声明**不算就绪**，必须真的拿到一块已验证的
//       可写 JIT 区（brk #0x69 被调试器服务）。只有 CS_DEBUGGED（调试器已 attach，例外
//       端口在岗）与 getppid()≠1 才可以直接认 —— 这两个是「外部注入正在进行」的事实，
//       不是资格声明。
//    ② **防死循环**：被调试器拉起（getppid() != 1）或已拿到 JIT 区 ⇒ 绝不再跳转；
//       同一进程最多跳一次（第二次起只做短等待）。跳转↔重拉 的无限循环由此断开。
//    ③ **不许闪退**：拿不到就回调 NO，由调用方出可读失败页；绝不带着无 JIT 的
//       进程继续去建 VM。
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
 *       // 已就绪（含「被调试器拉起」）⇒ 照旧往下启动，零额外副作用
 *   } else {
 *       [A2JITEnabler ensureJITThen:^(BOOL ok) {
 *           if (ok) { / * 重新进入启动链 * / } else { / * 出失败页，不建 VM * / }
 *       }];
 *       return;   // ★回调不在这条调用栈里发生★
 *   }
 * @endcode
 */
@interface A2JITEnabler : NSObject

/// 本进程**现在**能否安全建 VM（同步、有界：最坏一次区域验证 ≈2.5s）。
/// 判据见头文件「四条铁律 ①」；被调试器拉起 / 调试器已 attach 时直接 YES（铁律 ②）。
+ (BOOL)isJITReadyNow;

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

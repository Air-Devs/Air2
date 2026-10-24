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
//    ① **判据只认真凭据**：(a) 内核级 JIT entitlement（TrollStore / 越狱装机的
//       dynamic-codesigning / com.apple.private.cs.debugger）—— 装机自带 JIT，直接放行；
//       (b) 真凭据：镜像设备（iOS 26+）必须 verifiedRegion != NULL（真的发过 brk #0x69 且
//       调试器真交付了一块已映射、max 含 EXECUTE 的区）；非镜像设备（< iOS 26）必须
//       执行式探针真的跑过（真 mmap+写指令+exec，与前者同性质）。
//       ★CS_DEBUGGED（调试器已 attach / 例外端口在岗）与 getppid()≠1 都**不再**是就绪
//       依据★：它们是「别人的状态」，不证明本进程真能执行自产代码，曾据此放行 ⇒
//       没拿到区也建 VM ⇒ HotSpot 首帧取指 SIGBUS（真机停在「③ 建 VM 开始」）。
//       拿不到凭据 ⇒ 一律返回未就绪，走等待 / 申请流程。
//    ② **防死循环**：同一进程最多跳一次；被使能器重拉起来的进程（getppid()≠1）也算
//       「已跳过一次」⇒ 只做短等待、绝不再拉起使能器，跳转↔重拉 的无限循环由此断开。
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

/// 本进程**现在**能否安全建 VM（同步、有界：最坏一次区域验证 ≈2.5s）。
/// 判据见头文件「四条铁律 ①」：**只认**内核级 JIT entitlement 或已验证的 JIT 区
/// （verifiedRegion != NULL）；CS_DEBUGGED / 被使能器拉起 一律**不**算就绪。
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

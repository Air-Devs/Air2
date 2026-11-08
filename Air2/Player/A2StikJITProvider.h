//
//  A2StikJITProvider.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 【内建 JIT】提供方：不依赖外部 StikDebug App，自己开 JIT。
// ----------------------------------------------------------------------------
//  三个动作（顺序即实现顺序，见 .m 里 `+enableBuiltInJITWithBudget:reason:`）：
//    ① 读取配对文件（A2JITPairingFileStore 的导入结果 / 候选路径）
//    ② 解析 RSD 端点（Bonjour `_remotepairing._tcp` ⇒ host + port）
//    ③ 让 debugserver attach 本进程并跑 JIT 脚本（StikJIT.framework → getpid()）
//
//  ★① 的隧道在哪★：TLS-PSK 隧道与 RSD 服务调用**由 StikJIT.framework 内部完成**
//  （它自带 Rust rppairing）。本提供方只负责「把配对文件 + 可达端点交给引擎」，
//  不重写隧道（本仓 a2_tlspsk_* 是自研链路，见 docs/ONDEVICE-PAIR.md，
//  两条路互不替代）。
//
//  ★谁调它★
//    · `+enableBuiltInJITWithBudget:reason:` ← Natives/Support/A2JITEnabler.m 的内建钩子
//      （钩子由 Air2/App/A2AppDelegate.m 注册；A2JITEnabler 属 Natives 层，不认识本类）。
//    · `+isAvailable` / `+frameworkVersion` ← Air2/UI/Screens/Settings/A2JITSettings.m
//      的「JIT 启动器」行（显示「内建（StikJIT x.y.z）」与不可用原因）。
//
//  ★不是万能★：真机上 RSD 端点通常要靠 LocalDevVPN 之类把本机 RSD 暴露到回环；
//  发现不到端点 ⇒ 如实失败并给出可读原因（不猜端口、不假装成功）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2StikJITProvider : NSObject

/// 本机能不能用内建引擎：iOS ≥ 17.4（框架 minos）+ 包内有 Frameworks/StikJIT.framework/StikJIT。
/// ★只判能力，不判是否已配对★。
+ (BOOL)isAvailable;

/// 不可用的可读原因（availability=YES 时为 nil）。
+ (nullable NSString *)unavailableReason;

/// 框架版本（读 Frameworks/StikJIT.framework/Info.plist 的 CFBundleShortVersionString）。
+ (nullable NSString *)frameworkVersion;

/// 当前已导入的配对文件路径（无则 nil）。★唯一来源 = A2JITPairingFileStore★。
+ (nullable NSString *)pairingFilePath;

/// 走内建引擎为**本进程**开 JIT。
///
/// ★阻塞★：RSD 握手 + debugserver attach + 跑完脚本，真机可达数十秒 ⇒ 调用方必须在
/// 后台队列/线程调用（A2JITEnabler 用 dispatch 到全局队列）。
///
/// @param budget  端点发现的时间上限（秒；内部再夹到 8s，别把预算都花在 Bonjour 上）。
/// @param whyOut  失败原因（成功时 nil）。
/// @return YES = 引擎返回成功（★不等于进程已经有 JIT★ —— 之后由 A2LegacyJITGate 复验）。
+ (BOOL)enableBuiltInJITWithBudget:(NSTimeInterval)budget
                            reason:(NSString *_Nullable *_Nullable)whyOut;

/// 下载并挂载开发者镜像（DDI）：交给扩展进程里的 StikJIT.prepareDevice 完成。
/// 与 enable 走同一条 appex 通道，只是 operation=prepare。
+ (BOOL)prepareDDIWithBudget:(NSTimeInterval)budget
                       reason:(NSString *_Nullable *_Nullable)whyOut;

@end

NS_ASSUME_NONNULL_END

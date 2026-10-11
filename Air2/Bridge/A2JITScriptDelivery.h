//
//  A2JITScriptDelivery.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Bridge —— ★启动链步骤①「下发自包含 JIT 脚本」的唯一实现★。
//
//  为什么在 Bridge：分层 App → UI → Player → Core → Bridge → Natives；
//  ★Bridge 是唯一与 Natives 相邻的层★，所以「调用 Natives/Support 的
//  a2_jit_send_script_safe（brk #0xf00d cmd=2）」只能发生在这里。
//  Player 的 A2LaunchChain 只表达「①→②→③ 的顺序」，具体做法由本类提供。
//
//  ★一步只做一件事★：定位随包脚本（AmethystJIT69.js）→ 交给 Natives 的
//  「带 SIGTRAP 安全网的下发原语」。★不判据、不建 VM、不改任何既有语义★。
//
//  与 [JIT-ORDER] 的关系：脚本必须在任何 brk #0x69 探测【之前】下发，
//  否则 base 脚本对传统 0x69 只回 legacy 哨兵 0xE0000069（死锁）。
//  故本类被 A2LaunchChain 放在步骤①（探测之前），且★失败不拦路★。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 下发失败分类（放进 NSError.code；★不参与「是否继续」的判定★ —— ① 失败不拦路）。
typedef NS_ENUM(NSInteger, A2JITScriptDeliveryFailure) {
    A2JITScriptDeliveryFailureNone = 0,      ///< 成功
    A2JITScriptDeliveryFailureFileMissing,   ///< 随包脚本找不到
    A2JITScriptDeliveryFailureReadFailed,    ///< 读到空 / 读失败
    A2JITScriptDeliveryFailureSendFailed,    ///< brk #0xf00d 未被服务（无调试器 / 无脚本引擎）
};

/// 自包含 JIT 脚本的随包名（与 `Assets/` 下同名；由 scripts/gen_xcodeproj.py 收集进包）。
FOUNDATION_EXPORT NSString *const A2JITScriptFileName;

/// ① 下发自包含 JIT 脚本（阻塞；调用方须在后台队列）。
@interface A2JITScriptDelivery : NSObject

+ (BOOL)deliverSelfContainedScriptWithError:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

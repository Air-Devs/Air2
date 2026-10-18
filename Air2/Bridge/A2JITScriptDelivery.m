//
//  A2JITScriptDelivery.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  ★全仓唯一调用 a2_jit_send_script_safe 的地方★（Bridge → Natives 是允许方向）。
//  单测有源码级断言守着这一点（tests/JIT/jit_logic_tests.m §⑱）。
//

#import "A2JITScriptDelivery.h"

#import "A2Log.h"
// Bridge → Natives 的唯一跨界：头搜索路径由 scripts/gen_xcodeproj.py 的
// NATIVES_INCLUDE_DIRS 提供（含 $(SRCROOT)/Natives/Support）。
#import "A2JITEnvironment.h"    // a2_jit_send_script_safe（带 SIGTRAP 安全网的叶子原语）

NSString *const A2JITScriptFileName = @"Air2JIT69.js";

static NSString *const A2JITScriptDeliveryErrorDomain = @"A2JITScriptDeliveryError";

@implementation A2JITScriptDelivery

/// 随包脚本路径（探测面宽、返回值窄：找不到就返回 nil，不猜）。
+ (nullable NSString *)scriptPath {
    NSBundle *b = NSBundle.mainBundle;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    // ① 标准资源查找（collect_resources() 把 Assets/ 下的散落资源平铺进包根）
    NSString *res = [b pathForResource:@"Air2JIT69" ofType:@"js"];
    if (res.length) [candidates addObject:res];
    // ② 包根（不依赖资源注册）
    [candidates addObject:[b.bundlePath stringByAppendingPathComponent:A2JITScriptFileName]];
    // ③ Assets/ 子目录布局（若将来改成目录引用）
    [candidates addObject:[[b.bundlePath stringByAppendingPathComponent:@"Assets"]
                           stringByAppendingPathComponent:A2JITScriptFileName]];
    for (NSString *c in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:c]) {
            return c;
        }
    }
    return nil;
}

+ (BOOL)deliverSelfContainedScriptWithError:(NSError **)error {
    // ★2026-10-18 用户拍板★ 默认★不下发随包脚本★：JIT 环境交给 StikDebug 的附加(attach)。
    //   要恢复随包脚本：偏好键 A2DeliverJITScript = YES。
    id a2deliverVal = [NSUserDefaults.standardUserDefaults objectForKey:@"A2DeliverJITScript"];
    BOOL a2deliver = (a2deliverVal == nil) ? NO : [NSUserDefaults.standardUserDefaults boolForKey:@"A2DeliverJITScript"];
    if (!a2deliver) {
        [A2Log criterion:@"[A2-CHAIN] ① 下发 JIT 脚本 = 关（键 A2DeliverJITScript 未设 ⇒ 用 StikDebug 的附加）"];
        return YES;
    }
    NSString *path = [self scriptPath];
    if (path.length == 0) {
        [A2Log log:@"[A2-CHAIN] ① 下发 JIT 脚本：随包脚本 %@ 未找到（不拦路；② 探测会兜底）",
         A2JITScriptFileName];
        if (error) {
            *error = [NSError errorWithDomain:A2JITScriptDeliveryErrorDomain
                                         code:A2JITScriptDeliveryFailureFileMissing
                                     userInfo:@{ NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"随包 JIT 脚本 %@ 未找到", A2JITScriptFileName] }];
        }
        return NO;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        [A2Log log:@"[A2-CHAIN] ① 下发 JIT 脚本：读 %@ 为空/失败（不拦路）", path.lastPathComponent];
        if (error) {
            *error = [NSError errorWithDomain:A2JITScriptDeliveryErrorDomain
                                         code:A2JITScriptDeliveryFailureReadFailed
                                     userInfo:@{ NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"读取 JIT 脚本失败：%@", path.lastPathComponent] }];
        }
        return NO;
    }

    // ★唯一的一跳★：交给 Natives 的叶子原语（brk #0xf00d cmd=2，带 SIGTRAP 安全网 ⇒ 无人应答不致死）。
    BOOL ok = a2_jit_send_script_safe((const char *)data.bytes, (size_t)data.length);
    [A2Log log:@"[A2-CHAIN] ① 下发 JIT 脚本 %@（%lu B）ok=%d%@",
     path.lastPathComponent, (unsigned long)data.length, (int)ok,
     ok ? @"" : @"（脚本引擎未应答 —— 无调试器时属预期，不拦路）"];

    if (!ok && error) {
        *error = [NSError errorWithDomain:A2JITScriptDeliveryErrorDomain
                                     code:A2JITScriptDeliveryFailureSendFailed
                                 userInfo:@{ NSLocalizedDescriptionKey:
        @"brk #0xf00d（下发 JIT 脚本）未被服务 —— 无调试器应答时属预期" }];
    }
    return ok;
}

@end

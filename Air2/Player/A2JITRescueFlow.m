// ============================================================================
//  Air2/Player/A2JITRescueFlow.m
//  Air2 —— ★启动前 JIT 补齐流程★
// ----------------------------------------------------------------------------
//  用户点「启动游戏」时：
//    ① 先判 JIT 是否可用（内核级 / 已连调试器 / 区域已验证）
//    ② 不可用 ⇒ 带着**我们自己的脚本**跳 StikDebug（URL scheme），
//       在 URL 里带上 bundle_id / 脚本路径 / 回跳标记
//    ③ 用户从 StikDebug 回来（App 重新 active）⇒ 等 2 秒再复查
//    ④ 复查通过 ⇒ 继续原来的启动；仍失败 ⇒ 给可读提示，不静默重试
//
//  说明：StikDebug 的 URL 约定按公开行为使用（enable-jit + 参数），
//        不做任何私有 hook；解析失败时退化为"唤起工具让用户手动 enable"。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "A2JITRescueFlow.h"
#import "A2JITEnvironment.h"
#import "A2Log.h"

static void (^gPendingCompletion)(BOOL) = nil;
static id gObserver = nil;

@implementation A2JITRescueFlow

+ (BOOL)jitReadyNow {
    // ★判据对齐老 Air★ 三层任一成立即视为已有 JIT：
    //   ① 内核级 entitlement(dynamic-codesigning / cs.debugger) —— TrollStore/越狱
    //   ② CS_DEBUGGED（调试器此刻还连着）
    //   ③ ★真的发一次 brk 拿到可执行区★
    //      Stik 的流程是「给完区就 detach」，detach 后 CS_DEBUGGED 位会掉，
    //      但 JIT 区依然可用 ⇒ 只看 ①② 会误判“没 JIT”而重复跳转（真机症状）。
    if (a2_jit_has_kernel_level()) return YES;

    extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
    uint32_t flags = 0;
    if (csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x00000100u) != 0) return YES;

    NSString *why = nil;
    BOOL verified = [A2JITEnvironment ensureVerifiedWithinBudget:2.0 reason:&why];
    NSLog(@"[A2-JIT-RESCUE] 区域验证: %d（%@）", verified, why ?: @"");
    return verified;
}

/// 组一个带参数的 StikDebug URL（scheme 用 stikdebug，失败再试 stikjit）
+ (NSURL *)rescueURLWithScript:(NSString *)scriptPath {
    // ★参数名照老 Air 的真实格式★（我们之前写成 bundle_id/script/return，StikDebug 不认）
    //   stikdebug://enable-jit?bundle-id=<id>&pid=<pid>&script-name=universal.js
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"dev.airdevs.air2";
    NSString *scriptName = scriptPath.lastPathComponent.length ? scriptPath.lastPathComponent : @"universal.js";
    NSString *s = [NSString stringWithFormat:
                   @"stikdebug://enable-jit?bundle-id=%@&pid=%d&script-name=%@",
                   [bundleID stringByAddingPercentEncodingWithAllowedCharacters:
                    NSCharacterSet.URLQueryAllowedCharacterSet],
                   (int)getpid(),
                   [scriptName stringByAddingPercentEncodingWithAllowedCharacters:
                    NSCharacterSet.URLQueryAllowedCharacterSet]];
    return [NSURL URLWithString:s];
}

+ (void)beginRescueWithScript:(NSString *)scriptPath
                   completion:(void (^)(BOOL ok))completion {
    gPendingCompletion = [completion copy];

    // 监听"回到前台"——从 StikDebug 回来就是这一次 active
    if (gObserver != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:gObserver];
        gObserver = nil;
    }
    gObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                               object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *n) {
        [A2Log criterion:@"[A2-JIT-RESCUE] 已回到前台 ⇒ 2s 后复查 JIT"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL ok = [A2JITRescueFlow jitReadyNow];
            [A2Log criterion:@"[A2-JIT-RESCUE] 复查结果：%@", ok ? @"JIT 可用" : @"仍不可用"];
            if (gObserver != nil) {
                [NSNotificationCenter.defaultCenter removeObserver:gObserver];
                gObserver = nil;
            }
            void (^cb)(BOOL) = gPendingCompletion;
            gPendingCompletion = nil;
            if (cb) cb(ok);
        });
    }];

    // ★TrollStore 优先★ 老 Air 的做法：apple-magnifier://enable-jit?bundle-id=<id>
    //   （TrollStore 自己接管这个 scheme，给指定 bundle 开 JIT）
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"dev.airdevs.air2";
    NSString *magnifier = [NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@",
                           [bid stringByAddingPercentEncodingWithAllowedCharacters:
                            NSCharacterSet.URLQueryAllowedCharacterSet]];
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:magnifier]]) {
        [A2Log criterion:@"[A2-JIT-RESCUE] 拉起 TrollStore: %@", magnifier];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:magnifier]
                                         options:@{}
                               completionHandler:^(BOOL ok) {
            if (!ok) {
                [A2Log criterion:@"[A2-JIT-RESCUE] apple-magnifier 打不开 ⇒ 回退 StikDebug"];
            }
        }];
        return;
    }

    NSURL *url = [self rescueURLWithScript:scriptPath];
    [A2Log criterion:@"[A2-JIT-RESCUE] 拉起外部工具：%@", url.absoluteString];
    [UIApplication.sharedApplication openURL:url
                                     options:@{}
                           completionHandler:^(BOOL success) {
        if (success) return;
        [A2Log criterion:@"[A2-JIT-RESCUE] stikdebug 打不开，试 stikjit"];
        NSString *alt = [url.absoluteString stringByReplacingOccurrencesOfString:@"stikdebug://" withString:@"stikjit://"];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:alt]
                                         options:@{}
                               completionHandler:^(BOOL ok2) {
            if (!ok2) {
                [A2Log criterion:@"[A2-JIT-RESCUE] 两个 scheme 都打不开（StikDebug 未安装？）"];
                void (^cb)(BOOL) = gPendingCompletion;
                gPendingCompletion = nil;
                if (cb) cb(NO);
            }
        }];
    }];
}

@end

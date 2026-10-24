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
    // ★严格口径★ 只有「内核级 entitlement」或「调试器已连(CS_DEBUGGED)」才算拿到 JIT。
    //   不能用 ensureVerifiedWithinBudget —— 它在无 CS_DEBUGGED 时按“不拦路”返回 YES，
    //   那样救援永远不会触发。
    if (a2_jit_has_kernel_level()) return YES;

    extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
    uint32_t flags = 0;
    if (csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags)) == 0) {
        if ((flags & 0x00000100u) != 0) return YES;   // CS_DEBUGGED
    }
    return NO;
}

/// 组一个带参数的 StikDebug URL（scheme 用 stikdebug，失败再试 stikjit）
+ (NSURL *)rescueURLWithScript:(NSString *)scriptPath {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"dev.airdevs.air2";
    NSString *script = scriptPath ?: @"";
    NSString *tmpl = [NSString stringWithFormat:
                      @"stikdebug://enable-jit?bundle_id=%@&script=%@&return=%@",
                      [bundleID stringByAddingPercentEncodingWithAllowedCharacters:
                       NSCharacterSet.URLQueryAllowedCharacterSet],
                      [script stringByAddingPercentEncodingWithAllowedCharacters:
                       NSCharacterSet.URLQueryAllowedCharacterSet],
                      @"air2"];
    return [NSURL URLWithString:tmpl];
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

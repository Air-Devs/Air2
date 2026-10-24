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
static UIAlertController *gWaitAlert = nil;

// ★“等待 JIT”弹窗★（老 Air 也有这个，不然用户不知道 App 在等什么）
static void a2_jit_wait_alert_show(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ a2_jit_wait_alert_show(); });
        return;
    }
    UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (top.presentedViewController != nil) top = top.presentedViewController;
    if (top == nil || gWaitAlert != nil) return;

    gWaitAlert = [UIAlertController alertControllerWithTitle:@"正在等待 JIT"
                                                     message:@"已打开 JIT 使能器，正在等待授权…\n请保持在 Air2 内，授权完成后会自动开始启动游戏。"
                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(gWaitAlert) weakAlert = gWaitAlert;
    [gWaitAlert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                   style:UIAlertActionStyleCancel
                                                 handler:^(UIAlertAction *a) {
        void (^cb)(BOOL) = gPendingCompletion;
        gPendingCompletion = nil;
        if (cb) cb(NO);
        (void)weakAlert;
    }]];
    [top presentViewController:gWaitAlert animated:YES completion:nil];
}

static void a2_jit_wait_alert_hide(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ a2_jit_wait_alert_hide(); });
        return;
    }
    if (gWaitAlert != nil) {
        [gWaitAlert dismissViewControllerAnimated:YES completion:nil];
        gWaitAlert = nil;
    }
}
static id gObserver = nil;

@implementation A2JITRescueFlow

+ (BOOL)jitReadyNow {
    // ★判据（2026-10-24 两份真机日志定案）★
    //   只认两件事：① 内核级 entitlement（TrollStore 给的真权限）
    //              ② 真的发一次 brk 拿到可执行区（有调试器且真的交付了）
    //   ★不再把 CS_DEBUGGED 单独当可用★ —— 日志 old-5 就是 debugged=1 但区没给，
    //   放行后建 VM 直接崩。
    if (a2_jit_has_kernel_level()) return YES;

    NSString *why = nil;
    BOOL verified = [A2JITEnvironment ensureVerifiedWithinBudget:2.5 reason:&why];
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
    // ★等待 JIT（老 Air 的 invokeAfterJITEnabled 口径）★
    //   回来后不能只查一次：StikDebug/TrollStore 给权限有延迟，且调试器可能稍后才 attach。
    //   每 0.5s 查一次，最多 25s；期间不建 VM（没 JIT 建 VM 会直接崩）。
    // ★后台任务★ 老 Air 用 beginBackgroundTask 保证切到使能器再回来时等待不被打断
    __block UIBackgroundTaskIdentifier bgTask =
        [UIApplication.sharedApplication beginBackgroundTaskWithName:@"a2-jit-wait" expirationHandler:^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    }];

    a2_jit_wait_alert_show();
    __block NSInteger waited = 0;
    void (^poll)(void) = ^{
        if (gPendingCompletion == nil) return;
        waited++;
        if ([A2JITRescueFlow jitReadyNow]) {
            [A2Log criterion:@"[A2-JIT-RESCUE] 轮询 %ld 次后拿到 JIT ⇒ 继续启动", (long)waited];
            if (gObserver != nil) { [NSNotificationCenter.defaultCenter removeObserver:gObserver]; gObserver = nil; }
            void (^cb)(BOOL) = gPendingCompletion; gPendingCompletion = nil;
            a2_jit_wait_alert_hide();
            if (cb) cb(YES);
            return;
        }
        if (waited >= 240) {   // 120s（对齐老 Air）
            [A2Log criterion:@"[A2-JIT-RESCUE] 等待 120s 仍未拿到 JIT ⇒ 交给用户"];
            if (gObserver != nil) { [NSNotificationCenter.defaultCenter removeObserver:gObserver]; gObserver = nil; }
            void (^cb)(BOOL) = gPendingCompletion; gPendingCompletion = nil;
            a2_jit_wait_alert_hide();
            if (cb) cb(NO);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), poll);
    };

    gObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                               object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *n) {
        [A2Log criterion:@"[A2-JIT-RESCUE] 已回到前台 ⇒ 开始轮询等待 JIT"];
        poll();
    }];

    // ★SideStore/Stik 优先(用户实际环境)★
    //   ① stikjit://     —— 带 JIT 重新拉起本 App（SideStore 的 JIT 就是这么给的）
    //   ② stikdebug://enable-jit?...&pid=...  —— 直接让 StikDebug 给本进程开 JIT
    //   ③ apple-magnifier://enable-jit  —— 只有 TrollStore 装的环境才有意义
    NSString *bid0 = NSBundle.mainBundle.bundleIdentifier ?: @"dev.airdevs.air2";
    NSString *stikjit = [NSString stringWithFormat:@"stikjit://enableJIT?bundleId=%@", bid0];
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:stikjit]]) {
        [A2Log criterion:@"[A2-JIT-RESCUE] 拉起 StikDebug(stikjit): %@", stikjit];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:stikjit] options:@{} completionHandler:nil];
        return;
    }

    NSString *magnifier = [NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@",
                           [bid0 stringByAddingPercentEncodingWithAllowedCharacters:
                            NSCharacterSet.URLQueryAllowedCharacterSet]];
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:magnifier]]
        && ![UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"stikdebug://enable-jit"]]) {
        [A2Log criterion:@"[A2-JIT-RESCUE] 拉起 TrollStore: %@", magnifier];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:magnifier] options:@{} completionHandler:nil];
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

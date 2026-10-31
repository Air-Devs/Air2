//
//  A2PluginLaunchChainConfirm.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★只做弹窗交互★：触发条件在 `A2PluginLaunchChainRisk`（Core），
//  调用时机在 `A2PluginInstaller`（闸门），本类不判「要不要弹」。
//

#import "A2PluginLaunchChainConfirm.h"

#import "A2Log.h"
#import "A2PluginLaunchChainRisk.h"   // 判据集合 → 人话名单（文案不在本文件另抄一份）

/// ★免责确认的次数★：用户明令 10 次，每次都要完整重读（不做「已同意」缓存）。
static const NSInteger A2PluginLaunchChainConfirmTimes = 10;

/// 在「本次确认窗收起之后」执行 next。
///
/// 为什么不能直接接着 present 下一个：点按钮的那一刻本窗正在收起，
/// `presentedViewController` 还没清空 —— 此时 present 会被 UIKit 拒（新窗静默不出现
/// ⇒ 用户以为卡住、确认门形同虚设）。
/// 做法：收起动画进行中（action 回调里必然如此）⇒ 借过渡协调者的 completion；
/// 拿不到协调者（无动画 / 已收起）⇒ 下一个主队列轮次。★两条路都不用 sleep★。
static void A2PluginRunAfterAlertDismissal(UIAlertController *alert, dispatch_block_t next) {
    id<UIViewControllerTransitionCoordinator> coordinator = alert.transitionCoordinator;
    if (coordinator != nil) {
        [coordinator animateAlongsideTransition:nil
                                     completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            next();
        }];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), next);
}

/// 唯一的正文拼装处：
///   第一行 = 哪个插件 + 它申请了哪些会改启动链的权限；
///   其后每次都是**完整的**免责声明（不写「同上」—— 每次都得能独立读懂）；
///   第 10 次追加一句后果承担。
static NSString *A2PluginLaunchChainMessage(NSInteger step,
                                            NSString *pluginName,
                                            NSString *permissionNames) {
    NSMutableString *message = [NSMutableString stringWithFormat:
        @"插件 %@ 申请了会修改启动链的权限：%@\n", pluginName, permissionNames];
    [message appendString:@"启动链被插件改动后，如果游戏启动失败、黑屏、闪退或存档损坏，"
                           @"那不是启动器的问题。"];
    if (step >= A2PluginLaunchChainConfirmTimes) {
        [message appendString:@"\n继续即表示你已知晓并自行承担后果。"];
    }
    return message;
}

/// 插件展示名：manifest.name 优先，空则回退到 pluginId（不显示空串）。
static NSString *A2PluginLaunchChainPluginName(A2PluginManifest *manifest) {
    NSString *name = manifest.name;
    if (name.length > 0) return name;
    NSString *pluginId = manifest.pluginId;
    return pluginId.length > 0 ? pluginId : @"（未命名插件）";
}

/// 弹窗宿主：给定的控制器 → 沿 presentedViewController 逐层下钻到最前面。
/// 给定 nil 时返回 nil（调用方按「呈现不了」处理，★不许静默当成已同意★）。
static UIViewController *A2PluginLaunchChainTopFrom(UIViewController *presenter) {
    UIViewController *top = presenter;
    while (top.presentedViewController != nil) top = top.presentedViewController;
    return top;
}

/// 逐次推进（只在本文件内调用，不对外暴露）。
@interface A2PluginLaunchChainConfirm ()
+ (void)a2_presentStep:(NSInteger)step
              manifest:(A2PluginManifest *)manifest
           permissions:(NSArray<NSString *> *)permissions
             presenter:(UIViewController *)presenter
            completion:(nullable A2PluginLaunchChainConfirmResult)completion;
@end

@implementation A2PluginLaunchChainConfirm

#pragma mark - 异步：逐次弹 10 次

+ (void)presentForManifest:(A2PluginManifest *)manifest
               permissions:(NSArray<NSString *> *)permissions
                      from:(UIViewController *)presenter
                completion:(nullable A2PluginLaunchChainConfirmResult)completion {
    // 没命中判据 ⇒ 不打扰用户（调用方按同一判据决定要不要进来，这里只是兜底）。
    if (permissions.count == 0) {
        if (completion) completion(YES);
        return;
    }
    [self a2_presentStep:1
                manifest:manifest
             permissions:permissions
               presenter:presenter
              completion:completion];
}

/// 弹第 step 次（1 起）。★递归只发生在主线程、且只由用户点击驱动★，不叠、不并行。
+ (void)a2_presentStep:(NSInteger)step
              manifest:(A2PluginManifest *)manifest
           permissions:(NSArray<NSString *> *)permissions
             presenter:(UIViewController *)presenter
            completion:(nullable A2PluginLaunchChainConfirmResult)completion {
    NSString *pluginId = manifest.pluginId ?: @"";
    NSString *permissionList = [permissions componentsJoinedByString:@","];

    NSString *title = [NSString stringWithFormat:@"修改启动链的插件（%ld/%ld）",
                       (long)step, (long)A2PluginLaunchChainConfirmTimes];
    NSString *message = A2PluginLaunchChainMessage(step,
                                                   A2PluginLaunchChainPluginName(manifest),
                                                   A2PluginLaunchChainPermissionNames(permissions));
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    // ★判据行★：一次一行 —— 真机日志上能数出「弹到第几次、哪个插件、哪几项权限」。
    [A2Log log:@"[A2-PLUGIN] experimental-confirm %ld/%ld plugin=%@ permissions=%@",
     (long)step, (long)A2PluginLaunchChainConfirmTimes, pluginId, permissionList];

    // 只认第一次点击：同一步被回调两次时不会把下一步弹两遍（叠窗 = 用户莫名要点更多次）。
    __block BOOL answered = NO;
    __weak UIAlertController *weakAlert = alert;   // 动作块被弹窗持有 ⇒ 只弱引用，避免自持有
    void (^settle)(BOOL) = ^(BOOL proceed) {
        if (answered) return;
        answered = YES;
        if (!proceed) {
            [A2Log log:@"[A2-PLUGIN] 用户取消（第 %ld 次）⇒ 安装终止（不写 registry）", (long)step];
            if (completion) completion(NO);
            return;
        }
        if (step >= A2PluginLaunchChainConfirmTimes) {
            [A2Log log:@"[A2-PLUGIN] %ld 次免责确认全部通过 ⇒ 继续安装 plugin=%@",
             (long)A2PluginLaunchChainConfirmTimes, pluginId];
            if (completion) completion(YES);
            return;
        }
        A2PluginRunAfterAlertDismissal(weakAlert, ^{
            [A2PluginLaunchChainConfirm a2_presentStep:step + 1
                                              manifest:manifest
                                           permissions:permissions
                                             presenter:presenter
                                            completion:completion];
        });
    };

    // ★按钮顺序 = 位置★：先加的「取消」在左，后加的「继续」在右（第 10 次换成明确表态的文案）。
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *action) { settle(NO); }]];
    NSString *continueTitle = (step >= A2PluginLaunchChainConfirmTimes)
        ? @"我已知晓，安装"
        : [NSString stringWithFormat:@"继续（%ld/%ld）", (long)step, (long)A2PluginLaunchChainConfirmTimes];
    [alert addAction:[UIAlertAction actionWithTitle:continueTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) { settle(YES); }]];

    UIViewController *host = A2PluginLaunchChainTopFrom(presenter);
    if (host == nil) {
        // ★呈现不了就不放行★：替用户「默认同意」比多弹一次更糟。
        [A2Log log:@"[A2-PLUGIN] 无法呈现免责确认窗（没有可用的宿主控制器）⇒ 按取消处理"];
        if (completion) completion(NO);
        return;
    }
    [host presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 同步：给安装器闸门用

+ (BOOL)confirmSynchronouslyForManifest:(A2PluginManifest *)manifest
                            permissions:(NSArray<NSString *> *)permissions
                                   from:(UIViewController *)presenter {
    if (permissions.count == 0) return YES;
    // ★拒绝在主线程阻塞★：10 次弹窗要主线程跑，主线程在这里等自己 = 死锁。
    //   宁可拒装（用户重试一次即可），也不要把界面冻死 —— 冻死的确认门比没有更糟。
    if (NSThread.isMainThread) {
        [A2Log log:@"[A2-PLUGIN] 免责确认的同步版在主线程被调用 ⇒ 直接按取消处理"
                       @"（安装必须放到非主线程）plugin=%@", manifest.pluginId ?: @""];
        return NO;
    }

    __block BOOL proceed = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentForManifest:manifest
                     permissions:permissions
                            from:presenter
                      completion:^(BOOL ok) {
            proceed = ok;
            dispatch_semaphore_signal(semaphore);
        }];
    });
    // 不设超时：用户可能把手机放下（10 次点击本来就慢），这里等他点完或被取消。
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return proceed;
}

@end

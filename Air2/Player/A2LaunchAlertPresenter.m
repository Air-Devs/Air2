//
//  A2LaunchAlertPresenter.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★只做弹窗交互，判据与取值都不在本文件★。
//

#import "A2LaunchAlertPresenter.h"

#import "A2RendererCatalog.h"   // Core/Renderer —— 「是不是实验性启动链」的唯一判据
#import "A2Log.h"

/// 私有方法：10 次确认的逐级推进（只在本文件内调用，不对外暴露）。
@interface A2LaunchAlertPresenter ()
+ (void)a2_presentConsentStep:(NSInteger)step
                   identifier:(NSString *)identifier
                 rendererName:(NSString *)rendererName
                   completion:(void (^)(BOOL proceed))completion;
@end

/// ★免责确认的次数★：用户明令 10 次，且每次都完整重读（不做「已同意」缓存）。
static const NSInteger A2ExperimentalChainConfirmTimes = 10;

/// 在「本次确认窗收起之后」执行 next。
///
/// 为什么不能直接接着 present 下一个：
///   点按钮的那一刻本窗正在收起，`presentedViewController` 还没清空 —— 此时直接
///   present 会被 UIKit 拒（新窗静默不出现 ⇒ 用户以为卡住、确认门形同虚设）。
/// 做法：
///   · 收起动画进行中（action 回调里必然如此）⇒ 借过渡协调者的 completion，动画一结束就弹下一个；
///   · 拿不到协调者（无动画 / 已收起）⇒ 下一个主队列轮次执行。
/// ★两条路都不用固定延时的 sleep★（延时既不可靠也白等）。
static void A2RunAfterAlertDismissal(UIAlertController *alert, dispatch_block_t next) {
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

/// 唯一的正文拼装处：第一行 = 用的哪个渲染器，其后每次都是**完整的**免责声明
/// （不写「同上」「不再赘述」—— 每次都得能独立读懂），第 10 次再加一句后果承担。
static NSString *A2ExperimentalConsentMessage(NSInteger step, NSString *rendererName) {
    NSMutableString *message = [NSMutableString stringWithFormat:@"你即将使用实验性渲染器：%@\n", rendererName];
    [message appendString:@"这条链路仍在调试中。如果你添加/切换到它之后游戏启动不了、黑屏、"
                           @"闪退或存档受损，那不是我们的问题，也不会作为缺陷受理。"];
    if (step >= A2ExperimentalChainConfirmTimes) {
        [message appendString:@"\n继续即表示你已知晓并自行承担后果。"];
    }
    return message;
}

/// 渲染器的弹窗展示名：用候选表里的**技术名**（MobileGlues / 系统 GLES 3.0 (EAGL) /
/// NG-GL4ES / KW），未登记的标识回退到 technical 的 identifier。
/// ★不走四语表★：本确认窗按用户要求「文案全中文」，混进英文词条会让同一句话变半截外语。
static NSString *A2ExperimentalRendererName(NSString *identifier) {
    A2Renderer *candidate = [A2RendererCatalog candidateForIdentifier:identifier];
    NSString *name = candidate.displayName;
    return name.length > 0 ? name : identifier;
}

@implementation A2LaunchAlertPresenter

+ (nullable UIViewController *)topViewController {
    UIWindow *keyWin = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
    }
    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController != nil) top = top.presentedViewController;
    return top;
}

+ (void)confirmExperimentalChainForRendererIdentifier:(NSString *)rendererIdentifier
                                           completion:(void (^)(BOOL))completion {
    // ★判据只有一处★：实验性启动链才弹；metallum / 内置 gl4es 直接放行，
    //   调用方不必再判一次（两处判据迟早会不一致）。
    if (![A2RendererCatalog isExperimentalLaunchChainIdentifier:rendererIdentifier]) {
        if (completion) completion(YES);
        return;
    }
    [self a2_presentConsentStep:1
                     identifier:(rendererIdentifier ?: @"")
                   rendererName:A2ExperimentalRendererName(rendererIdentifier)
                     completion:completion];
}

#pragma mark - 10 次确认的逐级推进

/// 弹第 step 次（1 起）。★递归只发生在主线程、且只由用户点击驱动★，不叠、不并行。
+ (void)a2_presentConsentStep:(NSInteger)step
                   identifier:(NSString *)identifier
                 rendererName:(NSString *)rendererName
                   completion:(void (^)(BOOL))completion {
    NSString *title = [NSString stringWithFormat:@"实验性启动链（%ld/%ld）",
                       (long)step, (long)A2ExperimentalChainConfirmTimes];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:A2ExperimentalConsentMessage(step, rendererName)
                                     preferredStyle:UIAlertControllerStyleAlert];

    // ★判据行★：一次一行，真机上一眼看出「弹到第几次、哪个渲染器」。
    [A2Log criterion:@"[A2-EXPERIMENTAL] confirm %ld/%ld renderer=%@",
     (long)step, (long)A2ExperimentalChainConfirmTimes, identifier];

    // 只认第一次点击：同一步被回调两次时不会把下一步弹两遍（叠窗 = 用户莫名要点更多次）。
    __block BOOL answered = NO;
    __weak UIAlertController *weakAlert = alert;   // 动作块被弹窗持有 ⇒ 只弱引用，避免自持有
    void (^settle)(BOOL) = ^(BOOL proceed) {
        if (answered) return;
        answered = YES;
        if (!proceed) {
            [A2Log criterion:@"[A2-EXPERIMENTAL] 用户取消（第 %ld 次）", (long)step];
            if (completion) completion(NO);
            return;
        }
        if (step >= A2ExperimentalChainConfirmTimes) {
            [A2Log criterion:@"[A2-EXPERIMENTAL] %ld 次免责确认全部通过 ⇒ 继续启动 renderer=%@",
             (long)A2ExperimentalChainConfirmTimes, identifier];
            if (completion) completion(YES);
            return;
        }
        A2RunAfterAlertDismissal(weakAlert, ^{
            [A2LaunchAlertPresenter a2_presentConsentStep:step + 1
                                              identifier:identifier
                                            rendererName:rendererName
                                              completion:completion];
        });
    };

    // ★按钮顺序 = 位置★：先加的「取消」在左，后加的「继续」在右（第 10 次换成明确表态的文案）。
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *action) { settle(NO); }]];
    NSString *continueTitle = (step >= A2ExperimentalChainConfirmTimes)
        ? @"我已知晓，启动"
        : [NSString stringWithFormat:@"继续（%ld/%ld）", (long)step, (long)A2ExperimentalChainConfirmTimes];
    [alert addAction:[UIAlertAction actionWithTitle:continueTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) { settle(YES); }]];

    UIViewController *host = [self topViewController];
    if (host == nil) {
        // ★呈现不了就不放行★：替用户「默认同意」比多弹一次更糟（他要点 10 次才有权后悔）。
        [A2Log criterion:@"[A2-EXPERIMENTAL] 无法呈现确认窗（没有可用的宿主控制器）⇒ 按取消处理"];
        if (completion) completion(NO);
        return;
    }
    [host presentViewController:alert animated:YES completion:nil];
}

@end

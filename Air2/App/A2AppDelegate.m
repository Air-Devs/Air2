//
//  A2AppDelegate.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//

#import "A2JITEnabler.h"        // JIT 闸门/判据的唯一实现（重挂后自动继续也用它判）
#import "A2LaunchSession.h"
#import "A2AppDelegate.h"
#import "A2SceneDelegate.h"
#import "A2ThemeManager.h"
#import "A2Logger.h"
#import "A2Settings.h"
#import "A2AccountManager.h"
#import "A2GameDirMigration.h"
#import "A2VersionIsolation.h"   // A2GamePath：恢复用户选定目录的安全作用域访问权
#import "A2Log.h"
#import "A2CrashReportViewController.h"
#import "A2PairingKeepAlive.h"   // [PAIRWIRE-KEEPALIVE] 配对期间保活
#import "A2RendererImporter.h"  // 导入的渲染器插件：启动时扫一遍（见 docs/RENDERER_PLUGIN_SPEC.md）

@implementation A2AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    [A2Log log:@"AppDelegate: didFinishLaunching 开始"];

    // ★[PAIRWIRE-KEEPALIVE] BGTaskScheduler 必须在启动早期注册 handler（之后不能再注册）★
    //   设备发起配对时用户要离开 App 去系统设置输码 ⇒ 靠「后台继续任务 + 静音音频」保住进程。
    A2PairingKeepAliveRegisterBGTask();

    // ★[A2-JIT-KEEPALIVE] 等 JIT 期间保活★（本单：修「开完 JIT 回来卡死」）
    //   真机症状：没 JIT ⇒ 弹「正在等待 JIT」⇒ 跳 StikDebug ⇒ 开完 JIT 回到 Air2 ⇒ 卡死。
    //   根因：等待期间本进程被系统挂起（只剩 A2JITEnabler 里那条 ~30s 的 beginBackgroundTask），
    //         0.5s 轮询与「回前台继续启动」都停在挂起那一刻，回来时没有任何东西重新开始判定。
    //   修法（两层）：
    //     ① 保活 —— A2JITEnabler 在等待窗上屏/收尾时各发一条广播，这里挂到 A2PairingKeepAlive
    //        （静音音频 + 后台继续任务）⇒ 等待期间进程不被挂起，轮询照跑；
    //     ② 复查 —— 回前台的**强制立即复查**在 A2JITEnabler 内部（DidBecomeActive），
    //        拿到 JIT 就带着同一次请求的参数继续启动，没拿到就重新进入等待（不判死）。
    //   ★分层★：Natives 不认识 A2PairingKeepAlive（App 层），只发广播；挂钩在这里。
    //   ★生命周期★：这两个观察者与 App 同寿（AppDelegate 不销毁），故不保存 token。
    [NSNotificationCenter.defaultCenter addObserverForName:A2JITEnablerWaitingDidBeginNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
        (void)note;
        [A2Log criterion:@"[A2-PAIRPIN] 等 JIT ⇒ 保活开（静音音频 + 后台继续任务）"];
        A2PairingKeepAliveStart(@"正在等待 JIT…");
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:A2JITEnablerWaitingDidEndNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
        (void)note;
        [A2Log criterion:@"[A2-PAIRPIN] 等 JIT 收尾（拿到 / 超时 / 取消）⇒ 保活关"];
        A2PairingKeepAliveStop();
    }];

    // 用户在「版本管理」里选过沙盒外的游戏目录时，访问权靠安全作用域书签。
    // 必须在任何读游戏目录的逻辑之前恢复，否则第一轮版本扫描会读到不存在的路径。
    [A2GamePath restoreGameHomeAccess];
    // 最早的目录改名迁移：把旧的 Documents/.minecraft 迁成 Documents/minecraft。
    // 必须早于任何读取游戏目录的逻辑（版本扫描、主题背景等），否则会读到旧路径。
    [A2GameDirMigration migrateIfNeeded];
    // 提前实例化主题管理器。它第一次访问会读 UserDefaults 与沙盒里的
    // 背景图，放在启动早期做，避免首次渲染时在布局过程中触发磁盘 IO。
    (void)A2ThemeManager.shared;

    // 启动自动登录：仅在开关打开且有当前账号时，刷新其凭据。
    // 这里只做「续期」——离线账号无需网络，Microsoft / 第三方账号
    // 只有在令牌过期时才会真正发请求，未过期时立即返回。
    // 不阻塞启动：回调里只写日志，UI 由账号页自己按需重读。
    if (A2Settings.shared.autoLogin) {
        A2AccountManager *mgr = A2AccountManager.shared;
        if (mgr.currentAccount) {
            [A2Log log:@"AppDelegate: 自动登录开始（当前账号 %@）", mgr.currentAccount.username];
            [mgr refreshCurrentAccountIfNeeded:^(BOOL success, NSError *error) {
                if (success) {
                    [A2Log log:@"AppDelegate: 自动登录成功"];
                } else {
                    [A2Log log:@"AppDelegate: 自动登录失败 %@", error.localizedDescription ?: @"未知错误"];
                }
            }];
        } else {
            [A2Log log:@"AppDelegate: 自动登录跳过（无当前账号）"];
        }
    } else {
        [A2Log log:@"AppDelegate: 自动登录已关闭"];
    }

    // ★崩溃界面（用户要求 2026-10-18）★
    //   真崩溃是信号级杀进程，来不及弹窗 ⇒ 用「崩溃标记文件」在★下次启动★展示上次崩溃摘要。
    //   机制：启动时若发现标记 ⇒ 说明上次没走到正常收尾 ⇒ 读 lastlog.old.txt 尾部当崩溃页内容；
    //         然后把标记重新写上（本次也在跑），正常退出时由 applicationWillTerminate 删除。
    {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *marker = [docs stringByAppendingPathComponent:@".a2_last_session_running"];
        // ★2026-10-18 用户反馈「没崩也弹异常」★ 判定收紧：
        //   marker 只说明"上次没走到 applicationWillTerminate"——用户大退/系统回收 RAM
        //   也算没走到，但那不是崩溃。真正的崩溃由 A2CrashGuard 写 .a2_crash_report.txt。
        //   ⇒ 只有★崩溃产物存在★才展示崩溃页；展示后立刻删除，保证只弹一次。
        NSString *crashArtifact = [docs stringByAppendingPathComponent:@".a2_crash_report.txt"];
        BOOL hadCrashArtifact = [NSFileManager.defaultManager fileExistsAtPath:crashArtifact];
        BOOL crashed = hadCrashArtifact;
        if (crashed) {
            NSString *oldLog = [docs stringByAppendingPathComponent:@"lastlog.old.txt"];
            NSString *tail = [NSString stringWithContentsOfFile:oldLog encoding:NSUTF8StringEncoding error:NULL];
            if (tail.length > 4000) tail = [tail substringFromIndex:tail.length - 4000];
            NSString *msg = tail.length ? tail : @"（上次会话日志为空）";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // ★不是弹窗★：整页崩溃报告（可滚动 + 导出日志），照老 Air 的做法。
                UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
                while (top.presentedViewController) top = top.presentedViewController;
                A2CrashReportViewController *vc =
                    [[A2CrashReportViewController alloc] initWithReport:msg logPath:oldLog];
                UINavigationController *nav =
                    [[UINavigationController alloc] initWithRootViewController:vc];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [top presentViewController:nav animated:YES completion:nil];
            });
            [A2Log log:@"[A2-CRASH-UI] 检测到崩溃产物（.a2_crash_report.txt），已排队展示崩溃摘要"];
            [NSFileManager.defaultManager removeItemAtPath:crashArtifact error:NULL];   // 只弹一次
        } else if ([NSFileManager.defaultManager fileExistsAtPath:marker]) {
            [A2Log log:@"[A2-CRASH-UI] 上次未正常收尾但无崩溃产物（大退/被系统回收）⇒ 不打扰"];
        }
        [@"" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }

    // ★导入的渲染器插件：启动时扫一遍★
    //   为什么在启动时扫：插件目录是用户可见的（Documents），可能被文件 App 改动过；
    //   列表只靠「导入时写内存」的话，重启后就会是空的（假状态）。
    //   放后台队列：要遍历目录 + 读 Mach-O 头，不能压在主线程的首帧上。
    //   扫完发 A2RendererPluginsDidChangeNotification（主线程），管理页据此刷新。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [A2RendererImporter.shared reloadAll];
    });

    [A2Log log:@"AppDelegate: didFinishLaunching 完成"];

    // ★stikjit 重挂后自动继续★ 上次点启动时因没 JIT 跳去使能器（会重拉本 App），
    //   回到 App 后若标记还在且 JIT 已就绪 ⇒ 自动开始启动，用户不用再点一次。
    //   标记的【写点】= Natives/Support/A2JITEnabler（只在拉起会重拉进程的 stikjit 前写），
    //   读点就是这里；判据与启动闸门同一个（[A2JITEnabler isJITReadyNow]），不另算一套。
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"A2AutoLaunchAfterJIT"]) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"A2AutoLaunchAfterJIT"];
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL ready = [A2JITEnabler isJITReadyNow];
            [A2Log criterion:@"[A2-JIT] 重挂回来自动继续：ready=%d", ready];
            if (ready) {
                [A2LaunchSession startCurrentVersionWithCompletion:^(A2LaunchSessionResult *r) {
                    (void)r;
                }];
            }
        });
    }
    return YES;
}

#pragma mark - 方向锁定

/// 全应用锁定横屏。
///
/// 理由：Minecraft Java 版是横屏游戏。启动器如果支持竖屏，
/// 从启动器切到游戏时需要旋转一次；从游戏返回时又要转回来。
/// 这两次旋转都会产生黑屏和内容重排，体验是断裂的。
/// 锁横屏后整个使用流程方向恒定，也没有旋转带来的布局抖动。
- (UIInterfaceOrientationMask)application:(UIApplication *)application
  supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - Scene 生命周期

/// 返回 Scene 配置。
///
/// 用代码显式指定代理类，不依赖 Info.plist 的 UIApplicationSceneManifest
/// 清单 —— 清单方式在字段不全时会静默失败（没有窗口 / 白屏 / 闪退），
/// 原因极难定位。代码方式配置是明确的。
- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config =
        [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                      sessionRole:connectingSceneSession.role];
    config.delegateClass = [A2SceneDelegate class];
    return config;
}

@end

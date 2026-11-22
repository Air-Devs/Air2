//
//  A2SceneDelegate.m
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

#import "A2SceneDelegate.h"
#import "A2RootViewController.h"
#import "A2ThemeManager.h"
#import "A2Log.h"
#import "PLCrashView.h"
#import "utils.h"
#include <stdlib.h>

/// 信号号 → 名字（只用于崩溃页文案，不参与任何逻辑）
static NSString *A2SignalNameForNumber(int sig) {
    switch (sig) {
        case 4:  return @"ILL";
        case 5:  return @"TRAP";
        case 6:  return @"ABRT";
        case 8:  return @"FPE";
        case 9:  return @"KILL";
        case 10: return @"BUS";
        case 11: return @"SEGV";
        case 15: return @"TERM";
        default: return @"?";
    }
}

@implementation A2SceneDelegate

- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {

    [A2Log log:@"SceneDelegate: willConnect 开始"];

    // scene 必须是 UIWindowScene 才能建窗口。
    // 如果不是（理论上不会发生），记录下来而不是静默返回 ——
    // 静默返回的表现是「启动了什么都没有」，极难排查。
    if (![scene isKindOfClass:UIWindowScene.class]) {
        NSLog(@"[Air2] 意外的 scene 类型: %@", NSStringFromClass(scene.class));
        [A2Log log:@"SceneDelegate: 意外的 scene 类型 %@，放弃建窗",
                     NSStringFromClass(scene.class)];
        return;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];

    // 关键顺序：外观必须在 rootViewController 之前设置。
    //
    // 原因：给 window.rootViewController 赋值会立即触发它的 viewDidLoad，
    // 里面所有取色逻辑都会按「当时的 trait」执行。如果此时还没设
    // overrideUserInterfaceStyle，取到的就是系统外观（可能与应用内
    // 选择相反），而且事后改样式不会让已取色的视图自动重算 ——
    // 表现为「iPad 系统亮色 + 应用选了暗色 → 界面按亮色渲染」。
    [A2ThemeManager.shared applyAppearanceToWindow:self.window];

    self.window.rootViewController = [[A2RootViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 窗口上屏后再刷一次，兜底覆盖 viewDidLoad 阶段可能取错的颜色
    [A2ThemeManager.shared notifyThemeChanged];

    [A2Log log:@"SceneDelegate: 根视图已上屏，启动流程完成"];
}

/// 主题变更时同步窗口外观
- (void)sceneDidBecomeActive:(UIScene *)scene {
    [A2ThemeManager.shared applyAppearanceToWindow:self.window];
    [self presentPendingCrashReportIfNeeded];
}

/// 上次运行被硬信号/未捕获异常杀掉时，本次冷启动补偿展示崩溃页。
///
/// A2CrashGuard 在信号处理器里只写了「标记文件」（异步信号安全），
/// 真正的 PLCrashView 拉不起来 —— 进程当时已被内核判死。
/// 这里在 scene 激活后消费标记：删文件、按信号号/异常名弹崩溃页。
/// 正常退出不会写标记，所以不会误弹。
- (void)presentPendingCrashReportIfNeeded {
    static BOOL handled = NO;
    if (handled) return;
    handled = YES;

    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') return;
    NSString *path = [NSString stringWithFormat:@"%s/last_crash_pending.txt", home];
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (content.length == 0) return;
    // 先删标记：崩溃页只补偿展示一次，避免每次启动都弹
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    content = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    int exitCode = 1;
    NSString *detail = content;
    if ([content hasPrefix:@"signal:"]) {
        exitCode = [[content substringFromIndex:7] intValue];
        if (exitCode <= 0) exitCode = 1;
        detail = [NSString stringWithFormat:@"收到信号 %d（SIG%@）",
                  exitCode, A2SignalNameForNumber(exitCode)];
    } else if ([content hasPrefix:@"exception:"]) {
        // ObjC 未捕获异常最终以 abort 收尾，统一按 SIGABRT 归类
        exitCode = 6;
        detail = [content substringFromIndex:10];
    }

    NSString *reason = [NSString stringWithFormat:
        PLCrashLocalizedText(@"crash.previous_abnormal", @"上次运行被异常终止：%@。下面是崩溃现场留下的日志，可用于反馈问题。"),
        detail];
    NSLog(@"[A2SceneDelegate] pending crash report: %@", content);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [PLCrashView showWithExitCode:exitCode
                          customTitle:PLCrashLocalizedText(@"crash.previous_title", @"上次运行异常终止")
                         customReason:reason];
    });
}

@end

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

#import "A2AppDelegate.h"
#import "A2SceneDelegate.h"
#import "A2ThemeManager.h"
#import "A2Settings.h"
#import "A2AccountManager.h"
#import "A2GameDirMigration.h"
#import "A2Log.h"

@implementation A2AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    [A2Log log:@"AppDelegate: didFinishLaunching 开始"];
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

    [A2Log log:@"AppDelegate: didFinishLaunching 完成"];
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

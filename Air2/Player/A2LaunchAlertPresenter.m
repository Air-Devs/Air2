//
//  A2LaunchAlertPresenter.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★本文件只剩「找宿主」一件事★。
//
//  10 次免责确认（实验性启动链那套）已随用户澄清迁去插件安装侧，
//  这里不留一份「暂时没人调用的」确认实现：不会被调用的弹窗代码只会误导下一个人。
//

#import "A2LaunchAlertPresenter.h"

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

@end

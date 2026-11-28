// ============================================================================
//  Natives/Input/a2_host_window.h
//  Air2 —— 宿主窗口查找（Natives 侧的 key window 口径）
// ----------------------------------------------------------------------------
//  为什么是 static inline 而不是 .m：只有两个调用点（A2GameControlsView、
//  a2_controls_overlay），为它单开一个编译单元不划算；写在头里也不会产生
//  「没人调的对外符号」（没有 inline 的 static 函数不参与链接）。
//
//  ★与 Air2/Utils/A2KeyWindow 同口径★：只认 isKeyWindow，找不到返回 nil。
//    分层上 Natives 不能 import Air2/Utils，所以只能各一份 —— 改这里请一起改那边。
// ============================================================================
#ifndef A2_HOST_WINDOW_H
#define A2_HOST_WINDOW_H

#import <UIKit/UIKit.h>

/// 当前 key window（跨所有已连接的 UIWindowScene）。没有则 nil。
static inline UIWindow *a2_host_key_window(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *) scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

#endif /* A2_HOST_WINDOW_H */

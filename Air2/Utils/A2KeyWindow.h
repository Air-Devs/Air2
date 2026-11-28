// ============================================================================
//  Air2/Utils/A2KeyWindow.h
//  Air2 —— 取「当前 key window」的唯一口径（替掉废弃的 UIApplication.keyWindow）
// ----------------------------------------------------------------------------
//  为什么要有它：
//    `UIApplication.sharedApplication.keyWindow` 从 iOS 13 起标记废弃（多场景下语义
//    不清），但仓里 5 处都在用它找「该往上贴东西的那个窗口」。各处自己写一遍
//    connectedScenes 遍历，早晚会出现「崩溃页贴在 A 窗、遮罩贴在 B 窗」。
//
//  ★口径刻意与旧 API 一致★：只认 `isKeyWindow`，找不到就返回 nil。
//    不「顺手回落到第一个窗口」—— 遮罩层靠 nil 触发 0.3s 重试，若这里提前返回一个
//    非 key 窗口，遮罩会贴到错误的窗口上，表现为「启动遮罩不显示/贴到黑屏层」。
//
//  ★Natives 侧有一份同口径的 static inline（Natives/Input/a2_host_window.h）★：
//    分层上 Natives 不能 import Air2/Utils，所以只能各一份；两处都写了「同口径」注释，
//    改动时请一起改。
// ============================================================================
#ifndef A2_KEY_WINDOW_H
#define A2_KEY_WINDOW_H

#import <UIKit/UIKit.h>

/// 当前 key window（跨所有已连接的 UIWindowScene）。没有则 nil。
UIWindow *A2KeyWindow(void);

#endif /* A2_KEY_WINDOW_H */

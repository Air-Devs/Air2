// ============================================================================
//  Natives/Input/a2_glfw_input.h
//  Air2 —— 自研 GLFW 输入层（阶段 A）· 宿主视图工厂
// ----------------------------------------------------------------------------
//  职责：为某个窗口造一个「捕获触摸/按键」的宿主视图（iOS 上为 UIView 子类）。
//  触摸/按键 → GLFW 事件的翻译全部在 a2_glfw_input.m 内部（静态函数），
//  不对外暴露 —— 避免出现「没人调的接口」（石山纪律）。
//
//  与 a2_glfw_window.h 的关系：两者互不 include（无循环）；各自的 .m 按需同时
//  包含两个头。窗口层用本头造视图；输入层用窗口层的事件总线投递事件。
//
//  净室：独立编写，未参考 Pojav / Boardwalk / Amethyst / LWJGL 源码。
// ============================================================================
#ifndef A2_GLFW_INPUT_H
#define A2_GLFW_INPUT_H

#import <UIKit/UIKit.h>

// 造一个绑定到 window 的宿主视图（触摸 + 外接键盘按下/抬起）。
// 调用点：a2_glfw_window.m 的 a2_glfw_window_create（主队列内）。
// 失败返回 nil。
UIView *a2_glfw_input_make_view(long window);

#endif /* A2_GLFW_INPUT_H */

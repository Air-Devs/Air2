// ============================================================================
//  Natives/Input/a2_glfw_input.h
//  Air2 —— 自研 GLFW 输入层（阶段 A）· 宿主视图工厂 + 合成输入 + 映射层入口
// ----------------------------------------------------------------------------
//  职责：为某个窗口造一个「捕获触摸/按键」的宿主视图（iOS 上为 UIView 子类），
//  并对外提供「往这个窗口的事件总线里合成一次输入」的函数。
//
//  ★[INPUT-MAP-1] 起，外接键盘不再在本文件里翻译★
//    键盘的 HID→GLFW 翻译与映射统一走 A2KeyboardInputSource / A2InputRouter
//    （见 A2InputRouter.h）。本文件只保留：触摸/指针/滚动/文本（CHAR）这几条
//    「不是可映射按键」的通道 —— 文本输入是字符流，不是「按了哪个键」。
//
//  与 a2_glfw_window.h 的关系：两者互不 include（无循环）；各自的 .m 按需同时
//  包含两个头。窗口层用本头造视图；输入层用窗口层的事件总线投递事件。
//
//  净室：独立编写，未参考 Pojav / Boardwalk / Amethyst / LWJGL 源码。
// ============================================================================
#ifndef A2_GLFW_INPUT_H
#define A2_GLFW_INPUT_H

#import <UIKit/UIKit.h>

@class A2InputRouter;

// 造一个绑定到 window 的宿主视图（触摸 + 外接键盘按下/抬起）。
// 调用点：a2_glfw_window.m 的 a2_glfw_window_create（主队列内）。
// 失败返回 nil。
UIView *a2_glfw_input_make_view(long window);

// ---------------------------------------------------------------------------
//  合成输入（控件/映射层用）
// ---------------------------------------------------------------------------
// 这三个函数是「事件总线」的公开投递口：键盘走映射层后会落到这里，
// 屏幕控件（A2GameControlsView）目前也直接调它们（[INPUT-MAP-2] 再改走映射层）。
// key 一律用 GLFW 键码；action 1=按下 0=抬起。
// ★26.3 内核★：这些函数内部会同时把同一份输入镜像给 SDL 事件队列
// （26.2 及更早没有 SdlInputBridge ⇒ 自动 no-op）。所以「一份输入覆盖所有内核」
// 不需要调用方判断版本。
void a2_glfw_input_post_key(long window, int key, int action);

// 完整版：带扫描码与 GLFW mods 位（映射层投递键盘事件走这条）。
//   scancode 传 0 表示「合成输入、没有物理扫描码」；
//   mods 传 0 表示「不带修饰键」（Ctrl/Shift 组合键要靠它，丢了组合键就失效）。
void a2_glfw_input_post_key_event(long window, int key, int scancode, int action, int mods);

void a2_glfw_input_post_mouse_button(long window, int button, int action);
void a2_glfw_input_post_char(long window, int codepoint, int mods);

// ---------------------------------------------------------------------------
//  映射层入口（[INPUT-MAP-1]）
// ---------------------------------------------------------------------------
// 取这个窗口的输入路由器；第一次调用时装配：绑定表（默认表）、内核汇、
// 键盘源（已启动）、虚拟按钮源与手柄源（只有接口，start 会如实失败）。
//
// ★为什么由本文件持有★：路由器与「窗口句柄」同生共死（汇要靠句柄投事件），
// 而窗口的生命周期归 a2_glfw_window；这里用「弱值表」登记，视图没了条目自动消失，
// 不需要在窗口销毁路径上加钩子。
//
// ★生命周期★：路由器的强引用归该窗口的宿主视图（A2GlfwView.a2InputRouter）；
// 本函数只在窗口表里**弱登记**。所以：
//   · 窗口视图还在 ⇒ 拿到的就是同一个路由器（改绑、按下集合都连续）；
//   · 窗口视图已销毁 ⇒ 拿到的可能是新造的一个（旧状态已随视图释放），
//     此时往它里面投事件不会崩，但也没有内核在收。
// window 为 0 时返回 nil。
A2InputRouter *a2_glfw_input_router(long window);

#endif /* A2_GLFW_INPUT_H */

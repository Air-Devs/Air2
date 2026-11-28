// ============================================================================
//  Natives/Input/A2KeyboardInputSource.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 键盘源（本迭代真正实现的那一种）
// ----------------------------------------------------------------------------
//  键盘源只做两件事：① USB HID usage → GLFW 键码（唯一一份表）；
//  ② 把宿主视图（A2GlfwView）收到的按下/抬起转成触发交给映射层。
//
//  ★为什么表放在这里而不是留在 a2_glfw_input.m★
//    表是「键盘这个源怎么翻译自己」的知识，属于源；输入层只该管触摸/指针/滚动。
//    更重要的是：映射层的直通与改绑都以 GLFW 键码为口径，全仓只能有一份表，
//    否则「同一个物理键」在两条路径上会给出两个键码，改绑就永远对不上。
//
//  ★mods 必须原样带下去★
//    MC 的按键回调会读 mods（Ctrl/Shift 组合键、Ctrl+Q 退出等）。若这里把 mods
//    丢掉，硬件键盘在 MC 里就只能单键操作 —— 这是「能打字但组合键全失效」的根因。
// ============================================================================
#ifndef A2_KEYBOARD_INPUT_SOURCE_H
#define A2_KEYBOARD_INPUT_SOURCE_H

#import <Foundation/Foundation.h>

#import "A2InputSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2KeyboardInputSource : NSObject <A2InputSource>

/// USB HID Keyboard/Keypad usage ID → GLFW 键码。未覆盖的键返回 -1（GLFW_KEY_UNKNOWN）。
/// ★公开是为了单测能逐键断言★：这张表错了，表现是「某个键按了没反应」，
/// 只有把表本身测住，才不用每次上真机去试。
+ (int)glfwKeyForHIDUsage:(long)hidUsage;

/// 宿主视图把 UIKit 的按下/抬起转进来。
/// 返回 YES = 已作为一次按键触发投给映射层；NO = 该键未覆盖或源已关闭。
- (BOOL)handleHIDUsage:(long)hidUsage action:(A2InputAction)action mods:(int)mods;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_KEYBOARD_INPUT_SOURCE_H */

// ============================================================================
//  Natives/Input/A2GamepadInputSource.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 手柄源（本迭代只给接口）
// ----------------------------------------------------------------------------
//  [INPUT-MAP-3] 要做的事已经写死在这份接口上：
//    ① 用 GameController 框架（GCController）注册连接/断开通知，start 时枚举已连接手柄；
//    ② 把 GCController 的按键值变化翻成 -button:action:（编号用 A2GamepadButton）；
//    ③ 摇杆/扳机的模拟量进 A2InputEvent.value（本次不给轴接口：没有内核收，
//       先给一个「投出去必然被拒」的接口等于给后来人埋一个假通道）。
//
//  ★手柄的「任意按键」怎么落到 MC 里★
//    MC 没有原生手柄通道（只认 GLFW 键/鼠标回调）。所以手柄的用法是：
//    手柄按键 →（绑定表）→ 键盘键位。出厂表已按 MC 默认键位配好（见
//    A2InputBindingTable +defaultTable），用户也可以把任意手柄按键绑到任意键盘键，
//    这就是「手柄任何按键映射到键盘所有按键」。
//
//  ★本迭代 start 会如实失败★（A2InputErrorCodeNotImplemented）：
//    假装成功会让 UI 显示「手柄已连接」，而玩家按下去毫无反应。
// ============================================================================
#ifndef A2_GAMEPAD_INPUT_SOURCE_H
#define A2_GAMEPAD_INPUT_SOURCE_H

#import <Foundation/Foundation.h>

#import "A2InputSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2GamepadInputSource : NSObject <A2InputSource>

/// GameController 是否已经接进来。[INPUT-MAP-1] 恒为 NO（见文件头）。
@property (nonatomic, readonly) BOOL isWired;

/// 手柄按键按下/抬起。★这是将来 GCController 回调的唯一出口★。
- (void)button:(A2GamepadButton)button action:(A2InputAction)action;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_GAMEPAD_INPUT_SOURCE_H */

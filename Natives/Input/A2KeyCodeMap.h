//
//  A2KeyCodeMap.h
//  Air2
//
//  两套「外部键码 → GLFW 键码」的静态映射表：
//   · FCL 用 Linux evdev 键码（KEY_W = 17），与 GLFW 完全是两套编号；
//   · ZL2 用字符串名字（"GLFW_KEY_W"），和 GLFW 数值一一对应。
//  导入布局时若不换算，按出来的键会落到完全无关的按键上。
//
//  映射依据（只读参考，未拷实现）：
//   · FCL  LwjglKeycodeMap.java 的 add(LwjglGlfwKeycode.*, FCLKeycodes.*) 对照
//   · ZL2  LwjglGlfwKeycode.java 的常量名与数值
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2KeyCodeMap : NSObject

/// "GLFW_KEY_W" / "KEY_W" / "W" / "87" → GLFW 键码；鼠标键 → -1/-2/-3；未知返回 0。
/// 数字字符串按 GLFW 码处理，但 "0" 按数字键 0（48）处理，避免被当成「未绑定」。
+ (NSInteger)keyCodeFromName:(NSString *)name;

/// FCL 的 evdev 键码 → GLFW 键码；未知返回 0。
+ (NSInteger)keyCodeFromFCLKeycode:(NSInteger)evdevCode;

/// GLFW 键码 → FCL 的 evdev 键码（导出用）；未知返回 0。
+ (NSInteger)fclKeycodeFromKeyCode:(NSInteger)keyCode;

@end

NS_ASSUME_NONNULL_END

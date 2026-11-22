//
//  A2KeyCodeMap.h
//  Air2
//
//  键码换算表 —— FCL ⇄ ZL2 ⇄ Air2 三家键码体系的唯一权威来源。
//
//  ## 三套键码
//
//    Air2 / ZL2 运行时   GLFW 键码（glfw3.h）
//                       键盘 32~348；鼠标 0~7（0 左 / 1 右 / 2 中）
//    ZL2 布局文件        GLFW 名称字符串（"GLFW_KEY_W" / "GLFW_MOUSE_BUTTON_LEFT"）
//    FCL 布局文件        Linux input 键码（KEY_W=17 / KEY_A=30 …），
//                       鼠标 1000=左 1001=中 1002=右，滚轮 1003=上 1004=下
//
//  ## 对照源码
//
//    FCL  model: fcl/FCL/src/main/java/com/tungsten/fcl/control/data/ButtonEventData.java
//                （outputKeycodes 存的就是 Linux input 键码）
//    FCL⇄ZL2 映射表: fcl/FCL/src/main/java/com/mio/controlconverter/CcConstants.kt
//                （GLFW_TO_FCL / FCL_MOUSE / FCL_SCROLL_REVERSE）
//
//  ## 为什么单独一个文件
//
//  格式转换（A2ControlFormatFCL / A2ControlFormatZL）和运行时（A2ControlInput）
//  都要用同一张表。分散写两份，迟早一份改了一份没改。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// FCL 的「鼠标左键」键码（与 Linux input 键码不冲突，从 1000 起）
FOUNDATION_EXPORT const NSInteger A2FCLMouseLeft;    ///< 1000
FOUNDATION_EXPORT const NSInteger A2FCLMouseMiddle;  ///< 1001
FOUNDATION_EXPORT const NSInteger A2FCLMouseRight;   ///< 1002
FOUNDATION_EXPORT const NSInteger A2FCLScrollUp;     ///< 1003
FOUNDATION_EXPORT const NSInteger A2FCLScrollDown;   ///< 1004

@interface A2KeyCodeMap : NSObject

#pragma mark - FCL ⇄ GLFW

/// GLFW 键码 / 鼠标键 → FCL 键码。无法映射返回 -1。
+ (NSInteger)fclCodeForGLFWCode:(NSInteger)glfwCode;
/// FCL 键码 → GLFW 键码。无法映射返回 -1。
+ (NSInteger)glfwCodeForFCLCode:(NSInteger)fclCode;

/// FCL 键码是不是鼠标/滚轮类（>= 1000）
+ (BOOL)isFCLPointerCode:(NSInteger)fclCode;
/// FCL 滚轮键码 → 方向（+1 上 / -1 下 / 0 非滚轮）
+ (NSInteger)scrollDirectionForFCLCode:(NSInteger)fclCode;

#pragma mark - 名称 ⇄ GLFW

/// GLFW 名称 → GLFW 键码（"GLFW_KEY_W" → 87）；鼠标名走同一张表（→ 0/1/2）
+ (NSInteger)glfwCodeForName:(nullable NSString *)name;
/// GLFW 键码 → GLFW 名称（87 → "GLFW_KEY_W"）
+ (nullable NSString *)nameForGLFWCode:(NSInteger)code;

#pragma mark - 事件键 ⇄ FCL

/// 任意写法的控件事件键（"87" / "GLFW_KEY_W" / "GLFW_MOUSE_BUTTON_LEFT" /
/// "launcher.event.scroll_up.single"）→ FCL 键码。无法映射返回 -1。
+ (NSInteger)fclCodeForEventKey:(nullable NSString *)eventKey;

/// FCL 键码 → ZL2 的 clickEvent 类型字符串
/// 返回 @{@"type": @"key"|"launcher_event", @"key": <事件键>}；无法映射返回 nil。
+ (nullable NSDictionary<NSString *, NSString *> *)zlEventForFCLCode:(NSInteger)fclCode;

/// ZL2 事件（type + key）→ FCL 键码；无法映射返回 -1
+ (NSInteger)fclCodeForZLEventType:(nullable NSString *)type key:(nullable NSString *)key;

@end

NS_ASSUME_NONNULL_END

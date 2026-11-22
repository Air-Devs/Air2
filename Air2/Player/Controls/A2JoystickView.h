//
//  A2JoystickView.h
//  Air2
//
//  摇杆控件 —— 对照 ZL2：
//    ui/control/joystick/JoystickDirection.kt  八方向枚举
//    ui/control/joystick/_Movement.kt          方向 → 移动键（斜向=两键）
//    ui/control/gamepad/Joystick.kt            归一化、加速度、8 扇区判定
//
//  ## 相对旧实现补齐的能力
//
//    · **死区重标定**：死区内的位移不触发；死区外的幅度重新映射到 0~1，
//      而不是旧版的「按原始距离直接判方向」——否则死区周边会很"跳"。
//    · **八方向 + 滞回**：旧版只有四方向（up/down/left/right 各自独立阈值），
//      斜向靠两个阈值同时成立，边界附近会反复 press/release 抖键。
//      现在按 ZL2 的 45° 扇区判定，并加 12° 滞回：扇区不换就不换键。
//    · **方向 → 键集合**：斜向 = 两个键同时按住（ZL2 directionMapping 的语义），
//      用集合差分来 press/release，不会重复发同一个键。
//    · **摇杆模式（ROCKER）**：持续输出归一化的鼠标位移，
//      幅度按 ZL2 的 `magnitude^2`（MOUSE_MAX_ACCELERATION=2.0）加速，
//      采样间隔按 16ms 基准归一化（MAX_TIME_SCALE=4）。
//    · **按键引用计数**：经 A2ControlInputDispatcher，多个控件按同一个键不会互相打架。
//
//  ## 兼容
//
//  upKey/downKey/leftKey/rightKey、deadZone、initWithWidget:、applyTheme
//  全部保留（原来的语义不变：设置这四个键就等于给了四方向事件）。
//

#import <UIKit/UIKit.h>
#import "A2ControlLayout.h"
#import "A2ControlRenderer.h"
#import "A2ControlInput.h"

NS_ASSUME_NONNULL_BEGIN

/// 八方向 + 无方向（顺序与 ZL2 的 JoystickDirection 一致，不要重排）
typedef NS_ENUM(NSInteger, A2JoystickDirection) {
    A2JoystickDirectionEast = 0,
    A2JoystickDirectionNorthEast,
    A2JoystickDirectionNorth,
    A2JoystickDirectionNorthWest,
    A2JoystickDirectionWest,
    A2JoystickDirectionSouthWest,
    A2JoystickDirectionSouth,
    A2JoystickDirectionSouthEast,
    A2JoystickDirectionNone,
};

@interface A2JoystickView : UIView

@property (nonatomic, strong) A2ControlWidget *widget;
@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> inputDelegate;

/// 共享的输入分发器（由 A2ControlRenderer 注入；不注入时自己造一个）
@property (nonatomic, strong, nullable) A2ControlInputDispatcher *input;

/// 死区比例（0~1，默认 0.15）
@property (nonatomic, assign) CGFloat deadZone;

/// 四个方向绑定的按键码（旧 API，保留）
@property (nonatomic, copy) NSString *upKey;
@property (nonatomic, copy) NSString *downKey;
@property (nonatomic, copy) NSString *leftKey;
@property (nonatomic, copy) NSString *rightKey;

/// 触发模式（默认取 widget.triggerMode）
@property (nonatomic, assign) A2JoystickTriggerMode triggerMode;

/// ROCKER 模式的鼠标灵敏度（像素 / 秒 / 满幅），默认 900
@property (nonatomic, assign) CGFloat mouseSensitivity;

/// 当前方向（只读，调试/测试用）
@property (nonatomic, readonly) A2JoystickDirection direction;
/// 当前归一化幅度（0~1，已扣掉死区）
@property (nonatomic, readonly) CGFloat magnitude;

- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

/// 外部复位（切后台 / 编辑模式切换）
- (void)resetToCenter;

@end

NS_ASSUME_NONNULL_END

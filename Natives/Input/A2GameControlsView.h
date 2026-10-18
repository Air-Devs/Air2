//
//  A2GameControlsView.h
//  Air2
//
//  ★游戏内触屏控件（阶段1：移动两套模式 + 潜行/疾跑 + 跳跃）★
//
//  需求出处：D:\hermes workplace\amethyst-air\A2_CONTROLS_SPEC.md（用户 2026-10-18 口述）
//   · 模式A 分键：前/后/左/右 各自点；潜行在中间；快速点两下某个移动键 = 疾跑
//   · 模式B 摇杆：拖动范围够大自动疾跑；点一下摇杆中心 = 进入潜行（再点解除）
//   · 跳跃放右边，点一下
//
//  为什么放在 Natives/Input 而不是 Air2/Player/Controls：
//    本视图与输入层同生共死（它只做一件事：把触摸翻译成 GLFW 按键），
//    放在输入层可避免跨层依赖，也不需要改工程生成器的目录清单。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 移动模式（持久化键：A2MoveMode）
typedef NS_ENUM(NSInteger, A2MoveMode) {
    A2MoveModeDPad = 0,     ///< 分键（十字）
    A2MoveModeStick = 1,    ///< 圆形摇杆
};

@interface A2GameControlsView : UIView

/// 窗口句柄（GLFW window id），合成按键事件时带上。
- (instancetype)initWithWindowHandle:(long)window NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// 切换移动模式（即时生效 + 持久化）。
- (void)setMoveMode:(A2MoveMode)mode;

/// 当前模式。
@property (nonatomic, assign, readonly) A2MoveMode moveMode;

@end

NS_ASSUME_NONNULL_END

//
//  A2GamepadView.h
//  Air2
//
//  屏幕手柄控件 —— 对照 ZL2 的 ui/control/gamepad/GamepadMap.kt。
//
//  ## ZL2 的定义（逐条对齐）
//
//    GamepadMap 枚举给出每个物理按键在「游戏内 / 菜单内」分别映射到什么键：
//      A  → SPACE      菜单内 MOUSE_LEFT
//      B  → LEFT_SHIFT 菜单内 ESCAPE
//      X  → F1
//      Y  → E
//      START → ESCAPE
//      SELECT → 鼠标中键
//      LB → 滚轮上     RB → 滚轮下
//      LT → 鼠标右键   RT → 鼠标左键
//      DPAD_UP → F5    LEFT → F   DOWN → Q   RIGHT → T
//      STICK_LEFT_CLICK  → LEFT_CONTROL
//      STICK_RIGHT_CLICK → （ZL2 未绑）
//
//  ## iOS 的现实差别
//
//  ZL2 是读 Android 的物理手柄事件；iOS 侧有 GameController.framework。
//  但 GameController 需要 Info.plist 的 GCSupportsControllerUserInteraction
//  与真机手柄，没法在控件层替宿主决定，所以这里做的是**屏幕虚拟手柄**：
//  把同一套映射表画成触摸可用的 dpad + ABXY + start/select，
//  触摸走 controlPressKey: 下发 —— 没有手柄的玩家也能用同一套布局。
//  （要接真实手柄，宿主在 GameController 回调里按同一张映射表发键即可。）
//
//  ## 映射可覆盖
//
//  widget.gamepadMapping 里给了什么就用什么（键名见 .h 底部），
//  没给的用上面的 ZL2 默认值。
//

#import <UIKit/UIKit.h>
#import "A2ControlRenderer.h"
#import "A2ControlInput.h"

NS_ASSUME_NONNULL_BEGIN

/// 手柄按键区域（对应 GamepadMap.identifier 的小写形式）
typedef NS_ENUM(NSInteger, A2GamepadRegion) {
    A2GamepadRegionNone = 0,
    A2GamepadRegionA,
    A2GamepadRegionB,
    A2GamepadRegionX,
    A2GamepadRegionY,
    A2GamepadRegionStart,
    A2GamepadRegionSelect,
    A2GamepadRegionDpadUp,
    A2GamepadRegionDpadDown,
    A2GamepadRegionDpadLeft,
    A2GamepadRegionDpadRight,
};

@interface A2GamepadView : A2ControlButtonView

/// 当前按住的区域（只读，调试/预览用）
@property (nonatomic, assign, readonly) A2GamepadRegion activeRegion;
/// 编辑模式（由 A2ControlRenderer 在布局编辑时置 YES）。
/// 编辑态下控件不派发游戏输入，只响应拖拽/缩放。
@property (nonatomic, assign) BOOL editing;


- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

/// 该区域当前绑定的键码（nil 表示未绑定）
- (nullable NSString *)keyForRegion:(A2GamepadRegion)region;

@end

NS_ASSUME_NONNULL_END

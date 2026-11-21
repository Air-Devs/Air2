//
//  A2JoystickView.h
//  Air2
//
//  摇杆控件 —— 对照 ZL2 的 JoystickWidget.kt（533 行）。
//
//  ## ZL2 的摇杆规格
//
//    **触发模式**（JoystickTriggerMode）：
//      ROCKER        摇杆式：拖动时持续发送方向键，回中即停
//      DIRECTION     方向式：拖到某个方向就按下该方向的键
//
//    **方向**（JoystickDirection）：
//      up / down / left / right 四个方向，每个可绑不同按键
//
//    **死区**：中心区域不触发（避免误触）
//
//    **外观**：
//      外圈（背景）+ 内圈（摇杆头）
//      摇杆头位移限制在半径内
//
//  ## 我们的实现
//
//  ZL2 用 Compose 的 pointerInput 处理多指。
//  iOS 上用 UIPanGestureRecognizer + 位移映射到四方向。
//  多个方向可同时生效（斜向移动 = 同时按下 up/right）。
//

#import <UIKit/UIKit.h>
#import "A2ControlLayout.h"
#import "A2ControlRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2JoystickView : UIView

@property (nonatomic, strong) A2ControlWidget *widget;
@property (nonatomic, weak, nullable) id<A2ControlInputDelegate> inputDelegate;

/// 死区比例（0~1，默认 0.15）
@property (nonatomic, assign) CGFloat deadZone;

/// 四个方向绑定的按键码
@property (nonatomic, copy) NSString *upKey;
@property (nonatomic, copy) NSString *downKey;
@property (nonatomic, copy) NSString *leftKey;
@property (nonatomic, copy) NSString *rightKey;

- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

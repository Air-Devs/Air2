//
//  A2ControlFormatZL.h
//  Air2
//
//  ZalithLauncher2 原生控件格式（editorVersion 12）⇄ Air2 内部模型。
//
//  ## 源文件（实证）
//
//    zl2/ZalithLauncher/src/main/java/com/movtery/zalithlauncher/ui/control/
//      joystick/JoystickDirection.kt   八方向枚举（East/NorthEast/...）
//      joystick/_Movement.kt          方向 → 移动键的映射（含斜向两键）
//      gyroscope/GyroscopeReader.kt   陀螺仪采样参数
//      Hotbar.kt                      快捷栏九格与键码
//    fcl/FCL/src/main/java/com/mio/controlconverter/CcZlToFcl.kt
//      （官方互转实现，作为字段名的权威参考；这里**不移植 Kotlin 代码**）
//    fcl/FCL/src/main/java/com/mio/controlconverter/CcDirection.kt
//      ZL 摇杆 JSON 的真实形状（sizeType/sizeDp/sizePercentage/
//      deadZoneRatio/lockThreshold/canLock/triggerMode/directionEvents）
//
//  ## ZL2 根结构
//
//    {
//      "editorVersion": 12,
//      "info": { "name": "...", "author": "..." },   // 可缺省
//      "layers": [ { "uuid": "...", "name": "...", "hide": false,
//                    "normalButtons": [...],
//                    "joystickButtons": [...],
//                    "textBoxes": [...] } ],
//      "styles": [ ... ],            // 按钮样式
//      "joystickStyles": [ ... ]     // 摇杆样式
//    }
//
//  ## 坐标
//
//    position.x / y     0~10000，相对「可用空间」（见 A2ControlLayout.h）
//    buttonSize.widthPercentage / heightPercentage
//                       0~10000，相对 widthReference / heightReference
//                       （"screen_width" 默认 / "screen_height"）
//    sizeType:"dp"      时以 widthDp / heightDp 为准
//    摇杆的 sizePercentage 相对**屏幕高**（CcDirection.kt 里的换算）
//

#import <Foundation/Foundation.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ControlFormatZL : NSObject

/// ZL2 JSON → 内部模型。失败时通过 error 返回原因。
+ (nullable A2ControlLayout *)layoutFromJSON:(NSDictionary *)json error:(NSError **)error;

/// 内部模型 → ZL2 JSON（editorVersion 12）。
+ (NSDictionary *)jsonFromLayout:(A2ControlLayout *)layout aspect:(CGFloat)aspect;

/// Air2 扩展的三种控件（gamepad/gyroscope/hotbar）在 ZL2 里没有对应类型，
/// 导出时会不会丢？—— 不会：它们会被写进 ZL2 的扩展键
/// gamepadButtons / gyroscopeButtons / hotbarButtons，ZL2 自己读不懂但会原样保留，
/// 再导回 Air2 时能完整恢复。
@property (class, nonatomic, readonly) NSArray<NSString *> *extensionKeys;

@end

NS_ASSUME_NONNULL_END

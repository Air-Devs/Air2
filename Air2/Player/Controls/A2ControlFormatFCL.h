//
//  A2ControlFormatFCL.h
//  Air2
//
//  FoldCraftLauncher 原生控件格式（controllerVersion 21）⇄ Air2 内部模型。
//
//  ## 源文件（实证）
//
//    fcl/FCL/src/main/java/com/tungsten/fcl/control/data/
//      CustomControl.java            ViewType = CONTROL_BUTTON / CONTROL_DIRECTION
//      BaseInfoData.java             visibilityType / xPosition / yPosition /
//                                    sizeType / absoluteWidth / absoluteHeight /
//                                    percentageWidth{reference,size} / percentageHeight{...}
//      ControlButtonData.java        {id,text,style,baseInfo,event}
//      ControlDirectionData.java     {id,style,baseInfo,event}
//      ControlViewGroup.java         {id,name,visibility,viewData{buttonList,directionList}}
//      ButtonEventData.java          pointerFollow / Movable / swipable /
//                                    pressEvent / longPressEvent / clickEvent / doubleClickEvent
//      DirectionEventData.java       upKeycode/downKeycode/leftKeycode/rightKeycode /
//                                    followOption / sneak / sneakKeycode /
//                                    deadZone / canLock / lockThreshold
//      ButtonStyles.java / DirectionStyles.java
//    fcl/FCL/src/main/java/com/mio/controlconverter/
//      CcFclToZl.kt / CcZlToFcl.kt / CcGeometry.kt / CcConstants.kt
//      （官方互转实现 —— 这里只取「字段怎么映射」这一个信息，
//        不移植算法，也不引入任何 JVM 组件）
//
//  ## 坐标（关键差异）
//
//    FCL 的 xPosition 0~1000 是相对「可用空间」的比例：
//        x_px = (screenW - width) * xPosition / 1000
//        （fcl/FCL/.../control/view/ControlButton.java:242）
//    尺寸 percentageWidth.size 0~1000 相对 reference 指定的边
//    （SCREEN_WIDTH / SCREEN_HEIGHT）。
//    Air2 内部是 0~100 的屏幕百分比 —— 转换必须过坐标换算，
//    不能直接除 10 了事（见 A2ControlLayout.h 的坐标换算说明）。
//
//  ## 有损字段（导出/导入时保留在 rawJSON 与扩展键里）
//
//    · pointerFollow      没有 ZL2/Air2 等价语义 → 保留在 event 里，不影响运行
//    · Movable            同上
//    · followOption/sneak  方向控件的「潜行跟随」，Air2 未实现 → 保留
//    · switchTouchMode / switchMouseMode / quickInput
//                         官方互转也把它们降级成 launcher 菜单/输入法事件
//    · outputText         → send_text 事件（Air2 已有）
//

#import <Foundation/Foundation.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// FCL 当前的 controllerVersion（CcConstants.FCL_CONTROLLER_VERSION）
FOUNDATION_EXPORT const NSInteger A2FCLControllerVersion;   ///< 21

@interface A2ControlFormatFCL : NSObject

+ (nullable A2ControlLayout *)layoutFromJSON:(NSDictionary *)json error:(NSError **)error;
+ (NSDictionary *)jsonFromLayout:(A2ControlLayout *)layout aspect:(CGFloat)aspect;

/// 判断一个 JSON 是不是 FCL 控件（看 viewGroups 或 controllerVersion）
+ (BOOL)sniff:(NSDictionary *)json;

@end

NS_ASSUME_NONNULL_END

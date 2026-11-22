//
//  A2ViewAreaView.h
//  Air2
//
//  视角区控件 —— 手指在区域内拖动 = 转视角。
//
//  ## 对照源码
//
//    zl2/.../ui/control/mouse/TouchInput.kt
//      拖动模式（slide）：ACTION_MOVE 的 (dx, dy) 直接转成鼠标位移
//      点击模式（click） ：单指点击 = 左键单击
//    fcl/.../control/FCLInput.java
//      鼠标移动区域同样按「上一帧 → 当前帧」的差值累计
//
//  ## 为什么单独一个视图
//
//  A2ControlButtonView 的触摸语义是「按下 → 发一次 key → 抬起 → 释放」。
//  视角区需要的是**连续位移**，而且不能有按下/抬起的概念（否则每指一下
//  就多一次点击）。所以独立成类，直接走 A2ControlInputDispatcher 的
//  moveMouseBy: / pressMouseButton:。
//
//  ## 布局 JSON
//
//  ZL2 / FCL 都没有「视角区」这个控件类型。Air2 用扩展键
//  `viewAreas`（层内）+ `air2Extensions`（导出到对方格式时）保存。
//  坐标、尺寸仍按 0~100 屏幕百分比。
//

#import <UIKit/UIKit.h>
#import "A2ControlRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ViewAreaView : A2ControlButtonView

/// 是否处于编辑模式（编辑模式下不派发输入，只让渲染层拖拽/缩放）
@property (nonatomic, assign) BOOL editing;

- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

/// 复位内部触摸状态（切后台 / 重载布局）
- (void)resetTouchState;

@end

NS_ASSUME_NONNULL_END

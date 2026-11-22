//
//  A2ScrollWheelView.h
//  Air2
//
//  滚轮控件 —— 上下拖动 / 点上下半区，产生鼠标滚轮事件。
//
//  ## 对照源码
//
//    zl2/.../ui/control/event/Events.kt
//      LAUNCHER_EVENT_SCROLL_UP / SCROLL_DOWN         长按连续滚
//      LAUNCHER_EVENT_SCROLL_UP_SINGLE / ..._SINGLE   单击滚一格
//      → ZL2 没有独立的滚轮控件，是绑在按钮上的事件；
//        但它区分「单次」和「长按连续」的语义，这里照搬。
//    fcl/.../control/data/ButtonEventData.java
//      滚轮用 outputKeycodes 里的 1003（上）/ 1004（下），
//      对应 CcConstants.FCL_SCROLL_*。
//    fcl/.../control/FCLInput.java
//      滚轮事件的连发在 tick 里做（按住不放会一直滚）。
//
//  ## 派发
//
//  统一走 A2ControlInputDispatcher 的 scrollByX:y:：
//    宿主实现了 A2ControlAdvancedInput → 真正的滚轮通道
//    没实现 → A2ControlScrollNotification（带 dx/dy）
//  这样不会像旧实现那样把滚轮伪装成键盘键。
//

#import <UIKit/UIKit.h>
#import "A2ControlRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ScrollWheelView : A2ControlButtonView

/// 是否处于编辑模式（编辑模式下不派发输入）
@property (nonatomic, assign) BOOL editing;

/// 最近一次滚动的方向：+1 上 / -1 下 / 0 无（预览/调试用）
@property (nonatomic, assign, readonly) NSInteger lastDirection;

- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

/// 复位内部累计（切后台 / 重载布局）
- (void)resetTouchState;

@end

NS_ASSUME_NONNULL_END

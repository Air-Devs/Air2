//
//  A2HotbarView.h
//  Air2
//
//  快捷栏控件（九格判定框）—— 对照 ZL2 的 ui/control/Hotbar.kt。
//
//  ## ZL2 的行为（逐条对齐）
//
//    · 九格，点哪格就发哪个数字键（默认 1~9 → GLFW 49~57）
//    · 按下即触发（不等抬起）—— 因为切换物品栏后游戏状态已经变了
//    · 滑动跨格时，实时按新格子发键
//    · 双指/双击：切换副手（默认 F = 70）
//    · 长按：丢弃（默认 Q = 81）
//    · 长按判定：按下超过 longClickDelay，且位移没超过 touchSlop
//
//  ## 为什么不做成九个独立按钮
//
//  九个按钮能放，但「滑动跨格连切」这种操作做不出来，
//  而且九个控件会让布局文件膨胀。ZL2 也把它当**一个**判定框处理。
//
//  ## 继承关系
//
//  继承 A2ControlButtonView 而不是裸 UIView：
//    SurfaceViewController 的 updateControlHiddenState: 只遍历
//    A2ControlButtonView 子视图做显示/隐藏 —— 继承它才能跟着开关走，
//    否则「隐藏控件」对它无效。
//

#import <UIKit/UIKit.h>
#import "A2ControlRenderer.h"
#import "A2ControlInput.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2HotbarView : A2ControlButtonView

/// 当前高亮的格子；-1 表示没有
@property (nonatomic, assign, readonly) NSInteger selectedSlot;
/// 选中回调（编辑器预览用，可以为 nil）
@property (nonatomic, copy, nullable) void (^onSlotSelected)(NSInteger slot);
/// 编辑模式（由 A2ControlRenderer 在布局编辑时置 YES）。
/// 编辑态下控件不派发游戏输入，只响应拖拽/缩放。
@property (nonatomic, assign) BOOL editing;


- (instancetype)initWithWidget:(A2ControlWidget *)widget;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

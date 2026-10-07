//
//  A2Metrics.h
//  Air2
//
//  尺寸与动效常量。视图层禁止硬编码字面量，一律从这里取。
//

#import <UIKit/UIKit.h>
#import "A2GlassCard.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 间距（4pt 网格）

UIKIT_EXTERN const CGFloat A2SpaceXS;    // 4
UIKIT_EXTERN const CGFloat A2SpaceS;     // 8
UIKIT_EXTERN const CGFloat A2SpaceM;     // 12
UIKIT_EXTERN const CGFloat A2SpaceL;     // 16
UIKIT_EXTERN const CGFloat A2SpaceXL;    // 24
UIKIT_EXTERN const CGFloat A2SpaceXXL;   // 32

/// 页面左右安全边距
UIKIT_EXTERN const CGFloat A2PageMargin;

#pragma mark - 圆角

UIKIT_EXTERN const CGFloat A2RadiusXS;   // 8
UIKIT_EXTERN const CGFloat A2RadiusS;    // 12
UIKIT_EXTERN const CGFloat A2RadiusM;    // 16
UIKIT_EXTERN const CGFloat A2RadiusL;    // 20
UIKIT_EXTERN const CGFloat A2RadiusXL;   // 28

#pragma mark - 高度

UIKIT_EXTERN const CGFloat A2TopBarHeight;      // 52
UIKIT_EXTERN const CGFloat A2ButtonHeight;      // 52
UIKIT_EXTERN const CGFloat A2MinTouchTarget;    // 44
UIKIT_EXTERN const CGFloat A2IconSize;          // 24

#pragma mark - 布局

/// 主界面右侧操作栏宽度
UIKIT_EXTERN CGFloat A2SidePanelWidth(CGFloat screenWidth);
/// 侧栏内边距
UIKIT_EXTERN const CGFloat A2PanelPadding;

#pragma mark - 动效

/// 标准过渡（页面切换、卡片展开）
UIKIT_EXTERN const NSTimeInterval A2AnimDuration;
/// 快速反馈（按压、高亮）
UIKIT_EXTERN const NSTimeInterval A2AnimDurationFast;
/// 慢速（背景切换、大面积）
UIKIT_EXTERN const NSTimeInterval A2AnimDurationSlow;
/// 卡片入场
UIKIT_EXTERN const NSTimeInterval A2AnimDurationCard;

/// 弹簧阻尼比。越接近 1 越稳，0.78 有轻微回弹但不晃。
UIKIT_EXTERN const CGFloat A2SpringDamping;
UIKIT_EXTERN const CGFloat A2SpringVelocity;

/// 卡片入场时的逐个延迟
UIKIT_EXTERN const NSTimeInterval A2CardStaggerDelay;

#pragma mark - 动画器

/// 指定时长的弹簧动画器
UIViewPropertyAnimator *A2SpringAnimator(NSTimeInterval duration);
/// 标准弹簧
UIViewPropertyAnimator *A2StandardSpring(void);
/// 更"软"的弹簧，用于大面积元素
UIViewPropertyAnimator *A2SoftSpring(NSTimeInterval duration);

#pragma mark - 卡片入场动画

/// 给一组视图做依次淡入上浮的入场动画
UIViewPropertyAnimator *A2AnimateCardEntrance(NSArray<UIView *> *views,
                                              CGFloat staggerDelay,
                                              void (^ _Nullable completion)(void));

NS_ASSUME_NONNULL_END

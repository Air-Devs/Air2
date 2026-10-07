//
//  A2Metrics.h
//  Air2
//
//  尺寸、间距、圆角、动效时长的统一常量。
//  禁止在视图代码里硬编码字面量 —— 全部从这里取。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 间距

/// 4pt 基准网格
UIKIT_EXTERN const CGFloat A2SpaceXS;    // 4
UIKIT_EXTERN const CGFloat A2SpaceS;     // 8
UIKIT_EXTERN const CGFloat A2SpaceM;     // 12
UIKIT_EXTERN const CGFloat A2SpaceL;     // 16
UIKIT_EXTERN const CGFloat A2SpaceXL;    // 24
UIKIT_EXTERN const CGFloat A2SpaceXXL;   // 32

/// 页面左右安全边距
UIKIT_EXTERN const CGFloat A2PageMargin;

#pragma mark - 圆角

UIKIT_EXTERN const CGFloat A2RadiusS;    // 10  — 小控件
UIKIT_EXTERN const CGFloat A2RadiusM;    // 14  — 按钮
UIKIT_EXTERN const CGFloat A2RadiusL;    // 18  — 卡片
UIKIT_EXTERN const CGFloat A2RadiusXL;   // 26  — 大卡片 / 弹层

#pragma mark - 高度

UIKIT_EXTERN const CGFloat A2TopBarHeight;      // 44
UIKIT_EXTERN const CGFloat A2ButtonHeight;      // 50
UIKIT_EXTERN const CGFloat A2CardTitleHeight;   // 44
UIKIT_EXTERN const CGFloat A2MinTouchTarget;    // 44  — Apple HIG 下限

#pragma mark - 动效

/// 标准过渡（页面切换、卡片展开）
UIKIT_EXTERN const NSTimeInterval A2AnimDuration;
/// 快速反馈（按压、高亮）
UIKIT_EXTERN const NSTimeInterval A2AnimDurationFast;
/// 慢速（大面积背景、抽屉）
UIKIT_EXTERN const NSTimeInterval A2AnimDurationSlow;

/// 弹簧参数 —— iOS 原生手感
UIKIT_EXTERN const CGFloat A2SpringDamping;
UIKIT_EXTERN const CGFloat A2SpringVelocity;

#pragma mark - 便捷构造

/// 带自定义时长的弹簧
UIViewPropertyAnimator *A2SpringAnimator(NSTimeInterval duration);
/// 标准弹簧
UIViewPropertyAnimator *A2StandardSpring(void);

NS_ASSUME_NONNULL_END

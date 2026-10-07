//
//  A2GlassCard.h
//  Air2
//
//  毛玻璃卡片 —— 全应用的基础视觉单元。
//
//  设计说明：
//  参考 ZL2 的 BackgroundCard/backgroundGlass 思路，但 iOS 侧用系统的
//  UIVisualEffectView 实现，比手工预模糊省电、且自动跟随亮暗模式。
//
//  玻璃强度由 A2ThemeManager.glassIntensity 控制，
//  为 0 或设备性能不足时退化为实色卡片（仍然好看，只是没有模糊）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2GlassCard : UIView

/// 圆角，默认 A2RadiusL
@property (nonatomic, assign) CGFloat cornerRadius;

/// 是否响应点击（会加上按压回弹反馈）
@property (nonatomic, assign) BOOL tappable;

/// 点击回调
@property (nonatomic, copy, nullable) void (^onTap)(void);

/// 内容容器。往这里加子视图，不要直接加到 card 上。
@property (nonatomic, strong, readonly) UIView *contentView;

/// 上下内边距覆盖。默认 A2SpaceL。
@property (nonatomic, assign) UIEdgeInsets contentInsets;

/// 重新套用主题（收到 A2ThemeDidChangeNotification 时自动调用）
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

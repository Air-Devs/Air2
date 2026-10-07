//
//  A2ThemeManager.h
//  Air2
//
//  主题与外观的全局管理。
//
//  职责边界：
//    · 持有当前主题与外观模式
//    · 广播变更（视图订阅后重新取色）
//    · 管理自定义背景（图片/模糊/遮罩强度）
//  不负责：具体视图怎么画 —— 那是视图自己的事。
//

#import <UIKit/UIKit.h>
#import "A2ColorTheme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2AppearanceMode) {
    A2AppearanceModeSystem = 0,  ///< 跟随系统
    A2AppearanceModeLight,       ///< 强制亮色
    A2AppearanceModeDark,        ///< 强制暗色
};

/// 主题变更通知。userInfo: @"theme" → A2ColorTheme
extern NSNotificationName const A2ThemeDidChangeNotification;
/// 背景变更通知（图片/模糊/遮罩）
extern NSNotificationName const A2BackgroundDidChangeNotification;

@interface A2ThemeManager : NSObject

+ (instancetype)shared;

#pragma mark - 主题

/// 当前主题（永不为 nil）
@property (nonatomic, strong, readonly) A2ColorTheme *theme;

/// 当前生效的语义色板 —— 【已按当前亮暗模式解析】。
///
/// 这里返回的是具体色值，不是动态颜色。视图在 applyTheme 里
/// 直接取用即可，不需要关心 trait 环境。
/// 每次 isDark 变化或主题切换后都会重新解析，并广播通知。
@property (nonatomic, strong, readonly) A2ColorScheme *scheme;

@property (nonatomic, assign) A2ThemeKind selectedKind;

/// 配色风格（对应 MD3 的 PaletteStyle）。
/// 影响从种子色推导色板的方式，不改变主题本身。
@property (nonatomic, assign) NSInteger paletteStyle;

/// 用户自定义的种子色。非 nil 时 selectedKind 视为「自定义」。
@property (nonatomic, strong, nullable) UIColor *customSeedColor;

#pragma mark - 外观

@property (nonatomic, assign) A2AppearanceMode appearanceMode;

/// 当前是否为暗色（综合系统与用户设置）
@property (nonatomic, assign, readonly, getter=isDark) BOOL dark;

/// 应用到窗口
- (void)applyAppearanceToWindow:(UIWindow *)window;

#pragma mark - 自定义背景

/// 用户设置的背景图。nil 表示使用主题渐变。
@property (nonatomic, strong, nullable) UIImage *backgroundImage;

/// 背景模糊强度 0~100
@property (nonatomic, assign) NSInteger backgroundBlur;

/// 背景图在暗色模式下的遮罩强度 0.0~1.0，默认 0.28
@property (nonatomic, assign) CGFloat backgroundDarkOverlay;

/// 操作栏一侧的渐隐遮罩宽度比例 0.0~1.0，默认 0.35
/// 作用：用户可能选一张花哨的图，右侧卡片需要稳定的对比度才看得清
@property (nonatomic, assign) CGFloat backgroundFadeRatio;

/// 持久化背景图（存到沙盒，返回是否成功）
- (BOOL)persistBackgroundImage:(UIImage *)image;
/// 从沙盒读取已保存的背景图
- (nullable UIImage *)loadPersistedBackground;
/// 清除自定义背景
- (void)clearBackgroundImage;

#pragma mark - 广播

- (void)notifyThemeChanged;
- (void)notifyBackgroundChanged;

@end

NS_ASSUME_NONNULL_END

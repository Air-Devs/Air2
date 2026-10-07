//
//  A2ThemeManager.h
//  Air2
//
//  主题管理 —— 当前主题、亮暗模式、玻璃强度，并广播变更
//

#import <UIKit/UIKit.h>
#import "A2ColorTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// 外观模式
typedef NS_ENUM(NSInteger, A2AppearanceMode) {
    A2AppearanceModeSystem = 0,  ///< 跟随系统
    A2AppearanceModeLight,       ///< 强制亮色
    A2AppearanceModeDark,        ///< 强制暗色
};

/// 主题变更通知。object 为 A2ThemeManager，userInfo 含 @"theme"。
extern NSNotificationName const A2ThemeDidChangeNotification;

@interface A2ThemeManager : NSObject

/// 当前生效的主题（永不为 nil）
@property (nonatomic, strong, readonly) A2ColorTheme *currentTheme;

/// 用户选择的主题种类（Dynamic 表示跟随壁纸）
@property (nonatomic, assign) A2ThemeKind selectedKind;

/// 外观模式
@property (nonatomic, assign) A2AppearanceMode appearanceMode;

/// 当前是否暗色（综合系统与用户选择）
@property (nonatomic, assign, readonly, getter=isDark) BOOL dark;

/// 玻璃模糊强度 0~100。值越大越模糊，0 = 关闭玻璃
@property (nonatomic, assign) NSInteger glassIntensity;

/// 用户壁纸。设置后若 selectedKind 为 Dynamic 会立即重新取色。
@property (nonatomic, strong, nullable) UIImage *wallpaper;

/// 单例
+ (instancetype)shared;

/// 语义化取色：根据当前亮暗返回对应色
- (UIColor *)backgroundColor;
- (UIColor *)surfaceColor;
- (UIColor *)surfaceElevatedColor;
/// 卡片填充色（含玻璃适配后的半透明）
- (UIColor *)cardFillColor;

/// 为整个 window 套用外观
- (void)applyAppearanceToWindow:(UIWindow *)window;

/// 持久化到 UserDefaults
- (void)persist;

/// 手动触发一次通知（主题对象内部改完后调用）
- (void)notifyChanged;

@end

NS_ASSUME_NONNULL_END

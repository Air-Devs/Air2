//
//  A2ColorTheme.h
//  Air2
//
//  主题 —— 一套配色方案 = 一组 MD3 语义色板。
//
//  色板本身是「动态颜色」（随系统亮暗自动切换），
//  视图层拿 A2ColorTheme.scheme.primary 直接用即可，不需要判断模式。
//

#import <UIKit/UIKit.h>
#import "A2ColorScheme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ThemeKind) {
    A2ThemeKindEmbermire = 0,   ///< 烈焰红棕（默认）
    A2ThemeKindGlacier,         ///< 冰川蓝
    A2ThemeKindVerdantDawn,     ///< 青野绿
    A2ThemeKindVelvetRose,      ///< 绛紫玫瑰
    A2ThemeKindUrbanAsh,        ///< 都市灰
    A2ThemeKindDynamic,         ///< 从自定义背景图取色
    A2ThemeKindCount
};

@interface A2ColorTheme : NSObject

@property (nonatomic, assign, readonly) A2ThemeKind kind;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *themeDescription;

/// MD3 语义色板（动态颜色）
@property (nonatomic, strong, readonly) A2ColorScheme *scheme;

/// 亮 / 暗模式下的具体主色值，用于色板预览
@property (nonatomic, strong, readonly) UIColor *lightPrimary;
@property (nonatomic, strong, readonly) UIColor *darkPrimary;

/// 无自定义背景图时的页面渐变底色
@property (nonatomic, strong, readonly) NSArray<UIColor *> *backgroundGradient;

+ (instancetype)themeForKind:(A2ThemeKind)kind;
+ (NSArray<A2ColorTheme *> *)allThemes;
+ (instancetype)themeFromImage:(UIImage *)image;

/// 构造主题。override 块用于手调关键色，让成品不完全依赖算法。
+ (instancetype)themeWithSeed:(UIColor *)seed
                         kind:(A2ThemeKind)kind
                         name:(NSString *)name
                         desc:(NSString *)desc
                     gradient:(NSArray<UIColor *> *)gradient
                lightOverride:(void (^ _Nullable)(A2ColorScheme *scheme))lightOverride
                 darkOverride:(void (^ _Nullable)(A2ColorScheme *scheme))darkOverride;

@end

NS_ASSUME_NONNULL_END

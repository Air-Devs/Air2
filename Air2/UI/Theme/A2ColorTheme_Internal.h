//
//  A2ColorTheme_Internal.h
//  Air2
//
//  主题的内部结构 —— 供同模块的分类实现使用。
//

#import "A2ColorTheme.h"
#import "A2PaletteStyle.h"

NS_ASSUME_NONNULL_BEGIN

/// 中间结构：填充时先用具体 UIColor，最后再配对成 A2ColorSlot
@interface A2RawScheme : NSObject
@property (nonatomic, strong) UIColor *primary, *onPrimary, *primaryContainer, *onPrimaryContainer;
@property (nonatomic, strong) UIColor *secondary, *onSecondary, *secondaryContainer, *onSecondaryContainer;
@property (nonatomic, strong) UIColor *tertiary, *tertiaryContainer;
@property (nonatomic, strong) UIColor *surface, *onSurface;
@property (nonatomic, strong) UIColor *surfaceContainerLowest, *surfaceContainerLow, *surfaceContainer;
@property (nonatomic, strong) UIColor *surfaceContainerHigh, *surfaceContainerHighest;
@property (nonatomic, strong) UIColor *surfaceVariant, *onSurfaceVariant;
@property (nonatomic, strong) UIColor *outline, *outlineVariant;
@property (nonatomic, strong) UIColor *error, *onError, *errorContainer, *onErrorContainer;
@property (nonatomic, strong) UIColor *success, *warning;
@property (nonatomic, strong) UIColor *inverseSurface, *inverseOnSurface, *inversePrimary;
@end

/// 按风格参数推导色板
void A2FillSchemeWithParams(A2RawScheme *s, UIColor *seed, BOOL light, A2PaletteParams params);

/// 把亮/暗两个具体色板配对成色槽
void A2PairSchemePublic(A2ColorScheme *out, A2RawScheme *light, A2RawScheme *dark);

/// 主题的可写属性（供分类实现赋值）
@interface A2ColorTheme ()
@property (nonatomic, assign) A2ThemeKind kind;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *themeDescription;
@property (nonatomic, strong) A2ColorScheme *scheme;
@property (nonatomic, strong) UIColor *lightPrimary;
@property (nonatomic, strong) UIColor *darkPrimary;
@property (nonatomic, strong) NSArray<UIColor *> *backgroundGradient;
@end

NS_ASSUME_NONNULL_END

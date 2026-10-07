//
//  A2ColorTheme+Seed.m
//  Air2
//
//  从「种子色 + 配色风格」构造主题。
//
//  这是颜色主题弹窗使用的入口：用户在大色盘里选一个颜色，
//  再选一个配色风格，由此推导出完整的亮暗两套色板。
//

#import "A2ColorTheme_Internal.h"

@implementation A2ColorTheme (Seed)

+ (instancetype)themeWithSeedColor:(UIColor *)seed
                      paletteStyle:(NSInteger)style
                              name:(NSString *)name
                              desc:(NSString *)desc {

    A2PaletteParams params = A2PaletteParamsForStyle((A2PaletteStyle)style);

    A2RawScheme *light = [A2RawScheme new];
    A2RawScheme *dark = [A2RawScheme new];
    A2FillSchemeWithParams(light, seed, YES, params);
    A2FillSchemeWithParams(dark, seed, NO, params);

    A2ColorScheme *merged = [A2ColorScheme new];
    A2PairSchemePublic(merged, light, dark);

    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindCustom;
    t.displayName = name;
    t.themeDescription = desc;
    t.scheme = merged;
    t.lightPrimary = light.primary;
    t.darkPrimary = dark.primary;

    // 背景渐变由种子色推导：深 → 种子色 → 更深
    t.backgroundGradient = @[
        A2Tone(seed, MIN(1.0, params.saturationCap * 1.1), 0.34),
        seed,
        A2Tone(seed, MIN(1.0, params.saturationCap * 1.15), 0.16),
    ];
    return t;
}

@end

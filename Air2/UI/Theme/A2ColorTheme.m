//
//  A2ColorTheme.m
//  Air2
//

#import "A2ColorTheme.h"

/// 从 0xRRGGBB 构造颜色
static UIColor *A2Hex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

#pragma mark - 私有可变实现

@interface A2ColorTheme ()
@property (nonatomic, assign) A2ThemeKind kind;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) UIColor *primary;
@property (nonatomic, strong) UIColor *onPrimary;
@property (nonatomic, strong) UIColor *primaryContainer;
@property (nonatomic, strong) UIColor *accent;
@property (nonatomic, strong) UIColor *background;
@property (nonatomic, strong) UIColor *backgroundDark;
@property (nonatomic, strong) UIColor *surface;
@property (nonatomic, strong) UIColor *surfaceElevated;
@property (nonatomic, strong) UIColor *textPrimary;
@property (nonatomic, strong) UIColor *textSecondary;
@property (nonatomic, strong) UIColor *textTertiary;
@property (nonatomic, strong) UIColor *danger;
@property (nonatomic, strong) UIColor *success;
@property (nonatomic, strong) NSArray<UIColor *> *wallpaperGradient;
@end

@implementation A2ColorTheme

#pragma mark - 五套手调色板

/// Embermire —— 烈焰红棕。暖调，默认主题。
+ (instancetype)embermire {
    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindEmbermire;
    t.displayName = @"烈焰红棕";
    t.primary = A2Hex(0xA63A17);
    t.onPrimary = UIColor.whiteColor;
    t.primaryContainer = A2Hex(0xFE7A52);
    t.accent = A2Hex(0xFFB59F);
    t.background = A2Hex(0xFFF8F6);
    t.backgroundDark = A2Hex(0x1A0E0A);
    t.surface = A2Hex(0xFFE9E4);
    t.surfaceElevated = A2Hex(0xFFFFF1ED);
    t.textPrimary = A2Hex(0x241916);
    t.textSecondary = A2Hex(0x58423B);
    t.textTertiary = A2Hex(0x8B716A);
    t.danger = A2Hex(0xBA1A1A);
    t.success = A2Hex(0x276E31);
    t.wallpaperGradient = @[ A2Hex(0x8B2D0F), A2Hex(0xC4502B), A2Hex(0x4A1A08) ];
    return t;
}

/// Glacier —— 冰川蓝。冷调，长时间使用眼睛负担小。
+ (instancetype)glacier {
    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindGlacier;
    t.displayName = @"冰川蓝";
    t.primary = A2Hex(0x007EA2);
    t.onPrimary = UIColor.whiteColor;
    t.primaryContainer = A2Hex(0x4CAFD6);
    t.accent = A2Hex(0x73D2FB);
    t.background = A2Hex(0xF6FAFD);
    t.backgroundDark = A2Hex(0x081A22);
    t.surface = A2Hex(0xEBEEF1);
    t.surfaceElevated = A2Hex(0xF0F4F7);
    t.textPrimary = A2Hex(0x181C1F);
    t.textSecondary = A2Hex(0x3E484E);
    t.textTertiary = A2Hex(0x6E797E);
    t.danger = A2Hex(0xBA1A1A);
    t.success = A2Hex(0x276E31);
    t.wallpaperGradient = @[ A2Hex(0x00506B), A2Hex(0x0A8FB8), A2Hex(0x00303F) ];
    return t;
}

/// VerdantDawn —— 青野绿。生机感，适合 Minecraft 主题。
+ (instancetype)verdantDawn {
    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindVerdantDawn;
    t.displayName = @"青野绿";
    t.primary = A2Hex(0x276E31);
    t.onPrimary = UIColor.whiteColor;
    t.primaryContainer = A2Hex(0x4E9A5C);
    t.accent = A2Hex(0x8ED88E);
    t.background = A2Hex(0xF7FBF2);
    t.backgroundDark = A2Hex(0x0C170C);
    t.surface = A2Hex(0xECEFE6);
    t.surfaceElevated = A2Hex(0xF1F5EC);
    t.textPrimary = A2Hex(0x181D18);
    t.textSecondary = A2Hex(0x40493E);
    t.textTertiary = A2Hex(0x707A6D);
    t.danger = A2Hex(0xBA1A1A);
    t.success = A2Hex(0x276E31);
    t.wallpaperGradient = @[ A2Hex(0x14501E), A2Hex(0x2E7A3A), A2Hex(0x0A3313) ];
    return t;
}

/// VelvetRose —— 绛紫玫瑰。柔和，偏女性化审美。
+ (instancetype)velvetRose {
    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindVelvetRose;
    t.displayName = @"绛紫玫瑰";
    t.primary = A2Hex(0x723D57);
    t.onPrimary = UIColor.whiteColor;
    t.primaryContainer = A2Hex(0x9B607C);
    t.accent = A2Hex(0xF9B2D2);
    t.background = A2Hex(0xFFF8F8);
    t.backgroundDark = A2Hex(0x1B1016);
    t.surface = A2Hex(0xF7EBED);
    t.surfaceElevated = A2Hex(0xFCF1F3);
    t.textPrimary = A2Hex(0x1F1A1C);
    t.textSecondary = A2Hex(0x504348);
    t.textTertiary = A2Hex(0x827378);
    t.danger = A2Hex(0xBA1A1A);
    t.success = A2Hex(0x276E31);
    t.wallpaperGradient = @[ A2Hex(0x4E2438), A2Hex(0x8A4A68), A2Hex(0x33172A) ];
    return t;
}

/// UrbanAsh —— 都市灰。中性无彩，适合专注场景。
+ (instancetype)urbanAsh {
    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindUrbanAsh;
    t.displayName = @"都市灰";
    t.primary = A2Hex(0x5E5E5F);
    t.onPrimary = UIColor.whiteColor;
    t.primaryContainer = A2Hex(0x8E8E90);
    t.accent = A2Hex(0xC7C6C6);
    t.background = A2Hex(0xFCF8F8);
    t.backgroundDark = A2Hex(0x141414);
    t.surface = A2Hex(0xF1EDEC);
    t.surfaceElevated = A2Hex(0xF7F3F2);
    t.textPrimary = A2Hex(0x1C1B1B);
    t.textSecondary = A2Hex(0x444748);
    t.textTertiary = A2Hex(0x747878);
    t.danger = A2Hex(0xBA1A1A);
    t.success = A2Hex(0x276E31);
    t.wallpaperGradient = @[ A2Hex(0x3A3A3C), A2Hex(0x5A5A5D), A2Hex(0x28282A) ];
    return t;
}

+ (NSArray<A2ColorTheme *> *)allThemes {
    return @[
        [self embermire],
        [self glacier],
        [self verdantDawn],
        [self velvetRose],
        [self urbanAsh],
    ];
}

+ (instancetype)themeForKind:(A2ThemeKind)kind {
    switch (kind) {
        case A2ThemeKindEmbermire:   return [self embermire];
        case A2ThemeKindGlacier:     return [self glacier];
        case A2ThemeKindVerdantDawn: return [self verdantDawn];
        case A2ThemeKindVelvetRose:  return [self velvetRose];
        case A2ThemeKindUrbanAsh:    return [self urbanAsh];
        case A2ThemeKindDynamic:
        default:                     return [self embermire];
    }
}

#pragma mark - 动态取色

/// 把任意颜色规范化为「有品牌感」的主色：
/// 饱和度不足时提升，亮度钳制到中等区间，避免取到灰扑扑或刺眼的色
static UIColor *A2NormalizeBrandColor(UIColor *src) {
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if (![src getHue:&h saturation:&s brightness:&b alpha:&a]) return src;

    // 低饱和度的壁纸（灰阶/黑白云图）提取出来没有品牌感，给一个最低饱和度
    if (s < 0.28) s = 0.28 + s * 0.4;
    // 亮度太低会与暗色背景糊在一起，太高会刺眼
    if (b < 0.34) b = 0.34;
    if (b > 0.78) b = 0.78;

    return [UIColor colorWithHue:h saturation:s brightness:b alpha:1.0];
}

/// 主色的浅色版本，用于 container
static UIColor *A2Lighten(UIColor *src, CGFloat amount) {
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if (![src getHue:&h saturation:&s brightness:&b alpha:&a]) return src;
    return [UIColor colorWithHue:h
                      saturation:MAX(0, s - amount * 0.4)
                      brightness:MIN(1.0, b + amount)
                           alpha:1.0];
}

+ (instancetype)themeFromImage:(UIImage *)image {
    if (!image) return [self embermire];

    // 缩到 1x1 取平均色 —— 比逐像素遍历快几个数量级，且天然抗噪
    CGSize side = CGSizeMake(1, 1);
    UIGraphicsBeginImageContextWithOptions(side, YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, 1, 1)];
    UIImage *averaged = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!averaged) return [self embermire];

    CGImageRef cg = averaged.CGImage;
    if (!cg) return [self embermire];

    CGDataProviderRef provider = CGImageGetDataProvider(cg);
    CFDataRef data = CGDataProviderCopyData(provider);
    if (!data) return [self embermire];

    const UInt8 *bytes = CFDataGetBytePtr(data);
    size_t len = CFDataGetLength(data);
    if (len < 4) {
        CFRelease(data);
        return [self embermire];
    }

    CGFloat r = bytes[0] / 255.0;
    CGFloat g = bytes[1] / 255.0;
    CGFloat b = bytes[2] / 255.0;
    CFRelease(data);

    UIColor *extracted = A2NormalizeBrandColor([UIColor colorWithRed:r green:g blue:b alpha:1.0]);

    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = A2ThemeKindDynamic;
    t.displayName = @"动态取色";
    t.primary = extracted;
    t.onPrimary = UIColor.whiteColor;
    t.primaryContainer = A2Lighten(extracted, 0.22);
    t.accent = A2Lighten(extracted, 0.38);

    CGFloat h = 0, s = 0, br = 0, alpha = 0;
    [extracted getHue:&h saturation:&s brightness:&br alpha:&alpha];

    t.background = [UIColor colorWithHue:h saturation:MIN(0.06, s * 0.2) brightness:0.98 alpha:1.0];
    t.backgroundDark = [UIColor colorWithHue:h saturation:MIN(0.42, s * 0.7) brightness:0.10 alpha:1.0];
    t.surface = [UIColor colorWithHue:h saturation:MIN(0.10, s * 0.25) brightness:0.93 alpha:1.0];
    t.surfaceElevated = [UIColor colorWithHue:h saturation:MIN(0.08, s * 0.2) brightness:0.96 alpha:1.0];
    t.textPrimary = [UIColor colorWithHue:h saturation:MIN(0.35, s * 0.6) brightness:0.12 alpha:1.0];
    t.textSecondary = [UIColor colorWithHue:h saturation:MIN(0.30, s * 0.5) brightness:0.32 alpha:1.0];
    t.textTertiary = [UIColor colorWithHue:h saturation:MIN(0.25, s * 0.4) brightness:0.52 alpha:1.0];
    t.danger = A2Hex(0xBA1A1A);
    t.success = A2Hex(0x276E31);

    // 背景渐变：深→主色→更深，保证玻璃卡片有足够的明暗层次可透
    UIColor *deep = [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.15) brightness:MAX(0.18, br * 0.55) alpha:1.0];
    UIColor *darker = [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.2) brightness:MAX(0.10, br * 0.30) alpha:1.0];
    t.wallpaperGradient = @[ deep, extracted, darker ];

    return t;
}

@end

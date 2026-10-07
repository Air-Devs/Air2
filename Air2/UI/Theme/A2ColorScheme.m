//
//  A2ColorScheme.m
//  Air2
//

#import "A2ColorScheme.h"

#pragma mark - 工具函数

UIColor *A2Hex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

void A2GetHSB(UIColor *c, CGFloat *h, CGFloat *s, CGFloat *b) {
    CGFloat a = 0;
    if (![c getHue:h saturation:s brightness:b alpha:&a]) {
        *h = 0; *s = 0; *b = 0.5;
    }
}

UIColor *A2Tone(UIColor *seed, CGFloat sat, CGFloat bright) {
    CGFloat h = 0, s = 0, b = 0;
    A2GetHSB(seed, &h, &s, &b);
    // 灰阶种子也保留一丝饱和度，否则整板死灰没有层次
    if (s < 0.02) s = 0.02;
    return [UIColor colorWithHue:h
                      saturation:MAX(0.0, MIN(1.0, sat))
                      brightness:MAX(0.0, MIN(1.0, bright))
                           alpha:1.0];
}

UIColor *A2ShiftHue(UIColor *seed, CGFloat delta) {
    CGFloat h = 0, s = 0, b = 0;
    A2GetHSB(seed, &h, &s, &b);
    return [UIColor colorWithHue:fmod(h + delta + 1.0, 1.0) saturation:s brightness:b alpha:1.0];
}

uint32_t A2RGBValue(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return 0x808080;
    return ((uint32_t)lround(r * 255) << 16) |
           ((uint32_t)lround(g * 255) << 8) |
            (uint32_t)lround(b * 255);
}

#pragma mark - A2ColorSlot

@implementation A2ColorSlot

+ (instancetype)light:(UIColor *)light dark:(UIColor *)dark {
    A2ColorSlot *s = [A2ColorSlot new];
    s.light = light;
    s.dark = dark;
    return s;
}

- (UIColor *)colorForDark:(BOOL)isDark {
    return isDark ? (self.dark ?: self.light) : (self.light ?: self.dark);
}

@end

#pragma mark - A2ColorScheme

@interface A2ColorScheme ()
// 解析后的具体色值
@property (nonatomic, strong) UIColor *cPrimary;
@property (nonatomic, strong) UIColor *cOnPrimary;
@property (nonatomic, strong) UIColor *cPrimaryContainer;
@property (nonatomic, strong) UIColor *cOnPrimaryContainer;
@property (nonatomic, strong) UIColor *cSecondary;
@property (nonatomic, strong) UIColor *cOnSecondary;
@property (nonatomic, strong) UIColor *cSecondaryContainer;
@property (nonatomic, strong) UIColor *cOnSecondaryContainer;
@property (nonatomic, strong) UIColor *cTertiary;
@property (nonatomic, strong) UIColor *cTertiaryContainer;
@property (nonatomic, strong) UIColor *cSurface;
@property (nonatomic, strong) UIColor *cOnSurface;
@property (nonatomic, strong) UIColor *cSurfaceContainerLowest;
@property (nonatomic, strong) UIColor *cSurfaceContainerLow;
@property (nonatomic, strong) UIColor *cSurfaceContainer;
@property (nonatomic, strong) UIColor *cSurfaceContainerHigh;
@property (nonatomic, strong) UIColor *cSurfaceContainerHighest;
@property (nonatomic, strong) UIColor *cSurfaceVariant;
@property (nonatomic, strong) UIColor *cOnSurfaceVariant;
@property (nonatomic, strong) UIColor *cOutline;
@property (nonatomic, strong) UIColor *cOutlineVariant;
@property (nonatomic, strong) UIColor *cError;
@property (nonatomic, strong) UIColor *cOnError;
@property (nonatomic, strong) UIColor *cErrorContainer;
@property (nonatomic, strong) UIColor *cOnErrorContainer;
@property (nonatomic, strong) UIColor *cSuccess;
@property (nonatomic, strong) UIColor *cWarning;
@property (nonatomic, strong) UIColor *cInverseSurface;
@property (nonatomic, strong) UIColor *cInverseOnSurface;
@property (nonatomic, strong) UIColor *cInversePrimary;
@property (nonatomic, assign) BOOL resolvedIsDark;
@end

@implementation A2ColorScheme

- (instancetype)resolvedForDark:(BOOL)isDark {
    A2ColorScheme *r = [A2ColorScheme new];
    r.resolvedIsDark = isDark;

    // 逐槽按模式取具体值。手写而不是反射 ——
    // 属性名列表是稳定的，显式写编译期能查错，
    // 也不会因为改名在运行时静默失效。
#define A2RESOLVE(slot, prop) r.prop = [self.slot colorForDark:isDark]
    A2RESOLVE(primary, cPrimary);
    A2RESOLVE(onPrimary, cOnPrimary);
    A2RESOLVE(primaryContainer, cPrimaryContainer);
    A2RESOLVE(onPrimaryContainer, cOnPrimaryContainer);
    A2RESOLVE(secondary, cSecondary);
    A2RESOLVE(onSecondary, cOnSecondary);
    A2RESOLVE(secondaryContainer, cSecondaryContainer);
    A2RESOLVE(onSecondaryContainer, cOnSecondaryContainer);
    A2RESOLVE(tertiary, cTertiary);
    A2RESOLVE(tertiaryContainer, cTertiaryContainer);
    A2RESOLVE(surface, cSurface);
    A2RESOLVE(onSurface, cOnSurface);
    A2RESOLVE(surfaceContainerLowest, cSurfaceContainerLowest);
    A2RESOLVE(surfaceContainerLow, cSurfaceContainerLow);
    A2RESOLVE(surfaceContainer, cSurfaceContainer);
    A2RESOLVE(surfaceContainerHigh, cSurfaceContainerHigh);
    A2RESOLVE(surfaceContainerHighest, cSurfaceContainerHighest);
    A2RESOLVE(surfaceVariant, cSurfaceVariant);
    A2RESOLVE(onSurfaceVariant, cOnSurfaceVariant);
    A2RESOLVE(outline, cOutline);
    A2RESOLVE(outlineVariant, cOutlineVariant);
    A2RESOLVE(error, cError);
    A2RESOLVE(onError, cOnError);
    A2RESOLVE(errorContainer, cErrorContainer);
    A2RESOLVE(onErrorContainer, cOnErrorContainer);
    A2RESOLVE(success, cSuccess);
    A2RESOLVE(warning, cWarning);
    A2RESOLVE(inverseSurface, cInverseSurface);
    A2RESOLVE(inverseOnSurface, cInverseOnSurface);
    A2RESOLVE(inversePrimary, cInversePrimary);
#undef A2RESOLVE

    return r;
}

@end

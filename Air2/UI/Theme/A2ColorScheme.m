//
//  A2ColorScheme.m
//  Air2
//
//  MD3 语义色板的存储结构与「亮暗合并为动态颜色」逻辑。
//

#import "A2ColorScheme.h"

#pragma mark - 工具函数

UIColor *A2Hex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

/// 构造随亮暗切换的动态颜色
UIColor *A2DynamicColor(uint32_t lightRGB, uint32_t darkRGB) {
    UIColor *light = A2Hex(lightRGB);
    UIColor *dark = A2Hex(darkRGB);
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        }];
    }
    return light;
}

uint32_t A2RGBValue(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return 0x808080;
    return ((uint32_t)lround(r * 255) << 16) |
           ((uint32_t)lround(g * 255) << 8) |
            (uint32_t)lround(b * 255);
}

void A2GetHSB(UIColor *c, CGFloat *h, CGFloat *s, CGFloat *b) {
    CGFloat a = 0;
    if (![c getHue:h saturation:s brightness:b alpha:&a]) {
        *h = 0; *s = 0; *b = 0.5;
    }
}

/// 以指定饱和度/亮度重建同色相颜色
UIColor *A2Tone(UIColor *seed, CGFloat sat, CGFloat bright) {
    CGFloat h = 0, s = 0, b = 0;
    A2GetHSB(seed, &h, &s, &b);
    // 灰阶种子也保留一丝色相，否则整板死灰没有层次
    if (s < 0.02) s = 0.02;
    return [UIColor colorWithHue:h
                      saturation:MAX(0.0, MIN(1.0, sat))
                      brightness:MAX(0.0, MIN(1.0, bright))
                           alpha:1.0];
}

/// 色相偏移，用于生成 tertiary
UIColor *A2ShiftHue(UIColor *seed, CGFloat delta) {
    CGFloat h = 0, s = 0, b = 0;
    A2GetHSB(seed, &h, &s, &b);
    return [UIColor colorWithHue:fmod(h + delta + 1.0, 1.0) saturation:s brightness:b alpha:1.0];
}

#pragma mark - A2ColorScheme

@implementation A2ColorScheme

/// 关键实现：把亮/暗两组具体色值字段逐个包装成动态颜色。
/// 手写而不是用 KVC 反射，因为属性名列表是稳定的，
/// 显式写出来编译期就能查错，也不会在运行时因为改名静默失效。
- (void)makeDynamicFromLight:(A2ColorScheme *)light dark:(A2ColorScheme *)dark {
#define A2MERGE(prop) self.prop = A2DynamicColor(A2RGBValue(light.prop), A2RGBValue(dark.prop))
    A2MERGE(primary);
    A2MERGE(onPrimary);
    A2MERGE(primaryContainer);
    A2MERGE(onPrimaryContainer);
    A2MERGE(secondary);
    A2MERGE(onSecondary);
    A2MERGE(secondaryContainer);
    A2MERGE(onSecondaryContainer);
    A2MERGE(tertiary);
    A2MERGE(tertiaryContainer);
    A2MERGE(surface);
    A2MERGE(onSurface);
    A2MERGE(surfaceContainerLowest);
    A2MERGE(surfaceContainerLow);
    A2MERGE(surfaceContainer);
    A2MERGE(surfaceContainerHigh);
    A2MERGE(surfaceContainerHighest);
    A2MERGE(surfaceVariant);
    A2MERGE(onSurfaceVariant);
    A2MERGE(outline);
    A2MERGE(outlineVariant);
    A2MERGE(error);
    A2MERGE(onError);
    A2MERGE(errorContainer);
    A2MERGE(onErrorContainer);
    A2MERGE(success);
    A2MERGE(warning);
    A2MERGE(inverseSurface);
    A2MERGE(inverseOnSurface);
    A2MERGE(inversePrimary);
#undef A2MERGE
}

@end

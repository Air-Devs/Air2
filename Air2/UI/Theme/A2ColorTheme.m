//
//  A2ColorTheme.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//

#import "A2ColorTheme.h"
#import "A2ColorTheme_Internal.h"

#pragma mark - 色板推导

/// 由种子色推导一套完整的 MD3 色板。
///
/// 明度阶梯参考 MD3 tonal palette 的常用档位：
///   primary        → tone 40（亮）/ tone 80（暗）
///   container      → tone 90（亮）/ tone 30（暗）
///   surface        → tone 99（亮）/ tone 10（暗）
///   surfaceContainer 逐档加深
///
/// 说明：MD3 规范用 HCT 色彩空间，这里用 HSB 近似。
/// 视觉上与规范接近，代价是极端色相下略有偏差（已用钳制规避）。
/// 完整的 HCT 实现收益不大，代码量却要翻几倍，不划算。
@implementation A2RawScheme
@end

/// 按风格参数调整后的饱和度上限
static CGFloat A2ApplySat(float sat, A2PaletteParams p) {
    return MIN(p.saturationCap, sat * p.saturationScale);
}

void A2FillSchemeWithParams(A2RawScheme *s, UIColor *seed, BOOL light, A2PaletteParams p) {
    if (light) {
        s.primary            = A2Tone(seed, A2ApplySat(0.72, p), 0.48);
        s.onPrimary          = A2Hex(0xFFFFFF);
        s.primaryContainer   = A2Tone(seed, 0.34, 0.92);
        s.onPrimaryContainer = A2Tone(seed, 0.66, 0.24);

        s.secondary            = A2Tone(seed, 0.30, 0.40);
        s.onSecondary          = A2Hex(0xFFFFFF);
        s.secondaryContainer   = A2Tone(seed, 0.20, 0.90);
        s.onSecondaryContainer = A2Tone(seed, 0.38, 0.26);

        // 第三色偏移 1/3 色相，给界面一点色彩变化，避免单一色相发闷
        UIColor *t3 = A2ShiftHue(seed, p.tertiaryHueShift);
        s.tertiary          = A2Tone(t3, 0.42, 0.42);
        s.tertiaryContainer = A2Tone(t3, 0.24, 0.90);

        s.surface                 = A2Tone(seed, 0.03 * p.surfaceTint * 3, 0.985);
        s.onSurface               = A2Tone(seed, 0.16, 0.12);
        s.surfaceContainerLowest  = A2Hex(0xFFFFFF);
        s.surfaceContainerLow     = A2Tone(seed, 0.05, 0.965);
        s.surfaceContainer        = A2Tone(seed, 0.07 * p.surfaceTint * 2, 0.935);
        s.surfaceContainerHigh    = A2Tone(seed, 0.09, 0.905);
        s.surfaceContainerHighest = A2Tone(seed, 0.11, 0.875);
        s.surfaceVariant          = A2Tone(seed, 0.13, 0.90);
        s.onSurfaceVariant        = A2Tone(seed, 0.24, 0.32);

        s.outline        = A2Tone(seed, 0.18, 0.50);
        s.outlineVariant = A2Tone(seed, 0.15, 0.78);

        s.inverseSurface   = A2Tone(seed, 0.16, 0.20);
        s.inverseOnSurface = A2Tone(seed, 0.07, 0.94);
        s.inversePrimary   = A2Tone(seed, 0.34, 0.86);

    } else {
        s.primary            = A2Tone(seed, A2ApplySat(0.55, p), 0.82);
        s.onPrimary          = A2Tone(seed, 0.75, 0.18);
        s.primaryContainer   = A2Tone(seed, 0.68, 0.34);
        s.onPrimaryContainer = A2Tone(seed, 0.34, 0.92);

        s.secondary            = A2Tone(seed, 0.26, 0.80);
        s.onSecondary          = A2Tone(seed, 0.40, 0.20);
        s.secondaryContainer   = A2Tone(seed, 0.30, 0.30);
        s.onSecondaryContainer = A2Tone(seed, 0.20, 0.90);

        UIColor *t3 = A2ShiftHue(seed, p.tertiaryHueShift);
        s.tertiary          = A2Tone(t3, 0.34, 0.80);
        s.tertiaryContainer = A2Tone(t3, 0.26, 0.32);

        s.surface                 = A2Tone(seed, 0.16 * p.surfaceTint, 0.09);
        s.onSurface               = A2Tone(seed, 0.07, 0.92);
        s.surfaceContainerLowest  = A2Tone(seed, 0.18, 0.05);
        s.surfaceContainerLow     = A2Tone(seed, 0.16, 0.12);
        s.surfaceContainer        = A2Tone(seed, 0.15 * p.surfaceTint, 0.15);
        s.surfaceContainerHigh    = A2Tone(seed, 0.14, 0.19);
        s.surfaceContainerHighest = A2Tone(seed, 0.13, 0.23);
        s.surfaceVariant          = A2Tone(seed, 0.18, 0.27);
        s.onSurfaceVariant        = A2Tone(seed, 0.12, 0.80);

        s.outline        = A2Tone(seed, 0.12, 0.58);
        s.outlineVariant = A2Tone(seed, 0.16, 0.30);

        s.inverseSurface   = A2Tone(seed, 0.07, 0.92);
        s.inverseOnSurface = A2Tone(seed, 0.16, 0.20);
        s.inversePrimary   = A2Tone(seed, 0.72, 0.48);
    }

    // 语义色全主题统一 —— 错误必须是红的，这是跨应用的认知一致性，
    // 不跟着主色走。
    if (light) {
        s.error            = A2Hex(0xBA1A1A);
        s.onError          = A2Hex(0xFFFFFF);
        s.errorContainer   = A2Hex(0xFFDAD6);
        s.onErrorContainer = A2Hex(0x410002);
        s.success          = A2Hex(0x2E6B36);
        s.warning          = A2Hex(0x8A5300);
    } else {
        s.error            = A2Hex(0xFFB4AB);
        s.onError          = A2Hex(0x690005);
        s.errorContainer   = A2Hex(0x93000A);
        s.onErrorContainer = A2Hex(0xFFDAD6);
        s.success          = A2Hex(0x8ED88E);
        s.warning          = A2Hex(0xF5C36B);
    }
}

#pragma mark - A2ColorTheme

/// 把「亮版」与「暗版」两个具体色板配对成 A2ColorSlot。
///
/// 这是整个配色系统的关键一步：色槽同时持有两种模式的具体色值，
/// 视图在 applyTheme 时按 isDark 取用 —— 不依赖 trait 解析，
/// 因此不会出现「系统暗色但卡片渲染成亮色」的问题。
void A2PairSchemePublic(A2ColorScheme *out, A2RawScheme *light, A2RawScheme *dark) {
#define A2PAIR(prop) out.prop = [A2ColorSlot light:light.prop dark:dark.prop]
    A2PAIR(primary);            A2PAIR(onPrimary);
    A2PAIR(primaryContainer);   A2PAIR(onPrimaryContainer);
    A2PAIR(secondary);          A2PAIR(onSecondary);
    A2PAIR(secondaryContainer); A2PAIR(onSecondaryContainer);
    A2PAIR(tertiary);           A2PAIR(tertiaryContainer);
    A2PAIR(surface);            A2PAIR(onSurface);
    A2PAIR(surfaceContainerLowest);  A2PAIR(surfaceContainerLow);
    A2PAIR(surfaceContainer);        A2PAIR(surfaceContainerHigh);
    A2PAIR(surfaceContainerHighest);
    A2PAIR(surfaceVariant);     A2PAIR(onSurfaceVariant);
    A2PAIR(outline);            A2PAIR(outlineVariant);
    A2PAIR(error);              A2PAIR(onError);
    A2PAIR(errorContainer);     A2PAIR(onErrorContainer);
    A2PAIR(success);            A2PAIR(warning);
    A2PAIR(inverseSurface);     A2PAIR(inverseOnSurface);
    A2PAIR(inversePrimary);
#undef A2PAIR
}

@implementation A2ColorTheme

+ (instancetype)themeWithSeed:(UIColor *)seed
                         kind:(A2ThemeKind)kind
                         name:(NSString *)name
                         desc:(NSString *)desc
                     gradient:(NSArray<UIColor *> *)gradient
                lightOverride:(void (^)(A2RawScheme *))lightOverride
                 darkOverride:(void (^)(A2RawScheme *))darkOverride {

    // 内置主题用中性基准风格（TonalSpot）
    A2PaletteParams params = A2PaletteParamsForStyle(A2PaletteStyleTonalSpot);

    A2RawScheme *light = [A2RawScheme new];
    A2RawScheme *dark = [A2RawScheme new];
    A2FillSchemeWithParams(light, seed, YES, params);
    A2FillSchemeWithParams(dark, seed, NO, params);

    if (lightOverride) lightOverride(light);
    if (darkOverride) darkOverride(dark);

    A2ColorScheme *merged = [A2ColorScheme new];
    A2PairSchemePublic(merged, light, dark);

    A2ColorTheme *t = [A2ColorTheme new];
    t.kind = kind;
    t.displayName = name;
    t.themeDescription = desc;
    t.scheme = merged;
    t.lightPrimary = light.primary;
    t.darkPrimary = dark.primary;
    t.backgroundGradient = gradient;
    return t;
}

#pragma mark 五套内置主题

+ (instancetype)embermire {
    // 暖棕色的自动推导容易偏灰，关键色手调
    return [self themeWithSeed:A2Hex(0xA63A17)
                         kind:A2ThemeKindEmbermire
                         name:@"烈焰红棕"
                         desc:@"暖调，视觉重心强"
                     gradient:@[ A2Hex(0x8B2D0F), A2Hex(0xC4502B), A2Hex(0x4A1A08) ]
                lightOverride:^(A2RawScheme *s) {
        s.primary              = A2Hex(0xA63A17);
        s.primaryContainer     = A2Hex(0xFFDBD1);
        s.surface              = A2Hex(0xFFF8F6);
        s.surfaceContainer     = A2Hex(0xFCEAE5);
        s.surfaceContainerHigh = A2Hex(0xF7E3DE);
        s.onSurface            = A2Hex(0x241916);
        s.onSurfaceVariant     = A2Hex(0x58423B);
    } darkOverride:^(A2RawScheme *s) {
        s.primary              = A2Hex(0xFFB59F);
        s.primaryContainer     = A2Hex(0x7F2A05);
        s.surface              = A2Hex(0x1A110E);
        s.surfaceContainer     = A2Hex(0x271A16);
        s.surfaceContainerHigh = A2Hex(0x33231F);
        s.onSurface            = A2Hex(0xF1DFDA);
        s.onSurfaceVariant     = A2Hex(0xDBC2BA);
    }];
}

+ (instancetype)glacier {
    return [self themeWithSeed:A2Hex(0x00658B)
                         kind:A2ThemeKindGlacier
                         name:@"冰川蓝"
                         desc:@"冷调，长时间使用更舒适"
                     gradient:@[ A2Hex(0x004A66), A2Hex(0x0A8FB8), A2Hex(0x002F42) ]
                lightOverride:^(A2RawScheme *s) {
        s.primary            = A2Hex(0x00658B);
        s.primaryContainer   = A2Hex(0xC2E8FF);
        s.onPrimaryContainer = A2Hex(0x001E2E);
    } darkOverride:^(A2RawScheme *s) {
        s.primary          = A2Hex(0x7FD0F5);
        s.onPrimary        = A2Hex(0x003549);
        s.primaryContainer = A2Hex(0x004C6B);
    }];
}

+ (instancetype)verdantDawn {
    return [self themeWithSeed:A2Hex(0x2C6B36)
                         kind:A2ThemeKindVerdantDawn
                         name:@"青野绿"
                         desc:@"自然色，与游戏主题呼应"
                     gradient:@[ A2Hex(0x14501E), A2Hex(0x2E7A3A), A2Hex(0x0A3313) ]
                lightOverride:^(A2RawScheme *s) {
        s.primary            = A2Hex(0x2C6B36);
        s.primaryContainer   = A2Hex(0xC8EFC6);
        s.onPrimaryContainer = A2Hex(0x002204);
    } darkOverride:^(A2RawScheme *s) {
        s.primary          = A2Hex(0x8ED88E);
        s.onPrimary        = A2Hex(0x00390F);
        s.primaryContainer = A2Hex(0x0F5220);
    }];
}

+ (instancetype)velvetRose {
    return [self themeWithSeed:A2Hex(0x7A3D58)
                         kind:A2ThemeKindVelvetRose
                         name:@"绛紫玫瑰"
                         desc:@"柔和，低对比"
                     gradient:@[ A2Hex(0x4E2438), A2Hex(0x8A4A68), A2Hex(0x33172A) ]
                lightOverride:^(A2RawScheme *s) {
        s.primary            = A2Hex(0x7A3D58);
        s.primaryContainer   = A2Hex(0xFFD8E6);
        s.onPrimaryContainer = A2Hex(0x31081F);
    } darkOverride:^(A2RawScheme *s) {
        s.primary          = A2Hex(0xF9B2D2);
        s.onPrimary        = A2Hex(0x4B1130);
        s.primaryContainer = A2Hex(0x622947);
    }];
}

+ (instancetype)urbanAsh {
    return [self themeWithSeed:A2Hex(0x5E5E5F)
                         kind:A2ThemeKindUrbanAsh
                         name:@"都市灰"
                         desc:@"中性无彩，专注场景"
                     gradient:@[ A2Hex(0x3A3A3C), A2Hex(0x5A5A5D), A2Hex(0x28282A) ]
                lightOverride:^(A2RawScheme *s) {
        s.primary            = A2Hex(0x5E5E5F);
        s.primaryContainer   = A2Hex(0xE4E2E2);
        s.onPrimaryContainer = A2Hex(0x1B1B1C);
    } darkOverride:^(A2RawScheme *s) {
        s.primary          = A2Hex(0xC7C6C6);
        s.onPrimary        = A2Hex(0x2F3131);
        s.primaryContainer = A2Hex(0x454747);
    }];
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
        case A2ThemeKindCustom:
        default:
            // Dynamic / Custom 都需要外部提供种子色或背景图，
            // 单靠 kind 无法构造 —— 回落到默认主题，由 ThemeManager 覆盖
            return [self embermire];
    }
}

#pragma mark 从图片取色

+ (instancetype)themeFromImage:(UIImage *)image {
    if (!image) return [self embermire];

    // 缩到 1x1 取平均色：比逐像素遍历快几个数量级，且天然抗噪
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, 1, 1)];
    UIImage *averaged = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    CGImageRef cg = averaged.CGImage;
    if (!cg) return [self embermire];

    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(cg));
    if (!data) return [self embermire];

    const UInt8 *bytes = CFDataGetBytePtr(data);
    if (CFDataGetLength(data) < 4) {
        CFRelease(data);
        return [self embermire];
    }

    CGFloat r = bytes[0] / 255.0;
    CGFloat g = bytes[1] / 255.0;
    CGFloat b = bytes[2] / 255.0;
    CFRelease(data);

    // 规范化：灰阶图（黑白壁纸）直接取色会得到一个没有品牌感的灰。
    // 给出饱和度下限 + 亮度钳制，保证提取结果始终可用。
    CGFloat h = 0, s = 0, br = 0, a = 0;
    [[UIColor colorWithRed:r green:g blue:b alpha:1.0] getHue:&h saturation:&s brightness:&br alpha:&a];
    if (s < 0.15) s = 0.15 + s * 0.5;
    if (br < 0.30) br = 0.30;
    if (br > 0.80) br = 0.80;

    UIColor *seed = [UIColor colorWithHue:h saturation:s brightness:br alpha:1.0];

    return [self themeWithSeed:seed
                         kind:A2ThemeKindDynamic
                         name:@"动态取色"
                         desc:@"从自定义背景提取主色"
                     gradient:@[
                         A2Tone(seed, MIN(1.0, s * 1.1), MAX(0.22, br * 0.55)),
                         seed,
                         A2Tone(seed, MIN(1.0, s * 1.15), MAX(0.12, br * 0.30)),
                     ]
                lightOverride:nil
                 darkOverride:nil];
}

@end

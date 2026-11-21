//
//  A2ColorTheme+Seed.m
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

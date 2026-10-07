//
//  A2PaletteStyle.m
//  Air2
//

#import "A2PaletteStyle.h"

A2PaletteParams A2PaletteParamsForStyle(A2PaletteStyle style) {
    switch (style) {
        case A2PaletteStyleNeutral:
            // 接近灰阶：饱和度压到很低，表面几乎不染色
            return (A2PaletteParams){
                .saturationScale = 0.35,
                .saturationCap = 0.22,
                .surfaceTint = 0.12,
                .tertiaryHueShift = 0.25,
                .containerBrightnessShift = -0.01,
            };

        case A2PaletteStyleVibrant:
            // 高饱和：饱和度拉高，表面染色也更明显
            return (A2PaletteParams){
                .saturationScale = 1.45,
                .saturationCap = 0.95,
                .surfaceTint = 1.15,
                .tertiaryHueShift = 0.33,
                .containerBrightnessShift = 0.01,
            };

        case A2PaletteStyleExpressive:
            // 活泼：第三色差异更大，容器色更亮
            return (A2PaletteParams){
                .saturationScale = 1.2,
                .saturationCap = 0.85,
                .surfaceTint = 0.9,
                .tertiaryHueShift = 0.48,   // 明显偏离标准三分色相
                .containerBrightnessShift = 0.03,
            };

        case A2PaletteStyleTonalSpot:
        default:
            // 中性基准：MD3 默认风格
            return (A2PaletteParams){
                .saturationScale = 1.0,
                .saturationCap = 0.75,
                .surfaceTint = 0.6,
                .tertiaryHueShift = 0.33,
                .containerBrightnessShift = 0.0,
            };
    }
}

NSString *A2PaletteStyleName(A2PaletteStyle style) {
    switch (style) {
        case A2PaletteStyleNeutral:    return @"Neutral";
        case A2PaletteStyleVibrant:    return @"Vibrant";
        case A2PaletteStyleExpressive: return @"Expressive";
        case A2PaletteStyleTonalSpot:
        default:                       return @"TonalSpot";
    }
}

NSString *A2PaletteStyleDescription(A2PaletteStyle style) {
    switch (style) {
        case A2PaletteStyleNeutral:    return @"极低饱和，接近灰阶";
        case A2PaletteStyleVibrant:    return @"高饱和，色彩强烈";
        case A2PaletteStyleExpressive: return @"色相偏移更大，更活泼";
        case A2PaletteStyleTonalSpot:
        default:                       return @"中性均衡，MD3 默认";
    }
}

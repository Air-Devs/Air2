//
//  A2PaletteStyle.h
//  Air2
//
//  MD3 的配色风格（PaletteStyle）。
//
//  同一个种子色，用不同的推导参数会得到气质完全不同的色板：
//    TonalSpot   —— 中性均衡，饱和度适中，最接近 MD3 默认
//    Neutral     —— 极低饱和，接近灰阶，适合专注场景
//    Vibrant     —— 高饱和，色彩强烈
//    Expressive  —— 色相偏移更大，第三色偏离更多，更活泼
//
//  实现方式：每个风格提供一组「饱和度系数 / 明度偏移 / 第三色相偏移」，
//  传给色板推导函数。这是对 material-kolor 的 tonal palette 算法的近似 ——
//  规范用 HCT 色彩空间，我们用 HSB，视觉接近但实现成本低得多。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2PaletteStyle) {
    A2PaletteStyleTonalSpot = 0,
    A2PaletteStyleNeutral,
    A2PaletteStyleVibrant,
    A2PaletteStyleExpressive,
};

/// 配色风格对色板推导的影响
typedef struct {
    /// 主色饱和度系数（1.0 = 中性基准）
    CGFloat saturationScale;
    /// 饱和度的绝对值上限（Neutral 需要压得很低）
    CGFloat saturationCap;
    /// 表面色的染色强度（0 = 纯中性灰，1 = 强染色）
    CGFloat surfaceTint;
    /// 第三色的色相偏移（0.33 = 标准三分色相，Expressive 用更大值）
    CGFloat tertiaryHueShift;
    /// 容器色的明度偏移
    CGFloat containerBrightnessShift;
} A2PaletteParams;

/// 取指定风格的推导参数
A2PaletteParams A2PaletteParamsForStyle(A2PaletteStyle style);

/// 风格的中文名
NSString *A2PaletteStyleName(A2PaletteStyle style);
/// 风格说明
NSString *A2PaletteStyleDescription(A2PaletteStyle style);

NS_ASSUME_NONNULL_END

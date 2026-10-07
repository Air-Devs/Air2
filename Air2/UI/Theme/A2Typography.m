//
//  A2Typography.m
//  Air2
//

#import "A2Typography.h"

@implementation A2Typography

+ (UIFont *)titleLarge {
    UIFont *base = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

+ (UIFont *)titleCard {
    UIFont *base = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

+ (UIFont *)subtitleCard {
    UIFont *base = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

+ (UIFont *)body {
    UIFont *base = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

+ (UIFont *)caption {
    UIFont *base = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

+ (UIFont *)button {
    UIFont *base = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

+ (UIFont *)numeric {
    // 等宽数字：进度百分比、文件大小变化时不会左右抖动
    UIFont *base = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    if (@available(iOS 13.0, *)) {
        return [UIFontMetrics.defaultMetrics scaledFontForFont:base];
    }
    return base;
}

@end

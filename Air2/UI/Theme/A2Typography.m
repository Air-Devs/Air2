//
//  A2Typography.m
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

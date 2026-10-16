//
//  A2RenderScaleCatalog.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★只用 Foundation★（Core 不得 import UIKit / SwiftUI）。
//

#import "A2RenderScaleCatalog.h"

#include <math.h>   // fabs

/// 候选与默认档的唯一定义点（顺序即 UI 顺序）。
static const double kA2RenderScaleValues[] = { 0.5, 0.75, 1.0 };
static const NSUInteger kA2RenderScaleCount = sizeof(kA2RenderScaleValues) / sizeof(kA2RenderScaleValues[0]);
static const double kA2RenderScaleDefault  = 1.0;
static const double kA2RenderScaleEpsilon  = 0.001;   // 容差：0.7500…1 与 0.75 视为同一档

@implementation A2RenderScaleCatalog

+ (NSArray<NSNumber *> *)allScales {
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:kA2RenderScaleCount];
    for (NSUInteger i = 0; i < kA2RenderScaleCount; i++) {
        [out addObject:@(kA2RenderScaleValues[i])];
    }
    return out;
}

+ (double)defaultScale {
    return kA2RenderScaleDefault;
}

+ (BOOL)isSupportedScale:(double)scale {
    for (NSUInteger i = 0; i < kA2RenderScaleCount; i++) {
        if (fabs(scale - kA2RenderScaleValues[i]) < kA2RenderScaleEpsilon) return YES;
    }
    return NO;
}

+ (double)normalizedScaleForStoredString:(NSString *)stored {
    // ★不猜★：缺值 / 非数值 / 超范围一律回默认档；只有恰好落在一档上才采用。
    if (stored.length == 0) return kA2RenderScaleDefault;
    double parsed = stored.doubleValue;
    return [self isSupportedScale:parsed] ? parsed : kA2RenderScaleDefault;
}

+ (NSString *)displayPercentForScale:(double)scale {
    return [NSString stringWithFormat:@"%.0f%%", scale * 100.0];
}

@end

//
//  A2ResolutionManager.m
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
//
//  A2ResolutionManager.m
//  Air2
//

#import "A2ResolutionManager.h"
#import "A2Logger.h"
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

NSNotificationName const A2ResolutionDidChangeNotification = @"A2ResolutionDidChangeNotification";

static NSString *const kRuleKey  = @"A2ResolutionRule";
static NSString *const kScaleKey = @"A2ResolutionScale";
static NSString *const kCustomW  = @"A2ResolutionCustomW";
static NSString *const kCustomH  = @"A2ResolutionCustomH";

// ★CI★ `nativeSize` 在 .h 里是 readonly 且本文件手写了 getter，
//   编译器不会自动合成 _nativeSize 实例变量 ⇒ 报 use of undeclared identifier '_nativeSize'。
//   这里显式声明该 ivar（只补声明，不改语义）。
@interface A2ResolutionManager () {
    CGSize _nativeSize;
}
@end

@implementation A2ResolutionManager

+ (instancetype)shared {
    static A2ResolutionManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2ResolutionManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _rule = A2ResolutionRulePercentage;
    _scale = 1.0;
    _customSize = CGSizeZero;

    [self load];
    [self updateNativeSize];
    return self;
}

#pragma mark - 原生分辨率

- (void)updateNativeSize {
    // UIScreen.nativeBounds 是物理像素（与缩放系数无关）
    // 必须用 nativeBounds 而不是 bounds —— 后者是点（point），
    // 在 3x 屏上只有物理像素的 1/3，GL 渲染必须用物理像素。
    UIScreen *screen = UIScreen.mainScreen;
    if ([screen respondsToSelector:@selector(nativeBounds)]) {
        CGSize s = screen.nativeBounds.size;
        // nativeBounds 在横屏设备上可能返回竖屏尺寸，取长边为宽
        _nativeSize = CGSizeMake(MAX(s.width, s.height), MIN(s.width, s.height));
    } else {
        _nativeSize = CGSizeMake(1920, 1080);
    }
}

- (CGSize)nativeSize {
    if (CGSizeEqualToSize(_nativeSize, CGSizeZero)) {
        [self updateNativeSize];
    }
    return _nativeSize;
}

#pragma mark - 计算

- (CGSize)renderSize {
    CGSize native = self.nativeSize;

    switch (self.rule) {
        case A2ResolutionRuleFixed:
        case A2ResolutionRulePercentage: {
            CGFloat s = MAX(0.25, MIN(1.0, self.scale));
            // 取整到偶数 —— 部分 GPU 对奇数宽高的纹理有额外开销
            CGFloat w = floor(native.width  * s / 2) * 2;
            CGFloat h = floor(native.height * s / 2) * 2;
            return CGSizeMake(MAX(320, w), MAX(240, h));
        }
        case A2ResolutionRuleCustom: {
            CGFloat w = self.customSize.width  > 0 ? self.customSize.width  : native.width;
            CGFloat h = self.customSize.height > 0 ? self.customSize.height : native.height;
            return CGSizeMake(MAX(320, w), MAX(240, h));
        }
    }
    return native;
}

#pragma mark - 应用

- (void)applyToLayer:(CALayer *)layer {
    CGSize size = self.renderSize;

    if ([layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metal = (CAMetalLayer *)layer;
        // drawableSize 决定实际渲染缓冲区的像素尺寸。
        // 注意：它和 layer.bounds（点）不同，单位是像素。
        metal.drawableSize = size;
        [A2Logger info:@"Resolution"
               message:[NSString stringWithFormat:@"CAMetalLayer.drawableSize = %.0fx%.0f",
                        size.width, size.height]];
    }

    // 自定义 surface（OSMesa 回读路径用它）
    SEL sel = NSSelectorFromString(@"setRenderSize:");
    if ([layer respondsToSelector:sel]) {
        NSMethodSignature *sig = [layer methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:layer];
        [inv setSelector:sel];
        [inv setArgument:&size atIndex:2];
        [inv invoke];
    }
}

- (void)notifyGLViewportChange {
    [NSNotificationCenter.defaultCenter postNotificationName:A2ResolutionDidChangeNotification
                                                      object:self];
    [A2Logger info:@"Resolution"
           message:[NSString stringWithFormat:@"请求 GL viewport 更新为 %.0fx%.0f",
                    self.renderSize.width, self.renderSize.height]];
}

#pragma mark - 持久化

- (void)load {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger rule = [d integerForKey:kRuleKey];
    if (rule >= 0 && rule <= A2ResolutionRuleCustom) {
        _rule = (A2ResolutionRule)rule;
    }
    CGFloat scale = [d floatForKey:kScaleKey];
    if (scale > 0) _scale = scale;

    CGFloat w = [d floatForKey:kCustomW];
    CGFloat h = [d floatForKey:kCustomH];
    if (w > 0 && h > 0) _customSize = CGSizeMake(w, h);
}

- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:self.rule forKey:kRuleKey];
    [d setFloat:self.scale forKey:kScaleKey];
    [d setFloat:self.customSize.width forKey:kCustomW];
    [d setFloat:self.customSize.height forKey:kCustomH];
}

- (void)commitChange {
    [self save];
    [self notifyGLViewportChange];
}

@end

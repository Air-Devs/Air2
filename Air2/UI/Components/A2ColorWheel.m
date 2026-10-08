//
//  A2ColorWheel.m
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

#import "A2ColorWheel.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 色盘位图的分辨率。256 已足够细腻，再高只是浪费内存。
static const NSInteger kPaletteSize = 256;

@interface A2ColorWheel ()
/// 二维色盘：横轴 = 色相，纵轴 = 饱和度
@property (nonatomic, strong) UIImageView *paletteView;
/// 色盘上的取色指示器
@property (nonatomic, strong) UIView *indicator;
/// 明度条
@property (nonatomic, strong) UIImageView *brightnessBar;
@property (nonatomic, strong) UIView *brightnessIndicator;

@property (nonatomic, assign) CGFloat hue;          // 0~1
@property (nonatomic, assign) CGFloat saturation;   // 0~1
@property (nonatomic, assign) CGFloat brightness;   // 0~1

/// 缓存的色相渐变位图（亮度变化时只需重绘明度条）
@property (nonatomic, strong, nullable) UIImage *paletteImage;
@property (nonatomic, assign, getter=isDragging) BOOL dragging;
@end

@implementation A2ColorWheel

#pragma mark - 初始化

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _hue = 0;
    _saturation = 0.8;
    _brightness = 0.6;
    _showsBrightnessSlider = YES;

    // ---- 二维色盘 ----
    _paletteView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _paletteView.translatesAutoresizingMaskIntoConstraints = NO;
    _paletteView.contentMode = UIViewContentModeScaleToFill;
    _paletteView.clipsToBounds = YES;
    _paletteView.layer.cornerRadius = A2RadiusM;
    _paletteView.layer.cornerCurve = kCACornerCurveContinuous;
    _paletteView.userInteractionEnabled = YES;
    [self addSubview:_paletteView];

    // ---- 取色指示器：白圈 + 阴影，保证在任何底色上都看得清 ----
    _indicator = [[UIView alloc] initWithFrame:CGRectZero];
    _indicator.translatesAutoresizingMaskIntoConstraints = NO;
    _indicator.backgroundColor = UIColor.clearColor;
    _indicator.layer.borderWidth = 2.5;
    _indicator.layer.borderColor = UIColor.whiteColor.CGColor;
    _indicator.layer.cornerRadius = 9;
    _indicator.layer.shadowColor = UIColor.blackColor.CGColor;
    _indicator.layer.shadowOpacity = 0.4;
    _indicator.layer.shadowRadius = 3;
    _indicator.layer.shadowOffset = CGSizeZero;
    _indicator.userInteractionEnabled = NO;
    [self addSubview:_indicator];

    // ---- 明度条 ----
    _brightnessBar = [[UIImageView alloc] initWithFrame:CGRectZero];
    _brightnessBar.translatesAutoresizingMaskIntoConstraints = NO;
    _brightnessBar.contentMode = UIViewContentModeScaleToFill;
    _brightnessBar.clipsToBounds = YES;
    _brightnessBar.layer.cornerRadius = A2RadiusS;
    _brightnessBar.layer.cornerCurve = kCACornerCurveContinuous;
    _brightnessBar.userInteractionEnabled = YES;
    [self addSubview:_brightnessBar];

    _brightnessIndicator = [[UIView alloc] initWithFrame:CGRectZero];
    _brightnessIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _brightnessIndicator.backgroundColor = UIColor.clearColor;
    _brightnessIndicator.layer.borderWidth = 2.5;
    _brightnessIndicator.layer.borderColor = UIColor.whiteColor.CGColor;
    _brightnessIndicator.layer.cornerRadius = 8;
    _brightnessIndicator.layer.shadowColor = UIColor.blackColor.CGColor;
    _brightnessIndicator.layer.shadowOpacity = 0.4;
    _brightnessIndicator.layer.shadowRadius = 3;
    _brightnessIndicator.layer.shadowOffset = CGSizeZero;
    _brightnessIndicator.userInteractionEnabled = NO;
    [self addSubview:_brightnessIndicator];

    // ---- 手势 ----
    UIPanGestureRecognizer *palettePan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePalettePan:)];
    [_paletteView addGestureRecognizer:palettePan];

    UIPanGestureRecognizer *brightPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBrightnessPan:)];
    [_brightnessBar addGestureRecognizer:brightPan];

    [self setupConstraints];
    [self rebuildPalette];
    [self rebuildBrightnessBar];
    [self updateIndicatorsAnimated:NO];

    return self;
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [_paletteView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_paletteView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_paletteView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        // 明度条固定在底部，高度 32
        [_brightnessBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_brightnessBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_brightnessBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_brightnessBar.heightAnchor constraintEqualToConstant:32],
        [_brightnessBar.topAnchor constraintEqualToAnchor:_paletteView.bottomAnchor
                                                 constant:A2SpaceM],

        [_indicator.widthAnchor constraintEqualToConstant:18],
        [_indicator.heightAnchor constraintEqualToConstant:18],
        [_brightnessIndicator.widthAnchor constraintEqualToConstant:16],
        [_brightnessIndicator.heightAnchor constraintEqualToConstant:16],
    ]];
}

#pragma mark - 位图生成

/// 生成二维色盘：横轴色相、纵轴饱和度。
///
/// 用位图而不是逐像素 CALayer 组合 —— 后者在拖动时重绘代价太高。
/// 这张图只在尺寸变化时重建一次。
- (void)rebuildPalette {
    CGSize size = CGSizeMake(kPaletteSize, kPaletteSize);
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return; }

    // 逐列画色相（256 列 × 1 像素宽的渐变），再整体叠加饱和度渐变。
    // 比逐像素快得多，视觉上完全等价。
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    for (NSInteger x = 0; x < kPaletteSize; x++) {
        CGFloat h = (CGFloat)x / kPaletteSize;
        UIColor *c = [UIColor colorWithHue:h saturation:1.0 brightness:1.0 alpha:1.0];
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextFillRect(ctx, CGRectMake(x, 0, 1, kPaletteSize));
    }
    CGColorSpaceRelease(space);

    // 白→透明的纵向渐变叠加出饱和度效果
    CGContextSaveGState(ctx);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = { 1, 1, 1, 1,   1, 1, 1, 0 };
    CGFloat locs[] = { 0, 1 };
    CGGradientRef grad = CGGradientCreateWithColorComponents(rgb, comps, locs, 2);
    CGContextDrawLinearGradient(ctx, grad,
                                CGPointMake(0, 0),
                                CGPointMake(0, kPaletteSize),
                                kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(grad);
    CGColorSpaceRelease(rgb);
    CGContextRestoreGState(ctx);

    _paletteImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    _paletteView.image = _paletteImage;
}

/// 明度条：当前色相下，从黑到纯色的渐变
- (void)rebuildBrightnessBar {
    UIColor *full = [UIColor colorWithHue:_hue saturation:_saturation brightness:1.0 alpha:1.0];
    UIColor *black = UIColor.blackColor;

    CGSize size = CGSizeMake(2, 1);
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
        const CGFloat *c1 = CGColorGetComponents(black.CGColor);
        const CGFloat *c2 = CGColorGetComponents(full.CGColor);
        CGFloat comps[8] = { c1[0], c1[1], c1[2], 1, c2[0], c2[1], c2[2], 1 };
        CGFloat locs[2] = { 0, 1 };
        CGGradientRef grad = CGColorSpaceCreateDeviceRGB() ?
            CGGradientCreateWithColorComponents(rgb, comps, locs, 2) : NULL;
        if (grad) {
            CGContextDrawLinearGradient(ctx, grad,
                                        CGPointMake(0, 0), CGPointMake(2, 0), 0);
            CGGradientRelease(grad);
        }
        CGColorSpaceRelease(rgb);
    }
    _brightnessBar.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
}

#pragma mark - 颜色

- (UIColor *)color {
    return [UIColor colorWithHue:_hue saturation:_saturation brightness:_brightness alpha:1.0];
}

- (void)setColor:(UIColor *)color {
    [self setColor:color animated:NO];
}

- (void)setColor:(UIColor *)color animated:(BOOL)animated {
    if (!color) return;
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) {
        // 灰阶没有色相，保留原色相只改饱和度与明度
        s = 0;
        b = 0;
    }
    _hue = h;
    _saturation = s;
    _brightness = b;

    [self rebuildBrightnessBar];
    [self updateIndicatorsAnimated:animated];
}

#pragma mark - 交互

- (void)handlePalettePan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:_paletteView];
    CGSize size = _paletteView.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;

    _hue = MAX(0, MIN(1, p.x / size.width));
    // 纵轴：上 = 高饱和，下 = 低饱和
    _saturation = MAX(0, MIN(1, 1.0 - p.y / size.height));

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        [self updateIndicatorsAnimated:NO];
        [self rebuildBrightnessBar];
        [self notifyChange];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        [self updateIndicatorsAnimated:NO];
        [self notifyChange];
    } else {
        _dragging = NO;
        [self notifyFinish];
    }
}

- (void)handleBrightnessPan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:_brightnessBar];
    CGFloat w = _brightnessBar.bounds.size.width;
    if (w <= 0) return;

    _brightness = MAX(0, MIN(1, p.x / w));
    [self updateIndicatorsAnimated:NO];

    if (pan.state == UIGestureRecognizerStateBegan ||
        pan.state == UIGestureRecognizerStateChanged) {
        [self notifyChange];
    } else {
        [self notifyFinish];
    }
}

- (void)notifyChange {
    if ([self.delegate respondsToSelector:@selector(colorWheel:didChangeColor:)]) {
        [self.delegate colorWheel:self didChangeColor:self.color];
    }
}

- (void)notifyFinish {
    if ([self.delegate respondsToSelector:@selector(colorWheel:didFinishWithColor:)]) {
        [self.delegate colorWheel:self didFinishWithColor:self.color];
    }
}

#pragma mark - 指示器定位

/// 指示器位置由 HSV 值反推，所以窗口尺寸变化时要重新算。
- (void)updateIndicatorsAnimated:(BOOL)animated {
    [self layoutIfNeeded];

    CGSize ps = _paletteView.bounds.size;
    CGPoint center = CGPointMake(ps.width * _hue,
                                 ps.height * (1.0 - _saturation));

    CGSize bs = _brightnessBar.bounds.size;
    CGPoint brightCenter = CGPointMake(bs.width * _brightness, bs.height / 2.0);

    void (^apply)(void) = ^{
        self.indicator.center = [self convertPoint:center fromView:self.paletteView];
        self.brightnessIndicator.center = [self convertPoint:brightCenter
                                                    fromView:self.brightnessBar];
    };

    if (animated) {
        [UIView animateWithDuration:A2AnimDurationFast animations:apply];
    } else {
        apply();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 尺寸变化后指示器位置需要重算
    [self updateIndicatorsAnimated:NO];
}

@end

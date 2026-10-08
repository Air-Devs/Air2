//
//  A2BackgroundView.m
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

#import "A2BackgroundView.h"
#import "A2ThemeManager.h"

@interface A2BackgroundView ()
/// 主题渐变层（无图片时可见）
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
/// 三个径向光斑 —— 纯渐变太平，光斑提供明暗层次
@property (nonatomic, strong) UIView *glowTop;
@property (nonatomic, strong) UIView *glowBottom;
/// 用户图片
@property (nonatomic, strong) UIImageView *imageView;
/// 图片的模糊层（用 UIVisualEffectView 而非预模糊图片，切换强度时不用重算）
@property (nonatomic, strong) UIVisualEffectView *blurView;
/// 暗色遮罩
@property (nonatomic, strong) UIView *dimOverlay;
/// 右侧渐隐
@property (nonatomic, strong) CAGradientLayer *fadeLayer;
@end

@implementation A2BackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;
    _fadeRatio = 0.35;

    // ---- 渐变底 ----
    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0.05, 0.0);
    _gradientLayer.endPoint = CGPointMake(0.95, 1.0);
    _gradientLayer.locations = @[@0.0, @0.5, @1.0];
    [self.layer addSublayer:_gradientLayer];

    _glowTop = [self makeGlow];
    _glowBottom = [self makeGlow];

    // ---- 图片 ----
    _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds = YES;
    _imageView.alpha = 0;
    [self addSubview:_imageView];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
    _blurView.userInteractionEnabled = NO;
    _blurView.alpha = 0;
    [self addSubview:_blurView];

    // ---- 遮罩 ----
    _dimOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    _dimOverlay.userInteractionEnabled = NO;
    [self addSubview:_dimOverlay];

    // ---- 渐隐 ----
    _fadeLayer = [CAGradientLayer layer];
    _fadeLayer.startPoint = CGPointMake(0.0, 0.5);
    _fadeLayer.endPoint = CGPointMake(1.0, 0.5);
    [self.layer addSublayer:_fadeLayer];

    [self applyBackground];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleBackgroundChanged:)
                                              name:A2BackgroundDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIView *)makeGlow {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.userInteractionEnabled = NO;
    v.alpha = 0.5;
    [self addSubview:v];
    return v;
}

#pragma mark - 应用背景

- (void)handleThemeChanged:(NSNotification *)note      { [self applyBackgroundAnimated:YES]; }
- (void)handleBackgroundChanged:(NSNotification *)note { [self applyBackgroundAnimated:YES]; }

- (void)applyBackground {
    [self applyBackgroundAnimated:NO];
}

- (void)applyBackgroundAnimated:(BOOL)animated {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorTheme *theme = tm.theme;
    BOOL dark = tm.isDark;

    // ---- 渐变与光斑：始终更新（图片可能半透明，底下要有色） ----
    _gradientLayer.colors = @[
        (__bridge id)theme.backgroundGradient[0].CGColor,
        (__bridge id)theme.backgroundGradient[1].CGColor,
        (__bridge id)theme.backgroundGradient[2].CGColor,
    ];
    [self renderGlow:_glowTop color:tm.scheme.cTertiary];
    [self renderGlow:_glowBottom color:tm.scheme.cPrimary];

    // ---- 图片 ----
    UIImage *image = tm.backgroundImage;
    BOOL hasImage = (image != nil);

    void (^changes)(void) = ^{
        self.imageView.image = image;
        self.imageView.alpha = hasImage ? 1.0 : 0.0;

        // 模糊强度映射到系统材质档位
        NSInteger blur = tm.backgroundBlur;
        if (hasImage && blur > 0) {
            UIBlurEffectStyle style = (blur < 30) ? UIBlurEffectStyleSystemUltraThinMaterial
                                   : (blur < 70) ? UIBlurEffectStyleSystemThinMaterial
                                                 : UIBlurEffectStyleSystemMaterial;
            self.blurView.effect = [UIBlurEffect effectWithStyle:style];
            self.blurView.alpha = 0.85;
        } else {
            self.blurView.effect = nil;
            self.blurView.alpha = 0.0;
        }

        // 暗色遮罩：只有暗色模式且有图时才加重，避免卡片文字看不清
        CGFloat overlay = (dark && hasImage) ? tm.backgroundDarkOverlay : 0.0;
        self.dimOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:overlay];
        // 暗色下即使没有图，也压暗一点渐变，让卡片更分明
        if (dark && !hasImage) {
            self.dimOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
        }

        self.imageView.alpha = hasImage ? 1.0 : 0.0;
        self.glowTop.alpha = hasImage ? 0.22 : 0.5;
        self.glowBottom.alpha = hasImage ? 0.22 : 0.5;
    };

    if (animated) {
        [UIView transitionWithView:self
                          duration:0.6
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState
                        animations:changes
                        completion:nil];
    } else {
        changes();
    }

    [self setNeedsLayout];
}

- (void)renderGlow:(UIView *)glow color:(UIColor *)color {
    for (CALayer *l in glow.layer.sublayers) { [l removeFromSuperlayer]; }

    CAGradientLayer *g = [CAGradientLayer layer];
    g.type = kCAGradientLayerRadial;
    g.colors = @[
        (__bridge id)[color colorWithAlphaComponent:0.5].CGColor,
        (__bridge id)[color colorWithAlphaComponent:0.0].CGColor,
    ];
    g.locations = @[@0.0, @1.0];
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(1.0, 1.0);
    [glow.layer addSublayer:g];
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    // CAGradientLayer 不参与自动布局，帧变化时要手动同步并关闭隐式动画
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _gradientLayer.frame = self.bounds;
    _imageView.frame = self.bounds;
    _blurView.frame = self.bounds;
    _dimOverlay.frame = self.bounds;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    _glowTop.frame = CGRectMake(-w * 0.18, -h * 0.25, w * 0.75, h * 0.9);
    _glowBottom.frame = CGRectMake(w * 0.35, h * 0.45, w * 0.8, h * 0.9);

    for (UIView *g in @[_glowTop, _glowBottom]) {
        for (CALayer *l in g.layer.sublayers) { l.frame = g.bounds; }
    }

    // 右侧渐隐：从透明过渡到当前表面色，让操作栏一侧有稳定的底色
    CGFloat fadeW = w * MAX(0.0, MIN(1.0, _fadeRatio));
    _fadeLayer.frame = CGRectMake(w - fadeW, 0, fadeW, h);
    _fadeLayer.hidden = (fadeW <= 1);

    [CATransaction commit];

    [self updateFadeColors];
}

- (void)updateFadeColors {
    if (_fadeLayer.hidden) return;

    A2ThemeManager *tm = A2ThemeManager.shared;
    UIColor *edge = tm.isDark
        ? [tm.scheme.cSurface colorWithAlphaComponent:0.92]
        : [tm.scheme.cSurface colorWithAlphaComponent:0.88];

    UIColor *clear = [edge colorWithAlphaComponent:0.0];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fadeLayer.colors = @[
        (__bridge id)clear.CGColor,
        (__bridge id)[edge colorWithAlphaComponent:0.45].CGColor,
        (__bridge id)edge.CGColor,
    ];
    _fadeLayer.locations = @[@0.0, @0.6, @1.0];
    [CATransaction commit];
}

@end

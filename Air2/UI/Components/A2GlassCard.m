//
//  A2GlassCard.m
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
//  MD3 卡片实现。
//  设计取舍：不用 UIVisualEffectView 做玻璃。
//
//  原因：MD3 的 surfaceContainer 体系本身就是「分层表面」，
//  用半透明色 + 精确的层级色值就能表达深度，比强制加模糊更可控：
//    · 卡片数量多时模糊会显著掉帧（尤其中低端设备）
//    · 用户自定义背景图上叠模糊，色彩完全不可预测
//  所以这里用「MD3 语义色 + 可选的轻微模糊」，
//  模糊只在用户显式开启时才启用（走 A2ThemeManager.backgroundBlur 的联动）。
//

#import "A2GlassCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2GlassCard ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *borderView;
@property (nonatomic, strong) UIView *contentViewInternal;
@property (nonatomic, strong) UIImpactFeedbackGenerator *impact;
@end

@implementation A2GlassCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (void)commonInit {
    _cornerRadius = A2RadiusL;
    _contentInsets = UIEdgeInsetsMake(A2SpaceL, A2SpaceL, A2SpaceL, A2SpaceL);
    _elevation = A2CardElevationLow;
    _blurAmount = 0;

    self.clipsToBounds = NO;
    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = _cornerRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    // 模糊层在最底（默认关闭）
    _blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    _blurView.clipsToBounds = YES;
    _blurView.layer.cornerRadius = _cornerRadius;
    _blurView.layer.cornerCurve = kCACornerCurveContinuous;
    _blurView.hidden = YES;
    [self addSubview:_blurView];

    _fillView = [[UIView alloc] initWithFrame:CGRectZero];
    _fillView.translatesAutoresizingMaskIntoConstraints = NO;
    _fillView.userInteractionEnabled = NO;
    // 卡片自身不能裁剪（会切掉阴影），所以填充层得自己圆角，
    // 否则方角会伸到圆角边框之外，在四角露出方形毛刺。
    _fillView.clipsToBounds = YES;
    _fillView.layer.cornerRadius = _cornerRadius;
    _fillView.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_fillView];

    _borderView = [[UIView alloc] initWithFrame:CGRectZero];
    _borderView.translatesAutoresizingMaskIntoConstraints = NO;
    _borderView.userInteractionEnabled = NO;
    _borderView.layer.cornerRadius = _cornerRadius;
    _borderView.layer.cornerCurve = kCACornerCurveContinuous;
    _borderView.layer.borderWidth = 0.5;
    _borderView.backgroundColor = UIColor.clearColor;
    [self addSubview:_borderView];

    _contentViewInternal = [[UIView alloc] initWithFrame:CGRectZero];
    _contentViewInternal.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_contentViewInternal];

    // 注意：constrainEdges: 返回的是数组，必须用 addObjectsFromArray
    // 展开。直接塞进 @[...] 会变成「数组套数组」，
    // Auto Layout 遍历时对 NSArray 发 isActive 就崩了
    //（真机崩溃日志：-[__NSArrayI isActive]: unrecognized selector）。
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    [constraints addObjectsFromArray:[self constrainEdges:_blurView]];
    [constraints addObjectsFromArray:[self constrainEdges:_fillView]];
    [constraints addObjectsFromArray:[self constrainEdges:_borderView]];
    [constraints addObjectsFromArray:@[
        [_contentViewInternal.topAnchor constraintEqualToAnchor:self.topAnchor constant:_contentInsets.top],
        [_contentViewInternal.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-_contentInsets.bottom],
        [_contentViewInternal.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:_contentInsets.left],
        [_contentViewInternal.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-_contentInsets.right],
    ]];
    [NSLayoutConstraint activateConstraints:constraints];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

/// 让子视图四边贴合自身
- (NSArray<NSLayoutConstraint *> *)constrainEdges:(UIView *)v {
    return @[
        [v.topAnchor constraintEqualToAnchor:self.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 属性

- (UIView *)contentView {
    return _contentViewInternal;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.layer.cornerRadius = cornerRadius;
    _fillView.layer.cornerRadius = cornerRadius;
    _blurView.layer.cornerRadius = cornerRadius;
    _borderView.layer.cornerRadius = cornerRadius;
}

- (void)setElevation:(A2CardElevation)elevation {
    _elevation = elevation;
    [self applyTheme];
}

- (void)setContentInsets:(UIEdgeInsets)insets {
    _contentInsets = insets;
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem != _contentViewInternal && c.secondItem != _contentViewInternal) continue;
        c.active = NO;
    }
    [NSLayoutConstraint activateConstraints:@[
        [_contentViewInternal.topAnchor constraintEqualToAnchor:self.topAnchor constant:insets.top],
        [_contentViewInternal.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-insets.bottom],
        [_contentViewInternal.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:insets.left],
        [_contentViewInternal.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-insets.right],
    ]];
}

- (void)setBlurAmount:(CGFloat)blurAmount {
    _blurAmount = MAX(0, MIN(1, blurAmount));
    [self applyTheme];
}

- (void)setTappable:(BOOL)tappable {
    _tappable = tappable;
    if (tappable && !_impact) {
        _impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];
        self.userInteractionEnabled = YES;
    }
}

- (void)handleTap {
    if (self.onTap) self.onTap();
}

#pragma mark - 按压反馈

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_tappable) { [super touchesBegan:touches withEvent:event]; return; }
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{
        self.transform = CGAffineTransformMakeScale(0.975, 0.975);
    }];
    [a startAnimation];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_tappable) { [super touchesEnded:touches withEvent:event]; return; }
    [_impact impactOccurred];
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{
        self.transform = CGAffineTransformIdentity;
    }];
    [a startAnimation];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_tappable) { [super touchesCancelled:touches withEvent:event]; return; }
    self.transform = CGAffineTransformIdentity;
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorScheme *s = tm.scheme;
    BOOL hasCustomBg = (tm.backgroundImage != nil);

    // —— 填充色按层级选 ——
    UIColor *fill;
    switch (_elevation) {
        case A2CardElevationSurface:       fill = s.cSurfaceContainerLowest; break;
        case A2CardElevationHigh:          fill = s.cSurfaceContainerHigh;   break;
        case A2CardElevationHighest:       fill = s.cSurfaceContainerHighest;break;
        case A2CardElevationLow:
        default:                           fill = s.cSurfaceContainer;      break;
    }

    // 有自定义背景时让卡片半透明，让背景色透出来 —— 这是个性化的关键
    if (hasCustomBg) {
        CGFloat alpha = tm.isDark ? 0.68 : 0.76;
        // 用户设了模糊，卡片内部也跟一点，整体更统一
        if (tm.backgroundBlur > 60) alpha -= 0.08;
        fill = [fill colorWithAlphaComponent:alpha];
    }

    _fillView.backgroundColor = fill;

    // —— 模糊（仅在用户开启背景模糊且存在背景图时启用）——
    BOOL wantBlur = hasCustomBg && tm.backgroundBlur > 0 && _blurAmount > 0;
    if (wantBlur) {
        UIBlurEffectStyle style = tm.backgroundBlur < 40 ? UIBlurEffectStyleSystemUltraThinMaterial
                               : tm.backgroundBlur < 75 ? UIBlurEffectStyleSystemThinMaterial
                                                        : UIBlurEffectStyleSystemMaterial;
        _blurView.effect = [UIBlurEffect effectWithStyle:style];
        _blurView.hidden = NO;
    } else {
        _blurView.effect = nil;
        _blurView.hidden = YES;
    }

    // —— 描边：MD3 用 outlineVariant 做低对比描边 ——
    _borderView.layer.borderColor = [s.cOutlineVariant colorWithAlphaComponent:
                                     tm.isDark ? 0.6 : 0.9].CGColor;

    // —— 阴影：MD3 的 elevation 用阴影表达，但暗色下阴影几乎不可见，
    //    所以暗色模式减小阴影、改用描边区分层级 ——
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    if (tm.isDark) {
        self.layer.shadowOpacity = 0.0f;
    } else {
        CGFloat opacity;
        CGFloat radius;
        CGFloat offsetY;
        switch (_elevation) {
            case A2CardElevationHighest: opacity = 0.13f; radius = 20; offsetY = 6; break;
            case A2CardElevationHigh:    opacity = 0.10f; radius = 16; offsetY = 5; break;
            case A2CardElevationSurface: opacity = 0.03f; radius = 6;  offsetY = 2; break;
            case A2CardElevationLow:
            default:                     opacity = 0.06f; radius = 10; offsetY = 3; break;
        }
        self.layer.shadowOpacity = hasCustomBg ? opacity * 1.4f : opacity;
        self.layer.shadowRadius = radius;
        self.layer.shadowOffset = CGSizeMake(0, offsetY);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:self.cornerRadius].CGPath;
}

@end

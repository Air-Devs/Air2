//
//  A2GlassCard.m
//  Air2
//

#import "A2GlassCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2GlassCard ()
@property (nonatomic, strong, nullable) UIVisualEffectView *blurView;
@property (nonatomic, strong, nullable) UIView *solidFillView;
@property (nonatomic, strong) UIView *borderLayer;
@property (nonatomic, strong) UIView *contentViewInternal;
@property (nonatomic, strong, nullable) UISelectionFeedbackGenerator *feedback;
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
    _tappable = NO;

    self.clipsToBounds = NO;
    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = _cornerRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    // ---- 玻璃层 ----
    _blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    _blurView.clipsToBounds = YES;
    _blurView.layer.cornerRadius = _cornerRadius;
    _blurView.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_blurView];

    // ---- 实色填充层（玻璃关闭时使用，也是玻璃打开时的色调叠加）----
    _solidFillView = [[UIView alloc] initWithFrame:CGRectZero];
    _solidFillView.translatesAutoresizingMaskIntoConstraints = NO;
    _solidFillView.userInteractionEnabled = NO;
    [self addSubview:_solidFillView];

    // ---- 高光描边：模拟玻璃的边缘折射，没有它卡片会显得"糊在背景上" ----
    _borderLayer = [[UIView alloc] initWithFrame:CGRectZero];
    _borderLayer.translatesAutoresizingMaskIntoConstraints = NO;
    _borderLayer.userInteractionEnabled = NO;
    _borderLayer.layer.cornerRadius = _cornerRadius;
    _borderLayer.layer.cornerCurve = kCACornerCurveContinuous;
    _borderLayer.layer.borderWidth = 0.5;
    _borderLayer.backgroundColor = UIColor.clearColor;
    [self addSubview:_borderLayer];

    // ---- 内容 ----
    _contentViewInternal = [[UIView alloc] initWithFrame:CGRectZero];
    _contentViewInternal.translatesAutoresizingMaskIntoConstraints = NO;
    _contentViewInternal.backgroundColor = UIColor.clearColor;
    [self addSubview:_contentViewInternal];

    [NSLayoutConstraint activateConstraints:@[
        [_blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_solidFillView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_solidFillView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_solidFillView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_solidFillView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_borderLayer.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_borderLayer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_borderLayer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_borderLayer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_contentViewInternal.topAnchor constraintEqualToAnchor:self.topAnchor constant:_contentInsets.top],
        [_contentViewInternal.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-_contentInsets.bottom],
        [_contentViewInternal.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:_contentInsets.left],
        [_contentViewInternal.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-_contentInsets.right],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
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
    _blurView.layer.cornerRadius = cornerRadius;
    _borderLayer.layer.cornerRadius = cornerRadius;
}

- (void)setContentInsets:(UIEdgeInsets)contentInsets {
    _contentInsets = contentInsets;
    // 重新装上约束
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem == _contentViewInternal || c.secondItem == _contentViewInternal) {
            c.active = NO;
        }
    }
    [NSLayoutConstraint activateConstraints:@[
        [_contentViewInternal.topAnchor constraintEqualToAnchor:self.topAnchor constant:contentInsets.top],
        [_contentViewInternal.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-contentInsets.bottom],
        [_contentViewInternal.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:contentInsets.left],
        [_contentViewInternal.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-contentInsets.right],
    ]];
}

- (void)setTappable:(BOOL)tappable {
    _tappable = tappable;
    if (tappable) {
        if (!_feedback) _feedback = [UISelectionFeedbackGenerator new];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];
        self.userInteractionEnabled = YES;
    }
}

- (void)handleTap {
    [_feedback selectionChanged];
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
    NSInteger intensity = tm.glassIntensity;

    if (intensity > 0) {
        // 强度映射到系统模糊样式：低强度用薄材质，高强度用厚材质
        UIBlurEffectStyle style;
        if (intensity < 35) {
            style = UIBlurEffectStyleSystemUltraThinMaterial;
        } else if (intensity < 70) {
            style = UIBlurEffectStyleSystemThinMaterial;
        } else {
            style = UIBlurEffectStyleSystemMaterial;
        }
        _blurView.effect = [UIBlurEffect effectWithStyle:style];
        _blurView.hidden = NO;
        // 玻璃之上再叠一层主题色，让卡片带上品牌色调
        _solidFillView.backgroundColor = [tm cardFillColor];
    } else {
        // 关闭玻璃：退化为实色卡片
        _blurView.effect = nil;
        _blurView.hidden = YES;
        _solidFillView.backgroundColor = tm.isDark ? tm.surfaceElevatedColor : tm.surfaceElevatedColor;
    }

    _borderLayer.layer.borderColor = (tm.isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.14]
        : [UIColor colorWithWhite:0.0 alpha:0.06]).CGColor;

    _contentViewInternal.backgroundColor = UIColor.clearColor;

    // 阴影：玻璃卡片在暗色下用弱阴影，亮色下用柔和投影
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = tm.isDark ? 0.28f : 0.07f;
    self.layer.shadowRadius = tm.isDark ? 18 : 12;
    self.layer.shadowOffset = CGSizeMake(0, tm.isDark ? 8 : 4);
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:self.cornerRadius].CGPath;
}

@end

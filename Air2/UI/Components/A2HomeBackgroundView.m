//
//  A2HomeBackgroundView.m
//  Air2
//

#import "A2HomeBackgroundView.h"
#import "A2ThemeManager.h"

@interface A2HomeBackgroundView ()
@property (nonatomic, strong) CAGradientLayer *baseGradient;
@property (nonatomic, strong) UIView *glowTop;
@property (nonatomic, strong) UIView *glowSide;
@property (nonatomic, strong) UIView *glowBottom;
@end

@implementation A2HomeBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.blackColor;
    self.userInteractionEnabled = NO;

    _baseGradient = [CAGradientLayer layer];
    _baseGradient.startPoint = CGPointMake(0.1, 0.0);
    _baseGradient.endPoint = CGPointMake(0.9, 1.0);
    _baseGradient.locations = @[@0.0, @0.48, @1.0];
    [self.layer addSublayer:_baseGradient];

    _glowTop = [self makeGlow];
    _glowSide = [self makeGlow];
    _glowBottom = [self makeGlow];
    _glowSide.alpha = 0.34;

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIView *)makeGlow {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;
    v.alpha = 0.55;
    [self addSubview:v];
    return v;
}

/// 用径向渐变绘制光斑，边缘自然衰减到透明
- (void)renderGlow:(UIView *)glow withColor:(UIColor *)color {
    for (CALayer *l in glow.layer.sublayers) { [l removeFromSuperlayer]; }

    CAGradientLayer *g = [CAGradientLayer layer];
    g.type = kCAGradientLayerRadial;
    g.frame = glow.bounds;
    g.colors = @[
        (__bridge id)[color colorWithAlphaComponent:0.62].CGColor,
        (__bridge id)[color colorWithAlphaComponent:0.0].CGColor,
    ];
    g.locations = @[@0.0, @1.0];
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(1.0, 1.0);
    [glow.layer addSublayer:g];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorTheme *t = A2ThemeManager.shared.currentTheme;

    _baseGradient.colors = @[
        (__bridge id)t.wallpaperGradient[0].CGColor,
        (__bridge id)t.wallpaperGradient[1].CGColor,
        (__bridge id)t.wallpaperGradient[2].CGColor,
    ];

    [self renderGlow:_glowTop color:t.accent];
    [self renderGlow:_glowSide color:t.primaryContainer];
    [self renderGlow:_glowBottom color:t.primary];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // CAGradientLayer 不参与自动布局，帧变化时要手动同步
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _baseGradient.frame = self.bounds;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _glowTop.frame = CGRectMake(-w * 0.28, -h * 0.10, w * 1.05, h * 0.46);
    _glowSide.frame = CGRectMake(-w * 0.42, h * 0.34, w * 0.86, h * 0.36);
    _glowBottom.frame = CGRectMake(w * 0.18, h * 0.62, w * 1.05, h * 0.46);
    [CATransaction commit];

    for (UIView *g in @[_glowTop, _glowSide, _glowBottom]) {
        for (CALayer *l in g.layer.sublayers) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            l.frame = g.bounds;
            [CATransaction commit];
        }
    }
}

@end

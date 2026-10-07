//
//  A2PrimaryButton.m
//  Air2
//

#import "A2PrimaryButton.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2PrimaryButton ()
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImpactFeedbackGenerator *impact;
@end

@implementation A2PrimaryButton

- (instancetype)initWithTitle:(NSString *)title style:(A2ButtonStyle)style {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _title = [title copy];
    _style = style;
    _minHeight = A2ButtonHeight;
    [self commonInit];
    return self;
}

- (void)commonInit {
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0, 0);
    _gradientLayer.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:_gradientLayer];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = _title;
    _titleLabel.font = [A2Typography button];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.hidden = YES;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self addSubview:_spinner];

    _impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:_minHeight],

        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:0],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:A2SpaceXL],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-A2SpaceXL],

        [_iconView.trailingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor constant:-A2SpaceS],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:18],
        [_iconView.heightAnchor constraintEqualToConstant:18],

        [_spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
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

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleLabel.text = title;
    [self setNeedsLayout];
}

- (void)setMinHeight:(CGFloat)minHeight {
    _minHeight = minHeight;
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstAttribute == NSLayoutAttributeHeight && c.relation == NSLayoutRelationGreaterThanOrEqual) {
            c.constant = minHeight;
            break;
        }
    }
}

- (void)setIcon:(UIImage *)icon {
    _icon = icon;
    _iconView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _iconView.hidden = (icon == nil);
    // 有图标时标题右移
    _titleLabel.transform = icon ? CGAffineTransformMakeTranslation(11, 0) : CGAffineTransformIdentity;
    _iconView.transform = icon ? CGAffineTransformMakeTranslation(0, 0) : CGAffineTransformIdentity;
}

- (void)setStyle:(A2ButtonStyle)style {
    _style = style;
    [self applyTheme];
}

- (void)setLoading:(BOOL)loading {
    _loading = loading;
    self.userInteractionEnabled = !loading;
    if (loading) {
        [_spinner startAnimating];
        [UIView animateWithDuration:A2AnimDurationFast animations:^{
            self.titleLabel.alpha = 0;
            self.iconView.alpha = 0;
        }];
    } else {
        [_spinner stopAnimating];
        [UIView animateWithDuration:A2AnimDurationFast animations:^{
            self.titleLabel.alpha = 1;
            self.iconView.alpha = 1;
        }];
    }
}

#pragma mark - 交互

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.isLoading) return;
    [_impact prepare];
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{
        self.transform = CGAffineTransformMakeScale(0.97, 0.97);
        self.alpha = 0.9;
    }];
    [a startAnimation];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.isLoading) return;
    [_impact impactOccurred];
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
    }];
    [a startAnimation];

    // 判断是否仍在按钮内
    CGPoint p = [touches.anyObject locationInView:self];
    if (CGRectContainsPoint(self.bounds, p)) {
        [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.transform = CGAffineTransformIdentity;
    self.alpha = 1.0;
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorScheme *t = tm.scheme;

    switch (_style) {
        case A2ButtonStylePrimary: {
            _gradientLayer.hidden = NO;
            _gradientLayer.colors = @[
                (__bridge id)t.primary.CGColor,
                (__bridge id)t.primaryContainer.CGColor,
            ];
            _gradientLayer.locations = @[@0.0, @1.0];
            _titleLabel.textColor = t.onPrimary;
            _iconView.tintColor = t.onPrimary;
            _spinner.color = t.onPrimary;
            self.layer.borderWidth = 0;
            self.backgroundColor = UIColor.clearColor;
            break;
        }
        case A2ButtonStyleSecondary: {
            _gradientLayer.hidden = YES;
            self.backgroundColor = UIColor.clearColor;
            self.layer.borderWidth = 1.2;
            self.layer.borderColor = [t.outline colorWithAlphaComponent:0.45].CGColor;
            _titleLabel.textColor = t.onSurface;
            _iconView.tintColor = t.onSurface;
            _spinner.color = t.onSurface;
            break;
        }
        case A2ButtonStyleDanger: {
            _gradientLayer.hidden = NO;
            _gradientLayer.colors = @[
                (__bridge id)t.error.CGColor,
                (__bridge id)[t.error colorWithAlphaComponent:0.78].CGColor,
            ];
            _gradientLayer.locations = @[@0.0, @1.0];
            _titleLabel.textColor = UIColor.whiteColor;
            _iconView.tintColor = UIColor.whiteColor;
            _spinner.color = UIColor.whiteColor;
            self.layer.borderWidth = 0;
            self.backgroundColor = UIColor.clearColor;
            break;
        }
    }
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradientLayer.frame = self.bounds;
}

@end

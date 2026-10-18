//
//  A2GameMenuOverlay.m
//  Air2
//

#import "A2GameMenuOverlay.h"
#import "A2ThemeManager.h"

static const CGFloat kBallSize = 44;
static const CGFloat kEdgeInset = 10;

@interface A2GameMenuOverlay ()
@property (nonatomic, strong) UIView *ball;
@property (nonatomic, strong) UIImageView *ballIcon;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, assign, readwrite, getter=isExpanded) BOOL expanded;
@property (nonatomic, assign) CGPoint ballCenter;
/// 浮球旋转（展开时 45°，收起时回正）
- (void)rotateBallToAngle:(CGFloat)angle;
@end

@implementation A2GameMenuOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // ---- 浮球 ----
    _ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kBallSize, kBallSize)];
    _ball.layer.cornerRadius = kBallSize / 2;
    _ball.layer.cornerCurve = kCACornerCurveContinuous;
    _ball.layer.shadowColor = UIColor.blackColor.CGColor;
    _ball.layer.shadowOpacity = 0.35;
    _ball.layer.shadowRadius = 6;
    _ball.layer.shadowOffset = CGSizeMake(0, 2);
    [self addSubview:_ball];

    _ballIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _ballIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _ballIcon.contentMode = UIViewContentModeScaleAspectFit;
    _ballIcon.image = [UIImage systemImageNamed:@"gamecontroller.fill"
                              withConfiguration:[UIImageSymbolConfiguration
                                                 configurationWithPointSize:20
                                                                     weight:UIImageSymbolWeightMedium]];
    [_ball addSubview:_ballIcon];
    [NSLayoutConstraint activateConstraints:@[
        [_ballIcon.centerXAnchor constraintEqualToAnchor:_ball.centerXAnchor],
        [_ballIcon.centerYAnchor constraintEqualToAnchor:_ball.centerYAnchor],
    ]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [_ball addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_ball addGestureRecognizer:pan];

    // ---- FPS / 内存显示 ----
    _statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    _statsLabel.textAlignment = NSTextAlignmentRight;
    _statsLabel.hidden = YES;
    [self addSubview:_statsLabel];

    _ballOpacity = 0.9;
    [self applyTheme];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (CGPointEqualToPoint(_ballCenter, CGPointZero)) {
        _ballCenter = CGPointMake(self.bounds.size.width - kBallSize / 2 - kEdgeInset,
                                  self.safeAreaInsets.top + 24 + kBallSize / 2);
    }
    _ball.center = _ballCenter;

    // 统计文字放在球的左侧
    _statsLabel.frame = CGRectMake(_ballCenter.x - kBallSize / 2 - 160,
                                   _ballCenter.y - 10,
                                   150, 20);
}

#pragma mark - 交互

- (void)handleTap {
    [self toggle];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    CGPoint c = CGPointMake(_ballCenter.x + t.x, _ballCenter.y + t.y);
    [g setTranslation:CGPointZero inView:self];

    CGFloat half = kBallSize / 2;
    c.x = MAX(half + kEdgeInset, MIN(self.bounds.size.width - half - kEdgeInset, c.x));
    c.y = MAX(half + kEdgeInset, MIN(self.bounds.size.height - half - kEdgeInset, c.y));
    _ballCenter = c;
    _ball.center = c;

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        [self snapToEdge];
    }
}

/// 松手吸附到最近的左右边缘 —— 与 ZL2 一致，避免球停在屏幕中间挡游戏。
- (void)snapToEdge {
    CGFloat half = kBallSize / 2;
    BOOL toLeft = _ballCenter.x < self.bounds.size.width / 2;
    CGFloat targetX = toLeft ? (half + kEdgeInset)
                             : (self.bounds.size.width - half - kEdgeInset);

    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_ballCenter.x = targetX;
        self->_ball.center = self->_ballCenter;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    } completion:nil];
}

#pragma mark - 展开 / 收起

- (void)toggle {
    self.expanded = !self.expanded;
    [self rotateBallToAngle:self.expanded ? M_PI_4 : 0];
    // 菜单本体在 A2GameMenuPanel（下一步实现），这里先只切状态
}

- (void)expand {
    if (self.expanded) return;
    self.expanded = YES;
    [self rotateBallToAngle:M_PI_4];
}

- (void)collapse {
    if (!self.expanded) return;
    self.expanded = NO;
    [self rotateBallToAngle:0];
}

#pragma mark - 显隐与统计

- (void)setVisible:(BOOL)visible {
    _visible = visible;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = visible ? 1 : 0;
    }];
    self.userInteractionEnabled = visible;
    if (!visible) [self collapse];
}

- (void)setBallOpacity:(CGFloat)ballOpacity {
    _ballOpacity = MAX(0.2, MIN(1.0, ballOpacity));
    _ball.alpha = _ballOpacity;
}

- (void)updateFPS:(double)fps memoryUsageMB:(double)memoryMB {
    if (fps <= 0 && memoryMB <= 0) {
        _statsLabel.hidden = YES;
        return;
    }
    _statsLabel.hidden = NO;

    NSMutableString *text = [NSMutableString string];
    if (fps > 0) [text appendFormat:@"%.0f FPS", fps];
    if (memoryMB > 0) {
        if (text.length) [text appendString:@"  ·  "];
        [text appendFormat:@"%.0f MB", memoryMB];
    }
    _statsLabel.text = text;
}

#pragma mark - 动画

/// 浮球旋转。展开菜单时转 45°（像一颗被"拧开"的按钮），
/// 收起时回正 —— 与 ZL2 的悬浮球一致。
- (void)rotateBallToAngle:(CGFloat)angle {
    [UIView animateWithDuration:0.2
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.4
                        options:0
                     animations:^{
        self.ball.transform = CGAffineTransformMakeRotation(angle);
    } completion:nil];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _ball.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.92];
    _ball.alpha = _ballOpacity;
    _ballIcon.tintColor = t.cOnPrimary;
    _statsLabel.textColor = t.cOnSurface;
    _statsLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _statsLabel.layer.shadowOpacity = 0.5;
    _statsLabel.layer.shadowRadius = 2;
}

@end



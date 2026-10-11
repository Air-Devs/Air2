//
//  A2Switch.m
//  Air2
//

#import "A2Switch.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

/// MD3 Switch 的尺寸规格
static const CGFloat kTrackWidth = 52;
static const CGFloat kTrackHeight = 32;
static const CGFloat kThumbSize = 24;
static const CGFloat kThumbInset = 4;           // 滑块距轨道边缘
static const CGFloat kThumbTravel = kTrackWidth - kThumbSize - kThumbInset * 2;
static const CGFloat kIconSize = 16;

@interface A2Switch () {
    /// 滑块的水平位置约束（改 constant 实现位移）
    NSLayoutConstraint *_thumbLeading;
}
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, strong) UIImageView *thumbIcon;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedback;
@end

@implementation A2Switch

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _on = NO;
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    // 轨道
    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.translatesAutoresizingMaskIntoConstraints = NO;
    _track.layer.cornerRadius = kTrackHeight / 2;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    _track.userInteractionEnabled = NO;
    [self addSubview:_track];

    // 滑块
    _thumb = [[UIView alloc] initWithFrame:CGRectZero];
    _thumb.translatesAutoresizingMaskIntoConstraints = NO;
    _thumb.layer.cornerRadius = kThumbSize / 2;
    _thumb.layer.cornerCurve = kCACornerCurveContinuous;
    _thumb.userInteractionEnabled = NO;
    [_track addSubview:_thumb];

    // 滑块里的图标：开=对勾，关=叉
    _thumbIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _thumbIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_thumb addSubview:_thumbIcon];

    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:kTrackWidth],
        [self.heightAnchor constraintEqualToConstant:kTrackHeight],

        [_track.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_track.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_thumb.widthAnchor constraintEqualToConstant:kThumbSize],
        [_thumb.heightAnchor constraintEqualToConstant:kThumbSize],
        [_thumb.centerYAnchor constraintEqualToAnchor:_track.centerYAnchor],

        [_thumbIcon.centerXAnchor constraintEqualToAnchor:_thumb.centerXAnchor],
        [_thumbIcon.centerYAnchor constraintEqualToAnchor:_thumb.centerYAnchor],
        [_thumbIcon.widthAnchor constraintEqualToConstant:kIconSize],
        [_thumbIcon.heightAnchor constraintEqualToConstant:kIconSize],
    ]];

    // 用 leading 约束 + 改 constant 实现位移（比 transform 更精确）
    _thumbLeading = [_thumb.leadingAnchor constraintEqualToAnchor:_track.leadingAnchor
                                                        constant:kThumbInset];
    _thumbLeading.active = YES;

    [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];

    [self applyTheme];
    [self updateThumbIconAnimated:NO];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 状态

- (void)setOn:(BOOL)on {
    [self setOn:on animated:YES];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    if (_on == on) return;
    _on = on;

    [self applyTheme];
    [self updateThumbIconAnimated:animated];
    [self animateThumb];
}

- (void)handleTap {
    [_feedback impactOccurred];
    [self setOn:!_on animated:YES];
    if (self.onChange) self.onChange(_on);
}

#pragma mark - 动画

- (void)animateThumb {
    CGFloat target = _on ? kThumbInset + kThumbTravel : kThumbInset;
    _thumbLeading.constant = target;

    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{
        [self layoutIfNeeded];
    }];
    [a startAnimation];
}

/// 图标旋转 180° + 交叉淡入 —— 对应 ZL2 的 Crossfade + rotate
- (void)updateThumbIconAnimated:(BOOL)animated {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:11
                                                       weight:UIImageSymbolWeightBold];
    UIImage *next = [UIImage systemImageNamed:(_on ? @"checkmark" : @"xmark")
                            withConfiguration:cfg];

    if (!animated) {
        _thumbIcon.image = [next imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _thumbIcon.transform = CGAffineTransformIdentity;
        [self applyTheme];
        return;
    }

    // 旋转半圈 + 换图标，视觉上是「翻面」
    [UIView transitionWithView:_thumbIcon
                      duration:A2AnimDurationFast
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self.thumbIcon.image = [next imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.thumbIcon.transform = CGAffineTransformMakeRotation(M_PI);
    } completion:^(BOOL finished) {
        // 复位旋转，避免下次切换从 180° 开始
        self.thumbIcon.transform = CGAffineTransformIdentity;
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    if (_on) {
        // 开：轨道主色，滑块用 onPrimary，图标用主色
        _track.backgroundColor = t.cPrimary;
        _thumb.backgroundColor = t.cOnPrimary;
        _thumbIcon.tintColor = t.cPrimary;
    } else {
        // 关：轨道表面容器色，滑块用 outline，图标用表面色
        _track.backgroundColor = t.cSurfaceContainerHighest;
        _thumb.backgroundColor = t.cOutline;
        _thumbIcon.tintColor = t.cSurfaceContainerHighest;
    }
}

@end

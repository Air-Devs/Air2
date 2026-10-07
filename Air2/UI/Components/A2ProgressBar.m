//
//  A2ProgressBar.m
//  Air2
//
//  线性进度条 —— 进度 + 已下载/总量 + 实时速度。
//  头部带光晕，让进度推进有个明显的"亮头"。
//

#import "A2ProgressView.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

#pragma mark - A2ProgressBar

@interface A2ProgressBar ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UIView *glow;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
@end

@implementation A2ProgressBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _progress = 0;

    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.translatesAutoresizingMaskIntoConstraints = NO;
    _track.layer.cornerRadius = 3;
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.translatesAutoresizingMaskIntoConstraints = NO;
    [_track addSubview:_fill];

    // 进度条头部的光晕，让推进有个"亮头"
    _glow = [[UIView alloc] initWithFrame:CGRectZero];
    _glow.translatesAutoresizingMaskIntoConstraints = NO;
    _glow.layer.cornerRadius = 3;
    [_track addSubview:_glow];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [A2Typography numeric];

    _speedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _speedLabel.font = [A2Typography numeric];
    _speedLabel.textAlignment = NSTextAlignmentRight;

    [self addSubview:_detailLabel];
    [self addSubview:_speedLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_track.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_track.heightAnchor constraintEqualToConstant:6],

        [_fill.topAnchor constraintEqualToAnchor:_track.topAnchor],
        [_fill.bottomAnchor constraintEqualToAnchor:_track.bottomAnchor],
        [_fill.leadingAnchor constraintEqualToAnchor:_track.leadingAnchor],

        [_glow.centerYAnchor constraintEqualToAnchor:_track.centerYAnchor],
        [_glow.widthAnchor constraintEqualToConstant:24],
        [_glow.heightAnchor constraintEqualToConstant:6],

        [_detailLabel.topAnchor constraintEqualToAnchor:_track.bottomAnchor constant:A2SpaceS],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [_speedLabel.centerYAnchor constraintEqualToAnchor:_detailLabel.centerYAnchor],
        [_speedLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_speedLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_detailLabel.trailingAnchor constant:A2SpaceS],
    ]];

    _fillWidth = [_fill.widthAnchor constraintEqualToConstant:0];
    _fillWidth.active = YES;

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

- (void)setDetailText:(NSString *)detailText {
    _detailText = [detailText copy];
    _detailLabel.text = detailText;
}

- (void)setSpeedText:(NSString *)speedText {
    _speedText = [speedText copy];
    _speedLabel.text = speedText;
}

- (void)setProgress:(CGFloat)progress {
    [self setProgress:progress animated:NO];
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    _progress = MAX(0, MIN(1, progress));
    CGFloat target = self.bounds.size.width * _progress;
    if (!animated) {
        _fillWidth.constant = target;
        [self layoutIfNeeded];
        [self updateGlowPosition];
        return;
    }
    _fillWidth.constant = target;
    [UIView animateWithDuration:A2AnimDuration
                          delay:0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ [self layoutIfNeeded]; }
                     completion:nil];
    [self updateGlowPosition];
}

- (void)updateGlowPosition {
    CGFloat x = self.track.bounds.size.width * _progress;
    _glow.center = CGPointMake(x, _track.bounds.size.height / 2);
    _glow.alpha = (_progress > 0.01 && _progress < 0.99) ? 1.0 : 0.0;
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
    _fill.backgroundColor = t.cPrimary;
    _glow.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.55];
    _glow.layer.shadowColor = t.cPrimary.CGColor;
    _glow.layer.shadowOpacity = 0.8;
    _glow.layer.shadowRadius = 6;
    _glow.layer.shadowOffset = CGSizeZero;
    _detailLabel.textColor = t.cOnSurfaceVariant;
    _speedLabel.textColor = t.cPrimary;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _fillWidth.constant = self.bounds.size.width * _progress;
    [self updateGlowPosition];
}

@end

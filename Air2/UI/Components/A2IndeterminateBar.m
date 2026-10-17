//
//  A2IndeterminateBar.m
//  Air2
//

#import "A2IndeterminateBar.h"
#import "A2ThemeManager.h"

@interface A2IndeterminateBar () {
    /// 滑动条的 leading 约束 —— 改 constant 做位移动画
    NSLayoutConstraint *_barLeading;
}
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) CAShapeLayer *barMask;
@end

@implementation A2IndeterminateBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _barWidthRatio = 0.3;

    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.translatesAutoresizingMaskIntoConstraints = NO;
    _track.layer.cornerRadius = 2;
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.layer.cornerRadius = 2;
    [_track addSubview:_bar];

    [NSLayoutConstraint activateConstraints:@[
        [_track.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_track.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.heightAnchor constraintEqualToConstant:4],

        [_bar.topAnchor constraintEqualToAnchor:_track.topAnchor],
        [_bar.bottomAnchor constraintEqualToAnchor:_track.bottomAnchor],
        [_bar.widthAnchor constraintEqualToAnchor:_track.widthAnchor
                                       multiplier:_barWidthRatio],
    ]];

    // 用 leading constraint 的 constant 做位移
    _barLeading = [_bar.leadingAnchor constraintEqualToAnchor:_track.leadingAnchor
                                                      constant:0];
    _barLeading.active = YES;

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)startAnimating {
    [self.layer removeAllAnimations];
    [self animateOnce];
}

/// 循环：从左滑到右，再从头开始
- (void)animateOnce {
    [self layoutIfNeeded];

    CGFloat trackWidth = _track.bounds.size.width;
    if (trackWidth <= 0) {
        // 布局还没完成，下一轮再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self animateOnce];
        });
        return;
    }

    CGFloat barWidth = trackWidth * _barWidthRatio;
    CGFloat travel = trackWidth - barWidth;

    _barLeading.constant = 0;
    [self layoutIfNeeded];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:1.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_barLeading.constant = travel;
        [self layoutIfNeeded];
    } completion:^(BOOL finished) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !finished) return;
        // 短暂停顿再循环 —— 太连续会显得急促
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self animateOnce];
        });
    }];
}

- (void)stopAnimating {
    [self.layer removeAllAnimations];
    _barLeading.constant = 0;
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _track.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
    _bar.backgroundColor = t.cPrimary;
}

@end

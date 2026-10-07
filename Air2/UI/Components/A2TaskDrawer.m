//
//  A2TaskDrawer.m
//  Air2
//

#import "A2TaskDrawer.h"
#import "A2TaskProgressView.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2TaskDrawer ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *grabber;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIView *summaryTrack;
@property (nonatomic, strong) UIView *summaryFill;
@property (nonatomic, strong) UIScrollView *listScroll;
@property (nonatomic, strong) UIStackView *listStack;
@property (nonatomic, strong) NSLayoutConstraint *summaryFillWidth;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, assign) CGFloat panStartHeight;
@end

@implementation A2TaskDrawer

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _collapsedHeight = 56;
    _expandedHeight = 280;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipsToBounds = YES;
    self.layer.cornerRadius = 22;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

    [self setupBlur];
    [self setupSummary];
    [self setupList];

    // 拖拽手柄
    _grabber = [[UIView alloc] initWithFrame:CGRectZero];
    _grabber.translatesAutoresizingMaskIntoConstraints = NO;
    _grabber.layer.cornerRadius = 2;
    _grabber.userInteractionEnabled = NO;
    [self addSubview:_grabber];

    // 点击展开/收起
    _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:_tapGesture];

    // 上滑展开、下滑收起
    _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:_panGesture];

    [NSLayoutConstraint activateConstraints:@[
        [_grabber.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_grabber.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_grabber.widthAnchor constraintEqualToConstant:36],
        [_grabber.heightAnchor constraintEqualToConstant:4],

        [_blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

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

#pragma mark - 构建

- (void)setupBlur {
    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    _blurView.userInteractionEnabled = NO;
    [self addSubview:_blurView];
}

- (void)setupSummary {
    _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    _summaryLabel.text = @"暂无任务";
    [self addSubview:_summaryLabel];

    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.font = [A2Typography numeric];
    _percentLabel.textAlignment = NSTextAlignmentRight;
    _percentLabel.text = @"";
    [self addSubview:_percentLabel];

    _summaryTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _summaryTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryTrack.layer.cornerRadius = 1.25;
    _summaryTrack.clipsToBounds = YES;
    [self addSubview:_summaryTrack];

    _summaryFill = [[UIView alloc] initWithFrame:CGRectZero];
    _summaryFill.translatesAutoresizingMaskIntoConstraints = NO;
    [_summaryTrack addSubview:_summaryFill];

    _summaryFillWidth = [_summaryFill.widthAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [_summaryLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceXL],
        [_summaryLabel.centerYAnchor constraintEqualToAnchor:self.topAnchor constant:_collapsedHeight / 2],
        [_summaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_percentLabel.leadingAnchor constant:-A2SpaceS],

        [_percentLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceXL],
        [_percentLabel.centerYAnchor constraintEqualToAnchor:_summaryLabel.centerYAnchor],
        [_percentLabel.widthAnchor constraintGreaterThanOrEqualToConstant:44],

        [_summaryTrack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_summaryTrack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_summaryTrack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_summaryTrack.heightAnchor constraintEqualToConstant:2.5],

        [_summaryFill.leadingAnchor constraintEqualToAnchor:_summaryTrack.leadingAnchor],
        [_summaryFill.topAnchor constraintEqualToAnchor:_summaryTrack.topAnchor],
        [_summaryFill.bottomAnchor constraintEqualToAnchor:_summaryTrack.bottomAnchor],
    ]];
    _summaryFillWidth.active = YES;
}

- (void)setupList {
    _listScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _listScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _listScroll.showsVerticalScrollIndicator = YES;
    [self addSubview:_listScroll];

    _listStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _listStack.translatesAutoresizingMaskIntoConstraints = NO;
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = A2SpaceL;
    [_listScroll addSubview:_listStack];

    [NSLayoutConstraint activateConstraints:@[
        [_listScroll.topAnchor constraintEqualToAnchor:self.topAnchor constant:_collapsedHeight + A2SpaceS],
        [_listScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceXL],
        [_listScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceXL],
        [_listScroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-A2SpaceXL],

        [_listStack.topAnchor constraintEqualToAnchor:_listScroll.topAnchor],
        [_listStack.bottomAnchor constraintEqualToAnchor:_listScroll.bottomAnchor],
        [_listStack.leadingAnchor constraintEqualToAnchor:_listScroll.leadingAnchor],
        [_listStack.trailingAnchor constraintEqualToAnchor:_listScroll.trailingAnchor],
        [_listStack.widthAnchor constraintEqualToAnchor:_listScroll.widthAnchor],
    ]];
}

#pragma mark - 任务管理

- (void)addTaskView:(A2TaskProgressView *)taskView {
    [_listStack addArrangedSubview:taskView];
    taskView.alpha = 0;
    [UIView animateWithDuration:A2AnimDuration animations:^{ taskView.alpha = 1; }];
    [self updateVisibility];
}

- (void)removeTaskView:(A2TaskProgressView *)taskView {
    if (![_listStack.arrangedSubviews containsObject:taskView]) return;
    [UIView animateWithDuration:A2AnimDurationFast animations:^{
        taskView.alpha = 0;
        taskView.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [self.listStack removeArrangedSubview:taskView];
        [taskView removeFromSuperview];
        [self updateVisibility];
    }];
}

- (void)setSummaryTitle:(NSString *)title progress:(CGFloat)progress speed:(NSString *)speed {
    _summaryLabel.text = title;
    _percentLabel.text = speed.length
        ? speed
        : [NSString stringWithFormat:@"%.0f%%", progress * 100];

    _summaryFillWidth.constant = self.bounds.size.width * MAX(0, MIN(1, progress));
    [UIView animateWithDuration:A2AnimDuration animations:^{
        [self layoutIfNeeded];
    }];
}

- (void)updateVisibility {
    BOOL hasTasks = _listStack.arrangedSubviews.count > 0;
    if (!hasTasks && !self.isExpanded) {
        [UIView animateWithDuration:A2AnimDuration animations:^{
            self.transform = CGAffineTransformMakeTranslation(0, self.collapsedHeight + 30);
            self.alpha = 0;
        }];
    } else {
        [UIView animateWithDuration:A2AnimDuration animations:^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1;
        }];
    }
}

#pragma mark - 展开 / 收起

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;

    CGFloat target = expanded ? _expandedHeight : _collapsedHeight;
    void (^change)(void) = ^{
        self.heightConstraint.constant = target;
        [self.superview layoutIfNeeded];
    };

    if (animated) {
        UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDuration);
        [a addAnimations:change];
        [a startAnimation];
    } else {
        change();
    }

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

- (void)handleTap {
    [self setExpanded:!self.isExpanded animated:YES];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    CGFloat baseHeight = self.isExpanded ? _expandedHeight : _collapsedHeight;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _panStartHeight = baseHeight;
            break;

        case UIGestureRecognizerStateChanged: {
            // 手指向上为负，抽屉变高
            CGFloat h = _panStartHeight - translation.y;
            h = MAX(_collapsedHeight, MIN(_expandedHeight, h));
            self.heightConstraint.constant = h;
            [self.superview layoutIfNeeded];
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocity = [pan velocityInView:self.superview].y;
            BOOL shouldExpand;
            if (fabs(velocity) > 400) {
                // 快速滑动时以方向为准
                shouldExpand = (velocity < 0);
            } else {
                // 慢速拖动时看过了中点没有
                CGFloat mid = (_collapsedHeight + _expandedHeight) / 2;
                shouldExpand = (self.heightConstraint.constant > mid);
            }
            _expanded = !shouldExpand;   // 触发 setExpanded 的状态变更
            [self setExpanded:shouldExpand animated:YES];
            break;
        }

        default:
            break;
    }
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _grabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    _summaryLabel.textColor = t.cOnSurface;
    _percentLabel.textColor = t.cPrimary;
    _summaryTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    _summaryFill.backgroundColor = t.cPrimary;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
}

@end

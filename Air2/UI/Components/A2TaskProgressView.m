//
//  A2TaskProgressView.m
//  Air2
//
//  任务卡片 —— 下载任务列表的一项。
//  含状态点（运行中呼吸）、标题、副标题、进度条、暂停/继续按钮。
//

#import "A2ProgressView.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2TaskProgressView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) A2ProgressBar *bar;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *statusDot;
@end

@implementation A2TaskProgressView

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _title = [title copy];
    _subtitle = [subtitle copy];
    _state = A2TaskStatePending;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _statusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 4;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [A2Typography titleCard];
    _titleLabel.text = _title;

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = [A2Typography caption];
    _subtitleLabel.text = _subtitle;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_toggleButton setImage:[UIImage systemImageNamed:@"pause.fill" withConfiguration:cfg]
                   forState:UIControlStateNormal];
    [_toggleButton addTarget:self action:@selector(handleToggle) forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:_statusDot];
    [self addSubview:textStack];
    [self addSubview:_toggleButton];

    _bar = [[A2ProgressBar alloc] initWithFrame:CGRectZero];
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_bar];

    [NSLayoutConstraint activateConstraints:@[
        [_statusDot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_statusDot.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_statusDot.widthAnchor constraintEqualToConstant:8],
        [_statusDot.heightAnchor constraintEqualToConstant:8],

        [textStack.leadingAnchor constraintEqualToAnchor:_statusDot.trailingAnchor constant:A2SpaceS],
        [textStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_toggleButton.leadingAnchor constant:-A2SpaceS],

        [_toggleButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_toggleButton.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_toggleButton.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_toggleButton.heightAnchor constraintEqualToConstant:36],

        [_bar.topAnchor constraintEqualToAnchor:textStack.bottomAnchor constant:A2SpaceM],
        [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_bar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_bar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
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

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleLabel.text = title;
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitle = [subtitle copy];
    _subtitleLabel.text = subtitle;
}

- (void)setSpeedText:(NSString *)speedText {
    _speedText = [speedText copy];
    _bar.speedText = speedText;
}

- (void)setProgress:(CGFloat)progress {
    [self setProgress:progress animated:NO];
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    _progress = MAX(0, MIN(1, progress));
    [_bar setProgress:_progress animated:animated];
    _bar.detailText = [NSString stringWithFormat:@"%.0f%%", _progress * 100];
}

- (void)setState:(A2TaskState)state {
    _state = state;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];

    switch (state) {
        case A2TaskStateRunning:
            [_toggleButton setImage:[UIImage systemImageNamed:@"pause.fill" withConfiguration:cfg]
                           forState:UIControlStateNormal];
            _toggleButton.hidden = NO;
            break;
        case A2TaskStatePaused:
            [_toggleButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:cfg]
                           forState:UIControlStateNormal];
            _toggleButton.hidden = NO;
            break;
        case A2TaskStateCompleted:
            [_toggleButton setImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:cfg]
                           forState:UIControlStateNormal];
            _toggleButton.hidden = NO;
            break;
        case A2TaskStateFailed:
            [_toggleButton setImage:[UIImage systemImageNamed:@"arrow.clockwise" withConfiguration:cfg]
                           forState:UIControlStateNormal];
            _toggleButton.hidden = NO;
            break;
        case A2TaskStatePending:
        default:
            _toggleButton.hidden = YES;
            break;
    }
    [self applyTheme];
}

- (void)handleToggle {
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
    if (self.onTogglePause) self.onTogglePause();
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = UIColor.whiteColor;
    _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];

    switch (_state) {
        case A2TaskStateRunning:   _statusDot.backgroundColor = t.primary; break;
        case A2TaskStateCompleted: _statusDot.backgroundColor = t.success; break;
        case A2TaskStateFailed:    _statusDot.backgroundColor = t.error; break;
        case A2TaskStatePaused:    _statusDot.backgroundColor = t.outline; break;
        default:                   _statusDot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3]; break;
    }
    // 运行中的圆点呼吸，提示"正在动"
    if (_state == A2TaskStateRunning) {
        if (!_statusDot.layer.animationKeys.count) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
            pulse.fromValue = @1.0;
            pulse.toValue = @0.35;
            pulse.duration = 0.85;
            pulse.autoreverses = YES;
            pulse.repeatCount = HUGE_VALF;
            [_statusDot.layer addAnimation:pulse forKey:@"pulse"];
        }
    } else {
        [_statusDot.layer removeAllAnimations];
    }

    _toggleButton.tintColor = UIColor.whiteColor;
}

@end

//
//  A2TaskLogCard.m
//  Air2
//

#import "A2TaskLogCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2TaskLogOutput.h"

@interface A2TaskLogCard ()
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *stateIcon;
@property (nonatomic, strong) UILabel *taskLabel;
@property (nonatomic, strong) UILabel *rateLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) double progressValue;
@property (nonatomic, copy, readwrite) NSString *title;
@end

@implementation A2TaskLogCard

+ (instancetype)presentInView:(UIView *)host title:(NSString *)title {
    A2TaskLogCard *c = [[A2TaskLogCard alloc] initWithFrame:CGRectZero];
    c.title = title;
    c.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:c];

    // 右上角挂载，宽度固定 260（与 ZL2 的卡片宽度接近）
    [NSLayoutConstraint activateConstraints:@[
        [c.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:12],
        [c.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [c.widthAnchor constraintEqualToConstant:260],
    ]];

    [c build];
    [c animateIn];
    return c;
}

#pragma mark - 构建

- (void)build {
    _logLines = [NSMutableArray array];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = A2RadiusL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.2;
    _card.layer.shadowRadius = 8;
    _card.layer.shadowOffset = CGSizeMake(0, 3);
    [self addSubview:_card];

    // 标题行：状态图标 + 标题 + 展开箭头
    _stateIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _stateIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _stateIcon.contentMode = UIViewContentModeScaleAspectFit;
    _stateIcon.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"
                              withConfiguration:[UIImageSymbolConfiguration
                                                 configurationWithPointSize:13
                                                                     weight:UIImageSymbolWeightSemibold]];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.text = self.title;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_stateIcon, _titleLabel]];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisHorizontal;
    header.spacing = 6;
    header.alignment = UIStackViewAlignmentCenter;

    // 任务名
    _taskLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _taskLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _taskLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _taskLabel.numberOfLines = 2;
    _taskLabel.text = @"准备中…";

    // 进度条 + 速率 + 百分比（同一行 —— 与 ZL2 的 InstallingTaskItem 一致）
    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _progressTrack.layer.cornerRadius = 1.5;
    _progressTrack.clipsToBounds = YES;
    [self setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    _progressFill.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressTrack addSubview:_progressFill];

    _rateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _rateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _rateLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    _rateLabel.hidden = YES;

    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];

    UIStackView *progressRow = [[UIStackView alloc] initWithArrangedSubviews:
                                @[_progressTrack, _rateLabel, _percentLabel]];
    progressRow.translatesAutoresizingMaskIntoConstraints = NO;
    progressRow.axis = UILayoutConstraintAxisHorizontal;
    progressRow.spacing = 6;
    progressRow.alignment = UIStackViewAlignmentCenter;

    // 日志区（默认隐藏）
    _logView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    _logView.layer.cornerRadius = A2RadiusS;
    _logView.hidden = YES;
    [_logView.heightAnchor constraintEqualToConstant:90].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[header, _taskLabel, progressRow, _logView]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    [_card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-10],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],

        [_stateIcon.widthAnchor constraintEqualToConstant:13],
        [_stateIcon.heightAnchor constraintEqualToConstant:13],

        [_progressTrack.heightAnchor constraintEqualToConstant:3],
        [_percentLabel.widthAnchor constraintGreaterThanOrEqualToConstant:30],

        [_progressFill.topAnchor constraintEqualToAnchor:_progressTrack.topAnchor],
        [_progressFill.bottomAnchor constraintEqualToAnchor:_progressTrack.bottomAnchor],
        [_progressFill.leadingAnchor constraintEqualToAnchor:_progressTrack.leadingAnchor],
    ]];

    _fillWidth = [_progressFill.widthAnchor constraintEqualToConstant:0];
    _fillWidth.active = YES;

    // 点标题展开/收起
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(headerTapped)];
    [_card addGestureRecognizer:tap];

    [self applyTheme];
}

- (void)headerTapped {
    [self toggleExpanded];
}

#pragma mark - 更新

- (void)updateTaskName:(NSString *)name progress:(double)progress rate:(NSString *)rate {
    _taskLabel.text = name;
    _progressValue = progress;

    _rateLabel.hidden = (rate.length == 0);
    _rateLabel.text = rate;

    if (progress < 0) {
        // 不确定进度：只显示速率，不显示百分比
        _percentLabel.text = @"";
        _fillWidth.constant = 0;
    } else {
        _percentLabel.text = [NSString stringWithFormat:@"%.0f%%", progress * 100];
        [self setNeedsLayout];
        [self layoutIfNeeded];
        CGFloat w = _progressTrack.bounds.size.width;
        if (w > 0) _fillWidth.constant = w * MAX(0, MIN(1, progress));
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_progressValue >= 0) {
        CGFloat w = _progressTrack.bounds.size.width;
        if (w > 0) _fillWidth.constant = w * MAX(0, MIN(1, _progressValue));
    }
}

- (void)finishWithState:(A2TaskCardState)state message:(NSString *)message {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    switch (state) {
        case A2TaskCardStateSuccess:
            _stateIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            _stateIcon.tintColor = t.cSuccess;
            _taskLabel.text = message ?: @"完成";
            _percentLabel.text = @"100%";
            _fillWidth.constant = _progressTrack.bounds.size.width;
            break;
        case A2TaskCardStateFailed:
            _stateIcon.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
            _stateIcon.tintColor = t.cError;
            _taskLabel.text = message ?: @"失败";
            break;
        default:
            break;
    }
    _rateLabel.hidden = YES;
}

/// 设置外部日志源时，把它的输出转发到本卡片的日志区。
///
/// A2TaskLogOutput 是「日志流」抽象：安装器、启动器都往里写，
/// 订阅者各自决定怎么展示（这里是折叠的日志区）。
- (void)setLogOutput:(A2TaskLogOutput *)logOutput {
    _logOutput = logOutput;
    if (!logOutput) return;

    // A2TaskLogOutput 用 onLinesChanged 回调（不是逐行推送）——
    // 每次变化给完整数组，这里只取最后一行作为新增内容。
    __weak typeof(self) weakSelf = self;
    __block NSUInteger lastCount = logOutput.lines.count;
    logOutput.onLinesChanged = ^(NSArray<NSString *> *lines) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (lines.count > lastCount) {
            for (NSUInteger i = lastCount; i < lines.count; i++) {
                [self appendLog:lines[i]];
            }
        }
        lastCount = lines.count;
    };
}

- (void)appendLog:(NSString *)line {
    if (line.length == 0) return;
    [_logLines addObject:line];
    if (_logLines.count > 200) {
        [_logLines removeObjectsInRange:NSMakeRange(0, _logLines.count - 200)];
    }
    _logView.text = [_logLines componentsJoinedByString:@"\n"];
}

- (void)toggleExpanded {
    _expanded = !_expanded;
    _logView.hidden = !_expanded;
    if (_expanded && _logView.text.length == 0) {
        _logView.text = _logLines.count ? [_logLines componentsJoinedByString:@"\n"] : @"（暂无日志）";
    }
}

#pragma mark - 动画

- (void)animateIn {
    self.alpha = 0;
    self.transform = CGAffineTransformMakeTranslation(20, 0);
    [UIView animateWithDuration:0.24
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.4
                        options:0
                     animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismissAfterDelay:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{
            self.alpha = 0;
            self.transform = CGAffineTransformMakeTranslation(20, 0);
        } completion:^(BOOL finished) {
            [self removeFromSuperview];
        }];
    });
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _card.backgroundColor = t.cSurfaceContainerHigh;
    _titleLabel.textColor = t.cOnSurface;
    _taskLabel.textColor = t.cOnSurfaceVariant;
    _rateLabel.textColor = t.cOnSurfaceVariant;
    _percentLabel.textColor = t.cOnSurfaceVariant;
    _progressTrack.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
    _progressFill.backgroundColor = t.cPrimary;
    _stateIcon.tintColor = t.cPrimary;
    _logView.backgroundColor = t.cSurfaceContainer;
    _logView.textColor = t.cOnSurfaceVariant;
}

@end

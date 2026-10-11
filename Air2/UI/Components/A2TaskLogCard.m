//
//  A2TaskLogCard.m
//  Air2
//

#import "A2TaskLogCard.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2TaskLogCard ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIView *logBackground;
@end

@implementation A2TaskLogCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _followScroll = YES;

    // ---- 标题 ----
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _titleLabel.numberOfLines = 1;

    // ---- 日志区 ----
    // 用 UITextView 而不是 UITableView：
    //   · 日志是只读的纯文本，不需要 cell 复用
    //   · 自带滚动 + 可滚到最后一行
    //   · selectable 让用户能复制报错信息
    _logBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _logBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _logBackground.layer.cornerRadius = 8;   // ZL2 用 8dp
    _logBackground.layer.cornerCurve = kCACornerCurveContinuous;
    _logBackground.clipsToBounds = YES;
    [self addSubview:_logBackground];

    _logView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.backgroundColor = UIColor.clearColor;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsMake(6, 8, 6, 8);
    _logView.textContainer.lineFragmentPadding = 0;
    [_logBackground addSubview:_logView];

    [self addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_logBackground.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
                                                 constant:A2SpaceS],
        [_logBackground.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_logBackground.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_logBackground.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        // 日志区至少留 3 行高度，否则内容少时卡片会塌成一条
        [_logBackground.heightAnchor constraintGreaterThanOrEqualToConstant:88],

        [_logView.topAnchor constraintEqualToAnchor:_logBackground.topAnchor],
        [_logView.bottomAnchor constraintEqualToAnchor:_logBackground.bottomAnchor],
        [_logView.leadingAnchor constraintEqualToAnchor:_logBackground.leadingAnchor],
        [_logView.trailingAnchor constraintEqualToAnchor:_logBackground.trailingAnchor],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 绑定

- (void)setLogOutput:(A2TaskLogOutput *)logOutput {
    _logOutput = logOutput;
    _titleLabel.text = logOutput.title;

    __weak typeof(self) weakSelf = self;
    logOutput.onLinesChanged = ^(NSArray<NSString *> *lines) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self renderLines:lines];
    };

    [self renderLines:logOutput.lines];
}

- (void)renderLines:(NSArray<NSString *> *)lines {
    _logView.text = [lines componentsJoinedByString:@"\n"];

    // 自动滚到最新 —— 但用户手动上翻看历史时不打断
    if (_followScroll && lines.count > 0) {
        NSRange end = NSMakeRange(_logView.text.length, 0);
        [_logView scrollRangeToVisible:end];
    }
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.cOnSurface;
    // 日志区用 surfaceContainer —— 与卡片本身区分层级
    _logBackground.backgroundColor = t.cSurfaceContainer;
    _logView.textColor = t.cOnSurfaceVariant;
}

@end

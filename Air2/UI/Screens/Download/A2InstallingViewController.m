//
//  A2InstallingViewController.m
//  Air2
//

#import "A2InstallingViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2ProgressView.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 安装步骤
typedef NS_ENUM(NSInteger, A2InstallStep) {
    A2InstallStepFetchManifest = 0,   ///< 获取版本清单
    A2InstallStepDownloadJar,         ///< 下载客户端
    A2InstallStepDownloadLibraries,   ///< 下载依赖库
    A2InstallStepDownloadAssets,      ///< 下载资源文件
    A2InstallStepInstallLoader,       ///< 安装模组加载器
    A2InstallStepFinalize,            ///< 收尾
    A2InstallStepCount,
};

#pragma mark - 步骤行

@interface A2InstallStepRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL done;
- (void)updateTheme;
@end

@implementation A2InstallStepRow

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _dot = [[UIView alloc] initWithFrame:CGRectZero];
    _dot.translatesAutoresizingMaskIntoConstraints = NO;
    _dot.layer.cornerRadius = 5;
    [self addSubview:_dot];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = title;
    _titleLabel.font = [A2Typography body];
    [self addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_dot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_dot.widthAnchor constraintEqualToConstant:10],
        [_dot.heightAnchor constraintEqualToConstant:10],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:A2SpaceM],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    [self updateTheme];
    return self;
}

- (void)setActive:(BOOL)active {
    _active = active;
    [self updateDot];
}

- (void)setDone:(BOOL)done {
    _done = done;
    [self updateDot];
}

- (void)updateDot {
    if (_done) {
        _dot.backgroundColor = A2ThemeManager.shared.scheme.success;
        _dot.alpha = 1.0;
    } else if (_active) {
        _dot.backgroundColor = A2ThemeManager.shared.scheme.primary;
        _dot.alpha = 1.0;
    } else {
        _dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        _dot.alpha = 0.7;
    }
}

- (void)updateTheme {
    _titleLabel.textColor = _done ? [UIColor colorWithWhite:1.0 alpha:0.62] : UIColor.whiteColor;
    [self updateDot];
}

@end

#pragma mark - 安装页

@interface A2InstallingViewController ()
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy, nullable) NSString *loader;
@property (nonatomic, strong) A2GlassCard *progressCard;
@property (nonatomic, strong) A2RingProgress *ring;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) NSMutableArray<A2InstallStepRow *> *stepRows;
@property (nonatomic, strong) A2PrimaryButton *actionButton;
@property (nonatomic, assign) A2InstallStep currentStep;
@property (nonatomic, assign) CGFloat overallProgress;
@property (nonatomic, strong, nullable) NSTimer *demoTimer;
@end

@implementation A2InstallingViewController

- (instancetype)initWithVersionName:(NSString *)versionName loader:(NSString *)loader {
    self = [super init];
    if (!self) return nil;
    _versionName = [versionName copy];
    _loader = [loader copy];
    _stepRows = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"安装中";

    __weak typeof(self) weakSelf = self;
    self.onBack = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self cancelInstall];
    };

    [self setupProgressCard];
    [self setupStepList];
    [self setupActionButton];

    [self startDemoProgress];
}

- (void)dealloc {
    [_demoTimer invalidate];
}

#pragma mark - 进度卡

- (void)setupProgressCard {
    _progressCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _progressCard.cornerRadius = A2RadiusXL;
    _progressCard.contentInsets = UIEdgeInsetsMake(A2SpaceXL, A2SpaceL, A2SpaceXL, A2SpaceL);

    _ring = [[A2RingProgress alloc] initWithFrame:CGRectZero];
    _ring.translatesAutoresizingMaskIntoConstraints = NO;
    _ring.lineWidth = 7;
    _ring.centerText = @"0%";
    _ring.captionText = _versionName;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.text = self.loader.length
        ? [NSString stringWithFormat:@"%@ · %@", _versionName, _loader]
        : _versionName;
    titleLabel.textColor = UIColor.whiteColor;

    _stageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stageLabel.font = [A2Typography subtitleCard];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    _stageLabel.text = @"正在准备…";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_ring, titleLabel, _stageLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentCenter;

    [_progressCard.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [_ring.widthAnchor constraintEqualToConstant:132],
        [_ring.heightAnchor constraintEqualToConstant:132],
        [stack.topAnchor constraintEqualToAnchor:_progressCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_progressCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_progressCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_progressCard.contentView.trailingAnchor],
    ]];

    [self addSection:_progressCard];
}

#pragma mark - 步骤清单

- (void)setupStepList {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;

    NSArray<NSString *> *titles = @[
        @"获取版本清单",
        @"下载客户端",
        @"下载依赖库",
        @"下载资源文件",
        @"安装模组加载器",
        @"完成安装",
    ];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;

    for (NSString *t in titles) {
        A2InstallStepRow *row = [[A2InstallStepRow alloc] initWithTitle:t];
        [row.heightAnchor constraintEqualToConstant:22].active = YES;
        [_stepRows addObject:row];
        [stack addArrangedSubview:row];
    }

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

#pragma mark - 操作按钮

- (void)setupActionButton {
    _actionButton = [[A2PrimaryButton alloc] initWithTitle:@"取消安装" style:A2ButtonStyleSecondary];
    _actionButton.icon = [UIImage systemImageNamed:@"xmark"];
    [_actionButton addTarget:self action:@selector(cancelInstall) forControlEvents:UIControlEventTouchUpInside];
    [self addSection:_actionButton];
}

- (void)cancelInstall {
    [_demoTimer invalidate];
    _demoTimer = nil;
    [A2Toast show:@"已取消安装" inView:self.view];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf.navigationController popViewControllerAnimated:YES];
    });
}

#pragma mark - 进度驱动（演示用，待接 Core 层真实进度）

- (void)startDemoProgress {
    _currentStep = A2InstallStepFetchManifest;
    _overallProgress = 0;

    _demoTimer = [NSTimer scheduledTimerWithTimeInterval:0.08
                                                 target:self
                                               selector:@selector(tick)
                                               userInfo:nil
                                                repeats:YES];
}

- (void)tick {
    _overallProgress += 0.004;
    if (_overallProgress >= 1.0) {
        _overallProgress = 1.0;
        [_demoTimer invalidate];
        _demoTimer = nil;
        [self finishInstall];
    }

    NSInteger step = (NSInteger)floor(_overallProgress * A2InstallStepCount);
    if (step >= A2InstallStepCount) step = A2InstallStepCount - 1;
    _currentStep = (A2InstallStep)step;

    [_ring setProgress:_overallProgress animated:YES];
    _ring.centerText = [NSString stringWithFormat:@"%.0f%%", _overallProgress * 100];

    _stageLabel.text = [self stageTextForStep:_currentStep];

    for (NSUInteger i = 0; i < _stepRows.count; i++) {
        A2InstallStepRow *row = _stepRows[i];
        row.done = (i < (NSUInteger)_currentStep);
        row.active = (i == (NSUInteger)_currentStep);
        [row updateTheme];
    }
}

- (NSString *)stageTextForStep:(A2InstallStep)step {
    switch (step) {
        case A2InstallStepFetchManifest:     return @"正在获取版本清单…";
        case A2InstallStepDownloadJar:       return @"正在下载客户端…";
        case A2InstallStepDownloadLibraries: return @"正在下载依赖库…";
        case A2InstallStepDownloadAssets:    return @"正在下载资源文件…";
        case A2InstallStepInstallLoader:     return @"正在安装模组加载器…";
        case A2InstallStepFinalize:          return @"正在收尾…";
        default:                             return @"";
    }
}

- (void)finishInstall {
    for (A2InstallStepRow *row in _stepRows) {
        row.done = YES;
        row.active = NO;
        [row updateTheme];
    }
    self.pageTitle = @"安装完成";
    _stageLabel.text = @"安装完成";

    [_actionButton removeFromSuperview];
    A2PrimaryButton *done = [[A2PrimaryButton alloc] initWithTitle:@"完成" style:A2ButtonStylePrimary];
    done.icon = [UIImage systemImageNamed:@"checkmark"];
    [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSection:done];
    _actionButton = done;

    UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)doneTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

@end

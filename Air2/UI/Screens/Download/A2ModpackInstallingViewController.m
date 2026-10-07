//
//  A2ModpackInstallingViewController.m
//  Air2
//
//  整合包安装进度页 —— 接真实的 A2ModpackInstaller。
//

#import "A2ModpackInstallingViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2ProgressView.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2VersionManager.h"

#pragma mark - 步骤行

@interface A2ModpackStepRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL done;
- (void)updateTheme;
@end

@implementation A2ModpackStepRow

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
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
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

- (void)setActive:(BOOL)active { _active = active; [self updateDot]; }
- (void)setDone:(BOOL)done { _done = done; [self updateDot]; }

- (void)updateDot {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    if (_done) {
        _dot.backgroundColor = t.cSuccess;
        _dot.alpha = 1.0;
    } else if (_active) {
        _dot.backgroundColor = t.cPrimary;
        _dot.alpha = 1.0;
        // 运行中的圆点呼吸
        if (!_dot.layer.animationKeys.count) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
            pulse.fromValue = @1.0;
            pulse.toValue = @0.35;
            pulse.duration = 0.8;
            pulse.autoreverses = YES;
            pulse.repeatCount = HUGE_VALF;
            [_dot.layer addAnimation:pulse forKey:@"pulse"];
        }
    } else {
        [_dot.layer removeAllAnimations];
        _dot.backgroundColor = t.cOutline;
        _dot.alpha = 0.7;
    }
}

- (void)updateTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = _done ? t.cOnSurfaceVariant : t.cOnSurface;
    [self updateDot];
}

@end

#pragma mark - 安装页

@interface A2ModpackInstallingViewController ()
@property (nonatomic, strong) A2ModpackInstallRequest *request;
@property (nonatomic, strong) A2ModpackInstaller *installer;
@property (nonatomic, strong) UIStackView *stepStack;
@property (nonatomic, strong) A2RingProgress *ring;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) NSMutableArray<A2ModpackStepRow *> *stepRows;
@property (nonatomic, strong) A2PrimaryButton *actionButton;
@end

@implementation A2ModpackInstallingViewController

- (instancetype)initWithRequest:(A2ModpackInstallRequest *)request {
    self = [super init];
    if (!self) return nil;
    _request = request;
    _stepRows = [NSMutableArray array];
    _installer = [[A2ModpackInstaller alloc] init];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"安装整合包";

    __weak typeof(self) weakSelf = self;
    self.onBack = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self confirmCancel];
    };

    [self setupProgressCard];
    [self setupStepList];
    [self setupActionButton];
    [self startInstall];
}

- (void)dealloc {
    [_installer cancel];
}

#pragma mark - UI

/// 步骤清单的中文标题，顺序与 A2ModpackInstallStage 一一对应
- (NSArray<NSString *> *)stageTitles {
    return @[
        @"清理临时文件",
        @"下载整合包",
        @"解压整合包",
        @"识别整合包格式",
        @"铺开覆盖文件",
        @"下载模组文件",
        @"安装游戏本体",
        @"完成安装",
    ];
}

/// 页面上显示的整合包名称
- (NSString *)displayName {
    if (self.request.versionName.length) return self.request.versionName;
    return @"整合包";
}

- (void)setupProgressCard {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    _ring = [[A2RingProgress alloc] initWithFrame:CGRectZero];
    _ring.translatesAutoresizingMaskIntoConstraints = NO;
    _ring.lineWidth = 7;
    _ring.centerText = @"0%";
    _ring.captionText = [self displayName];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 1;
    titleLabel.text = [self displayName];
    titleLabel.textColor = A2ThemeManager.shared.scheme.cOnSurface;

    _stageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stageLabel.font = [A2Typography caption];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    _stageLabel.text = @"正在准备…";
    _stageLabel.numberOfLines = 2;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_ring, titleLabel, _stageLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentCenter;

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [_ring.widthAnchor constraintEqualToConstant:140],
        [_ring.heightAnchor constraintEqualToConstant:140],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

- (void)setupStepList {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;

    _stepStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stepStack.translatesAutoresizingMaskIntoConstraints = NO;
    _stepStack.axis = UILayoutConstraintAxisVertical;
    _stepStack.spacing = A2SpaceM;

    for (NSString *t in [self stageTitles]) {
        A2ModpackStepRow *row = [[A2ModpackStepRow alloc] initWithTitle:t];
        [row.heightAnchor constraintEqualToConstant:20].active = YES;
        [_stepRows addObject:row];
        [_stepStack addArrangedSubview:row];
    }

    [card.contentView addSubview:_stepStack];
    [NSLayoutConstraint activateConstraints:@[
        [_stepStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [_stepStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [_stepStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_stepStack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

- (void)setupActionButton {
    _actionButton = [[A2PrimaryButton alloc] initWithTitle:@"取消安装" style:A2ButtonStyleSecondary];
    _actionButton.icon = [UIImage systemImageNamed:@"xmark"];
    [_actionButton addTarget:self action:@selector(confirmCancel) forControlEvents:UIControlEventTouchUpInside];
    [self addSection:_actionButton];
}

#pragma mark - 安装

- (void)startInstall {
    // 兜底：调用方没给游戏目录时用当前游戏根目录
    if (self.request.gameHome.length == 0) {
        self.request.gameHome = A2VersionManager.shared.gameHome;
    }

    __weak typeof(self) weakSelf = self;
    [_installer install:self.request
        progress:^(A2ModpackInstallStage stage, double progress, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self updateUIForStage:stage progress:progress message:message];
    }
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self handleCompletion:success error:error];
    }];
}

- (void)updateUIForStage:(A2ModpackInstallStage)stage progress:(double)progress message:(NSString *)message {
    if (message.length) _stageLabel.text = message;

    // 总进度：8 个阶段等分
    double total = ((double)stage + progress) / (double)A2ModpackInstallStageCount;
    [_ring setProgress:total animated:YES];
    _ring.centerText = [NSString stringWithFormat:@"%.0f%%", total * 100];

    for (NSUInteger i = 0; i < _stepRows.count; i++) {
        A2ModpackStepRow *row = _stepRows[i];
        row.done = (i < (NSUInteger)stage);
        row.active = (i == (NSUInteger)stage);
        [row updateTheme];
    }
}

- (void)handleCompletion:(BOOL)success error:(NSError *)error {
    if (success) {
        for (A2ModpackStepRow *row in _stepRows) {
            row.done = YES;
            row.active = NO;
            [row updateTheme];
        }
        self.pageTitle = @"安装完成";
        _stageLabel.text = @"整合包安装完成";
        [_ring setProgress:1.0 animated:YES];
        _ring.centerText = @"100%";

        [_actionButton removeFromSuperview];
        A2PrimaryButton *done = [[A2PrimaryButton alloc] initWithTitle:@"完成"
                                                                style:A2ButtonStylePrimary];
        done.icon = [UIImage systemImageNamed:@"checkmark"];
        [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSection:done];
        _actionButton = done;

        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeSuccess];

        // 让版本管理页刷新
        [A2VersionManager.shared reload];
    } else {
        self.pageTitle = @"安装失败";
        _stageLabel.text = error.localizedDescription ?: @"整合包安装失败";

        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeError];
    }
}

#pragma mark - 动作

- (void)confirmCancel {
    if (_actionButton.title.length && [_actionButton.title isEqualToString:@"完成"]) {
        [self doneTapped];
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"取消安装"
                                            message:@"已下载的文件会保留，下次可以重新开始。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续安装" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消安装" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        __weak typeof(self) weakSelf = self;
        [weakSelf.installer cancel];
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)doneTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

@end

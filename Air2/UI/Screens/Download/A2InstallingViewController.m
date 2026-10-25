//
//  A2InstallingViewController.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  安装进度页 —— 接真实的 A2GameInstaller，把阶段/进度映射到环形+线性+分步清单。
//

#import "A2InstallingViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2RingProgress.h"
#import "A2ProgressBar.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2ColorScheme.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2GameInstaller.h"
#import "A2ModPackInstaller.h"
#import "A2TaskLogOutput.h"
#import "A2TaskLogCard.h"
#import "A2InstallProgressDialog.h"
#import "A2VersionManager.h"
#import "A2ModLoaderAPI.h"
#import "A2Log.h"

#pragma mark - 步骤行

typedef NS_ENUM(NSInteger, A2InstallStepState) {
    A2InstallStepStateWaiting = 0,
    A2InstallStepStateActive,
    A2InstallStepStateDone,
    A2InstallStepStateSkipped,
};

/// 分步清单的一行：状态图标 + 阶段名 + 右侧百分比/说明。
@interface A2InstallStepRow : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, assign) A2InstallStepState state;
- (instancetype)initWithTitle:(NSString *)title;
- (void)applyState:(A2InstallStepState)state percentText:(NSString *)percentText;
- (void)applyTheme;
@end

@implementation A2InstallStepRow

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = title;
    _titleLabel.font = [A2Typography body];
    _titleLabel.numberOfLines = 1;
    [self addSubview:_titleLabel];

    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.font = [A2Typography caption];
    _percentLabel.textAlignment = NSTextAlignmentRight;
    _percentLabel.numberOfLines = 1;
    [_percentLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                  forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:_percentLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:20],
        [_iconView.heightAnchor constraintEqualToConstant:20],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                                  constant:A2SpaceM],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [_percentLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor
                                                                 constant:A2SpaceS],
        [_percentLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_percentLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [self.heightAnchor constraintEqualToConstant:28],
    ]];

    _state = A2InstallStepStateWaiting;
    [self applyTheme];
    return self;
}

- (void)applyState:(A2InstallStepState)state percentText:(NSString *)percentText {
    _state = state;
    _percentLabel.text = percentText;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    NSString *symbol = @"circle";
    UIColor *iconColor = t.cOutline;
    switch (_state) {
        case A2InstallStepStateWaiting:
            symbol = @"circle";
            iconColor = t.cOutline;
            break;
        case A2InstallStepStateActive:
            symbol = @"circle.lefthalf.filled";
            iconColor = t.cPrimary;
            break;
        case A2InstallStepStateDone:
            symbol = @"checkmark.circle.fill";
            iconColor = t.cSuccess;
            break;
        case A2InstallStepStateSkipped:
            symbol = @"minus.circle";
            iconColor = t.cOnSurfaceVariant;
            break;
    }
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    _iconView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
    _iconView.tintColor = iconColor;

    BOOL dimmed = (_state == A2InstallStepStateDone || _state == A2InstallStepStateSkipped);
    _titleLabel.textColor = dimmed ? t.cOnSurfaceVariant : t.cOnSurface;
    _percentLabel.textColor = (_state == A2InstallStepStateActive) ? t.cPrimary : t.cOnSurfaceVariant;
}

@end

#pragma mark - 安装页

@interface A2InstallingViewController ()

@property (nonatomic, copy) NSString *mcVersion;
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, strong, nullable) NSNumber *loaderType;
@property (nonatomic, copy, nullable) NSString *loaderVersion;

@property (nonatomic, strong) A2GameInstaller *installer;
/// 整合包模式：zip 路径（nil 表示普通安装）
@property (nonatomic, strong, nullable) NSNumber *apiType;
@property (nonatomic, copy, nullable) NSString *apiVersion;
@property (nonatomic, copy, nullable) NSString *modPackPath;
@property (nonatomic, strong, nullable) A2ModPackInstaller *packInstaller;
@property (nonatomic, assign) BOOL finished;

@property (nonatomic, strong) A2RingProgress *ring;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) A2ProgressBar *progressBar;
@property (nonatomic, strong) NSMutableArray<A2InstallStepRow *> *stepRows;

@property (nonatomic, strong) A2PrimaryButton *cancelButton;

@property (nonatomic, strong) A2GlassCard *failureCard;
@property (nonatomic, strong) UILabel *failureDetailLabel;

@property (nonatomic, strong) A2GlassCard *successCard;

@property (nonatomic, assign) A2InstallStage currentStage;

// 安装日志卡片（A2InstallingViewController.m:250/335 使用 _logOutput/_logCard）
// —— 此前只写了使用点、漏了属性声明，导致 CI 报 “use of undeclared identifier”。
@property (nonatomic, strong) A2TaskLogOutput *logOutput;
@property (nonatomic, strong) A2TaskLogCard *logCard;

@end

@implementation A2InstallingViewController

/// 7 项阶段中文名，与 A2InstallStage 一一对应。
static NSArray<NSString *> *A2InstallStageTitles(void) {
    return @[
        @"获取版本清单",
        @"下载版本信息",
        @"下载客户端",
        @"下载依赖库",
        @"下载资源文件",
        @"安装模组加载器",
        @"完成安装",
    ];
}

- (instancetype)initWithMCVersion:(NSString *)mcVersion
                      versionName:(NSString *)versionName
                       loaderType:(NSNumber *)loaderType
                    loaderVersion:(NSString *)loaderVersion
                          apiType:(NSNumber *)apiType
                       apiVersion:(NSString *)apiVersion {
    self = [super init];
    if (!self) return nil;
    _mcVersion = [mcVersion copy];
    _versionName = [versionName copy];
    _loaderType = loaderType;
    _loaderVersion = [loaderVersion copy];
    _apiType = apiType;
    _apiVersion = [apiVersion copy];
    _stepRows = [NSMutableArray array];
    _installer = [[A2GameInstaller alloc] init];
    _currentStage = A2InstallStageFetchManifest;
    return self;
}

- (instancetype)initWithModPackPath:(NSString *)zipPath
                        versionName:(NSString *)versionName {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _mcVersion = @"";        // 整合包的 MC 版本从清单里解析
    _versionName = [versionName copy];
    _modPackPath = [zipPath copy];
    _stepRows = [NSMutableArray array];
    _packInstaller = [[A2ModPackInstaller alloc] init];
    _currentStage = A2InstallStageFetchManifest;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = _modPackPath.length ? @"安装整合包" : @"安装中";

    __weak typeof(self) weakSelf = self;
    self.onBack = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.finished) {
            [self backToDownloadCenter];
        } else {
            [self confirmCancel];
        }
    };

    _logOutput = [[A2TaskLogOutput alloc] initWithTitle:[NSString stringWithFormat:@"安装 %@", _versionName]];

    [self setupProgressCard];
    [self setupStepList];
    [self setupLogCard];
    [self setupCancelButton];
    [self setupFailureCard];
    [self setupSuccessCard];
    [self setupThemeObserver];

    [self applyTheme];
    [self startInstall];
}

- (void)dealloc {
    [_installer cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupThemeObserver {
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

#pragma mark - UI

- (void)setupProgressCard {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;

    _ring = [[A2RingProgress alloc] initWithFrame:CGRectZero];
    _ring.translatesAutoresizingMaskIntoConstraints = NO;
    _ring.lineWidth = 7;
    _ring.centerText = @"0%";
    _ring.captionText = _versionName;

    _stageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stageLabel.font = [A2Typography titleLarge];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.numberOfLines = 2;
    _stageLabel.text = @"正在准备…";

    _progressBar = [[A2ProgressBar alloc] initWithFrame:CGRectZero];
    _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    _progressBar.detailText = @"本阶段 0%";

    // 环形进度要固定尺寸并居中，而堆栈 Fill 对齐会把子视图拉满宽度，
    // 两者冲突。用一个等宽的盒子包住环，盒子随堆栈撑满，环在盒内居中。
    UIView *ringBox = [[UIView alloc] initWithFrame:CGRectZero];
    ringBox.translatesAutoresizingMaskIntoConstraints = NO;
    [ringBox addSubview:_ring];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        ringBox, _stageLabel, _progressBar,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentFill;

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [ringBox.heightAnchor constraintEqualToConstant:140],
        [_ring.widthAnchor constraintEqualToConstant:140],
        [_ring.heightAnchor constraintEqualToConstant:140],
        [_ring.centerXAnchor constraintEqualToAnchor:ringBox.centerXAnchor],
        [_ring.centerYAnchor constraintEqualToAnchor:ringBox.centerYAnchor],

        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self addSection:card];
}

- (void)setupLogCard {
    _logCard = [[A2TaskLogCard alloc] initWithFrame:CGRectZero];
    _logCard.logOutput = _logOutput;
    [self addSection:_logCard];

    // 日志区要占满剩余空间 —— 它是这个页面信息量最大的部分
    [NSLayoutConstraint activateConstraints:@[
        [_logCard.heightAnchor constraintGreaterThanOrEqualToConstant:140],
    ]];
}

- (void)setupStepList {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;

    BOOL hasLoader = (_loaderType != nil);
    NSArray<NSString *> *titles = A2InstallStageTitles();
    for (NSUInteger i = 0; i < titles.count; i++) {
        A2InstallStepRow *row = [[A2InstallStepRow alloc] initWithTitle:titles[i]];
        // 未选加载器时，加载器那项直接标注为跳过。
        if (!hasLoader && i == (NSUInteger)A2InstallStageInstallLoader) {
            [row applyState:A2InstallStepStateSkipped percentText:@"跳过（未选加载器）"];
        } else {
            [row applyState:A2InstallStepStateWaiting percentText:@"等待"];
        }
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

- (void)setupCancelButton {
    _cancelButton = [[A2PrimaryButton alloc] initWithTitle:@"取消安装" style:A2ButtonStyleSecondary];
    _cancelButton.icon = [UIImage systemImageNamed:@"xmark"];
    [_cancelButton addTarget:self action:@selector(confirmCancel)
            forControlEvents:UIControlEventTouchUpInside];
    [self addSection:_cancelButton];
}

- (void)setupFailureCard {
    _failureCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _failureCard.cornerRadius = A2RadiusL;
    _failureCard.elevation = A2CardElevationLow;
    _failureCard.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [A2Typography titleCard];
    title.textAlignment = NSTextAlignmentCenter;
    title.text = @"安装失败";

    _failureDetailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _failureDetailLabel.font = [A2Typography caption];
    _failureDetailLabel.textAlignment = NSTextAlignmentCenter;
    _failureDetailLabel.numberOfLines = 0;

    A2PrimaryButton *retry = [[A2PrimaryButton alloc] initWithTitle:@"重试"
                                                              style:A2ButtonStylePrimary];
    [retry addTarget:self action:@selector(retryInstall)
     forControlEvents:UIControlEventTouchUpInside];

    A2PrimaryButton *back = [[A2PrimaryButton alloc] initWithTitle:@"返回"
                                                             style:A2ButtonStyleSecondary];
    [back addTarget:self action:@selector(backToDownloadCenter)
    forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, _failureDetailLabel, retry, back,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentFill;

    [_failureCard.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_failureCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_failureCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_failureCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_failureCard.contentView.trailingAnchor],
        [retry.heightAnchor constraintEqualToConstant:A2ButtonHeight],
        [back.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self addSection:_failureCard];
}

- (void)setupSuccessCard {
    _successCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _successCard.cornerRadius = A2RadiusL;
    _successCard.elevation = A2CardElevationLow;
    _successCard.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [A2Typography titleCard];
    title.textAlignment = NSTextAlignmentCenter;
    title.text = @"安装成功";

    A2PrimaryButton *done = [[A2PrimaryButton alloc] initWithTitle:@"完成"
                                                             style:A2ButtonStylePrimary];
    done.icon = [UIImage systemImageNamed:@"checkmark"];
    [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, done]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentFill;

    [_successCard.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_successCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_successCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_successCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_successCard.contentView.trailingAnchor],
        [done.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self addSection:_successCard];
}

#pragma mark - 安装

- (void)startInstall {
    // 整合包模式走另一条流程 —— 它的阶段划分与「装原版+加载器」不同。
    if (_modPackPath.length) {
        [self startModPackInstall];
        return;
    }

    A2InstallRequest *req = [A2InstallRequest new];
    req.mcVersion = _mcVersion;
    req.versionName = _versionName;
    req.loaderType = _loaderType;
    req.loaderVersion = _loaderVersion;
    req.apiModType = _apiType;
    req.apiModVersion = _apiVersion;
    req.gameHome = A2VersionManager.shared.gameHome;

    __weak typeof(self) weakSelf = self;
    [_installer install:req
        progress:^(A2InstallStage stage, double progress, NSString *message) {
        [weakSelf applyStage:stage progress:progress message:message];
    }
        completion:^(BOOL success, NSError *error) {
        [weakSelf applyCompletion:success error:error];
    }];
}

/// 整合包安装。
///
/// 阶段与普通安装不同（解析清单 / 装加载器 / 下载文件 / 解压覆盖），
/// 但复用同一套进度 UI —— 把安装器的回调映射到 A2InstallStage 的语义位置。
- (void)startModPackInstall {
    __weak typeof(self) weakSelf = self;
    [_packInstaller installPackAtPath:_modPackPath
                          versionName:_versionName
                             gameHome:A2VersionManager.shared.gameHome
                             progress:^(double progress, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 整合包进度总体映射到「下载资源」阶段 —— 它是耗时最长的一段
        [self applyStage:A2InstallStageDownloadAssets progress:progress message:message];
    }
                           completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self applyCompletion:success error:error];
    }];
}

/// progress 回调来自安装器；保险起见统一切主线程再动 UI。
- (void)applyStage:(A2InstallStage)stage progress:(double)progress message:(NSString *)message {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyStage:stage progress:progress message:message];
        });
        return;
    }
    [self updateForStage:stage progress:progress message:message];
}

- (void)applyCompletion:(BOOL)success error:(NSError *)error {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyCompletion:success error:error];
        });
        return;
    }
    [self handleCompletion:success error:error];
}

/// 阶段的中文名（日志里用）
- (NSString *)stageDisplayName:(A2InstallStage)stage {
    switch (stage) {
        case A2InstallStageFetchManifest:     return @"[清单]";
        case A2InstallStageDownloadJSON:      return @"[版本信息]";
        case A2InstallStageDownloadJar:       return @"[客户端]";
        case A2InstallStageDownloadLibraries: return @"[依赖库]";
        case A2InstallStageDownloadAssets:    return @"[资源]";
        case A2InstallStageInstallLoader:     return @"[加载器]";
        case A2InstallStageFinalize:          return @"[收尾]";
        default:                              return @"[安装]";
    }
}

- (void)updateForStage:(A2InstallStage)stage progress:(double)progress message:(NSString *)message {
    _currentStage = stage;
    _stageLabel.text = message.length ? message : @"安装中…";
    [A2Log log:@"download: 安装阶段 %ld 进度 %.0f%% %@",
        (long)stage, progress * 100, message ?: @""];

    // 阶段切换时写一行明确的日志；阶段内的高频进度用覆盖式
    NSString *stageName = [self stageDisplayName:stage];
    if (message.length > 0) {
        [_logOutput appendProgress:[NSString stringWithFormat:@"%@ %@", stageName, message]];
    }

    // 进度条上显示速度 —— 用户最关心"现在下得快不快"
    if (message.length > 0) {
        _progressBar.detailText = message;
    }

    // ---- 总进度 ----
    //
    // 之前用 (stage + progress) / A2InstallStageCount 有两个问题：
    //   1. 未选加载器时「安装模组加载器」被跳过，但分母仍算它 → 永远到不了 100%
    //   2. 步骤列表显示「下载依赖库 100%」时环形还停在 42%
    //      （stage 索引与实际进度脱节）
    //
    // 改成按【实际会执行的步骤数】算分母，并且以步骤列表的真实状态为准，
    // 不是直接信任 stage 索引。
    BOOL hasLoader = (_loaderType != nil);
    NSInteger effectiveStages = A2InstallStageCount - (hasLoader ? 0 : 1);
    if (effectiveStages <= 0) effectiveStages = 1;

    // stage 可能超过 effectiveStages（跳过加载器时），钳一下
    NSInteger effectiveStage = MIN((NSInteger)stage, effectiveStages - 1);
    double total = ((double)effectiveStage + progress) / (double)effectiveStages;
    total = MAX(0, MIN(1.0, total));

    [_ring setProgress:total animated:YES];
    _ring.centerText = [NSString stringWithFormat:@"%.0f%%", total * 100];
    [_progressBar setProgress:total animated:YES];
    _progressBar.detailText = [NSString stringWithFormat:@"总进度 %.0f%%", total * 100];
    for (NSUInteger i = 0; i < _stepRows.count; i++) {
        A2InstallStepRow *row = _stepRows[i];
        if (!hasLoader && i == (NSUInteger)A2InstallStageInstallLoader) {
            [row applyState:A2InstallStepStateSkipped percentText:@"跳过（未选加载器）"];
        } else if (i < (NSUInteger)stage) {
            [row applyState:A2InstallStepStateDone percentText:@"完成"];
        } else if (i == (NSUInteger)stage) {
            // 已经 100% 就该显示完成，不是继续转圈
            // （截图里出现过「下载依赖库 100%」还挂着半填充圆的情况）
            if (progress >= 0.999) {
                [row applyState:A2InstallStepStateDone percentText:@"完成"];
            } else {
                [row applyState:A2InstallStepStateActive
                    percentText:[NSString stringWithFormat:@"%.0f%%", progress * 100]];
            }
        } else {
            [row applyState:A2InstallStepStateWaiting percentText:@"等待"];
        }
    }
}

- (void)handleCompletion:(BOOL)success error:(NSError *)error {
    if (success) {
        _finished = YES;
        self.pageTitle = @"安装完成";
        _stageLabel.text = @"安装完成";
        [_ring setProgress:1.0 animated:YES];
        _ring.centerText = @"100%";
        [_progressBar setProgress:1.0 animated:YES];
        _progressBar.detailText = @"100%";

        BOOL hasLoader = (_loaderType != nil);
        for (NSUInteger i = 0; i < _stepRows.count; i++) {
            A2InstallStepRow *row = _stepRows[i];
            if (!hasLoader && i == (NSUInteger)A2InstallStageInstallLoader) {
                [row applyState:A2InstallStepStateSkipped percentText:@"跳过（未选加载器）"];
            } else {
                [row applyState:A2InstallStepStateDone percentText:@"完成"];
            }
        }

        _cancelButton.hidden = YES;
        _failureCard.hidden = YES;
        _successCard.hidden = NO;

        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeSuccess];

        [A2Log log:@"download: 安装完成 %@", _versionName];
        // 让版本管理页刷新，用户回到列表就能看到新版本。
        [A2VersionManager.shared reload];
    } else {
        self.pageTitle = @"安装失败";
        _stageLabel.text = error.localizedDescription ?: @"安装失败";
        _failureDetailLabel.text = error.localizedDescription ?: @"未知错误";
        _cancelButton.hidden = YES;
        _successCard.hidden = YES;
        _failureCard.hidden = NO;

        UINotificationFeedbackGenerator *fb = [UINotificationFeedbackGenerator new];
        [fb notificationOccurred:UINotificationFeedbackTypeError];

        [A2Log log:@"download: 安装失败 %@：%@",
            _versionName, error.localizedDescription ?: @"未知错误"];
    }
}

#pragma mark - 动作

- (void)retryInstall {
    [A2Log log:@"download: 重试安装 %@", _versionName];
    _finished = NO;
    _failureCard.hidden = YES;
    _successCard.hidden = YES;
    _cancelButton.hidden = NO;
    self.pageTitle = @"安装中";
    _stageLabel.text = @"正在重试…";

    BOOL hasLoader = (_loaderType != nil);
    for (NSUInteger i = 0; i < _stepRows.count; i++) {
        A2InstallStepRow *row = _stepRows[i];
        if (!hasLoader && i == (NSUInteger)A2InstallStageInstallLoader) {
            [row applyState:A2InstallStepStateSkipped percentText:@"跳过（未选加载器）"];
        } else {
            [row applyState:A2InstallStepStateWaiting percentText:@"等待"];
        }
    }
    [_ring setProgress:0 animated:NO];
    _ring.centerText = @"0%";
    [_progressBar setProgress:0 animated:NO];
    _progressBar.detailText = @"本阶段 0%";

    [self startInstall];
}

- (void)confirmCancel {
    if (_finished) {
        [self backToDownloadCenter];
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"取消安装"
                                            message:@"已下载的文件会保留，下次可以继续。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续安装"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消安装"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        __weak typeof(self) weakSelf = self;
        [A2Log log:@"download: 取消安装 %@", weakSelf.versionName];
        [weakSelf.installer cancel];
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)doneTapped {
    [self backToDownloadCenter];
}

/// 回到下载中心（链路：下载中心 → 选版 → 选项 → 安装）。
/// 下载中心现在是「容器 + 内层栈」：本页所在的这条栈由内层导航器承载，
/// 栈底就是当前分类的内容页（选版页），退到栈底即回到下载区首屏。
- (void)backToDownloadCenter {
    UINavigationController *nav = self.navigationController;
    if (!nav) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    UIViewController *root = nav.viewControllers.firstObject;
    if (root && root != self) {
        [nav popToViewController:root animated:YES];
        return;
    }
    [nav popViewControllerAnimated:YES];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _stageLabel.textColor = t.cOnSurface;
    for (A2InstallStepRow *row in _stepRows) {
        [row applyTheme];
    }
}

#pragma mark - 弹窗呈现

/// 以弹窗形式呈现安装进度 —— 对照 ZL2 的 TitleTaskFlowDialog。
///
/// ZL2 的规则：
///   · 简单安装（原版/加载器）：单列弹窗
///   · 需要看日志（整合包等）：双列弹窗，宽度 80%
///
/// 我们的做法：始终带日志（用户遇到问题能截图），因此始终双列。
+ (void)presentModPackDialogFrom:(UIViewController *)host
                         packPath:(NSString *)zipPath
                      versionName:(NSString *)versionName {

    // 整合包的安装阶段与「装原版+加载器」不同：
    //   解析清单 → 下载文件 → 解压覆盖 → 完成
    // 但展示形态统一用 A2InstallProgressDialog（与游戏安装一致）。
    A2TaskLogOutput *log = [[A2TaskLogOutput alloc]
                            initWithTitle:[NSString stringWithFormat:@"导入 %@", versionName]];

    A2InstallProgressDialog *dialog = [[A2InstallProgressDialog alloc] initWithLogOutput:log];
    dialog.dialogTitle = @"导入整合包";

    NSArray<NSString *> *steps = @[
        @"解析整合包",
        @"下载缺失文件",
        @"解压并写入",
        @"完成",
    ];
    [dialog setSteps:steps];

    A2ModPackInstaller *installer = [[A2ModPackInstaller alloc] init];

    dialog.onCancel = ^{
        [installer cancel];
    };

    [host presentViewController:dialog animated:YES completion:^{
        [log start];

        [installer installPackAtPath:zipPath
                          versionName:versionName
                             gameHome:A2VersionManager.shared.gameHome
                             progress:^(double progress, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // 粗略映射：前 10% 解析，10~70% 下载，70~100% 解压
                NSInteger idx = progress < 0.1 ? 0 : (progress < 0.7 ? 1 : 2);
                [dialog updateStepAtIndex:idx
                                    stage:A2ProgressStepStageRunning
                                  message:message
                                 progress:progress
                                     rate:nil];
            });
        }
                           completion:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    [dialog updateStepAtIndex:3
                                        stage:A2ProgressStepStageCompleted
                                      message:@"完成"
                                     progress:1.0
                                         rate:nil];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.6 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [dialog dismissWithCompletion:nil];
                    });
                } else {
                    [dialog updateStepAtIndex:3
                                        stage:A2ProgressStepStageRunning
                                      message:(error.localizedDescription ?: @"导入失败")
                                     progress:-1
                                         rate:nil];
                }
            });
        }];
    }];
}

+ (void)presentAsDialogFrom:(UIViewController *)host
                mcVersion:(NSString *)mcVersion
              versionName:(NSString *)versionName
               loaderType:(NSNumber *)loaderType
            loaderVersion:(NSString *)loaderVersion
                  apiType:(NSNumber *)apiType
               apiVersion:(NSString *)apiVersion {

    // 这里不直接复用 VC，而是弹出一个独立的进度弹窗 ——
    // 安装逻辑在 A2GameInstaller 里，弹窗只负责展示。
    A2TaskLogOutput *log = [[A2TaskLogOutput alloc]
                            initWithTitle:[NSString stringWithFormat:@"安装 %@", versionName]];

    A2InstallProgressDialog *dialog = [[A2InstallProgressDialog alloc] initWithLogOutput:log];
    dialog.dialogTitle = @"安装游戏中";

    NSArray<NSString *> *steps = @[
        @"获取版本清单",
        @"下载版本信息",
        @"下载客户端",
        @"下载依赖库",
        @"下载资源文件",
        @"安装模组加载器",
        @"完成安装",
    ];
    [dialog setSteps:steps];

    [host presentViewController:dialog animated:YES completion:^{
        [log start];

        A2InstallRequest *req = [A2InstallRequest new];
        req.mcVersion = mcVersion;
        req.versionName = versionName;
        req.loaderType = loaderType;
        req.loaderVersion = loaderVersion;
        req.apiModType = apiType;
        req.apiModVersion = apiVersion;
        req.gameHome = A2VersionManager.shared.gameHome;

        A2GameInstaller *installer = [[A2GameInstaller alloc] init];

        [installer install:req
            progress:^(A2InstallStage stage, double progress, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // 未选加载器时跳过那一项 —— 标成「跳过」，不是「完成」
                BOOL hasLoader = (loaderType != nil);

                // 先把所有已完成阶段标为完成
                for (NSInteger i = 0; i < (NSInteger)steps.count; i++) {
                    if (i < (NSInteger)stage) {
                        if (!hasLoader && i == (NSInteger)A2InstallStageInstallLoader) {
                            [dialog updateStepAtIndex:i
                                                stage:A2ProgressStepStageCompleted
                                              message:@"跳过（未选加载器）"
                                             progress:1.0
                                                 rate:nil];
                        } else {
                            [dialog updateStepAtIndex:i
                                                stage:A2ProgressStepStageCompleted
                                              message:nil
                                             progress:1.0
                                                 rate:nil];
                        }
                    }
                }

                // 当前阶段
                [dialog updateStepAtIndex:(NSInteger)stage
                                    stage:A2ProgressStepStageRunning
                                  message:message
                                 progress:progress
                                     rate:nil];

                [log appendProgress:[NSString stringWithFormat:@"%@ %@",
                                     [self stageTagFor:stage], message ?: @""]];
            });
        }
            completion:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSInteger i = 0; i < (NSInteger)steps.count; i++) {
                    [dialog updateStepAtIndex:i
                                        stage:success ? A2ProgressStepStageCompleted
                                                      : A2ProgressStepStagePreparing
                                      message:success ? nil : error.localizedDescription
                                     progress:1.0
                                         rate:nil];
                }
                [log append:success ? @"安装完成" : [NSString stringWithFormat:
                                                    @"安装失败：%@",
                                                    error.localizedDescription ?: @""]];
                [log stop];

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [dialog dismissWithCompletion:^{
                        if (success) [A2VersionManager.shared reload];
                    }];
                });
            });
        }];
    }];
}

/// 阶段标签，用于日志前缀（与安装页的 stageDisplayName: 一致）
+ (NSString *)stageTagFor:(A2InstallStage)stage {
    switch (stage) {
        case A2InstallStageFetchManifest:     return @"[清单]";
        case A2InstallStageDownloadJSON:      return @"[版本信息]";
        case A2InstallStageDownloadJar:       return @"[客户端]";
        case A2InstallStageDownloadLibraries: return @"[依赖库]";
        case A2InstallStageDownloadAssets:    return @"[资源]";
        case A2InstallStageInstallLoader:     return @"[加载器]";
        case A2InstallStageFinalize:          return @"[收尾]";
        default:                              return @"[安装]";
    }
}

@end

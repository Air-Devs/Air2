//
//  A2LauncherViewController.m
//  Air2
//
//  主界面装配。布局细节委托给各卡片，本文件只负责：
//    1. 三区骨架与约束
//    2. 顶栏
//    3. 入场动画编排
//    4. 转发导航动作
//

#import "A2LauncherViewController.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2GlassCard.h"
#import "A2BackgroundView.h"
#import "A2VersionCard.h"
#import "A2Toast.h"
#import "A2NavigationController.h"
#import "A2QuickActionCard.h"
#import "A2PrimaryButton.h"

#import "A2AccountViewController.h"
#import "A2SettingsViewController.h"
#import "A2VersionListViewController.h"
#import "A2DownloadViewController.h"


@interface A2LauncherViewController ()
@property (nonatomic, strong) A2BackgroundView *backgroundView;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UILabel *appNameLabel;
@property (nonatomic, strong) UIStackView *topTrailingStack;

/// 右侧操作栏
@property (nonatomic, strong) UIScrollView *panelScroll;
@property (nonatomic, strong) UIStackView *panelStack;

/// 账户卡
@property (nonatomic, strong) A2GlassCard *accountCard;
@property (nonatomic, strong) UIView *avatarView;
@property (nonatomic, strong) UILabel *avatarInitial;
@property (nonatomic, strong) UILabel *accountNameLabel;
@property (nonatomic, strong) UILabel *accountTypeLabel;

/// 版本卡
@property (nonatomic, strong) A2GlassCard *versionCard;
@property (nonatomic, strong) UIView *versionIconBox;
@property (nonatomic, strong) UILabel *versionInitial;
@property (nonatomic, strong) UILabel *versionNameLabel;
@property (nonatomic, strong) UILabel *versionMetaLabel;
@property (nonatomic, strong) A2PrimaryButton *launchButton;

/// 快捷入口
@property (nonatomic, strong) UIStackView *quickRow1;
@property (nonatomic, strong) UIStackView *quickRow2;

@property (nonatomic, assign) BOOL didSetupConstraints;
@property (nonatomic, assign) BOOL didPlayEntrance;
@end

@implementation A2LauncherViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    [self setupBackground];
    [self setupTopBar];
    [self setupSidePanel];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2BackgroundDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_didPlayEntrance) {
        _didPlayEntrance = YES;
        [self playEntranceAnimation];
    }
}

#pragma mark - 背景

- (void)setupBackground {
    _backgroundView = [[A2BackgroundView alloc] initWithFrame:CGRectZero];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_backgroundView];
}

#pragma mark - 顶栏

- (void)setupTopBar {
    _topBar = [[UIView alloc] initWithFrame:CGRectZero];
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_topBar];

    _appNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _appNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _appNameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _appNameLabel.text = @"Air2";
    [_topBar addSubview:_appNameLabel];

    _topTrailingStack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _topTrailingStack.translatesAutoresizingMaskIntoConstraints = NO;
    _topTrailingStack.axis = UILayoutConstraintAxisHorizontal;
    _topTrailingStack.spacing = A2SpaceXS;
    [_topBar addSubview:_topTrailingStack];

    // 三个入口：账户 / 下载 / 设置
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"person.crop.circle", @"openAccount"],
        @[@"arrow.down.circle",  @"openDownload"],
        @[@"gearshape",          @"openSettings"],
    ];
    for (NSArray<NSString *> *item in items) {
        [self addTopBarButtonWithSymbol:item[0] selectorName:item[1]];
    }
}

- (void)addTopBarButtonWithSymbol:(NSString *)symbol selectorName:(NSString *)name {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [b.heightAnchor constraintEqualToConstant:A2MinTouchTarget],
    ]];
    SEL sel = NSSelectorFromString(name);
    [b addAction:[UIAction actionWithHandler:^(UIAction *action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([self respondsToSelector:sel]) [self performSelector:sel];
#pragma clang diagnostic pop
    }] forControlEvents:UIControlEventTouchUpInside];
    b.tag = 700;   // 标记以便主题刷新时着色
    [_topTrailingStack addArrangedSubview:b];
}

#pragma mark - 右侧操作栏

- (void)setupSidePanel {
    _panelScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _panelScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _panelScroll.showsVerticalScrollIndicator = NO;
    _panelScroll.alwaysBounceVertical = YES;
    _panelScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_panelScroll];

    _panelStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _panelStack.translatesAutoresizingMaskIntoConstraints = NO;
    _panelStack.axis = UILayoutConstraintAxisVertical;
    _panelStack.spacing = A2SpaceM;
    [_panelScroll addSubview:_panelStack];

    [self buildAccountCard];
    [self buildVersionCard];
    [self buildQuickGrid];
}
#pragma mark - 约束

- (void)updateViewConstraints {
    if (_didSetupConstraints) {
        [super updateViewConstraints];
        return;
    }
    _didSetupConstraints = YES;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    CGFloat panelW = A2SidePanelWidth(self.view.bounds.size.width);
    if (panelW <= 0) panelW = 320;   // 布局尚未完成时的兜底

    [NSLayoutConstraint activateConstraints:@[
        // 背景铺满，但右侧被操作栏盖住的部分会被渐隐遮罩压暗
        [_backgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backgroundView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backgroundView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        // 顶栏横跨全宽
        [_topBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_topBar.heightAnchor constraintEqualToConstant:A2TopBarHeight],

        [_appNameLabel.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2PanelPadding],
        [_appNameLabel.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],

        [_topTrailingStack.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-A2SpaceM],
        [_topTrailingStack.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],

        // 右侧操作栏
        [_panelScroll.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_panelScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_panelScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_panelScroll.widthAnchor constraintEqualToConstant:panelW],

        [_panelStack.topAnchor constraintEqualToAnchor:_panelScroll.topAnchor constant:A2SpaceS],
        [_panelStack.bottomAnchor constraintEqualToAnchor:_panelScroll.bottomAnchor constant:-A2PanelPadding],
        [_panelStack.leadingAnchor constraintEqualToAnchor:_panelScroll.leadingAnchor constant:A2PanelPadding],
        [_panelStack.trailingAnchor constraintEqualToAnchor:_panelScroll.trailingAnchor constant:-A2PanelPadding],
        [_panelStack.widthAnchor constraintEqualToAnchor:_panelScroll.widthAnchor constant:-A2PanelPadding * 2],
    ]];

    [super updateViewConstraints];
}

#pragma mark - 入场动画

/// 卡片依次淡入上浮。这是用户打开 App 看到的第一件事，
/// 做得克制一点：位移只有 16pt，间隔 35ms，整体不到 0.5 秒。
- (void)playEntranceAnimation {
    NSMutableArray<UIView *> *cards = [NSMutableArray array];
    if (_accountCard) [cards addObject:_accountCard];
    if (_versionCard) [cards addObject:_versionCard];
    if (_quickRow1) [cards addObject:_quickRow1];
    if (_quickRow2) [cards addObject:_quickRow2];

    A2AnimateCardEntrance(cards, A2CardStaggerDelay, nil);

    // 顶栏同时淡入，但更快
    _topBar.alpha = 0;
    UIViewPropertyAnimator *a = A2SpringAnimator(A2AnimDurationFast);
    [a addAnimations:^{ self.topBar.alpha = 1; }];
    [a startAnimation];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2ColorScheme *s = tm.scheme;

    _appNameLabel.textColor = s.onSurface;
    for (UIButton *b in _topTrailingStack.arrangedSubviews) {
        if ([b isKindOfClass:UIButton.class]) b.tintColor = s.onSurfaceVariant;
    }

    _avatarView.backgroundColor = s.primaryContainer;
    _avatarInitial.textColor = s.onPrimaryContainer;
    _accountNameLabel.textColor = s.onSurface;
    _accountTypeLabel.textColor = s.onSurfaceVariant;

    _versionIconBox.backgroundColor = s.primaryContainer;
    _versionInitial.textColor = s.onPrimaryContainer;
    _versionNameLabel.textColor = s.onSurface;
    _versionMetaLabel.textColor = s.onSurfaceVariant;

    for (UIView *v in _versionCard.contentView.subviews) {
        if ([v isKindOfClass:UIButton.class]) ((UIButton *)v).tintColor = s.onSurfaceVariant;
    }
}

#pragma mark - 卡片构建

#pragma mark 账户卡

- (void)buildAccountCard {
    _accountCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _accountCard.cornerRadius = A2RadiusL;
    _accountCard.elevation = A2CardElevationLow;
    _accountCard.tappable = YES;
    _accountCard.onTap = ^{ [self openAccount]; };

    _avatarView = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.layer.cornerRadius = 22;
    _avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarView.clipsToBounds = YES;

    _avatarInitial = [[UILabel alloc] initWithFrame:CGRectZero];
    _avatarInitial.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarInitial.text = @"S";
    _avatarInitial.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _avatarInitial.textAlignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_avatarInitial];

    _accountNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _accountNameLabel.text = @"Steve";

    _accountTypeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountTypeLabel.font = [A2Typography caption];
    _accountTypeLabel.text = @"Microsoft 正版账号";

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_accountNameLabel, _accountTypeLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_avatarView, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceM;
    row.alignment = UIStackViewAlignmentCenter;

    [_accountCard.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.widthAnchor constraintEqualToConstant:44],
        [_avatarView.heightAnchor constraintEqualToConstant:44],
        [_avatarInitial.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_avatarInitial.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:_accountCard.contentView.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_accountCard.contentView.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:_accountCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_accountCard];
}

#pragma mark 版本卡

- (void)buildVersionCard {
    _versionCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _versionCard.cornerRadius = A2RadiusL;
    _versionCard.elevation = A2CardElevationHigh;

    // —— 顶行：图标 + 版本名 + 设置按钮 ——
    _versionIconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _versionIconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _versionIconBox.layer.cornerRadius = A2RadiusXS;
    _versionIconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _versionIconBox.clipsToBounds = YES;

    _versionInitial = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionInitial.translatesAutoresizingMaskIntoConstraints = NO;
    _versionInitial.text = @"1";
    _versionInitial.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _versionInitial.textAlignment = NSTextAlignmentCenter;
    [_versionIconBox addSubview:_versionInitial];

    _versionNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _versionNameLabel.text = @"1.21.5-fabric";
    _versionNameLabel.adjustsFontSizeToFitWidth = YES;
    _versionNameLabel.minimumScaleFactor = 0.75;

    _versionMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionMetaLabel.font = [A2Typography caption];
    _versionMetaLabel.text = @"Fabric 0.16.10 · Java 21";

    UIStackView *versionTextStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_versionNameLabel, _versionMetaLabel]];
    versionTextStack.axis = UILayoutConstraintAxisVertical;
    versionTextStack.spacing = 1;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    settingsBtn.tag = 701;
    [settingsBtn addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self openVersionSettings];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[_versionIconBox, versionTextStack, settingsBtn]];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = A2SpaceM;
    topRow.alignment = UIStackViewAlignmentCenter;
    [topRow setCustomSpacing:A2SpaceS afterView:versionTextStack];

    // —— 启动按钮 ——
    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"启动游戏" style:A2ButtonStylePrimary];
    [_launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, _launchButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;

    [_versionCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_versionIconBox.widthAnchor constraintEqualToConstant:34],
        [_versionIconBox.heightAnchor constraintEqualToConstant:34],
        [_versionInitial.centerXAnchor constraintEqualToAnchor:_versionIconBox.centerXAnchor],
        [_versionInitial.centerYAnchor constraintEqualToAnchor:_versionIconBox.centerYAnchor],
        [settingsBtn.widthAnchor constraintEqualToConstant:36],
        [settingsBtn.heightAnchor constraintEqualToConstant:36],

        [stack.topAnchor constraintEqualToAnchor:_versionCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_versionCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_versionCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_versionCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_versionCard];
}

#pragma mark 快捷入口

- (void)buildQuickGrid {
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"版本管理", @"square.stack.3d.up",          @"openVersions"],
        @[@"下载",     @"arrow.down.circle",           @"openDownload"],
        @[@"联机",     @"antenna.radiowaves.left.and.right", @"openMultiplayer"],
        @[@"文件",     @"folder",                      @"openFiles"],
    ];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    for (UIStackView *r in @[row1, row2]) {
        r.translatesAutoresizingMaskIntoConstraints = NO;
        r.axis = UILayoutConstraintAxisHorizontal;
        r.distribution = UIStackViewDistributionFillEqually;
        r.spacing = A2SpaceM;
    }

    for (NSUInteger i = 0; i < items.count; i++) {
        A2QuickActionCard *card = [[A2QuickActionCard alloc] initWithTitle:items[i][0]
                                                                symbolName:items[i][1]];
        SEL sel = NSSelectorFromString(items[i][2]);
        __weak typeof(self) weakSelf = self;
        card.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([self respondsToSelector:sel]) [self performSelector:sel];
#pragma clang diagnostic pop
        };
        [(i < 2 ? row1 : row2) addArrangedSubview:card];
    }

    _quickRow1 = row1;
    _quickRow2 = row2;

    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = A2SpaceM;

    [_panelStack addArrangedSubview:grid];
}

#pragma mark - 动作与导航

- (void)launchGame {
    _launchButton.loading = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.launchButton.loading = NO;
        [A2Toast show:@"启动流程尚未接入" inView:self.view];
    });
}

- (void)pushScreen:(UIViewController *)vc style:(A2TransitionStyle)style {
    if ([self.navigationController isKindOfClass:A2NavigationController.class]) {
        [(A2NavigationController *)self.navigationController pushViewController:vc transition:style animated:YES];
    } else {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    }
}

- (void)openAccount {
    [self pushScreen:[[A2AccountViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openSettings {
    [self pushScreen:[[A2SettingsViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openVersions {
    [self pushScreen:[[A2VersionListViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openDownload {
    [self pushScreen:[[A2DownloadViewController alloc] init] style:A2TransitionStyleSheet];
}

- (void)openMultiplayer { [A2Toast show:@"联机功能尚未接入" inView:self.view]; }
- (void)openFiles       { [A2Toast show:@"文件管理尚未接入" inView:self.view]; }
- (void)openVersionSettings { [A2Toast show:@"版本设置" inView:self.view]; }

@end

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

#import "A2LauncherViewController_Internal.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2GlassCard.h"
#import "A2BackgroundView.h"
#import "A2VersionCard.h"
#import "A2Toast.h"
#import "A2NavigationController.h"


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

@end
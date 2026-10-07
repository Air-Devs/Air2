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

/// 账户条
@property (nonatomic, strong) A2GlassCard *accountCard;
@property (nonatomic, strong) UIView *avatarView;
@property (nonatomic, strong) UILabel *avatarInitial;
@property (nonatomic, strong) UILabel *accountNameLabel;
@property (nonatomic, strong) UILabel *accountTypeLabel;

/// 版本卡（右栏主体）
@property (nonatomic, strong) A2GlassCard *versionCard;
@property (nonatomic, strong) UILabel *versionNameLabel;
@property (nonatomic, strong) UILabel *versionMetaLabel;
@property (nonatomic, strong) A2PrimaryButton *launchButton;

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
    _panelStack.spacing = A2CardSpacing;   // 12pt，与卡片内边距一致
    [_panelScroll addSubview:_panelStack];

    // 操作区只放两张卡：账户 + 版本。
    // 之前我额外加了「版本/下载/联机/文件」快捷网格，但它和顶栏入口
    // 功能重叠，还把右栏撑得很满。ZL2 的操作区也只有账户卡与版本卡。
    [self buildAccountCard];
    [self buildVersionCard];
}

#pragma mark - 操作区垂直布局

/// 操作区的垂直布局。
///
/// 对齐 ZL2 的做法（cardHeight = maxHeight - outerPadding * 2）：
/// **两张卡撑满操作区高度**，而不是内容自适应后居中留白。
///
/// 为什么撑满反而不显得「满」：
///   ZL2 的卡内是分层的 —— 账户区在上、版本区在下，
///   中间靠 ConstraintLayout 的 top/bottom 锚点撑开。
///   空间大时中间自然形成呼吸感，而不是把元素堆在顶部。
///   我之前的做法是内容自适应 + 居中，视觉上像「漂浮的小盒子」。
///
/// 这里用两个 spacer 实现同样的分层：
///   账户卡（定高） + spacer（弹性） + 版本卡（定高）
/// spacer 吸收多余空间，卡片贴住上下两端。
- (void)setupPanelPlacement {
    UILayoutGuide *content = _panelScroll.contentLayoutGuide;
    UILayoutGuide *frame = _panelScroll.frameLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        // 内容宽度跟随可视区域（只允许垂直滚动）
        [_panelStack.widthAnchor constraintEqualToAnchor:frame.widthAnchor
                                               constant:-A2PanelOuterPadding * 2],

        // 撑满高度：内容区上下贴合
        [_panelStack.topAnchor constraintEqualToAnchor:content.topAnchor
                                              constant:A2PanelOuterPadding],
        [_panelStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                 constant:-A2PanelOuterPadding],

        // 内容高度不足一屏时，也至少撑满可视区域 ——
        // 这样卡片才会贴住上下边，而不是缩成一小块
        [_panelStack.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor
                                                             constant:-A2PanelOuterPadding * 2],
    ]];

    // 版本卡吃掉剩余空间（账户卡定高、版本卡弹性）
    [_versionCard setContentHuggingPriority:UILayoutPriorityDefaultLow
                                    forAxis:UILayoutConstraintAxisVertical];
    [_accountCard setContentHuggingPriority:UILayoutPriorityDefaultHigh
                                    forAxis:UILayoutConstraintAxisVertical];
    [_versionCard setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisVertical];
}
#pragma mark - 约束

- (void)updateViewConstraints {
    if (_didSetupConstraints) {
        [super updateViewConstraints];
        return;
    }
    _didSetupConstraints = YES;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // 操作区宽度用「比例约束」，交给 Auto Layout 处理。
    // 比例取自 ZL2 的实测值：操作区 : 内容区 = 3 : 7。
    // 用 multiplier 而不是算好的固定值 —— 后者在 updateViewConstraints
    // 首次调用时 bounds 还是 0，兜底值会被固化且旋转后不更新。
    NSLayoutConstraint *panelWidth =
        [_panelScroll.widthAnchor constraintEqualToAnchor:self.view.widthAnchor
                                               multiplier:A2PanelWidthRatio];

    [NSLayoutConstraint activateConstraints:@[
        panelWidth,

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

        [_appNameLabel.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2PanelOuterPadding],
        [_appNameLabel.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],

        [_topTrailingStack.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-A2SpaceM],
        [_topTrailingStack.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],

        // 右侧操作栏
        [_panelScroll.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_panelScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_panelScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        // 右栏水平边距；垂直定位见 setupPanelPlacement
        [_panelStack.leadingAnchor constraintEqualToAnchor:_panelScroll.frameLayoutGuide.leadingAnchor
                                                 constant:A2PanelOuterPadding],
        [_panelStack.trailingAnchor constraintEqualToAnchor:_panelScroll.frameLayoutGuide.trailingAnchor
                                                  constant:-A2PanelOuterPadding],
    ]];

    [self setupPanelPlacement];

    [super updateViewConstraints];
}

#pragma mark - 入场动画

/// 卡片依次淡入上浮。这是用户打开 App 看到的第一件事，
/// 做得克制一点：位移只有 16pt，间隔 35ms，整体不到 0.5 秒。
- (void)playEntranceAnimation {
    NSMutableArray<UIView *> *cards = [NSMutableArray array];
    if (_accountCard) [cards addObject:_accountCard];
    if (_versionCard) [cards addObject:_versionCard];


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

    _appNameLabel.textColor = s.cOnSurface;
    for (UIButton *b in _topTrailingStack.arrangedSubviews) {
        if ([b isKindOfClass:UIButton.class]) b.tintColor = s.cOnSurfaceVariant;
    }

    // ---- 账户条 ----
    _avatarView.backgroundColor = s.cPrimaryContainer;
    _avatarInitial.textColor = s.cOnPrimaryContainer;
    _accountNameLabel.textColor = s.cOnSurface;
    _accountTypeLabel.textColor = s.cOnSurfaceVariant;

    // ---- 版本卡 ----
    _versionNameLabel.textColor = s.cOnSurface;
    _versionMetaLabel.textColor = s.cOnSurfaceVariant;

    // ---- 按 tag 统一着色 ----
    // 注意：不能只遍历直接子视图 —— 控件都在 UIStackView 里，
    // 必须递归查找。
    [self tintTaggedViewsIn:_topBar color:s.cOnSurfaceVariant];
    [self tintTaggedViewsIn:_versionCard color:s.cOnSurfaceVariant];
    [self tintTaggedViewsIn:_accountCard color:s.cOnSurfaceVariant];
}

/// 递归给打了标记的视图着色。
///  703 = 账号切换图标   704 = 分隔点
///  705 = 文字链接       706 = 版本设置齿轮
- (void)tintTaggedViewsIn:(UIView *)root color:(UIColor *)color {
    if (root.tag == 703 || root.tag == 705 || root.tag == 706) {
        if ([root isKindOfClass:UIButton.class]) {
            ((UIButton *)root).tintColor = color;
        } else if ([root isKindOfClass:UIImageView.class]) {
            ((UIImageView *)root).tintColor = color;
        }
    }
    if (root.tag == 704 && [root isKindOfClass:UILabel.class]) {
        ((UILabel *)root).textColor = [color colorWithAlphaComponent:0.5];
    }
    for (UIView *child in root.subviews) {
        [self tintTaggedViewsIn:child color:color];
    }
}
#pragma mark - 右侧操作区
//
// 布局规格对齐 ZalithLauncher2（Android 上成熟落地的 MD3 启动器）：
//
//   ┌───────────────────────────┐
//   │      ┌─────┐              │  账户卡
//   │      │ 头像 │  64pt       │    头像居中，名字与类型在下方居中
//   │      └─────┘              │
//   │       Steve               │
//   │       Microsoft 正版账号    │
//   ├───────────────────────────┤
//   │  1.21.5-fabric        ⚙   │  版本卡
//   │  Fabric 0.16.10 · Java 21 │    版本信息 + 齿轮（有版本时才出现）
//   │  ┌─────────────────────┐  │
//   │  │      启动游戏        │  │    主操作按钮
//   │  └─────────────────────┘  │
//   │  版本设置 · 游戏目录        │    次级操作（文字链接）
//   └───────────────────────────┘
//
//  两张卡撑满操作区高度（高度 = 屏高 - 上下外边距），
//  而不是内容自适应 —— ZL2 就是这么做的，撑满但不臃肿，
//  因为内部是分层的：账户区在上、版本区在下。
//
//  卡片外边距与内边距都是 12，圆角用 MD3 的 extraLarge(28)。

#pragma mark 账户卡

/// 账户卡 —— 头像居中的竖向排列（对应 ZL2 的 AccountAvatarCenter）。
///
/// 为什么用居中而不是横向一行：
/// 操作区宽度只有屏幕的 30%，横向排列时文字空间被挤压，
/// 竖排能让 64pt 头像成为视觉锚点，名字和类型在下方居中。
- (void)buildAccountCard {
    _accountCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _accountCard.cornerRadius = A2RadiusXL;          // MD3 extraLarge
    _accountCard.elevation = A2CardElevationLow;
    _accountCard.tappable = YES;
    _accountCard.onTap = ^{ [self openAccount]; };
    _accountCard.contentInsets = UIEdgeInsetsMake(A2CardPadding, A2CardPadding,
                                                  A2CardPadding, A2CardPadding);

    // ---- 头像 64pt ----
    _avatarView = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.layer.cornerRadius = A2AvatarSizeLarge / 2;
    _avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarView.clipsToBounds = YES;

    _avatarInitial = [[UILabel alloc] initWithFrame:CGRectZero];
    _avatarInitial.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarInitial.text = @"S";
    _avatarInitial.font = [UIFont systemFontOfSize:26 weight:UIFontWeightSemibold];
    _avatarInitial.textAlignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_avatarInitial];

    // ---- 名字与类型 ----
    _accountNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _accountNameLabel.textAlignment = NSTextAlignmentCenter;
    _accountNameLabel.text = @"Steve";
    _accountNameLabel.adjustsFontSizeToFitWidth = YES;
    _accountNameLabel.minimumScaleFactor = 0.8;

    _accountTypeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountTypeLabel.font = [A2Typography caption];
    _accountTypeLabel.textAlignment = NSTextAlignmentCenter;
    _accountTypeLabel.text = @"Microsoft 正版账号";
    _accountTypeLabel.adjustsFontSizeToFitWidth = YES;
    _accountTypeLabel.minimumScaleFactor = 0.8;

    UIStackView *textStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_accountNameLabel, _accountTypeLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    textStack.alignment = UIStackViewAlignmentCenter;

    // ---- 竖向整体 ----
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_avatarView, textStack]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;

    [_accountCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.widthAnchor constraintEqualToConstant:A2AvatarSizeLarge],
        [_avatarView.heightAnchor constraintEqualToConstant:A2AvatarSizeLarge],
        [_avatarInitial.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_avatarInitial.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],

        // 文字撑满卡片宽度，超出则截断（而不是撑破布局）
        [textStack.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [textStack.trailingAnchor constraintEqualToAnchor:_accountCard.contentView.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:_accountCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_accountCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_accountCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_accountCard];

    // 账户卡的内部留白要多一些 —— 它是「个人信息」区，不是数据行
    [_accountCard.contentView.heightAnchor
        constraintGreaterThanOrEqualToConstant:A2AvatarSizeLarge + A2SpaceXL].active = YES;
}

#pragma mark 版本卡

/// 版本卡 —— 操作区的功能主体。
///
/// 与 ZL2 的 VersionsContent 一致：
///   · 版本信息占满宽度，齿轮只在有有效版本时出现
///   · 启动按钮撑满卡片宽度
///   · 版本名用大字，加载器信息用 labelSmall
- (void)buildVersionCard {
    _versionCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _versionCard.cornerRadius = A2RadiusXL;
    _versionCard.elevation = A2CardElevationLow;
    _versionCard.contentInsets = UIEdgeInsetsMake(A2CardPadding, A2CardPadding,
                                                  A2CardPadding, A2CardPadding);

    // ---- 顶部行：版本信息 + 齿轮 ----
    _versionNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionNameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _versionNameLabel.text = @"1.21.5-fabric";
    _versionNameLabel.adjustsFontSizeToFitWidth = YES;
    _versionNameLabel.minimumScaleFactor = 0.7;

    _versionMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionMetaLabel.font = [A2Typography caption];
    _versionMetaLabel.text = @"Fabric 0.16.10 · Java 21";
    _versionMetaLabel.adjustsFontSizeToFitWidth = YES;
    _versionMetaLabel.minimumScaleFactor = 0.8;

    UIStackView *infoStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_versionNameLabel, _versionMetaLabel]];
    infoStack.axis = UILayoutConstraintAxisVertical;
    infoStack.spacing = 2;

    // 齿轮：仅在有版本时显示（无版本时显示「去安装」提示）
    UIImageSymbolConfiguration *gearCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
    UIButton *gearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gearBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [gearBtn setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:gearCfg]
             forState:UIControlStateNormal];
    gearBtn.tag = 706;
    [gearBtn addTarget:self action:@selector(openVersionSettings)
      forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[infoStack, gearBtn]];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = A2SpaceS;
    // 信息区吃掉剩余宽度，齿轮靠右固定大小
    [infoStack setContentHuggingPriority:UILayoutPriorityDefaultLow
                                 forAxis:UILayoutConstraintAxisHorizontal];

    // ---- 启动按钮 ----
    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"启动游戏" style:A2ButtonStylePrimary];
    _launchButton.icon = [UIImage systemImageNamed:@"play.fill"];
    _launchButton.minHeight = A2ButtonHeight;
    [_launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];

    // ---- 次级操作：文字链接 ----
    UIButton *settingsLink = [self makeTextLink:@"版本设置" action:@selector(openVersionSettings)];
    UILabel *dot = [[UILabel alloc] initWithFrame:CGRectZero];
    dot.text = @"·";
    dot.font = [A2Typography caption];
    dot.tag = 704;
    UIButton *folderLink = [self makeTextLink:@"游戏目录" action:@selector(openGameFolder)];

    UIStackView *linkRow = [[UIStackView alloc] initWithArrangedSubviews:@[settingsLink, dot, folderLink]];
    linkRow.axis = UILayoutConstraintAxisHorizontal;
    linkRow.spacing = A2SpaceXS;
    linkRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[topRow, _launchButton, linkRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;   // 子项撑满宽度
    [stack setCustomSpacing:A2SpaceL afterView:topRow];
    [stack setCustomSpacing:A2SpaceM afterView:_launchButton];

    [_versionCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [gearBtn.widthAnchor constraintEqualToConstant:32],
        [gearBtn.heightAnchor constraintEqualToConstant:32],

        [stack.topAnchor constraintEqualToAnchor:_versionCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_versionCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_versionCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_versionCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_versionCard];
}

/// 文字链接样式的次级操作。
/// 用链接而不是按钮 —— 次级操作不该和「启动游戏」争视觉焦点。
- (UIButton *)makeTextLink:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    b.tag = 705;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
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


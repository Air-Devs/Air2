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

/// 快捷入口（一行横排）
@property (nonatomic, strong) UIStackView *quickRow;

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
    _panelStack.spacing = A2SpaceL;   // 16pt
    [_panelScroll addSubview:_panelStack];

    [self buildAccountCard];
    [self buildVersionCard];
    [self buildQuickGrid];
}

#pragma mark - 右栏留白策略

/// 右栏内容的垂直布局。
///
/// 设计原则：**右侧是操作区，不是信息面板。**
/// 之前的做法是把内容从顶栏下方一直排到底部、卡片撑满整高，
/// 结果整个右栏又满又吵，没有主次。
///
/// 现在：内容块整体吸附在垂直中部偏上的位置，
/// 上方留约 6% 屏高、下方留白交给内容自然长度。
/// 内容少的时候右侧是大块留白 —— 留白本身就是设计的一部分。
- (void)setupPanelPlacement {
    UILayoutGuide *content = _panelScroll.contentLayoutGuide;
    UILayoutGuide *frame = _panelScroll.frameLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        // 内容区宽度跟随可视区域（只允许垂直滚动）
        [_panelStack.widthAnchor constraintEqualToAnchor:frame.widthAnchor
                                               constant:-A2PanelPadding * 2],
        // 用 top/bottom ≥ 而不是 ==，让内容短时不会被拉伸
        [_panelStack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor
                                                           constant:A2SpaceXL],
        // 整体在垂直方向居中偏上：用一个高优先级的「居中」约束，
        // 内容高度不足时它会生效；内容超高时被上面的 ≥ 约束接管。
        [_panelStack.centerYAnchor constraintEqualToAnchor:frame.centerYAnchor
                                                  constant:-A2SpaceXXL],
    ]];

    // 居中约束优先级调低，让内容增高时能被拉伸约束压制
    for (NSLayoutConstraint *c in _panelScroll.constraints) {
        if (c.firstItem == _panelStack && c.firstAttribute == NSLayoutAttributeCenterY) {
            c.priority = UILayoutPriorityDefaultHigh;   // 750
        }
    }
}
#pragma mark - 约束

- (void)updateViewConstraints {
    if (_didSetupConstraints) {
        [super updateViewConstraints];
        return;
    }
    _didSetupConstraints = YES;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // 侧栏宽度用「比例约束」而不是算好的固定值。
    // 之前用 A2SidePanelWidth(self.view.bounds.size.width) 有两个问题：
    //   1. updateViewConstraints 首次调用时 bounds 还是 0，兜底值会被固化
    //   2. 该约束只算一次，旋转后不会更新
    // 用 multiplier 交给 Auto Layout 处理，自动适应任何尺寸。
    NSLayoutConstraint *panelWidth =
        [_panelScroll.widthAnchor constraintEqualToAnchor:self.view.widthAnchor
                                               multiplier:0.38];

    [NSLayoutConstraint activateConstraints:@[
        // 侧栏宽度：屏宽 38%，但不超过 400pt（iPad 上不至于过宽）
        panelWidth,
        [_panelScroll.widthAnchor constraintLessThanOrEqualToConstant:400],

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

        // 右栏水平边距；垂直定位见 setupPanelPlacement
        [_panelStack.leadingAnchor constraintEqualToAnchor:_panelScroll.frameLayoutGuide.leadingAnchor
                                                 constant:A2PanelPadding],
        [_panelStack.trailingAnchor constraintEqualToAnchor:_panelScroll.frameLayoutGuide.trailingAnchor
                                                  constant:-A2PanelPadding],
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
    if (_quickRow) [cards addObject:_quickRow];

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

    // ---- 账户条 ----
    _avatarView.backgroundColor = s.primaryContainer;
    _avatarInitial.textColor = s.onPrimaryContainer;
    _accountNameLabel.textColor = s.onSurface;
    _accountTypeLabel.textColor = s.onSurfaceVariant;

    // ---- 版本卡 ----
    _versionNameLabel.textColor = s.onSurface;
    _versionMetaLabel.textColor = s.onSurfaceVariant;

    // ---- 按 tag 统一着色 ----
    // 注意：不能只遍历直接子视图 —— 控件都在 UIStackView 里，
    // 必须递归查找。
    [self tintTaggedViewsIn:_topBar color:s.onSurfaceVariant];
    [self tintTaggedViewsIn:_versionCard color:s.onSurfaceVariant];
    [self tintTaggedViewsIn:_accountCard color:s.onSurfaceVariant];
}

/// 递归给打了标记的视图着色。
///  703 = 账号切换图标    704 = 分隔点    705 = 文字链接
- (void)tintTaggedViewsIn:(UIView *)root color:(UIColor *)color {
    if (root.tag == 703 || root.tag == 705) {
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

#pragma mark - 右侧栏内容构建

/// 账户条 —— 刻意做成「一行」而不是大卡片。
///
/// 设计说明：账号切换是低频操作，不需要占据半个屏幕的视觉权重。
/// 之前做成大卡片是照着 ZL2 的样子走的，结果账号和版本两个卡片
/// 互相抢焦点，整个右栏没有主次。
/// 现在把它压成一行，让版本卡成为唯一的主体。
- (void)buildAccountCard {
    _accountCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _accountCard.cornerRadius = A2RadiusM;
    _accountCard.elevation = A2CardElevationSurface;   // 最低层级，视觉上退后
    _accountCard.tappable = YES;
    _accountCard.onTap = ^{ [self openAccount]; };
    _accountCard.contentInsets = UIEdgeInsetsMake(A2SpaceS, A2SpaceM, A2SpaceS, A2SpaceS);

    // 头像：小一圈，从 44 收到 32
    _avatarView = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.layer.cornerRadius = 16;
    _avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarView.clipsToBounds = YES;

    _avatarInitial = [[UILabel alloc] initWithFrame:CGRectZero];
    _avatarInitial.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarInitial.text = @"S";
    _avatarInitial.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _avatarInitial.textAlignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_avatarInitial];

    _accountNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountNameLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _accountNameLabel.text = @"Steve";

    _accountTypeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountTypeLabel.font = [A2Typography caption];
    _accountTypeLabel.text = @"微软账号";

    UIStackView *textStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_accountNameLabel, _accountTypeLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 0;

    // 右侧「切换」提示，明确这里有交互
    UIImageSymbolConfiguration *swapCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    UIImageView *swapIcon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.left.arrow.right" withConfiguration:swapCfg]];
    swapIcon.translatesAutoresizingMaskIntoConstraints = NO;
    swapIcon.tag = 703;   // 主题刷新时着色用

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_avatarView, textStack, swapIcon]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceS;
    row.alignment = UIStackViewAlignmentCenter;
    [row setCustomSpacing:A2SpaceS afterView:textStack];

    [_accountCard.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.widthAnchor constraintEqualToConstant:32],
        [_avatarView.heightAnchor constraintEqualToConstant:32],
        [_avatarInitial.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_avatarInitial.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],
        [swapIcon.widthAnchor constraintEqualToConstant:16],
        [swapIcon.heightAnchor constraintEqualToConstant:16],

        [row.topAnchor constraintEqualToAnchor:_accountCard.contentView.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_accountCard.contentView.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:_accountCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_accountCard];
}

/// 版本卡 —— 右栏唯一的视觉主体。
///
/// 信息层级（从强到弱）：
///   版本名（大字，主）→ 加载器信息（小字，次）→ 启动按钮（块，操作）
///   → 版本设置 / 游戏目录（文字链接，最弱）
///
/// 刻意去掉了 ZL2 那种「图标 + 齿轮按钮」的顶部行 ——
/// 版本图标本来就辨识度低（多数是同一张草方块图），
/// 齿轮单独放一个 36pt 按钮也浪费横向空间。
/// 改成文字链接后，整张卡只有两个视觉焦点：版本名和启动按钮。
- (void)buildVersionCard {
    _versionCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _versionCard.cornerRadius = A2RadiusXL;      // 主体用更大的圆角
    _versionCard.elevation = A2CardElevationHigh;
    _versionCard.contentInsets = UIEdgeInsetsMake(A2SpaceL, A2SpaceL, A2SpaceM, A2SpaceL);

    // ---- 版本名 ----
    _versionNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionNameLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _versionNameLabel.text = @"1.21.5-fabric";
    _versionNameLabel.adjustsFontSizeToFitWidth = YES;
    _versionNameLabel.minimumScaleFactor = 0.7;

    // ---- 加载器信息 ----
    _versionMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionMetaLabel.font = [A2Typography subtitleCard];
    _versionMetaLabel.text = @"Fabric 0.16.10 · Java 21";
    _versionMetaLabel.adjustsFontSizeToFitWidth = YES;
    _versionMetaLabel.minimumScaleFactor = 0.8;

    // ---- 启动按钮 ----
    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"启动游戏" style:A2ButtonStylePrimary];
    _launchButton.icon = [UIImage systemImageNamed:@"play.fill"];
    _launchButton.minHeight = A2ButtonHeight;
    [_launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];

    // ---- 次级操作：文字链接，不用按钮 ----
    UIButton *settingsLink = [self makeTextLink:@"版本设置" action:@selector(openVersionSettings)];
    UIButton *folderLink = [self makeTextLink:@"游戏目录" action:@selector(openGameFolder)];

    // 中间加个圆点分隔
    UILabel *dot = [[UILabel alloc] initWithFrame:CGRectZero];
    dot.text = @"·";
    dot.font = [A2Typography caption];
    dot.tag = 704;

    UIStackView *linkRow = [[UIStackView alloc] initWithArrangedSubviews:@[settingsLink, dot, folderLink]];
    linkRow.axis = UILayoutConstraintAxisHorizontal;
    linkRow.spacing = A2SpaceXS;
    linkRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_versionNameLabel, _versionMetaLabel, _launchButton, linkRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    // 关键：按钮和上方文字贴近，下方链接贴近按钮 ——
    // 之前按钮上下各留 16pt，卡片被撑得很空
    [stack setCustomSpacing:A2SpaceXS afterView:_versionNameLabel];
    [stack setCustomSpacing:A2SpaceL afterView:_versionMetaLabel];
    [stack setCustomSpacing:A2SpaceM afterView:_launchButton];

    [_versionCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_versionCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_versionCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_versionCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_versionCard.contentView.trailingAnchor],
        // 启动按钮撑满宽度
        [_launchButton.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [_launchButton.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_versionCard];
}

/// 造一个文字链接样式的按钮。
/// 次级操作用链接而不是按钮，是为了不让它们和「启动游戏」抢视觉焦点。
- (UIButton *)makeTextLink:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    b.tag = 705;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/// 快捷入口 —— 一行横排图标 + 文字。
///
/// 之前是 2×2 的大方块，每个 90pt 高，占掉右栏近三分之一。
/// 改成一行横排后高度降到 56pt，把纵向空间让给版本卡。
- (void)buildQuickGrid {
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"版本", @"square.stack.3d.up",                   @"openVersions"],
        @[@"下载", @"arrow.down.circle",                    @"openDownload"],
        @[@"联机", @"antenna.radiowaves.left.and.right",    @"openMultiplayer"],
        @[@"文件", @"folder",                               @"openFiles"],
    ];

    NSMutableArray<UIView *> *cards = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        A2QuickActionCard *card = [[A2QuickActionCard alloc] initWithTitle:item[0]
                                                                symbolName:item[1]];
        // 紧凑模式：图标在上、文字在下，但压缩内边距
        card.contentInsets = UIEdgeInsetsMake(A2SpaceS, A2SpaceXS, A2SpaceS, A2SpaceXS);
        SEL sel = NSSelectorFromString(item[2]);
        __weak typeof(self) weakSelf = self;
        card.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([self respondsToSelector:sel]) [self performSelector:sel];
#pragma clang diagnostic pop
        };
        [cards addObject:card];
    }

    _quickRow = [[UIStackView alloc] initWithArrangedSubviews:cards];
    _quickRow.translatesAutoresizingMaskIntoConstraints = NO;
    _quickRow.axis = UILayoutConstraintAxisHorizontal;
    _quickRow.distribution = UIStackViewDistributionFillEqually;
    _quickRow.spacing = A2SpaceS;

    [_panelStack addArrangedSubview:_quickRow];
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

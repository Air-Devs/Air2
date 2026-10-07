//
//  A2HomeViewController.m
//  Air2
//
//  主页装配。布局细节委托给各卡片组件，本文件只负责：
//    1. 组装视图层级
//    2. 持有约束
//    3. 转发导航动作
//
//  如果本文件再次膨胀到 400 行以上，说明有新组件该拆出去了。
//

#import "A2HomeViewController.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2QuickActionCard.h"
#import "A2VersionCard.h"
#import "A2HomeBackgroundView.h"
#import "A2Toast.h"

@interface A2HomeViewController ()
@property (nonatomic, strong) A2HomeBackgroundView *backgroundView;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UILabel *topTitle;
@property (nonatomic, strong) UIButton *accountButton;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

@property (nonatomic, strong) A2GlassCard *heroCard;
@property (nonatomic, strong) A2PrimaryButton *launchButton;
@property (nonatomic, strong) UILabel *heroVersionLabel;
@property (nonatomic, strong) UILabel *heroMetaLabel;

@property (nonatomic, strong) UIStackView *quickRow;

@property (nonatomic, assign) BOOL didSetupConstraints;
@end

@implementation A2HomeViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    [self setupBackground];
    [self setupTopBar];
    [self setupScrollContent];
    [self setupHeroCard];
    [self setupQuickGrid];
    [self setupRecentCard];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 背景与顶栏

- (void)setupBackground {
    _backgroundView = [[A2HomeBackgroundView alloc] initWithFrame:CGRectZero];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_backgroundView];
}

- (void)setupTopBar {
    _topBar = [[UIView alloc] initWithFrame:CGRectZero];
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_topBar];

    _topTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _topTitle.translatesAutoresizingMaskIntoConstraints = NO;
    _topTitle.font = [A2Typography titleLarge];
    _topTitle.text = @"Air2";
    [_topBar addSubview:_topTitle];

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];

    _accountButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _accountButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_accountButton setImage:[UIImage systemImageNamed:@"person.crop.circle" withConfiguration:cfg]
                    forState:UIControlStateNormal];
    [_accountButton addTarget:self action:@selector(openAccount) forControlEvents:UIControlEventTouchUpInside];

    _settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_settingsButton setImage:[UIImage systemImageNamed:@"gearshape" withConfiguration:cfg]
                     forState:UIControlStateNormal];
    [_settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];

    [_topBar addSubview:_accountButton];
    [_topBar addSubview:_settingsButton];
}

#pragma mark - 滚动容器

- (void)setupScrollContent {
    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scrollView];

    _contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = A2SpaceL;
    [_scrollView addSubview:_contentStack];
}

#pragma mark - 主页卡片

- (void)setupHeroCard {
    _heroCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _heroCard.cornerRadius = A2RadiusXL;

    _heroVersionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _heroVersionLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _heroVersionLabel.numberOfLines = 1;
    _heroVersionLabel.adjustsFontSizeToFitWidth = YES;
    _heroVersionLabel.minimumScaleFactor = 0.7;

    _heroMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _heroMetaLabel.font = [A2Typography subtitleCard];
    _heroMetaLabel.numberOfLines = 2;

    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"开始游戏" style:A2ButtonStylePrimary];
    _launchButton.icon = [UIImage systemImageNamed:@"play.fill"];
    [_launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];

    A2PrimaryButton *detailButton = [[A2PrimaryButton alloc] initWithTitle:@"版本设置" style:A2ButtonStyleSecondary];
    detailButton.icon = [UIImage systemImageNamed:@"slider.horizontal.3"];
    [detailButton addTarget:self action:@selector(openVersionSettings) forControlEvents:UIControlEventTouchUpInside];

    A2PrimaryButton *folderButton = [[A2PrimaryButton alloc] initWithTitle:@"游戏目录" style:A2ButtonStyleSecondary];
    folderButton.icon = [UIImage systemImageNamed:@"folder"];
    [folderButton addTarget:self action:@selector(openGameFolder) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *secondaryRow = [[UIStackView alloc] initWithArrangedSubviews:@[detailButton, folderButton]];
    secondaryRow.axis = UILayoutConstraintAxisHorizontal;
    secondaryRow.distribution = UIStackViewDistributionFillEqually;
    secondaryRow.spacing = A2SpaceS;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_heroVersionLabel, _heroMetaLabel, _launchButton, secondaryRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    [stack setCustomSpacing:A2SpaceXS afterView:_heroVersionLabel];
    [stack setCustomSpacing:A2SpaceL afterView:_heroMetaLabel];
    [stack setCustomSpacing:A2SpaceS afterView:_launchButton];

    [_heroCard.contentView addSubview:stack];
    [self pinEdgesOf:stack toView:_heroCard.contentView];
    [_contentStack addArrangedSubview:_heroCard];
}

- (void)setupQuickGrid {
    NSArray<NSArray<NSString *> *> *defs = @[
        @[@"版本管理", @"square.stack.3d.up"],
        @[@"下载",     @"arrow.down.circle"],
        @[@"联机",     @"antenna.radiowaves.left.and.right"],
        @[@"文件",     @"folder.badge.gearshape"],
    ];
    NSArray<SEL> *selectors = @[
        @selector(openVersions), @selector(openDownload),
        @selector(openMultiplayer), @selector(openFiles),
    ];

    NSMutableArray<UIView *> *cards = [NSMutableArray arrayWithCapacity:defs.count];
    for (NSUInteger i = 0; i < defs.count; i++) {
        A2QuickActionCard *card = [[A2QuickActionCard alloc] initWithTitle:defs[i][0]
                                                                symbolName:defs[i][1]];
        SEL action = selectors[i];
        __weak typeof(self) weakSelf = self;
        card.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([self respondsToSelector:action]) [self performSelector:action];
#pragma clang diagnostic pop
        };
        [cards addObject:card];
    }

    _quickRow = [[UIStackView alloc] initWithArrangedSubviews:cards];
    _quickRow.translatesAutoresizingMaskIntoConstraints = NO;
    _quickRow.axis = UILayoutConstraintAxisHorizontal;
    _quickRow.distribution = UIStackViewDistributionFillEqually;
    _quickRow.spacing = A2SpaceS;

    [_contentStack addArrangedSubview:_quickRow];
}

#pragma mark - 约束

- (void)updateViewConstraints {
    if (_didSetupConstraints) {
        [super updateViewConstraints];
        return;
    }
    _didSetupConstraints = YES;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [_backgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backgroundView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backgroundView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_topBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_topBar.heightAnchor constraintEqualToConstant:A2TopBarHeight],

        [_topTitle.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:A2PageMargin],
        [_topTitle.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],

        [_settingsButton.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-A2SpaceM],
        [_settingsButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_settingsButton.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_settingsButton.heightAnchor constraintEqualToConstant:A2MinTouchTarget],

        [_accountButton.trailingAnchor constraintEqualToAnchor:_settingsButton.leadingAnchor constant:-A2SpaceXS],
        [_accountButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
        [_accountButton.widthAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_accountButton.heightAnchor constraintEqualToConstant:A2MinTouchTarget],

        [_scrollView.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_contentStack.topAnchor constraintEqualToAnchor:_scrollView.topAnchor constant:A2SpaceS],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:-A2SpaceXXL],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_scrollView.leadingAnchor constant:A2PageMargin],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor constant:-A2PageMargin],
        [_contentStack.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor constant:-A2PageMargin * 2],
    ]];

    [super updateViewConstraints];
}

/// 让 view 的四边贴合父视图
- (void)pinEdgesOf:(UIView *)view toView:(UIView *)parent {
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor],
        [view.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
    ]];
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorTheme *t = A2ThemeManager.shared.currentTheme;

    // 背景是深色渐变，顶栏文字固定白色
    _topTitle.textColor = UIColor.whiteColor;
    _accountButton.tintColor = UIColor.whiteColor;
    _settingsButton.tintColor = UIColor.whiteColor;

    _heroVersionLabel.textColor = UIColor.whiteColor;
    _heroMetaLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.68];

    if (_heroVersionLabel.text.length == 0) {
        _heroVersionLabel.text = @"尚未选择版本";
        _heroMetaLabel.text = @"前往「版本管理」安装一个版本吧";
    }
    (void)t;
}

#pragma mark - 动作

- (void)launchGame {
    _launchButton.loading = YES;
    // 待接入 Core 层启动流程
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.launchButton.loading = NO;
        [A2Toast show:@"启动流程尚未接入" inView:self.view];
    });
}

- (void)openAccount         { [A2Toast show:@"账号管理" inView:self.view]; }
- (void)openSettings        { [A2Toast show:@"设置" inView:self.view]; }
- (void)openVersions        { [A2Toast show:@"版本管理" inView:self.view]; }
- (void)openDownload        { [A2Toast show:@"下载" inView:self.view]; }
- (void)openMultiplayer     { [A2Toast show:@"联机" inView:self.view]; }
- (void)openFiles           { [A2Toast show:@"文件管理" inView:self.view]; }
- (void)openVersionSettings { [A2Toast show:@"版本设置" inView:self.view]; }
- (void)openGameFolder      { [A2Toast show:@"游戏目录" inView:self.view]; }

@end

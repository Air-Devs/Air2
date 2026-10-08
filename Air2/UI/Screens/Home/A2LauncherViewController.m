//
//  A2LauncherViewController.m
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
#import "A2VersionManager.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2QuickActionCard.h"
#import "A2PrimaryButton.h"
#import "A2SkinHeadView.h"

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
@property (nonatomic, strong) A2SkinHeadView *avatarView;
@property (nonatomic, strong) UILabel *accountNameLabel;
@property (nonatomic, strong) UILabel *accountTypeLabel;

/// 版本卡（右栏主体）
@property (nonatomic, strong) A2GlassCard *versionCard;
@property (nonatomic, strong) UILabel *versionNameLabel;
@property (nonatomic, strong) UILabel *versionMetaLabel;
@property (nonatomic, strong) A2PrimaryButton *launchButton;

/// 最近游玩
@property (nonatomic, strong) A2GlassCard *recentCard;
@property (nonatomic, strong) UIStackView *recentStack;

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
    // 版本与账号变化时刷新右侧
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleDataChanged)
                                              name:A2VersionsDidChangeNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleDataChanged)
                                              name:A2AccountsDidChangeNotification
                                            object:nil];

    [self handleDataChanged];
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
    [self buildRecentCard];
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
/// 右栏的垂直布局：三张卡按自然高度从顶部依次排列。
///
/// 之前是「撑满高度 + 卡片拉伸」，但右侧只有两张卡时，
/// 卡片会被拉得很长而内容稀疏，看起来是变形的。
/// 改成内容自适应后，卡片保持自然比例，下方留白 ——
/// 留白比拉伸好看。
- (void)setupPanelPlacement {
    UILayoutGuide *content = _panelScroll.contentLayoutGuide;
    UILayoutGuide *frame = _panelScroll.frameLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        // 宽度跟随可视区域（只允许垂直滚动）
        [_panelStack.widthAnchor constraintEqualToAnchor:frame.widthAnchor
                                               constant:-A2PanelOuterPadding * 2],

        // 顶部对齐，底部按内容自然结束
        [_panelStack.topAnchor constraintEqualToAnchor:content.topAnchor
                                              constant:A2PanelOuterPadding],
        [_panelStack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor
                                                           constant:-A2PanelOuterPadding],
    ]];

    // 三张卡都按内容撑高，不互相争抢空间
    for (UIView *card in @[_accountCard, _versionCard, _recentCard]) {
        [card setContentHuggingPriority:UILayoutPriorityRequired
                                forAxis:UILayoutConstraintAxisVertical];
        [card setContentCompressionResistancePriority:UILayoutPriorityRequired
                                              forAxis:UILayoutConstraintAxisVertical];
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
    if (_recentCard) [cards addObject:_recentCard];


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
    [self tintTaggedViewsIn:_recentCard color:s.cOnSurfaceVariant];
}

#pragma mark - 数据刷新

/// 版本或账号变化时刷新界面
- (void)handleDataChanged {
    [self refreshCurrentVersionUI];
    [self refreshAccountUI];
    [self refreshRecentVersions];
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
//  布局：
//    ┌───────────────────────────┐
//    │      ┌─────┐              │  账户卡
//    │      │ 头像 │  64pt       │    头像居中
//    │      └─────┘              │
//    │       Steve               │
//    │       Microsoft 正版账号    │
//    └───────────────────────────┘
//    ┌───────────────────────────┐
//    │  1.21.5-fabric        ⚙   │  版本卡
//    │  Fabric 0.16.10 · Java 21 │
//    │  ┌─────────────────────┐  │
//    │  │      启动游戏        │  │
//    │  └─────────────────────┘  │
//    │  版本设置 · 游戏目录        │
//    └───────────────────────────┘
//    ┌───────────────────────────┐
//    │  最近游玩                  │  最近游玩（新增）
//    │  [1.21.5]  [1.20.1]  ...  │    横向滚动的小卡
//    └───────────────────────────┘
//
//  三张卡从顶部依次排列，不强行撑满高度 ——
//  内容少时下方留白，比把两张卡拉变形好看。

#pragma mark 账户卡

- (void)buildAccountCard {
    _accountCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _accountCard.cornerRadius = A2RadiusXL;
    _accountCard.elevation = A2CardElevationLow;
    _accountCard.tappable = YES;
    _accountCard.onTap = ^{ [self openAccount]; };
    _accountCard.contentInsets = UIEdgeInsetsMake(A2CardPadding + 4, A2CardPadding,
                                                  A2CardPadding + 4, A2CardPadding);

    // ---- 头像 ----
    _avatarView = [[A2SkinHeadView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 名字与类型 ----
    _accountNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _accountNameLabel.textAlignment = NSTextAlignmentCenter;
    _accountNameLabel.text = @"未登录";
    _accountNameLabel.adjustsFontSizeToFitWidth = YES;
    _accountNameLabel.minimumScaleFactor = 0.8;

    _accountTypeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountTypeLabel.font = [A2Typography caption];
    _accountTypeLabel.textAlignment = NSTextAlignmentCenter;
    _accountTypeLabel.text = @"点击添加账号";
    _accountTypeLabel.adjustsFontSizeToFitWidth = YES;
    _accountTypeLabel.minimumScaleFactor = 0.8;

    UIStackView *textStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_accountNameLabel, _accountTypeLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    textStack.alignment = UIStackViewAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_avatarView, textStack]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;

    [_accountCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.widthAnchor constraintEqualToConstant:A2AvatarSizeLarge],
        [_avatarView.heightAnchor constraintEqualToConstant:A2AvatarSizeLarge],

        [textStack.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [textStack.trailingAnchor constraintEqualToAnchor:_accountCard.contentView.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:_accountCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_accountCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_accountCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_accountCard];
}

#pragma mark 版本卡

- (void)buildVersionCard {
    _versionCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _versionCard.cornerRadius = A2RadiusXL;
    _versionCard.elevation = A2CardElevationLow;
    _versionCard.contentInsets = UIEdgeInsetsMake(A2CardPadding, A2CardPadding,
                                                  A2CardPadding, A2CardPadding);

    // ---- 顶部行 ----
    _versionNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionNameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _versionNameLabel.text = @"未选择版本";
    _versionNameLabel.adjustsFontSizeToFitWidth = YES;
    _versionNameLabel.minimumScaleFactor = 0.7;

    _versionMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionMetaLabel.font = [A2Typography caption];
    _versionMetaLabel.text = @"点右下角进入版本管理";
    _versionMetaLabel.adjustsFontSizeToFitWidth = YES;
    _versionMetaLabel.minimumScaleFactor = 0.8;

    UIStackView *infoStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_versionNameLabel, _versionMetaLabel]];
    infoStack.axis = UILayoutConstraintAxisVertical;
    infoStack.spacing = 2;

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
    [infoStack setContentHuggingPriority:UILayoutPriorityDefaultLow
                                 forAxis:UILayoutConstraintAxisHorizontal];

    // ---- 启动按钮 ----
    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"启动游戏" style:A2ButtonStylePrimary];
    _launchButton.icon = [UIImage systemImageNamed:@"play.fill"];
    _launchButton.minHeight = A2ButtonHeight;
    [_launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];

    // ---- 次级操作 ----
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
    stack.alignment = UIStackViewAlignmentFill;
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

#pragma mark 最近游玩

/// 最近游玩 —— 横向滚动的版本小卡。
///
/// 之前右侧只有两张卡，内容太少而卡片被拉满高度，显空。
/// 加这一块后信息密度合适，且确实有用：快速切换常玩的版本。
- (void)buildRecentCard {
    _recentCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _recentCard.cornerRadius = A2RadiusXL;
    _recentCard.elevation = A2CardElevationLow;
    _recentCard.contentInsets = UIEdgeInsetsMake(A2CardPadding, 0, A2CardPadding, 0);

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.text = @"最近游玩";

    // 横向滚动
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;

    _recentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _recentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _recentStack.axis = UILayoutConstraintAxisHorizontal;
    _recentStack.spacing = A2SpaceS;
    [scroll addSubview:_recentStack];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, scroll]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;

    [_recentCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_recentCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_recentCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_recentCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_recentCard.contentView.trailingAnchor],
        [title.leadingAnchor constraintEqualToAnchor:_recentCard.contentView.leadingAnchor
                                            constant:A2CardPadding],

        [scroll.heightAnchor constraintEqualToConstant:56],
        [_recentStack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [_recentStack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [_recentStack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor
                                                   constant:A2CardPadding],
        [_recentStack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor
                                                    constant:-A2CardPadding],
        [_recentStack.heightAnchor constraintEqualToAnchor:scroll.heightAnchor],
    ]];

    [_panelStack addArrangedSubview:_recentCard];
    [self refreshRecentVersions];
}

/// 用真实安装的版本刷新最近游玩
- (void)refreshRecentVersions {
    for (UIView *v in _recentStack.arrangedSubviews) {
        [_recentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<A2Version *> *versions = A2VersionManager.shared.versions;
    if (versions.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        empty.text = @"还没有安装版本";
        empty.font = [A2Typography caption];
        empty.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
        [_recentStack addArrangedSubview:empty];
        return;
    }

    // 最多显示 6 个
    NSUInteger count = MIN(6, versions.count);
    for (NSUInteger i = 0; i < count; i++) {
        A2Version *v = versions[i];
        UIView *chip = [self makeVersionChip:v];
        [_recentStack addArrangedSubview:chip];
    }
}

/// 版本小卡：图标 + 名称
- (UIView *)makeVersionChip:(A2Version *)version {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    UIControl *chip = [[UIControl alloc] initWithFrame:CGRectZero];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = t.cSurfaceContainerHigh;
    chip.layer.cornerRadius = A2RadiusM;
    chip.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *initial = [[UILabel alloc] initWithFrame:CGRectZero];
    initial.translatesAutoresizingMaskIntoConstraints = NO;
    initial.text = version.name.length ? [[version.name substringToIndex:1] uppercaseString] : @"?";
    initial.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    initial.textAlignment = NSTextAlignmentCenter;
    initial.textColor = t.cOnPrimaryContainer;
    initial.backgroundColor = t.cPrimaryContainer;
    initial.layer.cornerRadius = A2RadiusS;
    initial.layer.cornerCurve = kCACornerCurveContinuous;
    initial.clipsToBounds = YES;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = version.name;
    name.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    name.textColor = t.cOnSurface;
    name.textAlignment = NSTextAlignmentCenter;
    name.numberOfLines = 1;
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.7;

    [chip addSubview:initial];
    [chip addSubview:name];

    __weak typeof(self) weakSelf = self;
    A2Version *capturedVersion = version;
    [chip addAction:[UIAction actionWithHandler:^(UIAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if ([A2VersionManager.shared selectCurrentVersion:capturedVersion]) {
            [self refreshCurrentVersionUI];
            [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", capturedVersion.name]
                   inView:self.view];
        }
    }] forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [chip.widthAnchor constraintGreaterThanOrEqualToConstant:72],
        [chip.heightAnchor constraintEqualToConstant:56],

        [initial.topAnchor constraintEqualToAnchor:chip.topAnchor constant:6],
        [initial.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
        [initial.widthAnchor constraintEqualToConstant:26],
        [initial.heightAnchor constraintEqualToConstant:26],

        [name.topAnchor constraintEqualToAnchor:initial.bottomAnchor constant:3],
        [name.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:4],
        [name.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-4],
        [name.bottomAnchor constraintLessThanOrEqualToAnchor:chip.bottomAnchor constant:-4],
    ]];

    return chip;
}

/// 刷新版本卡上的版本信息
- (void)refreshCurrentVersionUI {
    A2Version *current = A2VersionManager.shared.currentVersion;
    if (!current) {
        _versionNameLabel.text = @"未选择版本";
        _versionMetaLabel.text = @"点右下角进入版本管理";
        return;
    }

    _versionNameLabel.text = current.name;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:current.loaderInfo.length ? current.loaderInfo : @"原版"];
    [parts addObject:[NSString stringWithFormat:@"隔离·%@",
                      A2IsolationModeDisplayName(current.isolationMode)]];
    _versionMetaLabel.text = [parts componentsJoinedByString:@" · "];
}

/// 刷新账户卡
- (void)refreshAccountUI {
    A2Account *acc = A2AccountManager.shared.currentAccount;
    if (!acc) {
        _avatarView.skinPath = nil;
        _avatarView.fallbackText = @"+";
        _accountNameLabel.text = @"未登录";
        _accountTypeLabel.text = @"点击添加账号";
        return;
    }
    _avatarView.skinPath = acc.skinPath;
    _avatarView.fallbackText = acc.username;
    _accountNameLabel.text = acc.username;
    _accountTypeLabel.text = acc.typeDisplayName;

    // 本地没有皮肤时按需拉一次；拉到后只更新头像，不整块重刷（避免递归）。
    if (acc.skinPath.length == 0) {
        __weak typeof(self) weakSelf = self;
        [A2AccountManager.shared ensureSkinForAccount:acc completion:^(A2Account *a) {
            __strong typeof(weakSelf) self = weakSelf;
            if (a.skinPath.length) self->_avatarView.skinPath = a.skinPath;
        }];
    }
}

#pragma mark 文字链接

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
    // 用标准的缩放淡入，不用从底部滑入。
    // 底部滑入适合模态小面板（比如选择器、确认框），
    // 而下载是个完整的页面，横屏下从底部推一整屏非常突兀。
    [self pushScreen:[[A2DownloadViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openMultiplayer { [A2Toast show:@"联机功能尚未接入" inView:self.view]; }
- (void)openFiles       { [A2Toast show:@"文件管理尚未接入" inView:self.view]; }
- (void)openVersionSettings { [A2Toast show:@"版本设置" inView:self.view]; }

@end


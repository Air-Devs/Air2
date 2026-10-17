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
#import "A2LaunchSession.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Icon.h"
#import "A2GlassCard.h"
#import "A2BackgroundView.h"
#import "A2VersionCard.h"
#import "A2Toast.h"
#import "A2NavigationController.h"
#import "A2VersionManager.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2VersionSettingsViewController.h"
#import "A2PrimaryButton.h"
#import "A2SkinHeadView.h"

#import "A2AccountViewController.h"
#import "A2MultiplayerViewController.h"
#import "A2Multiplayer.h"
#import "A2SettingsViewController.h"
#import "A2VersionListViewController.h"
#import "A2DownloadViewController.h"


@interface A2LauncherViewController ()
@property (nonatomic, strong) A2BackgroundView *backgroundView;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UILabel *appNameLabel;
@property (nonatomic, strong) UIStackView *topTrailingStack;

/// 右侧操作栏
@property (nonatomic, strong) UIView *panelContainer;
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

/// 主卡（单卡三段式：账户 / 版本 / 启动）
@property (nonatomic, strong) A2GlassCard *mainCard;
@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) UIControl *accountSection;
@property (nonatomic, strong) UIControl *versionSection;

@property (nonatomic, strong) UILabel *plusLabel;
@property (nonatomic, strong) UIImageView *versionIcon;
@property (nonatomic, strong) UIButton *versionGear;
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
    // ZL2 的侧栏是固定不滚动的（ConstraintLayout + fillMaxSize）。
    // 之前用 UIScrollView，内容略高就会产生滚动 —— 侧栏本身只有两三张卡，
    // 不该让人滚动它。
    _panelContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _panelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_panelContainer];

    _panelStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _panelStack.translatesAutoresizingMaskIntoConstraints = NO;
    _panelStack.axis = UILayoutConstraintAxisVertical;
    _panelStack.spacing = A2CardSpacing;   // 12pt，与卡片内边距一致
    [_panelContainer addSubview:_panelStack];

    // 操作区只放两张卡：账户 + 版本。
    // 之前我额外加了「版本/下载/联机/文件」快捷网格，但它和顶栏入口
    // 功能重叠，还把右栏撑得很满。
    [self buildMainCard];
}

#pragma mark - 操作区垂直布局

/// 操作区的垂直布局。
///
/// **两张卡撑满操作区高度**，而不是内容自适应后居中留白。
/// 卡高 = 可用最大高度 - 上下外边距 × 2。
///
/// 为什么撑满反而不显得「满」：
///   卡内是分层的 —— 账户区在上、版本区在下，
///   中间靠 top/bottom 锚点撑开。
///   空间大时中间自然形成呼吸感，而不是把元素堆在顶部。
///   之前的做法是内容自适应 + 居中，视觉上像「漂浮的小盒子」。
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
    // 侧栏是固定容器，不滚动。
    // 内容从顶部按 12pt 外边距开始，卡片按内容高度排列。
    [NSLayoutConstraint activateConstraints:@[
        [_panelStack.topAnchor constraintEqualToAnchor:_panelContainer.topAnchor
                                               constant:A2PanelOuterPadding],
        [_panelStack.leadingAnchor constraintEqualToAnchor:_panelContainer.leadingAnchor
                                                  constant:A2PanelOuterPadding],
        [_panelStack.trailingAnchor constraintEqualToAnchor:_panelContainer.trailingAnchor
                                                   constant:-A2PanelOuterPadding],
        // 底部用 ≤ 而非 = ：内容短时不被拉伸
        [_panelStack.bottomAnchor constraintLessThanOrEqualToAnchor:_panelContainer.bottomAnchor
                                                           constant:-A2PanelOuterPadding],

        // 主卡片高度不超过侧栏可用空间 —— 屏幕矮时（如 iPhone 横屏 390pt 高）
        // 卡片内容会溢出屏幕。ZL2 的做法是卡片高度 = 容器高 - 24
        // （cardHeight = maxHeight - ActionMenuOuterPadding * 2）。
        [_mainCard.heightAnchor constraintLessThanOrEqualToAnchor:_panelContainer.heightAnchor
                                                        constant:-A2PanelOuterPadding * 2],
    ]];

    // 卡片按内容撑高，不互相争抢空间
    for (UIView *card in @[_mainCard]) {
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
    // 操作区 : 内容区 = 3 : 7。
    // 用 multiplier 而不是算好的固定值 —— 后者在 updateViewConstraints
    // 首次调用时 bounds 还是 0，兜底值会被固化且旋转后不更新。
    NSLayoutConstraint *panelWidth =
        [_panelContainer.widthAnchor constraintEqualToAnchor:self.view.widthAnchor
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
        [_panelContainer.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_panelContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_panelContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

    ]];

    // 侧栏内部的边距与排列在 setupPanelPlacement 里统一处理
    [self setupPanelPlacement];

    [super updateViewConstraints];
}

#pragma mark - 入场动画

/// 卡片依次淡入上浮。这是用户打开 App 看到的第一件事，
/// 做得克制一点：位移只有 16pt，间隔 35ms，整体不到 0.5 秒。
- (void)playEntranceAnimation {
    NSMutableArray<UIView *> *cards = [NSMutableArray array];
    if (_mainCard) [cards addObject:_mainCard];


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
    [self tintTaggedViewsIn:_mainCard color:s.cOnSurfaceVariant];
}

#pragma mark - 数据刷新

/// 版本或账号变化时刷新界面
- (void)handleDataChanged {
    [self refreshCurrentVersionUI];
    [self refreshAccountUI];
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

#pragma mark - 侧栏主卡片（单卡三段式）
//
//  对照 ZL2 主页截图：
//    整张卡是一个大圆角白卡，内部上中下三段
//    ┌──────────────────────────┐
//    │           ＋              │  ① 账号段：头像 + 名字（居中）
//    │       添加账号 / Steve     │     无账号时显示「＋ 添加账号」
//    │                          │
//    │  ┌────┐ 1.20.1      ⚙    │  ② 版本段：图标 + 名字 + meta + 齿轮
//    │  │草块│ 1.20.1, Fabric   │
//    │  └────┘                  │
//    │                          │
//    │  ┌────────────────────┐  │  ③ 操作段：启动按钮（整宽）
//    │  │     启动游戏        │  │
//    │  └────────────────────┘  │
//    └──────────────────────────┘

- (void)buildMainCard {
    _mainCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _mainCard.cornerRadius = A2RadiusXL;
    _mainCard.elevation = A2CardElevationLow;
    // 用户批注：版本卡（主卡）不要带边框和阴影。
    _mainCard.drawsBorder = NO;
    _mainCard.drawsShadow = NO;
    _mainCard.contentInsets = UIEdgeInsetsMake(A2SpaceXL, A2SpaceL, A2SpaceL, A2SpaceL);
    // ★一级页面是玻璃的唯一用武之地★：跟随壁纸做半透明 + 可模糊。
    // 默认（不写这行）是 MD3 实心表面 —— 二级界面一律走默认，见 docs/DECISIONS.md。
    _mainCard.glassEnabled = YES;

    [self buildAccountSection];
    [self buildVersionSection];
    [self buildLaunchSection];

    _mainStack = [[UIStackView alloc] initWithArrangedSubviews:
                  @[_accountSection, _versionSection, _launchButton]];
    _mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    _mainStack.axis = UILayoutConstraintAxisVertical;
    _mainStack.spacing = A2SpaceL;
    // 账号段与版本段之间留更大气口（截图里这两段分得较开）
    [_mainStack setCustomSpacing:A2SpaceXL afterView:_accountSection];

    [_mainCard.contentView addSubview:_mainStack];
    [NSLayoutConstraint activateConstraints:@[
        [_mainStack.topAnchor constraintEqualToAnchor:_mainCard.contentView.topAnchor],
        [_mainStack.bottomAnchor constraintEqualToAnchor:_mainCard.contentView.bottomAnchor],
        [_mainStack.leadingAnchor constraintEqualToAnchor:_mainCard.contentView.leadingAnchor],
        [_mainStack.trailingAnchor constraintEqualToAnchor:_mainCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_mainCard];
    [self.view setNeedsUpdateConstraints];
}

#pragma mark ① 账号段

- (void)buildAccountSection {
    _accountSection = [[UIControl alloc] initWithFrame:CGRectZero];
    _accountSection.translatesAutoresizingMaskIntoConstraints = NO;
    [_accountSection addTarget:self action:@selector(openAccount)
              forControlEvents:UIControlEventTouchUpInside];

    // 有账号：显示皮肤头像；无账号：显示「＋」
    _avatarView = [[A2SkinHeadView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;

    _plusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _plusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _plusLabel.text = @"＋";
    _plusLabel.font = [UIFont systemFontOfSize:44 weight:UIFontWeightLight];
    _plusLabel.textAlignment = NSTextAlignmentCenter;
    _plusLabel.hidden = YES;

    _accountNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _accountNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _accountNameLabel.textAlignment = NSTextAlignmentCenter;
    _accountNameLabel.text = @"添加账号";

    _accountTypeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountTypeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _accountTypeLabel.font = [A2Typography caption];
    _accountTypeLabel.textAlignment = NSTextAlignmentCenter;
    _accountTypeLabel.hidden = YES;

    [_accountSection addSubview:_avatarView];
    [_accountSection addSubview:_plusLabel];
    [_accountSection addSubview:_accountNameLabel];
    [_accountSection addSubview:_accountTypeLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.topAnchor constraintEqualToAnchor:_accountSection.topAnchor],
        [_avatarView.centerXAnchor constraintEqualToAnchor:_accountSection.centerXAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:64],
        [_avatarView.heightAnchor constraintEqualToConstant:64],

        [_plusLabel.centerXAnchor constraintEqualToAnchor:_accountSection.centerXAnchor],
        [_plusLabel.centerYAnchor constraintEqualToAnchor:_accountSection.topAnchor
                                                 constant:36],

        [_accountNameLabel.topAnchor constraintEqualToAnchor:_accountSection.topAnchor
                                                    constant:76],
        [_accountNameLabel.leadingAnchor constraintEqualToAnchor:_accountSection.leadingAnchor],
        [_accountNameLabel.trailingAnchor constraintEqualToAnchor:_accountSection.trailingAnchor],

        [_accountTypeLabel.topAnchor constraintEqualToAnchor:_accountNameLabel.bottomAnchor
                                                    constant:2],
        [_accountTypeLabel.leadingAnchor constraintEqualToAnchor:_accountSection.leadingAnchor],
        [_accountTypeLabel.trailingAnchor constraintEqualToAnchor:_accountSection.trailingAnchor],
        [_accountTypeLabel.bottomAnchor constraintEqualToAnchor:_accountSection.bottomAnchor],
    ]];
}

#pragma mark ② 版本段

- (void)buildVersionSection {
    _versionSection = [[UIControl alloc] initWithFrame:CGRectZero];
    _versionSection.translatesAutoresizingMaskIntoConstraints = NO;
    [_versionSection addTarget:self action:@selector(openVersions)
              forControlEvents:UIControlEventTouchUpInside];

    // 版本图标（草方块）
    _versionIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _versionIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _versionIcon.contentMode = UIViewContentModeScaleAspectFit;
    _versionIcon.image = [UIImage systemImageNamed:@"cube.fill"];
    _versionIcon.layer.cornerRadius = A2RadiusS;
    _versionIcon.layer.cornerCurve = kCACornerCurveContinuous;
    _versionIcon.clipsToBounds = YES;

    _versionNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _versionNameLabel.text = @"未选择版本";
    _versionNameLabel.numberOfLines = 1;
    _versionNameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _versionMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionMetaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionMetaLabel.font = [A2Typography caption];
    _versionMetaLabel.text = @"点击进入版本管理";
    _versionMetaLabel.numberOfLines = 1;
    _versionMetaLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_versionNameLabel, _versionMetaLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;

    // 齿轮：进入版本设置
    _versionGear = [UIButton buttonWithType:UIButtonTypeSystem];
    _versionGear.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIFontWeightRegular];
    [_versionGear setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg]
                  forState:UIControlStateNormal];
    [_versionGear addTarget:self action:@selector(openVersionSettings)
           forControlEvents:UIControlEventTouchUpInside];

    [_versionSection addSubview:_versionIcon];
    [_versionSection addSubview:textStack];
    [_versionSection addSubview:_versionGear];

    [NSLayoutConstraint activateConstraints:@[
        [_versionIcon.leadingAnchor constraintEqualToAnchor:_versionSection.leadingAnchor],
        [_versionIcon.centerYAnchor constraintEqualToAnchor:_versionSection.centerYAnchor],
        [_versionIcon.widthAnchor constraintEqualToConstant:36],
        [_versionIcon.heightAnchor constraintEqualToConstant:36],
        [_versionIcon.topAnchor constraintEqualToAnchor:_versionSection.topAnchor],
        [_versionIcon.bottomAnchor constraintEqualToAnchor:_versionSection.bottomAnchor],

        [textStack.leadingAnchor constraintEqualToAnchor:_versionIcon.trailingAnchor
                                                constant:A2SpaceM],
        [textStack.centerYAnchor constraintEqualToAnchor:_versionSection.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_versionGear.leadingAnchor
                                                           constant:-A2SpaceS],

        [_versionGear.trailingAnchor constraintEqualToAnchor:_versionSection.trailingAnchor],
        [_versionGear.centerYAnchor constraintEqualToAnchor:_versionSection.centerYAnchor],
        [_versionGear.widthAnchor constraintEqualToConstant:36],
        [_versionGear.heightAnchor constraintEqualToConstant:36],
    ]];
}

#pragma mark ③ 操作段

- (void)buildLaunchSection {
    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"启动游戏" style:A2ButtonStylePrimary];
    _launchButton.minHeight = A2ButtonHeight;
    [_launchButton addTarget:self action:@selector(launchGame)
            forControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - 数据刷新

- (void)refreshCurrentVersionUI {
    A2Version *current = A2VersionManager.shared.currentVersion;
    if (!current) {
        _versionNameLabel.text = @"未选择版本";
        _versionMetaLabel.text = @"点右下角进入版本管理";
        return;
    }

    _versionNameLabel.text = current.name;

    // 版本图标优先顺序：
    //   1. 用户自定义图标（.air_version/VersionIcon.png）
    //   2. 加载器图标（Fabric/Forge/NeoForge/Quilt/OptiFine 的品牌图）
    //   3. 草方块（原版）
    NSString *iconPath = [current.launcherDataPath stringByAppendingPathComponent:@"VersionIcon.png"];
    UIImage *icon = nil;

    if (iconPath.length && [NSFileManager.defaultManager fileExistsAtPath:iconPath]) {
        icon = [UIImage imageWithContentsOfFile:iconPath];
    }
    if (!icon && current.loaderInfo.length) {
        icon = [A2Icon loaderIconForLoaderInfo:current.loaderInfo];
    }
    if (!icon) {
        icon = [A2Icon vanillaIcon];
    }

    if (icon) {
        _versionIcon.image = icon;
        _versionIcon.backgroundColor = UIColor.clearColor;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:current.loaderInfo.length ? current.loaderInfo : @"原版"];
    [parts addObject:[NSString stringWithFormat:@"隔离·%@",
                      A2IsolationModeDisplayName(current.effectiveIsolationMode)]];
    _versionMetaLabel.text = [parts componentsJoinedByString:@" · "];
}

/// 刷新账号段。
///
/// 未登录时显示「＋」大图标 + 「添加账号」（对应 ZL2 截图的空状态），
/// 有账号时显示皮肤头像 + 名字 + 账号类型。
- (void)refreshAccountUI {
    A2Account *acc = A2AccountManager.shared.currentAccount;
    if (!acc) {
        _avatarView.hidden = YES;
        _plusLabel.hidden = NO;
        _accountNameLabel.text = @"添加账号";
        _accountTypeLabel.hidden = YES;
        return;
    }

    _avatarView.hidden = NO;
    _plusLabel.hidden = YES;
    _accountTypeLabel.hidden = NO;

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
    // 自研启动链默认关 ⇒ 结果恒为「未启用」，下面仍弹原来那句提示，**开箱行为不变**。
    [A2LaunchSession startCurrentVersionWithCompletion:^(A2LaunchSessionResult *result) {
        self.launchButton.loading = NO;
        if (result.started) {
            [A2Toast show:@"启动链已返回（见日志 [A2-LAUNCH]）" inView:self.view];
            return;
        }
        if ([result.message hasPrefix:@"自研启动链未启用"]) {
            // 保持与「未接入」时代完全一致的过渡文案（链未启用时零行为变化）。
            [A2Toast show:@"启动流程尚未接入" inView:self.view];
        } else {
            [A2Toast show:result.message inView:self.view];
        }
    }];
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

- (void)openDownload {
    // 用标准的缩放淡入，不用从底部滑入。
    // 底部滑入适合模态小面板（比如选择器、确认框），
    // 而下载是个完整的页面，横屏下从底部推一整屏非常突兀。
    [self pushScreen:[[A2DownloadViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openMultiplayer {
    // 确保联机模块已初始化
    [A2Multiplayer.shared initializeIfNeeded];
    A2MultiplayerViewController *vc = [[A2MultiplayerViewController alloc] init];
    [self pushScreen:vc style:A2TransitionStyleScaleFade];
}
- (void)openFiles       { [A2Toast show:@"文件管理尚未接入" inView:self.view]; }
- (void)openVersionSettings {
    // 齿轮与「版本设置」进当前版本的单版本设置页（真实页面）。
    // 无版本时给提示，不进空页面；只有「游戏目录」进版本管理列表。
    A2Version *current = A2VersionManager.shared.currentVersion;
    if (!current) {
        [A2Toast show:@"还没有安装版本" inView:self.view];
        return;
    }
    [self pushScreen:[[A2VersionSettingsViewController alloc] initWithVersionName:current.name]
               style:A2TransitionStyleScaleFade];
}
/// 只有「游戏目录」进这里：版本管理列表。
- (void)openVersions {
    [self pushScreen:[[A2VersionListViewController alloc] init] style:A2TransitionStyleScaleFade];
}

@end


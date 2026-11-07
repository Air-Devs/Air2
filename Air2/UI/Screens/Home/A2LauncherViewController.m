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
#import "A2VersionIsolation.h"   // A2GamePath：主界面展示当前游戏目录名
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2VersionSettingsViewController.h"
#import "A2PrimaryButton.h"
#import "A2Log.h"                 // [A2-LAUNCH] tap / 看门狗 判据行（与 [A2-CHAIN] 同一出口）
#import "A2SkinHeadView.h"

#import "A2AccountViewController.h"
#import "A2MultiplayerViewController.h"
#import "A2Multiplayer.h"
#import "A2SettingsViewController.h"
#import "A2VersionListViewController.h"
#import "A2DownloadViewController.h"

#import "A2PluginContributionHost.h"   // ★插件 P2 接线★ 主页三处插入点（① ② ⑥）
#import "A2SettingsSection.h"          // ⑥ home.section 与设置页同一种「整块分区」

// ★主页网格（实验）★ 开关 = home.ui.gridEnabled（默认 NO，见 A2HomeStore）。
// 全关时下面这几个模块只会被读一次设置，不建任何视图 ⇒ 经典三区行为不变。
#import "A2HomeGridView.h"                   // 卡片区（滚动 + 排布 + 拖拽）
#import "A2HomeStore.h"                      // 布局读写 + 网格开关（A2Settings 托管）
#import "A2HomeRuntime.h"                    // 卡片引用 → 真实版本（软失败，不删卡）
#import "A2HomeWidgetPickerViewController.h" // didRequestAddCard 的下钻面板
#import "A2Settings.h"                       // 监听 A2SettingsDidChangeNotification 热应用


@interface A2LauncherViewController () <A2HomeGridViewDelegate>
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

#pragma mark 插件插入点（P2）
/// 已插入的插件视图（① ② ⑥ 共用一份清单）：重画前先按它撤掉，避免反复进出主页叠出两份。
@property (nonatomic, strong) NSMutableArray<UIView *> *pluginInsertedViews;
/// 撤掉旧插入点并按当前注册表重画（幂等）。调用点：viewDidLoad / viewWillAppear。
- (void)reloadPluginInsertions;
/// ① home.toolbar.action：往 `_topTrailingStack` 尾部追加按钮（未装插件时一条不加）。
- (void)installPluginToolbarActions;
/// ② home.card.badge：主卡右上角徽标（叠加在 contentView 上，不进主栈）。
- (void)installCardBadges;
/// ⑥ home.section：卡片区下方追加插件分区（一个插件一张卡）。
- (void)installHomeSections;
/// 插件动作的点击处理：P2 没有动作运行时，只能如实说明（不假装执行）。
- (void)handlePluginAction:(A2PluginSlotContribution *)entry;

#pragma mark 主页网格（实验，home.ui.gridEnabled 默认 NO）
/// 网格模式的内容区（左侧 70%）。★开关 OFF 时恒为 nil★ —— 经典三区的层级与约束一条都没动过。
@property (nonatomic, strong, nullable) UIView *homeContentContainer;
/// 内容区的垂直栈：编辑条 → 网格 → 插件分区（home.section 在网格模式下的落点）。
@property (nonatomic, strong, nullable) UIStackView *homeContentStack;
@property (nonatomic, strong, nullable) A2HomeGridView *homeGridView;
@property (nonatomic, strong, nullable) UIButton *homeEditButton;
@property (nonatomic, strong, nullable) UIButton *homeAddButton;
/// 当前生效的布局文档（`A2HomeStore` 读出来那一篇；写回也走它，不自建存储）。
@property (nonatomic, strong, nullable) A2HomeDocument *homeDocument;
/// 内容区自身的约束（拆网格时先停用，避免约束指向已移除的视图）。
@property (nonatomic, strong, nullable) NSMutableArray<NSLayoutConstraint *> *homeContentConstraints;

/// 按开关建 / 拆网格内容区（幂等）。调用点：viewDidLoad / viewWillAppear / handleHomeSettingsChanged:。
- (void)refreshHomeGridMode;
/// 只建（已建则直接返回）：内容区 + 编辑条 + A2HomeGridView + 从 A2HomeStore 读方案。
- (void)buildHomeGridContent;
/// 只拆（未建则直接返回）：先 flush 未落盘的改动，再撤视图与约束。
- (void)teardownHomeGridContent;
/// 编辑 / 完成（网格的拖拽与卡片 ⋯ 菜单只在编辑态可达）。
- (void)toggleHomeGridEditing;
/// ＋ 卡片：下钻 A2HomeWidgetPickerViewController（加完即 reload + 走合并窗口落盘）。
- (void)presentHomeCardPicker;
/// 卡片本体被点：内置卡按现有快捷入口分发，插件卡只如实说明「暂不支持」。
- (void)activateHomeCard:(A2HomeCard *)card;
/// 自定义卡的跳转（内置页 / 网址），全部复用本 VC 已有的导航入口。
- (void)jumpToHomePage:(A2HomeJumpPage)page urlString:(nullable NSString *)urlString;
/// 启动某个版本：切当前版本后走本 VC 的 launchGame（不新造启动链）。
- (void)activateHomeVersion:(A2Version *)version;
/// 编辑态 ⋯：确认框 → removeHomeCard:（走 A2HomeStore 的落盘，不自造存储）。
- (void)confirmRemoveHomeCard:(A2HomeCard *)card;
- (void)removeHomeCard:(A2HomeCard *)card;
/// 把 `homeDocument` 交给 A2HomeStore 的 250ms 合并窗口（只读模式不写）。
- (void)commitHomeDocumentChange;
/// A2SettingsDidChangeNotification：网格开关变了就地重画（不用杀进程）。
- (void)handleHomeSettingsChanged:(NSNotification *)note;
@end

@implementation A2LauncherViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _pluginInsertedViews = [NSMutableArray array];

    [self setupBackground];
    [self setupTopBar];
    [self setupSidePanel];

    // ★主页网格（实验）★ 开关 ON 才建内容区；OFF 时这里只读一次设置，什么都不建。
    // 必须排在 reloadPluginInsertions 之前：home.section 的落点跟着模式走（内容区 / 右栏）。
    [self refreshHomeGridMode];

    // ★插件 P2 插入点 ① ② ⑥★ 页面骨架建好之后一次画齐（未装插件时一个视图都不加）。
    [self reloadPluginInsertions];

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
    // ★主页网格★ 设置页切换开关 ⇒ 主页就地重画（A2Settings 写穿透后发的那条通知）。
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleHomeSettingsChanged:)
                                              name:A2SettingsDidChangeNotification
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // ★主页网格★ 从「设置 → 外观」改完开关回来，先按当前值建 / 拆内容区（不建则什么都不做）。
    [self refreshHomeGridMode];
    // ★插件 P2★ 从设置 / 插件页回来时按当前注册表重画三处插入点（先撤后建，幂等）。
    // 没有这一条，刚启用的插件要杀进程重开才出现在主页上。
    [self reloadPluginInsertions];
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
    // 插件按钮不在这里加：由 reloadPluginInsertions（viewDidLoad / viewWillAppear）统一画，
    // 免得「初始化加一遍、回到主页再加一遍」。
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

#pragma mark - 插件插入点 ① ② ⑥（统一重画入口）

/// 撤掉旧插入点并按当前注册表重画（幂等）。
///
/// 为什么需要「重画」而不是只在 viewDidLoad 画一次：插件页装/启用一个插件后回到主页，
/// 期望立刻看见它的按钮；只在初始化画的话要杀进程才生效 —— 那种「设置了没反应」最难查。
/// 每次重画前按 `_pluginInsertedViews` 精确撤掉旧视图，不会叠出第二份。
- (void)reloadPluginInsertions {
    for (UIView *view in [_pluginInsertedViews copy]) {
        if (view.superview == _topTrailingStack) {
            [_topTrailingStack removeArrangedSubview:view];
        } else if (view.superview == _panelStack) {
            [_panelStack removeArrangedSubview:view];
        } else if (view.superview == _homeContentStack) {
            // 网格模式下 home.section 落在内容区栈里：撤的时候要认这一处，
            // 否则「先撤后建」会在内容区里叠出第二份分区。
            [_homeContentStack removeArrangedSubview:view];
        }
        [view removeFromSuperview];
    }
    [_pluginInsertedViews removeAllObjects];

    [self installPluginToolbarActions];
    [self installCardBadges];
    [self installHomeSections];
}

/// `home.toolbar.action`（PLUGIN-COMPAT 2.2：放按钮/开关，上限 4，多者按排序键取前 4）。
///
/// 只**追加**：三个内置入口的位置与尺寸不变，未装插件时这个循环一条也不执行，
/// 顶栏视觉与接线前逐字相同。
- (void)installPluginToolbarActions {
    NSArray<A2PluginSlotContribution *> *entries =
        [A2PluginContributionHost entriesForSlot:@"home.toolbar.action"];
    if (entries.count == 0) return;

    __weak typeof(self) weakSelf = self;
    for (A2PluginSlotContribution *entry in entries) {
        UIButton *button = [A2PluginContributionHost actionButtonForEntry:entry
                                                                  handler:^(A2PluginSlotContribution *tapped) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self handlePluginAction:tapped];
        }];
        if (button == nil) continue;   // 画不出的已被宿主记进判据行的「跳过 M 条」
        // 707 是「插件按钮」的标记：applyTheme 不按内置按钮的色板覆盖它（见 applyTheme）。
        button.tag = 707;
        [_topTrailingStack addArrangedSubview:button];
        [_pluginInsertedViews addObject:button];
    }
}

/// P2 没有动作运行时（`type: js` 在 P2 宿主上连装都装不上）。
/// 点了只能如实说清楚 —— 不弹「已完成」，也不留一个毫无反应的可点区域。
- (void)handlePluginAction:(A2PluginSlotContribution *)entry {
    NSString *actionId = entry.actionId.length > 0 ? entry.actionId : @"（插件未声明动作）";
    [A2Log criterion:@"[A2-PLUGIN-UI] home.toolbar.action 点击 %@（插件 %@）：P2 无动作运行时，不执行",
     actionId, entry.pluginId];
    [A2Toast show:[NSString stringWithFormat:@"插件动作 %@ 需要 P3 运行时", actionId]
           inView:self.view];
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
        // 707 = 插件按钮：色板由宿主映射（button.primary 用强调色），不被内置入口的统一色覆盖
        if ([b isKindOfClass:UIButton.class] && b.tag != 707) b.tintColor = s.cOnSurfaceVariant;
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

    // ---- 主页网格（实验）----
    // 网格未启用时这两行都是 nil 判断，经典路径一点没多。
    if (_homeGridView != nil) [_homeGridView applyTheme];
    if (_homeEditButton != nil) _homeEditButton.tintColor = s.cOnSurfaceVariant;
    if (_homeAddButton != nil) _homeAddButton.tintColor = s.cPrimary;
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

    // ② / ⑥ 不在这里加：由 reloadPluginInsertions 统一画（viewDidLoad 里紧跟 setupSidePanel 之后，
    // viewWillAppear 再按需重画），避免「建卡时加一遍、回主页再加一遍」。

    [self.view setNeedsUpdateConstraints];
}

#pragma mark - 插件插入点 ②：主页卡片徽标

/// `home.card.badge`（PLUGIN-COMPAT 2.2：上限 1，多者取 priority 最高 ——
/// 容量规则在注册表 `effectiveEntriesForSlot:` 里，这里不再算一遍）。
///
/// 徽标**叠加**在 contentView 右上角，不进 `_mainStack`：进栈会挤动卡内三段式排版。
- (void)installCardBadges {
    NSArray<A2PluginSlotContribution *> *entries =
        [A2PluginContributionHost entriesForSlot:@"home.card.badge"];
    if (entries.count == 0) return;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceXS;
    // 徽标是被动信息：不吞用户点击（下面压着账户段/版本段的可点区域）
    stack.userInteractionEnabled = NO;
    for (A2PluginSlotContribution *entry in entries) {
        UIView *badge = [A2PluginContributionHost badgeForEntry:entry onDarkSurface:NO];
        if (badge != nil) [stack addArrangedSubview:badge];
    }
    if (stack.arrangedSubviews.count == 0) return;   // 全部画不出 ⇒ 不占位

    [_mainCard.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_mainCard.contentView.topAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_mainCard.contentView.trailingAnchor],
    ]];
    [_pluginInsertedViews addObject:stack];
}

#pragma mark - 插件插入点 ⑥：主页分区

/// `home.section`（PLUGIN-COMPAT 2.2：放整块自定义分区）。
///
/// 落点说明：主页左 70% 只有背景、**没有内容列**，所以「卡片区下方」在这里就是
/// 右侧操作栏里主卡之后 —— 只在已有垂直栈尾部追加，不动页面骨架。
/// 分区本身与设置页用同一种行（`A2SettingsSection`），不另造一套卡片样式。
- (void)installHomeSections {
    NSArray<A2PluginSlotContribution *> *entries =
        [A2PluginContributionHost entriesForSlot:@"home.section"];
    if (entries.count == 0) return;

    // 落点跟着主页模式走，但插槽**与网格解耦**：开关 ON/OFF 两种状态下都会画，
    //   经典模式 = 右栏主卡之后（既有行为，一字未改）；
    //   网格模式 = 内容区里网格之后（同一份 entries，只是容器不同）。
    UIStackView *target = _homeContentStack ?: _panelStack;
    for (A2SettingsSection *section in [A2PluginContributionHost sectionsForEntries:entries]) {
        if (target == _homeContentStack) {
            // 内容区是「网格占满剩余高度」的填充栈：分区必须保持自身高度，不能被拉长。
            [section setContentHuggingPriority:UILayoutPriorityRequired
                                       forAxis:UILayoutConstraintAxisVertical];
        }
        [target addArrangedSubview:section];
        [_pluginInsertedViews addObject:section];
    }
}

#pragma mark - 主页网格（实验）

//  开关 = home.ui.gridEnabled（A2HomeStore.gridEnabled），★默认 NO★。
//  ON  ：左 70% 的内容区换成 A2HomeGridView（编辑条 + 网格 + 插件分区）；
//  OFF ：不建任何视图、不加任何约束 —— 上面的经典三区（顶栏 / 右栏主卡）一字未改。
//
//  为什么内容区是「新增一层」而不是改现有骨架：经典路径里左 70% 只有背景，没有内容列；
//  把网格塞进 _panelStack 会挤动右栏三段式。新增一个只属于网格模式的容器，
//  开关 OFF 时它整层不存在 ⇒ 「行为不变」是结构上成立的，不靠运行时判断。

- (void)refreshHomeGridMode {
    if (!self.isViewLoaded) return;
    if (A2HomeStore.shared.gridEnabled) {
        [self buildHomeGridContent];
    } else {
        [self teardownHomeGridContent];
    }
}

- (void)buildHomeGridContent {
    if (_homeContentContainer != nil) return;   // 幂等：已经在网格模式

    _homeContentContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _homeContentContainer.translatesAutoresizingMaskIntoConstraints = NO;

    _homeContentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _homeContentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _homeContentStack.axis = UILayoutConstraintAxisVertical;
    _homeContentStack.spacing = A2SpaceS;
    _homeContentStack.layoutMarginsRelativeArrangement = YES;
    // 左右只留 12：网格自身还有 24 的内边距，再大会把卡片挤到屏幕中间。
    _homeContentStack.layoutMargins = UIEdgeInsetsMake(0, A2PanelOuterPadding,
                                                       A2PanelOuterPadding, A2PanelOuterPadding);
    [_homeContentContainer addSubview:_homeContentStack];

    // ---- 编辑条：编辑/完成 + ＋卡片 ----
    // 为什么要有这一条：网格的拖拽与卡片 ⋯ 菜单只在 editing 下可达，
    // 没有入口就等于把这两个回调做成死代码。入口放在内容区内，不碰顶栏。
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _homeEditButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _homeEditButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_homeEditButton setTitle:@"编辑" forState:UIControlStateNormal];
    _homeEditButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _homeEditButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_homeEditButton addTarget:self action:@selector(toggleHomeGridEditing)
              forControlEvents:UIControlEventTouchUpInside];

    _homeAddButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _homeAddButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_homeAddButton setTitle:@"＋ 卡片" forState:UIControlStateNormal];
    _homeAddButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _homeAddButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentTrailing;
    [_homeAddButton addTarget:self action:@selector(presentHomeCardPicker)
             forControlEvents:UIControlEventTouchUpInside];

    [header addSubview:_homeEditButton];
    [header addSubview:_homeAddButton];

    // ---- 网格本体 ----
    _homeGridView = [[A2HomeGridView alloc] initWithFrame:CGRectZero];
    _homeGridView.translatesAutoresizingMaskIntoConstraints = NO;
    _homeGridView.delegate = self;

    [_homeContentStack addArrangedSubview:header];
    [_homeContentStack addArrangedSubview:_homeGridView];

    // ★视图层级★：叠在背景之上；不盖顶栏、不盖右栏（右边界贴右栏左沿）。
    [self.view insertSubview:_homeContentContainer aboveSubview:_backgroundView];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    [constraints addObjectsFromArray:@[
        [_homeContentContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_homeContentContainer.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_homeContentContainer.trailingAnchor constraintEqualToAnchor:_panelContainer.leadingAnchor],
        [_homeContentContainer.bottomAnchor constraintEqualToAnchor:
            self.view.safeAreaLayoutGuide.bottomAnchor],

        [_homeContentStack.topAnchor constraintEqualToAnchor:_homeContentContainer.topAnchor],
        [_homeContentStack.leadingAnchor constraintEqualToAnchor:_homeContentContainer.leadingAnchor],
        [_homeContentStack.trailingAnchor constraintEqualToAnchor:_homeContentContainer.trailingAnchor],
        [_homeContentStack.bottomAnchor constraintEqualToAnchor:_homeContentContainer.bottomAnchor],

        [header.heightAnchor constraintEqualToConstant:A2MinTouchTarget],
        [_homeEditButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_homeEditButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_homeAddButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_homeAddButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    [NSLayoutConstraint activateConstraints:constraints];
    self.homeContentConstraints = constraints;

    // ---- 数据：方案来自 A2HomeStore（唯一落盘入口），这里不解析 JSON ----
    _homeDocument = [A2HomeStore.shared loadDocument];
    A2HomeProfile *profile = _homeDocument.activeProfile;
    _homeGridView.profile = profile;   // setter 内部 reloadCards

    if (A2HomeStore.shared.isReadOnly) {
        // 只读：照常渲染，但不许写（commitHomeDocumentChange 也会拦一道）。
        _homeGridView.bannerText = @"当前布局由更新版本创建，只读：改动不会保存";
    } else if (A2HomeStore.shared.isLoadedFromBackup) {
        _homeGridView.bannerText = @"已从备份恢复主页布局";
    }

    [self applyTheme];
    [A2Log criterion:@"[A2-HOME] 主页网格启用：方案『%@』%lu 张卡，只读=%@",
     profile.name ?: @"(未命名)", (unsigned long)profile.cards.count,
     A2HomeStore.shared.isReadOnly ? @"是" : @"否"];
}

- (void)teardownHomeGridContent {
    if (_homeContentContainer == nil) return;   // 幂等：本来就是经典模式

    // 先落盘：切回经典不该丢掉刚拖出来的顺序（250ms 合并窗口里可能还没写）。
    [A2HomeStore.shared flush];

    if (_homeContentConstraints.count > 0) {
        // 约束由 self.view 持有，不显式停用的话，下次重建会拿旧锚点再激活一次。
        [NSLayoutConstraint deactivateConstraints:_homeContentConstraints];
        [_homeContentConstraints removeAllObjects];
    }
    _homeGridView.delegate = nil;
    [_homeContentContainer removeFromSuperview];

    _homeContentContainer = nil;
    _homeContentStack = nil;
    _homeGridView = nil;
    _homeEditButton = nil;
    _homeAddButton = nil;
    _homeDocument = nil;

    [A2Log log:@"[A2-HOME] 主页网格关闭：回到经典三区"];
}

- (void)toggleHomeGridEditing {
    if (_homeGridView == nil) return;
    BOOL editing = !_homeGridView.isEditing;
    _homeGridView.editing = editing;
    [_homeEditButton setTitle:(editing ? @"完成" : @"编辑") forState:UIControlStateNormal];
    [A2Log log:@"[A2-HOME] 网格编辑态=%@", editing ? @"开" : @"关"];
}

- (void)presentHomeCardPicker {
    A2HomeProfile *profile = _homeDocument.activeProfile;
    if (profile == nil) return;

    A2HomeWidgetPickerViewController *picker =
        [[A2HomeWidgetPickerViewController alloc] initWithProfile:profile replacingCardID:nil];
    // picker 自己在 finishWithCard: 里 pop / dismiss，这里只管把卡落进方案并保存。
    __weak typeof(self) weakSelf = self;
    picker.onPickCard = ^(A2HomeCard *card) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || card == nil) return;
        [profile.cards addObject:card];
        [self->_homeGridView reloadCards];
        [self commitHomeDocumentChange];
        [A2Log log:@"[A2-HOME] 网格加卡 kind=%@，共 %lu 张",
                    A2HomeCardKindToken(card.kind), (unsigned long)profile.cards.count];
    };
    [self pushScreen:picker style:A2TransitionStyleScaleFade];
}

- (void)activateHomeCard:(A2HomeCard *)card {
    if (card == nil) return;

    switch (card.kind) {
        case A2HomeCardKindShortcutVersion:
        case A2HomeCardKindPinnedVersions:
        case A2HomeCardKindRecent: {
            // 这三类都是「启动某个版本」：引用解析不到就软失败提示，绝不删卡。
            if (card.target == nil) { [self openVersions]; return; }
            A2HomeResolvedTarget *resolved =
                [A2HomeRuntime.shared resolveTarget:card.target kind:card.kind];
            if (!resolved.isUsable || resolved.version == nil) {
                [A2Toast show:(resolved.message.length > 0 ? resolved.message : @"这个版本已经不在了")
                       inView:self.view];
                return;
            }
            [self activateHomeVersion:resolved.version];
            return;
        }
        case A2HomeCardKindShortcutWorld:
        case A2HomeCardKindShortcutServer:
        case A2HomeCardKindPinnedWorlds:
        case A2HomeCardKindPinnedServers:
            // 存档 / 服务器的真实入口本版还没有（与右栏「文件管理尚未接入」同一口径）。
            [A2Toast show:@"存档 / 服务器管理尚未接入" inView:self.view];
            return;
        case A2HomeCardKindGreeting:
        case A2HomeCardKindCalendar:
            return;   // 纯展示卡：点本体不跳转
        case A2HomeCardKindShortcutCustom: {
            NSString *reason = nil;
            if (![card.options isJumpUsableWithReason:&reason]) {
                [A2Toast show:(reason.length > 0 ? reason : @"这张卡的跳转目标不可用")
                       inView:self.view];
                return;
            }
            [self jumpToHomePage:card.options.jumpPage urlString:card.options.jumpURLString];
            return;
        }
        default:
            break;
    }

    // 走到这里 = 本版没有对应快捷入口的卡（插件卡）。只如实说明，不假装执行。
    [A2Log criterion:@"[A2-HOME] 卡片激活暂不支持：kind=%ld（插件卡）", (long)card.kind];
    [A2Toast show:@"插件卡片暂不支持（需要 P3 运行时）" inView:self.view];
}

- (void)jumpToHomePage:(A2HomeJumpPage)page urlString:(nullable NSString *)urlString {
    switch (page) {
        case A2HomeJumpPageVersions:        [self openVersions]; return;
        case A2HomeJumpPageVersionSettings: [self openVersionSettings]; return;
        case A2HomeJumpPageDownload:        [self openDownload]; return;
        case A2HomeJumpPageAccount:         [self openAccount]; return;
        case A2HomeJumpPageMultiplayer:     [self openMultiplayer]; return;
        case A2HomeJumpPageFiles:           [self openFiles]; return;
        case A2HomeJumpPageSettings:        [self openSettings]; return;
        case A2HomeJumpPageUnknown:         break;
    }

    // 网址卡：只认 http/https（白名单在 A2HomeWebURLFromString 里，这里不重复判 scheme）。
    NSURL *url = A2HomeWebURLFromString(urlString);
    if (url != nil) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        return;
    }
    [A2Toast show:@"这张卡的跳转目标不可用" inView:self.view];
}

/// 网格里「启动某个版本」的唯一落点：切换当前版本 → 复用本 VC 的 launchGame。
/// 不新造启动链：看门狗、[A2-LAUNCH] 判据行、A2LaunchSession 全部沿用现成那份。
- (void)activateHomeVersion:(A2Version *)version {
    if (version == nil) return;
    if (version != A2VersionManager.shared.currentVersion) {
        // 切不过去就停在这里说清楚 —— 不能拿「上一个版本」假装启动了用户点的那一个。
        if (![A2VersionManager.shared selectCurrentVersion:version]) {
            [A2Toast show:@"这个版本当前不可用（可能已损坏或被删除）" inView:self.view];
            return;
        }
    }
    [self launchGame];
}

- (void)confirmRemoveHomeCard:(A2HomeCard *)card {
    if (card == nil) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"移除卡片"
                                            message:[NSString stringWithFormat:
                       @"「%@」会从当前方案里删掉，之后可以用「＋ 卡片」重新加回来。",
                       A2HomeKindDisplayName(card.kind)]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"移除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) return;
        [self removeHomeCard:card];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 移除一张卡：只改内存里的方案 + 走 A2HomeStore 的合并窗口落盘。
/// 特意**不**新增存储能力 —— 方案本来就是 store 管的那一篇文档。
- (void)removeHomeCard:(A2HomeCard *)card {
    A2HomeProfile *profile = _homeDocument.activeProfile;
    NSUInteger index = [profile.cards indexOfObjectIdenticalTo:card];
    if (index == NSNotFound) return;

    [profile.cards removeObjectAtIndex:index];
    [_homeGridView reloadCards];
    [self commitHomeDocumentChange];
    [A2Log log:@"[A2-HOME] 移除卡片 kind=%@，剩余 %lu 张",
                A2HomeCardKindToken(card.kind), (unsigned long)profile.cards.count];
}

- (void)commitHomeDocumentChange {
    if (_homeDocument == nil) return;
    if (A2HomeStore.shared.isReadOnly) {
        _homeGridView.bannerText = @"当前布局只读：改动不会保存";
        [A2Log criterion:@"[A2-HOME] 只读模式，拒绝写入布局改动"];
        return;
    }
    [A2HomeStore.shared scheduleSaveDocument:_homeDocument];
}

- (void)handleHomeSettingsChanged:(NSNotification *)note {
    NSString *key = note.userInfo[A2SettingsChangedKeyKey];
    if (![key isEqualToString:A2HomeSettingsKeyGridEnabled]) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleHomeSettingsChanged:note]; });
        return;
    }
    // 热应用：建 / 拆内容区，再按新的落点重画插件分区（不用杀进程）。
    [self refreshHomeGridMode];
    [self reloadPluginInsertions];
    [self applyTheme];
}

#pragma mark - A2HomeGridViewDelegate

- (void)homeGridViewDidRequestAddCard:(A2HomeGridView *)gridView {
    [self presentHomeCardPicker];
}

- (void)homeGridView:(A2HomeGridView *)gridView didActivateCard:(A2HomeCard *)card {
    [self activateHomeCard:card];
}

- (void)homeGridView:(A2HomeGridView *)gridView didActivateVersion:(A2Version *)version {
    [self activateHomeVersion:version];
}

- (void)homeGridView:(A2HomeGridView *)gridView didRequestMenuForCard:(A2HomeCard *)card {
    [self confirmRemoveHomeCard:card];
}

- (void)homeGridViewDidChangeLayout:(A2HomeGridView *)gridView {
    // profile.cards / 坐标已由网格就地更新（显示坐标不落盘），这里只负责保存。
    [self commitHomeDocumentChange];
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
    // 主界面要能看出游戏数据放在哪个目录 —— 只给名字（如 minecraft），
    // 不给整条长路径（那条路径在版本管理左栏的副标题里）。
    [parts addObject:[NSString stringWithFormat:@"目录·%@", A2GamePath.gameHomeDisplayName]];
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
    BOOL chainOn = [A2LaunchSession runtimeChainEnabled];
    A2Version *cur = A2VersionManager.shared.currentVersion;
    // ★点下去第一行就要有★：开关状态 + 当前版本，免得“点了没反应、日志也没有”。
    [A2Log log:@"[A2-LAUNCH] tap：启动链开关=%@ 版本=%@",
                 chainOn ? @"开" : @"关", cur.name ?: @"(未选版本)"];
    _launchButton.loading = YES;

    __block BOOL finished = NO;
    __weak typeof(self) weakSelf = self;
    // ★看门狗★：链在后台队列里跑（建 VM 可能卡住），不能无限转圈 ——
    //   90 秒还没回来就如实收尾并提示；最后一步看上面那条 [A2-CHAIN]/[A2-LAUNCH] 行。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (finished) return;
        [A2Log log:@"[A2-LAUNCH] ★看门狗：90 秒未返回★（最后一步见上一条 [A2-CHAIN]/[A2-LAUNCH] 判据行）"];
        weakSelf.launchButton.loading = NO;
        [A2Toast show:@"启动链 90 秒没有返回，已停止等待（详情见日志）" inView:weakSelf.view];
    });

    // 自研启动链默认关 ⇒ 结果恒为「未启用」，下面仍弹原来那句提示，**开箱行为不变**。
    [A2LaunchSession startCurrentVersionWithCompletion:^(A2LaunchSessionResult *result) {
        finished = YES;
        self.launchButton.loading = NO;
        if (result.started) {
            // ★2026-10-18★ 启动成功 ⇒ 不再弹提示（游戏视图会整屏盖上来）；
            //   只记一行日志，方便判据。
            [A2Log log:@"[A2-LAUNCH] 启动链完成，已交棒给游戏视图（不再弹提示）"];
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


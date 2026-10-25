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
#import "A2LaunchSplashView.h"
#import "A2JVMRunningViewController.h"
#import "A2Dialog.h"
#import "A2TaskLogCard.h"
#import "A2TaskLogOutput.h"
#import "A2InstallProgressDialog.h"
#import "A2GameLaunchCoordinator.h"
#import "ios_uikit_bridge.h"
#import "A2JREManager.h"
#import "A2Logger.h"
#import "A2DownloadTask.h"
#import "A2DownloadTaskCenter.h"
#import "A2DownloadPanel.h"
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
@property (nonatomic, strong, nullable) A2LaunchSplashView *launchSplash;
/// 启动进度弹窗（ZL2 的 TitleTaskFlowDialog 形式）
@property (nonatomic, strong, nullable) A2TaskLogCard *launchCard;
@property (nonatomic, strong, nullable) A2TaskLogOutput *launchLog;
/// 下载进度弹窗（ZL2 的 TaskFlowDialog 形式）
@property (nonatomic, strong, nullable) A2InstallProgressDialog *launchDialog;
@property (nonatomic, strong, nullable) id launchProgressObserver;
@property (nonatomic, copy, nullable) NSString *lastSpeedText;

/// JVM 运行中界面（对照 ZL2 的 JVMScreen）
@property (nonatomic, strong, nullable) A2JVMRunningViewController *jvmScreen;
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
    [self setupDownloadPanel];
}

/// 主页不再显示下载进度。
///
/// 之前我在这里挂了个「有下载任务就弹出 A2InstallProgressDialog」的逻辑，
/// 那是错的：
///   1. 下载不是主页发起的，进度应该由发起方（版本安装页 / 资源详情页）显示
///   2. 它会在用户浏览主页时强行弹窗
///   3. 与发起方自己的进度弹窗冲突（两个弹窗叠在一起）
///
/// 保留观察者只用于「点了打卡/更新」这类主页自己的动作。
- (void)setupDownloadPanel {
}

- (void)refreshDownloadPanel {
}

/// 是否跳过完整性检查。
///
/// 版本详情页的「跳过完整性检查」开关会写进
/// version.isolation.skipGameIntegrityCheck（存在 .air_version/config.json），
/// 这里读它。之前写死 NO，开关等于没接。
- (BOOL)shouldSkipIntegrityCheck {
    A2Version *v = A2VersionManager.shared.currentVersion;
    if (!v) return NO;
    return (v.isolation.skipGameIntegrityCheck == A2SettingStateEnable);
}

- (void)launchGame {
    // 当前选中的版本
    A2Version *current = A2VersionManager.shared.currentVersion;
    if (!current) {
        [A2Toast show:@"还没有选择版本" inView:self.view];
        return;
    }
    if (!current.isValid) {
        [A2Toast show:@"该版本不完整，请重新安装" inView:self.view];
        return;
    }

    _launchButton.loading = YES;

    // 启动进度 —— 用**侧边小卡片**，不是弹窗、不是全屏遮罩。
    //
    // 对照 ZL2：检查阶段（账号/版本/渲染器）在右上角挂一张
    // TaskLogCard，显示当前任务 + 细进度条，检查完自动消失。
    // 用户可以全程继续操作界面，不用点「取消」才能回退。
    //
    // 我前两版做错了两回：
    //   ① 做成全屏 A2LaunchSplashView（自己设计的，不是 ZL2）
    //   ② 改成居中弹窗（那是「安装游戏」用的，不是启动）
    A2TaskLogCard *card = [A2TaskLogCard presentInView:self.view
                                                 title:@"启动检查"];
    [card updateTaskName:@"准备中…" progress:-1 rate:nil];
    self.launchCard = card;

    __weak typeof(self) weakSelf = self;
    // 订阅编排器进度 → 更新卡片
    self.launchProgressObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:A2LaunchProgressDidChangeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.launchCard) return;

        A2LaunchProgress *pr = note.userInfo[@"progress"];
        if (![pr isKindOfClass:A2LaunchProgress.class]) return;

        NSString *rate = nil;
        if (pr.task == A2LaunchTaskVerifyFiles && self.lastSpeedText.length) {
            rate = self.lastSpeedText;
        }
        [self.launchCard updateTaskName:pr.message progress:pr.taskFraction rate:rate];
        [self.launchCard appendLog:pr.message];
    }];

    // 注意：weakSelf 已在上面订阅通知时定义，这里不要再定义一次
    // 签名对齐 ZL2 的 GameLaunchFlow：账号校验与文件校验分开跳过。
    // 这里都不跳过 —— 走完整流程（检查 → 补全 → 准备 JRE）。
    [[A2GameLaunchCoordinator shared] launchVersion:current.name
                                 skipAccountRefresh:NO
                                skipIntegrityCheck:[self shouldSkipIntegrityCheck]]
                                         completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        self.launchButton.loading = NO;

        if (!success) {
            // 失败：弹窗里显示原因（ZL2 也是「弹窗 + 错误信息」）
            [self.launchCard finishWithState:A2TaskCardStateFailed
                                     message:(error.localizedDescription ?: @"启动失败")];
            [self.launchCard dismissAfterDelay:3.0];
            self.launchCard = nil;

            [A2Dialog showInView:self.view
                           title:@"启动失败"
                         message:(error.localizedDescription ?: @"未知错误")
                         actions:@[
                [A2DialogAction actionWithTitle:@"取消" style:A2DialogActionStyleText handler:nil],
                [A2DialogAction actionWithTitle:@"重试" style:A2DialogActionStyleFilled handler:^{
                    __strong typeof(weakSelf) self2 = weakSelf;
                    [self2 launchGame];
                }],
            ]];
            return;
        }

        // 前置检查全部通过 → 拉起 JVM。
        //
        // 启动方式与 Air1 一致：把 metadata 交给 UIKit bridge，
        // 它会把根 VC 换成 SurfaceViewController（游戏画面宿主），
        // 那个类的 viewDidLoad 里才真正 launchJVM。
        A2Account *account = A2AccountManager.shared.currentAccount;
        NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
        metadata[@"accountId"] = account.profileID.length ? account.profileID
                                                          : (account.username ?: @"Player");
        metadata[@"versionName"] = current.name;
        metadata[@"gameHome"] = A2VersionManager.shared.gameHome;

        NSString *mc = current.versionInfo.minecraftVersion ?: current.name;
        A2JRE *jre = [A2JREManager.shared jreForVersionName:current.name mcVersion:mc];
        if (jre.path.length) metadata[@"javaHome"] = jre.path;

        [A2Logger info:@"Launch"
               message:[NSString stringWithFormat:
                        @"前置检查通过 → 拉起 JVM（版本=%@ Java=%@ 账号=%@）",
                        current.name, jre.displayName ?: @"?", metadata[@"accountId"]]];

        UIWindow *window = self.view.window;
        if (!window) { window = UIApplication.sharedApplication.keyWindow; }
        if (!window) {
            [self.launchCard dismissAfterDelay:0];
            self.launchCard = nil;
            return;
        }

        // 三段式（对照 ZL2）：
        //   1. 启动进度弹窗   ← 现在这个，检查完就关
        //   2. JVMScreen      ← 键盘工具条 + 等待气泡
        //   3. GameScreen     ← 控件 + 悬浮球
        [self.launchCard finishWithState:A2TaskCardStateSuccess message:@"检查通过"];
        [self.launchCard dismissAfterDelay:1.0];
        self.launchCard = nil;

        // 检查通过 → 直接切到 JVMScreen（ZL2 也是这样，没有额外过渡）
        {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            A2JVMRunningViewController *jvm = [[A2JVMRunningViewController alloc] init];
            jvm.view.frame = self.view.bounds;
            jvm.view.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                      | UIViewAutoresizingFlexibleHeight;
            [self.view addSubview:jvm.view];
            [self addChildViewController:jvm];
            [jvm didMoveToParentViewController:self];
            self.jvmScreen = jvm;
        }

        UIKit_launchMinecraftSurfaceVC(window, metadata);
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


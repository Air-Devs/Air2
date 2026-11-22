//
//  PLCrashView.m
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
//
#import "PLCrashView.h"
// ★ [GLASS-LIQUID] 材质统一走风格层(AmeGlassEffect):iOS≥26 ⇒ 系统 UIGlassEffect
#import "UIKit+GlassSurface.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "A2LogUploader.h"

/// 取本地化文案；缺词时用中文 fallback。
///
/// 重要：localize(key, comment) 的第二个参数是 **comment**，不是 fallback；
/// 没有对应 .strings 时 localize 会原样返回 key（例如 "crash.title.jvm_exit"）。
/// 崩溃页是最后一道兜底 UI，绝不能让用户看到 key 字面量，
/// 所以这里统一用「有翻译用翻译、没翻译用中文兜底」的入口。
NSString *PLCrashLocalizedText(NSString *key, NSString *fallback) {
    NSString *value = localize(key, nil);
    if (value.length == 0 || [value isEqualToString:key]) {
        return fallback.length > 0 ? fallback : key;
    }
    return value;
}

@interface PLCrashView ()
// 数据
@property (nonatomic, assign) int exitCode;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customReason;

// 崩溃类型分析（参照 HMCL 的崩溃分析器，提供更精确的崩溃分类和建议）
typedef NS_ENUM(NSInteger, CrashType) {
    CrashTypeNormal = 0,         // 正常退出
    CrashTypeOOM,                // 内存不足
    CrashTypeSegfault,           // 段错误（JNI/原生库）
    CrashTypeAbort,              // 程序异常终止
    CrashTypeTerminated,         // 被外部信号终止
    CrashTypeModConflict,        // Mod 冲突
    CrashTypeMissingLibrary,     // 缺失库文件
    CrashTypeJavaVersionMismatch,// Java 版本不匹配
    CrashTypeRendererError,      // 渲染器错误
    CrashTypeModLoadingFailure,  // Mod 加载失败
    CrashTypeJavaException,      // Java 异常
    CrashTypeJVMExit,            // JVM 非 0 退出（非信号，日志里也没有可识别特征）
    CrashTypeUnknown             // 未知错误
};
@property (nonatomic, assign) CrashType crashType;
@property (nonatomic, strong, nullable) NSString *crashDetail; // 崩溃详情（从日志提取的关键行）

// UI 组件
@property (nonatomic, strong) UIScrollView *mainScrollView;
@property (nonatomic, strong) UIStackView *mainStackView;
@property (nonatomic, strong) UIView *errorCardView;
@property (nonatomic, strong) UIImageView *errorIconView;
@property (nonatomic, strong) UILabel *errorTitleLabel;
@property (nonatomic, strong) UILabel *errorCodeLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UILabel *oomSuggestionLabel;
// 快速修复建议卡片（参照 FCL/HMCL 的"快速修复"面板）
@property (nonatomic, strong) UIView *suggestionsCardView;
@property (nonatomic, strong) UILabel *suggestionsTitleLabel;
@property (nonatomic, strong) UIStackView *suggestionsStackView;
@property (nonatomic, strong) UIView *logCardView;
@property (nonatomic, strong) UILabel *logTitleLabel;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logPlaceholderLabel;
@property (nonatomic, strong) UIButton *restartButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *githubButton;
@property (nonatomic, strong) UIButton *fullLogButton;
@property (nonatomic, strong) UIButton *exitButton;
/// 上传日志并复制链接（对照 ZL2 ErrorScreen 的「分享链接」动作）。
/// 旧实现只在 setupButtonsIntoContainer 里用了 _uploadButton 这个 ivar，
/// 类扩展里没有声明、uploadLogAndCopyLink 也没有实现 —— 一旦按钮被点中
/// 就是 unrecognized selector。这里补齐声明与实现。
@property (nonatomic, strong) UIButton *uploadButton;
/// 上传中标志：防止连点重复上传
@property (nonatomic, assign) BOOL uploadInFlight;
// 响应式布局容器：内容列 + 动作列
@property (nonatomic, strong) UIStackView *contentStackView;
@property (nonatomic, strong) UIStackView *actionStackView;
@property (nonatomic, strong) UILabel *crashTypeLabel;
// 横屏时动作列宽度约束（约 30%），竖屏失活
@property (nonatomic, strong) NSLayoutConstraint *actionWidthConstraint;
// 当前是否横屏布局
@property (nonatomic, assign) BOOL landscapeLayout;
// 错误卡片顶部红色 accent 条
@property (nonatomic, strong) CAGradientLayer *accentGradientLayer;
// 建议卡片顶部黄色 accent 条
@property (nonatomic, strong) CAGradientLayer *suggestionAccentLayer;
// 日志卡片高度约束（根据屏幕高度动态调整）
@property (nonatomic, strong) NSLayoutConstraint *logCardHeightConstraint;
@end

@implementation PLCrashView

// 当前正在显示的崩溃 VC 实例（单例）
static PLCrashView *currentCrashVC = nil;
// 崩溃页专用窗口（见 +presentCrashViewController: 注释）
static UIWindow *crashWindow = nil;
// 崩溃页出现前的 key window，关闭崩溃页时还原
static UIWindow *previousKeyWindow = nil;
static NSString *const kGitHubIssuesURL = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/issues";

#pragma mark - Crash Window

/// 取当前可用的 UIWindowScene（前台优先，后台兜底）。
///
/// 崩溃可能发生在 App 被切到后台之后（JIT 等待 / 用户切走再回来），
/// 旧实现只枚举 ForegroundActive/Inactive，找不到 key window 就 return ——
/// 崩溃页被静默丢弃。这里补后台 scene 兜底。
+ (UIWindowScene *)activeWindowScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive ||
            windowScene.activationState == UISceneActivationStateForegroundInactive) {
            return windowScene;
        }
        if (fallback == nil) fallback = windowScene;
    }
    return fallback;
}

/// 用独立 UIWindow 承载崩溃页（对照 ZL2 用独立 ErrorActivity 承载崩溃页的思路）。
///
/// 为什么不直接 present 在游戏 VC 上：
///   JVM 退出路径里 JavaLauncher 会先调 UIKit_returnToSplitView() 换根，
///   再调 handleExitCode: 弹崩溃页。两条都是 dispatch_async(main)，
///   换根动画没结束时 present 出来的 VC 会跟着旧 root 一起被丢掉。
///   独立 window（windowLevel = Alert + 1）不参与 rootViewController 替换，
///   这也让崩溃页在「游戏 surface 被销毁」后仍然留在屏幕上。
+ (void)presentCrashViewController:(PLCrashView *)crashVC {
    UIWindowScene *scene = [self activeWindowScene];
    if (scene != nil) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                previousKeyWindow = window;
                break;
            }
        }
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.frame = UIScreen.mainScreen.bounds;
        window.windowLevel = UIWindowLevelAlert + 1;
        window.backgroundColor = [UIColor clearColor];
        window.opaque = NO;
        // 崩溃页是深色玻璃风格（白色 8% 卡片 + labelColor 文字），
        // 独立窗口里没有游戏画面可透出，强制深色保证对比度与可读性。
        window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        window.rootViewController = crashVC;
        crashWindow = window;
        [window makeKeyAndVisible];
        NSLog(@"[PLCrashView] crash window presented on scene %@", NSStringFromClass(scene.class));
        return;
    }

    // 兜底：没有可用 scene（理论上 iOS 14+ 不会发生）时退回模态呈现
    UIWindow *keyWindow = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    UIViewController *rootVC = keyWindow.rootViewController ?: UIApplication.sharedApplication.delegate.window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    if (rootVC == nil) {
        NSLog(@"[PLCrashView] no window/rootVC, crash UI dropped");
        return;
    }
    crashVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    crashVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [rootVC presentViewController:crashVC animated:NO completion:nil];
    NSLog(@"[PLCrashView] crash VC presented modally on %@", NSStringFromClass(rootVC.class));
}

/// 关闭并释放崩溃窗口。窗口的实际隐藏放到下一个 runloop，
/// 避免在崩溃 VC 自己的方法里释放掉正在执行的对象（use-after-free）。
+ (void)teardownCrashWindow {
    UIWindow *window = crashWindow;
    UIWindow *restore = previousKeyWindow;
    crashWindow = nil;
    previousKeyWindow = nil;
    currentCrashVC = nil;
    if (window == nil) {
        if (restore != nil) [restore makeKeyWindow];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        window.hidden = YES;
        if (restore != nil && !restore.hidden) {
            [restore makeKeyWindow];
        }
    });
}

#pragma mark - Public Methods

+ (void)showWithExitCode:(int)exitCode {
    [self showWithExitCode:exitCode customTitle:nil customReason:nil];
}

+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason {
    // 正常退出（返回启动器）绝不弹崩溃页。
    // 调用链上游（PLLogOutputView.handleExitCode:）已经过滤过 0，
    // 这里再兜一层，防止别处误调。
    if (exitCode == 0) {
        NSLog(@"[PLCrashView] exit code 0 (normal exit), skip crash UI");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        // 如果已经存在崩溃界面，先拆掉，避免叠加
        if (currentCrashVC) {
            [self teardownCrashWindow];
        }

        PLCrashView *crashVC = [[PLCrashView alloc] init];
        crashVC.exitCode = exitCode;
        crashVC.customTitle = customTitle;
        crashVC.customReason = customReason;
        currentCrashVC = crashVC;
        [self presentCrashViewController:crashVC];
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _exitCode = 0;
        _customTitle = nil;
        _customReason = nil;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [self setupBackground];
    // 先分析崩溃类型，setupUI 中的建议卡片依赖此结果
    [self analyzeCrashType];
    [self setupUI];
    [self loadLogContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 横屏 / 竖屏两套排布（对照 ZL2 ErrorScreen.kt 的方向分支）
    [self applyResponsiveLayout];
    // 根据屏幕高度动态调整日志卡片高度，避免小屏挤压按钮或大屏浪费空间
    [self adjustLogCardHeight];
    // 更新错误卡片顶部红色 accent 条的 frame
    if (_accentGradientLayer) {
        _accentGradientLayer.frame = CGRectMake(0, 0, _errorCardView.bounds.size.width, 2);
    }
    // 更新建议卡片顶部黄色 accent 条的 frame
    if (_suggestionAccentLayer && _suggestionsCardView) {
        _suggestionAccentLayer.frame = CGRectMake(0, 0, _suggestionsCardView.bounds.size.width, 2);
    }
}

/// 按当前方向切换主 StackView 的排布。
///
/// 横屏（游戏主场景）：axis = horizontal，内容列左、动作列右，动作列约 30% 宽；
/// 竖屏（防御性兜底）：axis = vertical，内容在上、动作在下，动作列占满宽度。
/// 切换只改 axis 和一条宽度约束，不重建视图。
- (void)applyResponsiveLayout {
    if (_mainStackView == nil || _actionStackView == nil) return;
    BOOL landscape = self.view.bounds.size.width >= self.view.bounds.size.height;
    if (landscape == _landscapeLayout && _actionWidthConstraint.active == landscape) {
        return;
    }
    _landscapeLayout = landscape;
    _mainStackView.axis = landscape ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    _mainStackView.alignment = landscape ? UIStackViewAlignmentTop : UIStackViewAlignmentFill;
    _actionWidthConstraint.active = landscape;
    // 竖屏时动作列排在内容之后，给一组更紧凑的按钮高度；
    // 横屏保持 48pt，手指更容易点中。
    CGFloat buttonHeight = landscape ? 48.0 : 50.0;
    for (UIView *view in _actionStackView.arrangedSubviews) {
        if (![view isKindOfClass:UIButton.class]) continue;
        for (NSLayoutConstraint *constraint in view.constraints) {
            if (constraint.firstAttribute == NSLayoutAttributeHeight) {
                constraint.constant = buttonHeight;
                break;
            }
        }
    }
    NSLog(@"[PLCrashView] responsive layout -> %@ (%.0fx%.0f)",
          landscape ? @"landscape" : @"portrait",
          self.view.bounds.size.width, self.view.bounds.size.height);
}

#pragma mark - Background

- (void)setupBackground {
    // 背景走 Air2 的主题色板（A2ThemeManager），不再用 Air1 的壁纸透出
    self.view.backgroundColor = [UIColor clearColor];

    // 如果没有自定义背景，使用系统材质毛玻璃作为回退（自适应深浅色）
    UIBlurEffect *blurEffect;
    if (@available(iOS 13.0, *)) {
        // ★ [GLASS-LIQUID] 走风格层:iOS≥26 ⇒ 系统 UIGlassEffect
        blurEffect = (UIBlurEffect *)AmeGlassEffect(UIBlurEffectStyleSystemMaterial);
    } else {
        blurEffect = (UIBlurEffect *)AmeGlassEffect(UIBlurEffectStyleLight);
    }
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:blurView];
    [self.view sendSubviewToBack:blurView];

    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

#pragma mark - UI Setup

- (void)setupUI {
    // ============================================================
    // 崩溃界面布局（对照 ZL2 ErrorScreen.kt 的横屏 / 竖屏两套排布）
    // ============================================================
    // ZL2 的 ErrorScreen 用 Configuration.orientation 分成两套：
    //   横屏 ErrorScreenLandscape：左 70% 内容卡片（可滚动）+ 右 30% 动作列
    //                              （顶部崩溃类型，底部四个动作）
    //   竖屏 ErrorScreenPortrait ：内容纵向滚动，动作收进顶栏菜单
    //
    // Air2 是横屏为主的游戏场景（A2AppDelegate 全局锁 Landscape），
    // 所以横屏是主布局：左边错误信息 + 可滚动日志摘要，右边四个动作；
    // 竖屏作为防御性兜底：内容在上、动作在下，同样纵向可滚动。
    //
    // 四个动作严格对齐 ZL2（ErrorScreen.kt ActionLayout）：
    //   上传日志并复制链接（分享链接）/ 分享日志 / 重启 / 退出
    // GitHub Issues 和「查看完整日志」降级为内容区底部的小号文字入口，
    // 不占用主按钮位。
    //
    // 实现方式：一个可切换 axis 的 _mainStackView 装两个子栈 ——
    //   横屏 → axis = horizontal，内容列 70% / 动作列 30%
    //   竖屏 → axis = vertical，内容列在上、动作列在下
    // 避免维护两套 constraint 组，切换时只改 axis 与一条宽度约束。

    // 主滚动视图（内容超出屏幕时可滚动；日志卡片内部还有自己的滚动）
    _mainScrollView = [[UIScrollView alloc] init];
    _mainScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _mainScrollView.alwaysBounceVertical = YES;
    _mainScrollView.showsVerticalScrollIndicator = YES;
    _mainScrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _mainScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_mainScrollView];

    // 主 StackView（axis 由 applyResponsiveLayout 按方向切换）
    _mainStackView = [[UIStackView alloc] init];
    _mainStackView.axis = UILayoutConstraintAxisHorizontal;
    _mainStackView.spacing = 16;
    _mainStackView.alignment = UIStackViewAlignmentTop;
    _mainStackView.distribution = UIStackViewDistributionFill;
    _mainStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainScrollView addSubview:_mainStackView];

    [NSLayoutConstraint activateConstraints:@[
        [_mainScrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [_mainScrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [_mainScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_mainScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_mainStackView.topAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.topAnchor],
        [_mainStackView.bottomAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.bottomAnchor],
        [_mainStackView.leadingAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.leadingAnchor],
        [_mainStackView.trailingAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.trailingAnchor],
        [_mainStackView.widthAnchor constraintEqualToAnchor:_mainScrollView.frameLayoutGuide.widthAnchor],
    ]];

    // StackView 左右留白
    _mainStackView.layoutMargins = UIEdgeInsetsMake(16, 20, 16, 20);
    _mainStackView.layoutMarginsRelativeArrangement = YES;

    // 左侧内容列：错误卡片 + 建议卡片 + 日志卡片 + 次要入口
    _contentStackView = [[UIStackView alloc] init];
    _contentStackView.axis = UILayoutConstraintAxisVertical;
    _contentStackView.spacing = 12;
    _contentStackView.alignment = UIStackViewAlignmentFill;
    _contentStackView.distribution = UIStackViewDistributionFill;
    _contentStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_contentStackView];

    // 右侧动作列：崩溃类型 + 四个动作
    _actionStackView = [[UIStackView alloc] init];
    _actionStackView.axis = UILayoutConstraintAxisVertical;
    _actionStackView.spacing = 10;
    _actionStackView.alignment = UIStackViewAlignmentFill;
    _actionStackView.distribution = UIStackViewDistributionFill;
    _actionStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_actionStackView];

    // 横屏动作列约占 30% 宽（ZL2 是 7:3；中文按钮文字更长，留 30% 防截断）。
    // 优先级 750：窄屏时允许内容列让步，不产生不可满足约束。
    _actionWidthConstraint = [_actionStackView.widthAnchor constraintEqualToAnchor:_mainStackView.widthAnchor multiplier:0.30];
    _actionWidthConstraint.priority = UILayoutPriorityDefaultHigh;
    _actionWidthConstraint.active = YES;

    // 1. 错误信息卡片
    [self setupErrorCard];

    // 2. 快速修复建议卡片（可选，有建议时才创建）
    [self setupSuggestionsCard];

    // 3. 日志摘要卡片（内部 UITextView 可独立滚动）
    [self setupLogCard];
    [_contentStackView addArrangedSubview:_logCardView];

    // 4. 次要入口（GitHub Issues / 完整日志）
    [self setupSecondaryLinks];

    // 5. 四个动作
    [self setupButtonsIntoContainer:_actionStackView];
}

/// 次要入口：GitHub Issues + 查看完整日志。
///
/// 对照 ZL2 竖屏版把「更多」动作收进菜单的思路 —— 这两个是低频动作，
/// 不该和「重启/退出/分享」抢主按钮位，放在内容区底部当文字链接。
- (void)setupSecondaryLinks {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;
    row.alignment = UIStackViewAlignmentFill;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    _githubButton = [self createSecondaryButtonWithTitle:PLCrashLocalizedText(@"crash.github_issue", @"前往 GitHub Issues")
                                                    icon:@"link"
                                                  action:@selector(openGitHubIssues)];
    _fullLogButton = [self createSecondaryButtonWithTitle:PLCrashLocalizedText(@"crash.view_log", @"查看完整日志")
                                                     icon:@"doc.text.magnifyingglass"
                                                   action:@selector(showFullLog)];
    [row addArrangedSubview:_githubButton];
    [row addArrangedSubview:_fullLogButton];
    [row.heightAnchor constraintEqualToConstant:36].active = YES;
    [_contentStackView addArrangedSubview:row];
}

/// 小号文字按钮（内容区底部次要入口）
- (UIButton *)createSecondaryButtonWithTitle:(NSString *)title icon:(NSString *)icon action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    button.layer.cornerRadius = 10;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.titleLabel.font = [UIFont systemFontOfSize:13];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    [button setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:icon withConfiguration:config] forState:UIControlStateNormal];
        button.tintColor = [UIColor secondaryLabelColor];
        button.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    }
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}


- (void)setupErrorCard {
    _errorCardView = [[UIView alloc] init];
    _errorCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _errorCardView.layer.cornerRadius = 16;
    _errorCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _errorCardView.layer.borderWidth = 0.5;
    _errorCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _errorCardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _errorCardView.layer.shadowOffset = CGSizeMake(0, 4);
    _errorCardView.layer.shadowOpacity = 0.12;
    _errorCardView.layer.shadowRadius = 8;
    _errorCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentStackView addArrangedSubview:_errorCardView];
    // 应用毛玻璃效果（适配自定义背景壁纸）
    (void)0;

    // 顶部红色 accent 条（2pt 高的渐变层，从红色到透明）
    _accentGradientLayer = [CAGradientLayer layer];
    _accentGradientLayer.colors = @[
        (__bridge id)[UIColor systemRedColor].CGColor,
        (__bridge id)[[UIColor systemRedColor] colorWithAlphaComponent:0].CGColor,
    ];
    _accentGradientLayer.locations = @[@0.0, @1.0];
    _accentGradientLayer.startPoint = CGPointMake(0.5, 0.0);
    _accentGradientLayer.endPoint = CGPointMake(0.5, 1.0);
    _accentGradientLayer.cornerRadius = 16;
    _accentGradientLayer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_errorCardView.layer addSublayer:_accentGradientLayer];

    // 错误图标
    _errorIconView = [[UIImageView alloc] init];
    _errorIconView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightBold];
        _errorIconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:config];
    }
    _errorIconView.tintColor = [UIColor systemRedColor];
    _errorIconView.contentMode = UIViewContentModeScaleAspectFit;
    [_errorCardView addSubview:_errorIconView];

    // 错误标题
    _errorTitleLabel = [[UILabel alloc] init];
    _errorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorTitleLabel.text = _customTitle.length > 0 ? _customTitle : [self crashTitleText];
    _errorTitleLabel.font = [UIFont boldSystemFontOfSize:18];
    _errorTitleLabel.textColor = [UIColor labelColor];
    _errorTitleLabel.textAlignment = NSTextAlignmentCenter;
    _errorTitleLabel.numberOfLines = 0;
    [_errorCardView addSubview:_errorTitleLabel];

    // 错误代码
    _errorCodeLabel = [[UILabel alloc] init];
    _errorCodeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorCodeLabel.text = [NSString stringWithFormat:@"%@%d",
                            PLCrashLocalizedText(@"crash.error_code", @"退出代码："), _exitCode];
    _errorCodeLabel.font = [UIFont systemFontOfSize:14];
    _errorCodeLabel.textColor = [UIColor secondaryLabelColor];
    _errorCodeLabel.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:_errorCodeLabel];

    // 可能原因
    _reasonLabel = [[UILabel alloc] init];
    _reasonLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _reasonLabel.text = [self crashReasonText];
    _reasonLabel.font = [UIFont systemFontOfSize:13];
    _reasonLabel.textColor = [UIColor secondaryLabelColor];
    _reasonLabel.textAlignment = NSTextAlignmentCenter;
    _reasonLabel.numberOfLines = 0;
    [_errorCardView addSubview:_reasonLabel];

    // 通用约束（图标/标题/代码/原因）
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [_errorIconView.topAnchor constraintEqualToAnchor:_errorCardView.topAnchor constant:16],
        [_errorIconView.centerXAnchor constraintEqualToAnchor:_errorCardView.centerXAnchor],
        [_errorIconView.widthAnchor constraintEqualToConstant:40],
        [_errorIconView.heightAnchor constraintEqualToConstant:40],

        [_errorTitleLabel.topAnchor constraintEqualToAnchor:_errorIconView.bottomAnchor constant:12],
        [_errorTitleLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_errorTitleLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],

        [_errorCodeLabel.topAnchor constraintEqualToAnchor:_errorTitleLabel.bottomAnchor constant:6],
        [_errorCodeLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_errorCodeLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],

        [_reasonLabel.topAnchor constraintEqualToAnchor:_errorCodeLabel.bottomAnchor constant:6],
        [_reasonLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_reasonLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
    ]];

    // OOM 崩溃时显示建议标签，errorCardView 底部锚定到 oomSuggestionLabel 底部
    if ([self isOOMCrash]) {
        _oomSuggestionLabel = [[UILabel alloc] init];
        _oomSuggestionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _oomSuggestionLabel.font = [UIFont systemFontOfSize:12];
        _oomSuggestionLabel.textColor = [UIColor secondaryLabelColor];
        _oomSuggestionLabel.textAlignment = NSTextAlignmentCenter;
        _oomSuggestionLabel.numberOfLines = 0;
        NSString *suggestion = [NSString stringWithFormat:@"%@ %@",
                                PLCrashLocalizedText(@"crash.suggestion", @"建议操作"),
                                PLCrashLocalizedText(@"crash.suggestion.oom", @"iOS 内存限制导致崩溃，建议使用 GetMoreRam (LiveContainer) 解除内存限制后重试")];
        _oomSuggestionLabel.text = suggestion;
        [_errorCardView addSubview:_oomSuggestionLabel];

        [constraints addObjectsFromArray:@[
            [_oomSuggestionLabel.topAnchor constraintEqualToAnchor:_reasonLabel.bottomAnchor constant:8],
            [_oomSuggestionLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
            [_oomSuggestionLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
            [_oomSuggestionLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16],
        ]];
    } else {
        // 非 OOM 时，errorCardView 底部直接锚定到 reasonLabel 底部
        [constraints addObject:[_reasonLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Suggestions Card (快速修复建议卡片)

/// 创建快速修复建议卡片（参照 FCL/HMCL 的"快速修复"面板）
///
/// 根据 analyzeCrashType 分析的崩溃类型，显示对应的修复建议：
/// - OOM: 降低内存分配、移除重量级 Mod、使用 GetMoreRam
/// - Segfault: 切换渲染器、检查原生库兼容性
/// - ModConflict: 移除最近添加的 Mod、检查 Mod 兼容性
/// - MissingLibrary: 重新安装游戏版本、检查库文件
/// - JavaVersionMismatch: 切换 Java 版本
/// - RendererError: 切换渲染器、禁用光影
/// - ModLoadingFailure: 检查 Mod 加载器版本、移除问题 Mod
///
/// 每条建议以一行带图标的文字展示，点击可复制到剪贴板。
- (void)setupSuggestionsCard {
    // 获取当前崩溃类型的建议列表
    NSArray<NSDictionary *> *suggestions = [self suggestionsForCrashType];
    if (suggestions.count == 0) return; // 无建议时不显示卡片

    _suggestionsCardView = [[UIView alloc] init];
    _suggestionsCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    _suggestionsCardView.layer.cornerRadius = 16;
    _suggestionsCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _suggestionsCardView.layer.borderWidth = 0.5;
    _suggestionsCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _suggestionsCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentStackView addArrangedSubview:_suggestionsCardView];
    // 应用毛玻璃效果（适配自定义背景壁纸）
    (void)0;

    // 顶部黄色 accent 条（提示性质，非致命错误）
    CAGradientLayer *suggestionAccent = [CAGradientLayer layer];
    suggestionAccent.colors = @[
        (__bridge id)[UIColor systemYellowColor].CGColor,
        (__bridge id)[[UIColor systemYellowColor] colorWithAlphaComponent:0].CGColor,
    ];
    suggestionAccent.locations = @[@0.0, @1.0];
    suggestionAccent.startPoint = CGPointMake(0.5, 0.0);
    suggestionAccent.endPoint = CGPointMake(0.5, 1.0);
    suggestionAccent.cornerRadius = 16;
    suggestionAccent.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_suggestionsCardView.layer addSublayer:suggestionAccent];
    self.suggestionAccentLayer = suggestionAccent;
    // accent 条 frame 在 viewDidLayoutSubviews 中设置

    // 标题行：图标 + "快速修复建议"
    UIView *titleRow = [[UIView alloc] init];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_suggestionsCardView addSubview:titleRow];

    UIImageView *titleIcon = [[UIImageView alloc] init];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        titleIcon.image = [UIImage systemImageNamed:@"lightbulb.fill" withConfiguration:config];
    }
    titleIcon.tintColor = [UIColor systemYellowColor];
    titleIcon.contentMode = UIViewContentModeScaleAspectFit;
    [titleRow addSubview:titleIcon];

    _suggestionsTitleLabel = [[UILabel alloc] init];
    _suggestionsTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _suggestionsTitleLabel.text = PLCrashLocalizedText(@"crash.quick_fix", @"快速修复建议");
    _suggestionsTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _suggestionsTitleLabel.textColor = [UIColor labelColor];
    [titleRow addSubview:_suggestionsTitleLabel];

    // 建议列表（垂直 StackView）
    _suggestionsStackView = [[UIStackView alloc] init];
    _suggestionsStackView.axis = UILayoutConstraintAxisVertical;
    _suggestionsStackView.spacing = 8;
    _suggestionsStackView.alignment = UIStackViewAlignmentFill;
    _suggestionsStackView.distribution = UIStackViewDistributionFill;
    _suggestionsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_suggestionsCardView addSubview:_suggestionsStackView];

    // 为每条建议创建一行
    for (NSDictionary *suggestion in suggestions) {
        NSString *icon = suggestion[@"icon"];
        NSString *text = suggestion[@"text"];
        UIView *row = [self createSuggestionRowWithIcon:icon text:text];
        [_suggestionsStackView addArrangedSubview:row];
    }

    // 布局约束
    [NSLayoutConstraint activateConstraints:@[
        [titleRow.topAnchor constraintEqualToAnchor:_suggestionsCardView.topAnchor constant:14],
        [titleRow.leadingAnchor constraintEqualToAnchor:_suggestionsCardView.leadingAnchor constant:16],
        [titleRow.trailingAnchor constraintEqualToAnchor:_suggestionsCardView.trailingAnchor constant:-16],
        [titleRow.heightAnchor constraintEqualToConstant:22],

        [titleIcon.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [titleIcon.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
        [titleIcon.widthAnchor constraintEqualToConstant:18],
        [titleIcon.heightAnchor constraintEqualToConstant:18],

        [_suggestionsTitleLabel.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:8],
        [_suggestionsTitleLabel.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
        [_suggestionsTitleLabel.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],

        [_suggestionsStackView.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor constant:12],
        [_suggestionsStackView.leadingAnchor constraintEqualToAnchor:_suggestionsCardView.leadingAnchor constant:16],
        [_suggestionsStackView.trailingAnchor constraintEqualToAnchor:_suggestionsCardView.trailingAnchor constant:-16],
        [_suggestionsStackView.bottomAnchor constraintEqualToAnchor:_suggestionsCardView.bottomAnchor constant:-14],
    ]];
}

/// 创建单条建议行（图标 + 文字）
- (UIView *)createSuggestionRowWithIcon:(NSString *)iconName text:(NSString *)text {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
        icon.image = [UIImage systemImageNamed:iconName withConfiguration:config] ?: [UIImage systemImageNamed:@"chevron.right.circle" withConfiguration:config];
    }
    icon.tintColor = [UIColor systemYellowColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [row addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.topAnchor constraintEqualToAnchor:row.topAnchor constant:2],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    return row;
}

/// 根据崩溃类型返回对应的修复建议列表
- (NSArray<NSDictionary *> *)suggestionsForCrashType {
    NSMutableArray *result = [NSMutableArray array];

    switch (self.crashType) {
        case CrashTypeOOM:
            [result addObject:@{@"icon": @"arrow.down.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.oom_ram", @"降低内存分配（建议 1024-2048MB）")}];
            [result addObject:@{@"icon": @"sparkles", @"text": PLCrashLocalizedText(@"crash.suggestion.oom_getmoream", @"使用 GetMoreRam (LiveContainer) 解除 iOS 内存限制")}];
            [result addObject:@{@"icon": @"trash", @"text": PLCrashLocalizedText(@"crash.suggestion.oom_mods", @"移除重量级 Mod（如光影、高清材质）")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": PLCrashLocalizedText(@"crash.suggestion.oom_restart", @"重启启动器后重试（释放内存碎片）")}];
            break;
        case CrashTypeSegfault:
            [result addObject:@{@"icon": @"cpu", @"text": PLCrashLocalizedText(@"crash.suggestion.segfault_renderer", @"尝试切换渲染器（gl4es / MetalGlues / virgil）")}];
            [result addObject:@{@"icon": @"shield", @"text": PLCrashLocalizedText(@"crash.suggestion.segfault_jit", @"确保 JIT 已启用（TrollStore/SideStore + JIT 权限）")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": PLCrashLocalizedText(@"crash.suggestion.segfault_restart", @"重启启动器后重试")}];
            break;
        case CrashTypeAbort:
            [result addObject:@{@"icon": @"exclamationmark.bubble", @"text": PLCrashLocalizedText(@"crash.suggestion.abort_mods", @"检查 Mod 是否兼容（移除最近添加的 Mod）")}];
            [result addObject:@{@"icon": @"cpu", @"text": PLCrashLocalizedText(@"crash.suggestion.abort_renderer", @"尝试切换渲染器")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": PLCrashLocalizedText(@"crash.suggestion.abort_restart", @"重启启动器后重试")}];
            break;
        case CrashTypeModConflict:
            [result addObject:@{@"icon": @"trash", @"text": PLCrashLocalizedText(@"crash.suggestion.modconflict_remove", @"移除最近添加的 Mod")}];
            [result addObject:@{@"icon": @"info.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.modconflict_check", @"检查 Mod 版本兼容性（Forge/Fabric/API 版本）")}];
            [result addObject:@{@"icon": @"doc.text", @"text": PLCrashLocalizedText(@"crash.suggestion.modconflict_log", @"查看完整日志定位冲突 Mod")}];
            break;
        case CrashTypeMissingLibrary:
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.missinglib_reinstall", @"重新安装当前游戏版本")}];
            [result addObject:@{@"icon": @"folder", @"text": PLCrashLocalizedText(@"crash.suggestion.missinglib_check", @"检查实例目录中的 libraries 文件夹是否完整")}];
            [result addObject:@{@"icon": @"wifi", @"text": PLCrashLocalizedText(@"crash.suggestion.missinglib_network", @"检查网络连接，确保下载源可访问")}];
            break;
        case CrashTypeJavaVersionMismatch:
            [result addObject:@{@"icon": @"hammer", @"text": PLCrashLocalizedText(@"crash.suggestion.javaver_change", @"在设置中切换 Java 版本（8/17/21）")}];
            [result addObject:@{@"icon": @"info.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.javaver_check", @"检查游戏版本要求的 Java 版本")}];
            break;
        case CrashTypeRendererError:
            [result addObject:@{@"icon": @"cpu", @"text": PLCrashLocalizedText(@"crash.suggestion.renderer_switch", @"尝试切换渲染器：gl4es / MetalGlues / virgil")}];
            [result addObject:@{@"icon": @"eye.slash", @"text": PLCrashLocalizedText(@"crash.suggestion.renderer_shader", @"禁用光影包后重试")}];
            [result addObject:@{@"icon": @"arrow.down.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.renderer_resolution", @"降低游戏分辨率缩放比例")}];
            break;
        case CrashTypeModLoadingFailure:
            [result addObject:@{@"icon": @"trash", @"text": PLCrashLocalizedText(@"crash.suggestion.modload_remove", @"移除问题 Mod（查看日志中的错误行）")}];
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.modload_update", @"更新 Mod 加载器（Forge/Fabric/OptiFine）")}];
            [result addObject:@{@"icon": @"info.circle", @"text": PLCrashLocalizedText(@"crash.suggestion.modload_version", @"检查 Mod 是否支持当前 MC 版本")}];
            break;
        case CrashTypeJavaException:
            [result addObject:@{@"icon": @"doc.text", @"text": PLCrashLocalizedText(@"crash.suggestion.java_log", @"查看完整日志定位异常堆栈")}];
            [result addObject:@{@"icon": @"trash", @"text": PLCrashLocalizedText(@"crash.suggestion.java_mods", @"检查 Mod 是否兼容（移除最近添加的 Mod）")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": PLCrashLocalizedText(@"crash.suggestion.java_restart", @"重启启动器后重试")}];
            break;
        case CrashTypeNormal:
        case CrashTypeTerminated:
        case CrashTypeJVMExit:
        case CrashTypeUnknown:
            // 这些类型不显示建议卡片
            break;
    }

    return result;
}

#pragma mark - Crash Type Analysis (崩溃类型分析，参照 HMCL)

/// 分析崩溃类型（基于 exitCode 和日志关键词）
///
/// 参照 HMCL 的崩溃分析器，通过 exitCode 和日志中的异常关键词，
/// 将崩溃分类为 OOM/段错误/Mod 冲突/缺失库/Java 版本不匹配/渲染器错误等类型。
/// 分析结果用于：
/// 1. 在错误卡片中显示更精确的原因描述
/// 2. 在建议卡片中显示对应的修复建议
- (void)analyzeCrashType {
    NSString *logContent = [self readLatestLogForAnalysis];
    NSString *lowerLog = logContent.length > 0 ? [logContent lowercaseString] : @"";

    // 1. 正常退出
    if (_exitCode == 0) {
        self.crashType = CrashTypeNormal;
        self.crashDetail = nil;
        return;
    }

    // 2. OOM（SIGKILL 或日志含 OOM 关键词）
    if ([self isOOMCrash]) {
        self.crashType = CrashTypeOOM;
        self.crashDetail = [self extractLineContaining:@"outofmemory" fromLog:lowerLog] ?: [self extractLineContaining:@"cannot allocate" fromLog:lowerLog];
        return;
    }

    // 3. SIGSEGV 段错误
    if (_exitCode == 11) {
        self.crashType = CrashTypeSegfault;
        self.crashDetail = nil;
        return;
    }

    // 4. SIGABRT
    if (_exitCode == 6) {
        // 检查是否为 Mod 冲突导致
        if ([lowerLog containsString:@"nosuchmethoderror"] || [lowerLog containsString:@"classcastexception"] ||
            [lowerLog containsString:@"illegalaccessexception"] || [lowerLog containsString:@"nosuchfielderror"]) {
            self.crashType = CrashTypeModConflict;
            self.crashDetail = [self extractLineContaining:@"nosuchmethod" fromLog:lowerLog] ?: [self extractLineContaining:@"classcast" fromLog:lowerLog];
        } else if ([lowerLog containsString:@"unsatisfiedlinkerror"] || [lowerLog containsString:@"noclassdeffounderror"]) {
            self.crashType = CrashTypeMissingLibrary;
            self.crashDetail = [self extractLineContaining:@"unsatisfiedlink" fromLog:lowerLog] ?: [self extractLineContaining:@"noclassdef" fromLog:lowerLog];
        } else if ([lowerLog containsString:@"unsupportedclassversionerror"]) {
            self.crashType = CrashTypeJavaVersionMismatch;
            self.crashDetail = [self extractLineContaining:@"unsupportedclassversion" fromLog:lowerLog];
        } else {
            self.crashType = CrashTypeAbort;
            self.crashDetail = nil;
        }
        return;
    }

    // 5. SIGTERM
    if (_exitCode == 15) {
        self.crashType = CrashTypeTerminated;
        self.crashDetail = nil;
        return;
    }

    // 6. 基于日志关键词分析（其他 exitCode）
    // Mod 冲突
    if ([lowerLog containsString:@"nosuchmethoderror"] || [lowerLog containsString:@"classcastexception"] ||
        [lowerLog containsString:@"illegalaccessexception"] || [lowerLog containsString:@"nosuchfielderror"] ||
        [lowerLog containsString:@"duplicate mod"]) {
        self.crashType = CrashTypeModConflict;
        self.crashDetail = [self extractLineContaining:@"nosuchmethod" fromLog:lowerLog] ?: [self extractLineContaining:@"classcast" fromLog:lowerLog];
        return;
    }

    // 缺失库
    if ([lowerLog containsString:@"unsatisfiedlinkerror"] || [lowerLog containsString:@"noclassdeffounderror"] ||
        [lowerLog containsString:@"filenotfoundexception"] && [lowerLog containsString:@"library"]) {
        self.crashType = CrashTypeMissingLibrary;
        self.crashDetail = [self extractLineContaining:@"unsatisfiedlink" fromLog:lowerLog] ?: [self extractLineContaining:@"noclassdef" fromLog:lowerLog];
        return;
    }

    // Java 版本不匹配
    if ([lowerLog containsString:@"unsupportedclassversionerror"] || [lowerLog containsString:@"unsupported major.minor version"]) {
        self.crashType = CrashTypeJavaVersionMismatch;
        self.crashDetail = [self extractLineContaining:@"unsupportedclassversion" fromLog:lowerLog] ?: [self extractLineContaining:@"unsupported major" fromLog:lowerLog];
        return;
    }

    // 渲染器错误
    if ([lowerLog containsString:@"gl_invalid"] || [lowerLog containsString:@"egl_error"] ||
        [lowerLog containsString:@"opengl error"] || [lowerLog containsString:@"failed to create context"] ||
        [lowerLog containsString:@"glgeterror"] || [lowerLog containsString:@"metal:"]) {
        self.crashType = CrashTypeRendererError;
        self.crashDetail = [self extractLineContaining:@"gl_invalid" fromLog:lowerLog] ?: [self extractLineContaining:@"egl_error" fromLog:lowerLog] ?: [self extractLineContaining:@"opengl error" fromLog:lowerLog];
        return;
    }

    // Mod 加载失败
    if ([lowerLog containsString:@"fml"] && [lowerLog containsString:@"error"] ||
        [lowerLog containsString:@"forge"] && [lowerLog containsString:@"modloading"] ||
        [lowerLog containsString:@"fabric"] && [lowerLog containsString:@"error"] ||
        [lowerLog containsString:@"optifine"] && [lowerLog containsString:@"error"]) {
        self.crashType = CrashTypeModLoadingFailure;
        self.crashDetail = [self extractLineContaining:@"modloading" fromLog:lowerLog] ?: [self extractLineContaining:@"fml" fromLog:lowerLog];
        return;
    }

    // Java 异常
    if ([lowerLog containsString:@"exception"] || [lowerLog containsString:@"stacktrace"]) {
        self.crashType = CrashTypeJavaException;
        self.crashDetail = [self extractLineContaining:@"exception" fromLog:lowerLog];
        return;
    }

    // 兜底：JVM 非 0 退出，但日志里没有可识别特征。
    // 不归到 CrashTypeUnknown：exitCode 本身已经能说明「进程异常退出」，
    // 标题/原因按 JVM 退出码展示（对照 ZL2 ErrorActivity 的 JvmCrash(code, isSignal)）。
    self.crashType = CrashTypeJVMExit;
    self.crashDetail = nil;
}

/// 从日志中提取包含指定关键词的第一行（用于崩溃详情展示）
- (NSString *)extractLineContaining:(NSString *)keyword fromLog:(NSString *)lowerLog {
    if (lowerLog.length == 0) return nil;
    NSArray *lines = [lowerLog componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line containsString:keyword] && line.length < 200) {
            return [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

- (void)setupLogCard {
    _logCardView = [[UIView alloc] init];
    _logCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _logCardView.layer.cornerRadius = 16;
    _logCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _logCardView.layer.masksToBounds = YES;
    _logCardView.layer.borderWidth = 0.5;
    _logCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _logCardView.translatesAutoresizingMaskIntoConstraints = NO;
    // 注意：不在此处添加到 _mainStackView，由 setupUI 中的水平分栏容器管理
    // 应用毛玻璃效果（适配自定义背景壁纸）
    (void)0;

    // 日志标题
    _logTitleLabel = [[UILabel alloc] init];
    _logTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logTitleLabel.text = PLCrashLocalizedText(@"crash.log_info", @"日志摘要");
    _logTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _logTitleLabel.textColor = [UIColor labelColor];
    [_logCardView addSubview:_logTitleLabel];

    // 日志文本视图（可内部滚动）
    _logTextView = [[UITextView alloc] init];
    _logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _logTextView.backgroundColor = [UIColor clearColor];
    _logTextView.textColor = [UIColor labelColor];
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.editable = NO;
    _logTextView.showsVerticalScrollIndicator = YES;
    _logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_logCardView addSubview:_logTextView];

    // 占位符（日志为空时显示，居中放大文字）
    _logPlaceholderLabel = [[UILabel alloc] init];
    _logPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logPlaceholderLabel.text = PLCrashLocalizedText(@"crash.log_info", @"日志摘要");
    _logPlaceholderLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _logPlaceholderLabel.textColor = [UIColor tertiaryLabelColor];
    _logPlaceholderLabel.textAlignment = NSTextAlignmentCenter;
    [_logCardView addSubview:_logPlaceholderLabel];

    // 日志卡片高度约束（初始 240，viewDidLayoutSubviews 中根据屏幕高度调整）
    self.logCardHeightConstraint = [_logCardView.heightAnchor constraintEqualToConstant:240];
    self.logCardHeightConstraint.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_logTitleLabel.topAnchor constraintEqualToAnchor:_logCardView.topAnchor constant:12],
        [_logTitleLabel.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor constant:16],
        [_logTitleLabel.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor constant:-16],

        [_logTextView.topAnchor constraintEqualToAnchor:_logTitleLabel.bottomAnchor constant:8],
        [_logTextView.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor constant:8],
        [_logTextView.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor constant:-8],
        [_logTextView.bottomAnchor constraintEqualToAnchor:_logCardView.bottomAnchor constant:-8],

        [_logPlaceholderLabel.topAnchor constraintEqualToAnchor:_logCardView.topAnchor],
        [_logPlaceholderLabel.bottomAnchor constraintEqualToAnchor:_logCardView.bottomAnchor],
        [_logPlaceholderLabel.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor],
        [_logPlaceholderLabel.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor],

        self.logCardHeightConstraint,
    ]];
}

- (void)setupButtonsIntoContainer:(UIStackView *)container {
    // ============================================================
    // 动作列（对照 ZL2 ErrorScreen.kt ActionLayout）
    // ============================================================
    // ZL2 横屏版右栏：顶部一行「崩溃类型」，底部四个动作按钮，顺序为
    //   上传分享链接 → 分享日志 → 重启 → 退出。
    // 竖屏版把这四项收进顶栏菜单 —— Air2 竖屏时动作列在内容下方，
    // 顺序保持一致，减少两套布局的认知差异。
    //
    // 主按钮区只保留 ZL2 的四个动作；GitHub Issues / 完整日志
    // 作为低频入口放在内容区底部（setupSecondaryLinks）。

    // 崩溃类型（对照 ZL2 的 stringResource(R.string.crash_type, ...)）
    _crashTypeLabel = [[UILabel alloc] init];
    _crashTypeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _crashTypeLabel.text = [self crashTypeDescription];
    _crashTypeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _crashTypeLabel.textColor = [UIColor secondaryLabelColor];
    _crashTypeLabel.textAlignment = NSTextAlignmentCenter;
    _crashTypeLabel.numberOfLines = 0;
    [container addArrangedSubview:_crashTypeLabel];

    // 1. 上传日志并复制链接（对照 ZL2「分享链接」/ onUploadClick）
    //
    // 「分享日志」是把文件扔进系统分享面板，对方还得下载文件、找解析器；
    // 这里上传到日志托管服务并复制短链接，贴出去浏览器直接打开。
    // 上传器复用 A2LogUploader（Automatic = mclo.gs 失败自动切 logshare.cn）。
    _uploadButton = [self createButtonWithTitle:PLCrashLocalizedText(@"crash.upload_link", @"上传日志并复制链接")
                                           icon:@"link.badge.plus"
                                  backgroundColor:[UIColor colorWithRed:0.25 green:0.65 blue:0.45 alpha:0.55]
                                      textColor:[UIColor whiteColor]
                                         bold:YES
                                         action:@selector(uploadLogAndCopyLink)];
    [container addArrangedSubview:_uploadButton];

    // 2. 分享日志文件（对照 ZL2 onShareLogsClick）
    _shareButton = [self createButtonWithTitle:PLCrashLocalizedText(@"crash.share_log", @"分享日志")
                                          icon:@"square.and.arrow.up"
                                 backgroundColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15]
                                     textColor:[UIColor labelColor]
                                        bold:NO
                                        action:@selector(shareLog)];
    [container addArrangedSubview:_shareButton];

    // 3. 重启启动器（蓝色强调）— exit(0) + openURL 拉起应用
    // 参照 FCL/ZL2：很多崩溃是临时加载失败（JIT/dylib/内存碎片），重启即可解决。
    _restartButton = [self createButtonWithTitle:PLCrashLocalizedText(@"crash.restart_launcher", @"重启启动器")
                                            icon:@"arrow.clockwise"
                                   backgroundColor:[UIColor colorWithRed:0.2 green:0.6 blue:0.95 alpha:1.0]
                                       textColor:[UIColor whiteColor]
                                          bold:YES
                                          action:@selector(restartLauncherAction)];
    [container addArrangedSubview:_restartButton];

    // 4. 退出启动器（红色强调）— exit(0) 直接退出进程，不重启
    _exitButton = [self createButtonWithTitle:PLCrashLocalizedText(@"crash.return_launcher", @"退出启动器")
                                         icon:@"xmark.circle.fill"
                                backgroundColor:[UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0]
                                    textColor:[UIColor whiteColor]
                                       bold:YES
                                       action:@selector(exitLauncherAction)];
    [container addArrangedSubview:_exitButton];
}

- (UIButton *)createButtonWithTitle:(NSString *)title icon:(NSString *)icon backgroundColor:(UIColor *)bgColor textColor:(UIColor *)textColor bold:(BOOL)bold action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = bgColor;
    button.layer.cornerRadius = 12;
    button.layer.cornerCurve = kCACornerCurveContinuous;

    [button setTitleColor:textColor forState:UIControlStateNormal];
    button.titleLabel.font = bold ? [UIFont boldSystemFontOfSize:15] : [UIFont systemFontOfSize:15];
    // 横屏动作列只有约 30% 宽，中文长标题需要自动缩放而不是被截断
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    button.titleLabel.numberOfLines = 1;

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:bold ? UIImageSymbolWeightMedium : UIImageSymbolWeightRegular];
        UIImage *iconImage = [UIImage systemImageNamed:icon withConfiguration:config];
        [button setImage:iconImage forState:UIControlStateNormal];
    }

    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    // 固定按钮高度
    [button.heightAnchor constraintEqualToConstant:48].active = YES;

    return button;
}

- (void)adjustLogCardHeight {
    // 横屏 / 竖屏分别计算日志摘要卡片高度。
    //
    // 横屏（游戏主场景）给日志留最多空间，但不超过安全区的一半，
    // 保证右侧四个动作按钮始终完整可见（对照 ZL2 横屏左 7 右 3 的比例感）。
    // 竖屏时日志在内容流里，可以更高一些。
    CGFloat screenHeight = self.view.bounds.size.height;
    CGFloat logHeight;
    if (_landscapeLayout) {
        logHeight = MAX(180.0, screenHeight - 210.0);
        logHeight = MIN(logHeight, 360.0);
    } else {
        if (screenHeight < 600) {
            logHeight = 180;
        } else if (screenHeight < 800) {
            logHeight = 240;
        } else {
            logHeight = 320;
        }
    }
    self.logCardHeightConstraint.constant = logHeight;
}

#pragma mark - Log Content

- (void)loadLogContent {
    NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *logContent = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil];

    if (!logContent || logContent.length == 0) {
        _logTextView.text = nil;
        _logPlaceholderLabel.hidden = NO;
        return;
    }

    // 获取最后150行
    NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSInteger startIndex = MAX(0, (NSInteger)lines.count - 150);
    NSMutableArray *lastLines = [NSMutableArray array];
    for (NSInteger i = startIndex; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        if (line.length > 0) {
            [lastLines addObject:line];
        }
    }

    _logTextView.text = [lastLines componentsJoinedByString:@"\n"];
    _logPlaceholderLabel.hidden = _logTextView.text.length > 0;

    // 滚动到底部
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
    });
}

#pragma mark - Crash Analysis

/// 读取 latestlog.txt 的内容（用于崩溃原因分析）
- (NSString *)readLatestLogForAnalysis {
    static NSString *cachedLog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
        cachedLog = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    });
    return cachedLog;
}

/// 判断是否为 OOM（内存不足）崩溃
- (BOOL)isOOMCrash {
    // SIGKILL (信号 9) 通常是系统因内存不足强制终止进程
    if (_exitCode == 9) return YES;

    // 检查日志中是否包含 OOM 相关关键词
    NSString *logContent = [self readLatestLogForAnalysis];
    if (logContent.length > 0) {
        NSString *lowerLog = [logContent lowercaseString];
        NSArray<NSString *> *oomKeywords = @[
            @"outofmemoryerror",
            @"cannot allocate memory",
            @"failed to allocate",
            @"java.lang.outofmemory",
            @"insufficient memory",
            @"mmap failed",
            @"out of memory"
        ];
        for (NSString *keyword in oomKeywords) {
            if ([lowerLog containsString:keyword]) return YES;
        }
    }
    return NO;
}

/// 崩溃标题：按 CrashType 区分（对照 ZL2 ErrorScreen 顶栏按 crashType 换标题）。
///
/// 注意：localize 的第三级回退是「返回 key 本身」，所以旧代码里
/// PLCrashLocalizedText(@"crash.error_title", nil) 在没有对应 .strings 时会把
/// 字面量 "crash.error_title" 显示在标题上。这里全部给中文兜底，
/// 保证任何语言包里崩溃页都有可读文案。
- (NSString *)crashTitleText {
    if (_customTitle.length > 0) {
        return _customTitle;
    }
    switch (self.crashType) {
        case CrashTypeOOM:
            return PLCrashLocalizedText(@"crash.title.oom", @"游戏内存不足");
        case CrashTypeSegfault:
            return PLCrashLocalizedText(@"crash.title.segfault", @"游戏崩溃（段错误）");
        case CrashTypeAbort:
            return PLCrashLocalizedText(@"crash.title.abort", @"游戏异常终止");
        case CrashTypeTerminated:
            return PLCrashLocalizedText(@"crash.title.terminated", @"游戏被系统终止");
        case CrashTypeModConflict:
            return PLCrashLocalizedText(@"crash.title.mod_conflict", @"Mod 冲突");
        case CrashTypeMissingLibrary:
            return PLCrashLocalizedText(@"crash.title.missing_library", @"缺少游戏库文件");
        case CrashTypeJavaVersionMismatch:
            return PLCrashLocalizedText(@"crash.title.java_version", @"Java 版本不匹配");
        case CrashTypeRendererError:
            return PLCrashLocalizedText(@"crash.title.renderer", @"渲染器错误");
        case CrashTypeModLoadingFailure:
            return PLCrashLocalizedText(@"crash.title.mod_loading", @"Mod 加载失败");
        case CrashTypeJavaException:
            return PLCrashLocalizedText(@"crash.title.java_exception", @"Java 异常");
        case CrashTypeJVMExit:
            return PLCrashLocalizedText(@"crash.title.jvm_exit", @"游戏进程异常退出");
        case CrashTypeNormal:
            return PLCrashLocalizedText(@"crash.title.normal", @"游戏已结束");
        case CrashTypeUnknown:
        default:
            return PLCrashLocalizedText(@"crash.title.unknown", @"游戏崩溃");
    }
}

/// 崩溃类型描述，显示在动作列顶部（对照 ZL2 ErrorScreen 的 crash_type 行）。
- (NSString *)crashTypeDescription {
    NSString *typeName = [self crashTitleText];
    return [NSString stringWithFormat:PLCrashLocalizedText(@"crash.type_line", @"崩溃类型：%@"), typeName];
}

/// 根据 analyzeCrashType 分析的崩溃类型，返回本地化的原因描述
///
/// 参照 HMCL 的崩溃分析器，提供更精确的崩溃原因描述。
/// 新增的崩溃类型：Mod 冲突、缺失库、Java 版本不匹配、渲染器错误、Mod 加载失败、
/// JVM 非 0 退出（对照 ZL2 ErrorActivity 的 JvmCrash 分支）。
- (NSString *)crashReasonText {
    // 优先使用自定义原因
    if (_customReason.length > 0) {
        return [NSString stringWithFormat:@"%@%@",
                PLCrashLocalizedText(@"crash.possible_reason", @"可能原因："), _customReason];
    }

    NSString *reason = nil;

    switch (self.crashType) {
        case CrashTypeNormal:
            reason = PLCrashLocalizedText(@"crash.reason.normal", @"游戏正常结束（退出码 0）");
            break;
        case CrashTypeOOM:
            reason = PLCrashLocalizedText(@"crash.reason.memory", @"内存不足（OOM），iOS 因内存压力终止了游戏进程");
            break;
        case CrashTypeSegfault:
            reason = PLCrashLocalizedText(@"crash.reason.segmentation", @"段错误（SIGSEGV），原生库或 JNI 访问了非法内存");
            break;
        case CrashTypeAbort:
            reason = PLCrashLocalizedText(@"crash.reason.abort", @"程序异常终止（SIGABRT），通常是断言失败或未捕获异常");
            break;
        case CrashTypeTerminated:
            reason = PLCrashLocalizedText(@"crash.reason.terminated", @"进程被外部信号终止（SIGTERM）");
            break;
        case CrashTypeModConflict:
            reason = PLCrashLocalizedText(@"crash.reason.mod_conflict", @"Mod 冲突导致崩溃（NoSuchMethodError/ClassCastException 等）");
            break;
        case CrashTypeMissingLibrary:
            reason = PLCrashLocalizedText(@"crash.reason.missing_library", @"缺失游戏库文件（UnsatisfiedLinkError/NoClassDefFoundError）");
            break;
        case CrashTypeJavaVersionMismatch:
            reason = PLCrashLocalizedText(@"crash.reason.java_version", @"Java 版本不匹配（UnsupportedClassVersionError）");
            break;
        case CrashTypeRendererError:
            reason = PLCrashLocalizedText(@"crash.reason.renderer", @"渲染器错误（OpenGL/Metal/EGL 初始化失败）");
            break;
        case CrashTypeModLoadingFailure:
            reason = PLCrashLocalizedText(@"crash.reason.mod_loading", @"Mod 加载失败（Forge/Fabric/OptiFine 加载错误）");
            break;
        case CrashTypeJavaException:
            reason = PLCrashLocalizedText(@"crash.reason.java_exception", @"Java 异常导致游戏退出，详见下方日志");
            break;
        case CrashTypeJVMExit:
            reason = [NSString stringWithFormat:
                      PLCrashLocalizedText(@"crash.reason.jvm_exit", @"JVM 以退出码 %d 退出，日志里没有更具体的崩溃特征"),
                      _exitCode];
            break;
        case CrashTypeUnknown:
        default:
            reason = [NSString stringWithFormat:
                      PLCrashLocalizedText(@"crash.reason.unknown", @"未知错误（退出码 %d）"), _exitCode];
            break;
    }

    // 如果有崩溃详情，追加到原因后面
    if (self.crashDetail.length > 0) {
        reason = [NSString stringWithFormat:@"%@\n%@", reason, self.crashDetail];
    }

    return [NSString stringWithFormat:@"%@%@",
            PLCrashLocalizedText(@"crash.possible_reason", @"可能原因："), reason];
}

#pragma mark - Log Path Helpers

/// 崩溃日志路径：统一走 latestlog.txt（与 A2LogUploader / PLLogOutputView 一致）。
- (nullable NSString *)latestLogPath {
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') {
        return nil;
    }
    return [NSString stringWithFormat:@"%s/latestlog.txt", home];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:PLCrashLocalizedText(@"OK", @"好")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions

/// 分享日志文件（对照 ZL2 onShareLogsClick / shareFile）。
- (void)shareLog {
    NSString *latestlogPath = [self latestLogPath];
    if (latestlogPath == nil || ![[NSFileManager defaultManager] fileExistsAtPath:latestlogPath]) {
        [self showAlertWithTitle:PLCrashLocalizedText(@"crash.share_failed", @"分享失败")
                         message:PLCrashLocalizedText(@"crash.log_missing", @"找不到 latestlog.txt，日志可能还没生成")];
        return;
    }
    NSURL *logURL = [NSURL fileURLWithPath:latestlogPath];
    UIActivityViewController *activityVC =
        [[UIActivityViewController alloc] initWithActivityItems:@[logURL] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = _shareButton ?: self.view;
    activityVC.popoverPresentationController.sourceRect = _shareButton ? _shareButton.bounds : CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:activityVC animated:YES completion:nil];
}

/// 上传日志并复制链接（对照 ZL2 ErrorActivity 的 ShareLinkOperation / onUploadClick）。
///
/// 复用 A2LogUploader，不重写上传协议：
///   A2LogShareProviderAutomatic = 先 mclo.gs，失败自动切 logshare.cn。
/// 成功后把 URL 写进 UIPasteboard 并提示用户；失败给出原因，不上抛异常。
- (void)uploadLogAndCopyLink {
    if (self.uploadInFlight) {
        return;
    }
    NSString *latestlogPath = [self latestLogPath];
    if (latestlogPath == nil || ![[NSFileManager defaultManager] fileExistsAtPath:latestlogPath]) {
        [self showAlertWithTitle:PLCrashLocalizedText(@"crash.upload_failed", @"上传失败")
                         message:PLCrashLocalizedText(@"crash.log_missing", @"找不到 latestlog.txt，日志可能还没生成")];
        return;
    }

    self.uploadInFlight = YES;
    [self setUploadButtonBusy:YES];
    __weak typeof(self) weakSelf = self;
    [A2LogUploader uploadLogFileAtPath:latestlogPath
                              provider:A2LogShareProviderAutomatic
                            completion:^(A2LogShareResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) return;
        self.uploadInFlight = NO;
        [self setUploadButtonBusy:NO];

        if (result.url.length > 0) {
            UIPasteboard.generalPasteboard.string = result.url;
            NSString *message = [NSString stringWithFormat:
                PLCrashLocalizedText(@"crash.upload_success", @"日志已上传，链接已复制到剪贴板：\n%@"), result.url];
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:PLCrashLocalizedText(@"crash.upload_done", @"上传成功")
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];
            NSString *urlString = result.url;
            [alert addAction:[UIAlertAction actionWithTitle:PLCrashLocalizedText(@"crash.open_link", @"打开链接")
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                NSURL *url = [NSURL URLWithString:urlString];
                if (url != nil) {
                    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                }
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:PLCrashLocalizedText(@"OK", @"好")
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            NSLog(@"[PLCrashView] log uploaded: %@ (provider=%ld)", result.url, (long)result.provider);
        } else {
            NSString *reason = result.error.localizedDescription ?: PLCrashLocalizedText(@"crash.upload_unknown_error", @"未知错误");
            NSString *message = [NSString stringWithFormat:
                PLCrashLocalizedText(@"crash.upload_failure_detail", @"日志上传失败：%@\n可以改用「分享日志」把文件直接发出去。"), reason];
            [self showAlertWithTitle:PLCrashLocalizedText(@"crash.upload_failed", @"上传失败") message:message];
            NSLog(@"[PLCrashView] log upload failed: %@", result.error);
        }
    }];
}

/// 上传按钮忙碌态（防止连点重复上传）
- (void)setUploadButtonBusy:(BOOL)busy {
    if (_uploadButton == nil) return;
    _uploadButton.enabled = !busy;
    NSString *title = busy ? PLCrashLocalizedText(@"crash.uploading", @"正在上传日志…")
                           : PLCrashLocalizedText(@"crash.upload_link", @"上传日志并复制链接");
    [_uploadButton setTitle:title forState:UIControlStateNormal];
    [_uploadButton setTitle:title forState:UIControlStateDisabled];
}

/// 查看完整日志。
///
/// 旧实现调用 surface.logOutputView（依赖 PLLogOutputView 实例），
/// 但该 view 在当前工程从未被创建过，点了没有反应。
/// 这里改成自包含的日志查看页：不依赖游戏 surface，崩溃后再打开也有效。
- (void)showFullLog {
    NSString *latestlogPath = [self latestLogPath];
    NSString *content = latestlogPath ? [NSString stringWithContentsOfFile:latestlogPath
                                                                 encoding:NSUTF8StringEncoding
                                                                    error:nil] : nil;
    if (content.length == 0) {
        [self showAlertWithTitle:PLCrashLocalizedText(@"crash.view_log", @"查看完整日志")
                         message:PLCrashLocalizedText(@"crash.log_missing", @"找不到 latestlog.txt，日志可能还没生成")];
        return;
    }

    UIViewController *viewer = [[UIViewController alloc] init];
    viewer.title = PLCrashLocalizedText(@"crash.view_log", @"日志详情");
    viewer.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.text = content;
    textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    [viewer.view addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:viewer.view.safeAreaLayoutGuide.topAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:viewer.view.safeAreaLayoutGuide.bottomAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:viewer.view.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:viewer.view.trailingAnchor],
    ]];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:viewer];
    viewer.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonItemStyleDone
                                                      target:self
                                                      action:@selector(dismissLogViewer)];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dismissLogViewer {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openGitHubIssues {
    NSURL *url = [NSURL URLWithString:kGitHubIssuesURL];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

/// 退出启动器：直接 exit(0) 退出进程，不重启应用。
///
/// 关键修复：之前"退出启动器"按钮调用 dismissAndReturnToLauncher，
/// 该方法仅返回启动器主界面（不退出进程），与"重启启动器"按钮效果一样
/// （都是回到启动器）。用户反馈两个按钮功能相同，不符合 FCL 行为。
///
/// FCL 的行为：
///   - 重启启动器 = exit(0) + relaunch（重新拉起应用）
///   - 退出启动器 = exit(0)（直接退出，不重启）
///
/// 现在此方法直接调用 exit(0) 退出进程，不进行 relaunch。
- (void)exitLauncherAction {
    NSLog(@"[PLCrashView] User tapped exit launcher, exiting process directly");
    // 通知 SurfaceViewController 释放游戏资源 / 解除 fatalExitGroup 阻塞
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }
    // 直接退出进程，不重启（对照 FCL/ZL2 的退出动作，不是"返回启动器"）
    exit(0);
}

- (void)dismissAndReturnToLauncher {
    // 调用 PLLogOutputView 的返回逻辑（解除 JVM 退出线程的阻塞）
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }

    if (currentCrashVC == self) {
        // 崩溃页现在是独立窗口的 root，不能走 dismissViewController；
        // 由 +teardownCrashWindow 隐藏并释放窗口。
        [PLCrashView teardownCrashWindow];
    } else {
        // 模态兜底路径
        [self dismissViewControllerAnimated:YES completion:^{
            currentCrashVC = nil;
        }];
    }
}

/// 重启启动器按钮的实例回调，委托给类方法 +restartLauncher
- (void)restartLauncherAction {
    [PLCrashView restartLauncher];
}

#pragma mark - Class Methods for External Callers

/// 类方法：隐藏崩溃界面并返回启动器。
/// 供外部 VC 安全调用，避免直接对类对象 performSelector 实例方法导致的崩溃。
+ (void)dismissAndReturnToLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (currentCrashVC) {
            [currentCrashVC dismissAndReturnToLauncher];
        } else if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }
    });
}

/// 重启启动器：清理崩溃界面与游戏 surface，通过 exit(0) + relaunch 触发系统重启。
/// 参照 FCL/ZL2 的"重启软件"按钮：很多崩溃是临时加载失败，重启即可解决。
+ (void)restartLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 清理崩溃界面（独立窗口，先隐藏）
        [self teardownCrashWindow];

        // 2. 通知 SurfaceViewController 释放游戏资源
        if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }

        // 3. 通过 NSURL relaunch 触发系统重新拉起应用（TrollStore/越狱环境支持）
        //    若 relaunch 失败则回退到 exit(0)，系统在 10 秒内会重新唤起前台 App
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        NSURL *appURL = [NSURL fileURLWithPath:bundlePath];
        NSLog(@"[PLCrashView] Restarting launcher from %@", bundlePath);

        // 尝试通过 openURL 拉起（需要 UIApplication.openURL，越狱/TrollStore 可用）
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:appURL
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (!success) {
                    NSLog(@"[PLCrashView] openURL failed, falling back to exit(0)");
                }
                // 无论如何都退出当前进程，让系统重新拉起
                exit(0);
            }];
        } else {
            exit(0);
        }
    });
}

@end

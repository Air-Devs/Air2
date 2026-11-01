//
//  A2CrashReportViewController.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  崩溃页（照老 Air 的 PLCrashView 思路）：
//    · 不是弹窗，而是一整页：标题 + 可滚动内容 + 按钮
//    · 严格输入：调用方给什么就显示什么，不在本类里读崩溃文件
//
//  两种用法（同一套视觉，不另造一套）：
//    ① 上次启动异常结束 —— initWithReport:logPath:（「导出日志」+「返回启动器」）
//    ② ★游戏异常退出遮罩★ —— initWithGameExitCode:reportPath:report:
//       （「游戏崩溃了」+ 退出码 + 崩溃报告路径 + 「重启启动器」「返回启动器」）
//
//  调用方：A2AppDelegate（didFinishLaunching 的崩溃产物分支 / A2GameExitedNotification 观察者）、
//          崩溃守卫（非主线程信号崩后由主线程轮询展示）。
//

#import "A2CrashReportViewController.h"
#import "A2AppDelegate.h"

#import "A2Log.h"
#import "A2ThemeManager.h"   // 主题色板（崩溃遮罩用；既有崩溃页仍用系统色，观感不变）
#import "A2Typography.h"
// ★[A2-EXIT-GUARD] 进程级退出拦截层★：本页「重启启动器」的退出必须走它（不是 `exit(0)`）——
//   直接写 exit 会让链接器为 exit 生成本地 stub，使 __interpose 表里那一格失效 ⇒
//   游戏里的 System.exit(-1) 拦不住。原因与判据见 Natives/Context/a2_exit_guard.h 的注释。
#import "a2_exit_guard.h"

@interface A2CrashReportViewController ()
@property (nonatomic, copy) NSString *pageTitle;
/// 游戏崩溃遮罩：退出码行（nil ⇒ 不是遮罩模式）
@property (nonatomic, copy, nullable) NSString *exitCodeText;
/// 游戏崩溃遮罩：崩溃报告路径行（nil ⇒ 没找到报告，不出这一行）
@property (nonatomic, copy, nullable) NSString *reportPathText;
@property (nonatomic, copy) NSString *reportText;
@property (nonatomic, copy) NSString *logPath;
/// YES ⇒ 游戏崩溃遮罩（多一行退出码、多一个「重启启动器」、不加「导出日志」）
@property (nonatomic, assign) BOOL isGameCrash;
@end

@implementation A2CrashReportViewController

- (instancetype)initWithReport:(NSString *)report logPath:(NSString *)logPath {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _pageTitle = @"上次启动异常结束";
    _reportText = [report copy];
    _logPath = [logPath copy];
    _isGameCrash = NO;
    return self;
}

- (instancetype)initWithGameExitCode:(NSInteger)exitCode
                          reportPath:(NSString *)reportPath
                              report:(NSString *)report {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _isGameCrash = YES;
    _pageTitle = @"游戏崩溃了";
    _exitCodeText = [NSString stringWithFormat:@"退出码：%ld", (long)exitCode];
    // ★只写调用方给的真实路径★：没找到报告就不编一条（「报告=(无)」在 [A2-CRASH-UI] 行里）。
    _reportPathText = reportPath.length ? [NSString stringWithFormat:@"崩溃报告：%@", reportPath] : nil;
    _reportText = [report copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pageTitle;

    // 遮罩模式走主题色（与启动遮罩/首页同一套 MD3 语义色）；
    // 既有「上次启动异常」页保持系统色 —— 那条路径的观感不因本单改变。
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    self.view.backgroundColor = self.isGameCrash ? scheme.cSurface : UIColor.systemBackgroundColor;

    UITextView *text = [[UITextView alloc] initWithFrame:CGRectZero];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.editable = NO;
    text.selectable = YES;
    text.alwaysBounceVertical = YES;
    text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    text.text = self.reportText.length ? self.reportText : @"（没有可显示的崩溃信息）";
    text.backgroundColor = self.isGameCrash ? scheme.cSurfaceContainerLow
                                            : UIColor.secondarySystemBackgroundColor;
    text.textColor = self.isGameCrash ? scheme.cOnSurface : UIColor.labelColor;
    text.layer.cornerRadius = 12;
    text.clipsToBounds = YES;
    [self.view addSubview:text];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // ★游戏崩溃遮罩的头部★：标题 / 退出码（纯文本，不引图片资源）
    UILabel *codeLabel = nil;
    UILabel *pathLabel = nil;
    if (self.isGameCrash) {
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.text = self.pageTitle;
        titleLabel.font = [A2Typography titleLarge];
        titleLabel.textColor = scheme.cOnSurface;
        [self.view addSubview:titleLabel];

        codeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        codeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        codeLabel.text = self.exitCodeText;
        codeLabel.font = [A2Typography subtitleCard];
        codeLabel.textColor = scheme.cError;
        [self.view addSubview:codeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
            [titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [codeLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
            [codeLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
            [codeLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        ]];
        // 遮罩是整页呈现（没套导航栏）⇒ 标题由上面的标签显示，不再用导航栏标题
        self.title = nil;
    }

    // 报告路径行（仅遮罩模式；没有报告文件时整行不出）
    if (self.isGameCrash && self.reportPathText.length) {
        pathLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
        pathLabel.text = self.reportPathText;
        pathLabel.font = [A2Typography caption];
        pathLabel.textColor = scheme.cOnSurfaceVariant;
        pathLabel.numberOfLines = 2;
        pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.view addSubview:pathLabel];
        [NSLayoutConstraint activateConstraints:@[
            [pathLabel.topAnchor constraintEqualToAnchor:codeLabel.bottomAnchor constant:4],
            [pathLabel.leadingAnchor constraintEqualToAnchor:codeLabel.leadingAnchor],
            [pathLabel.trailingAnchor constraintEqualToAnchor:codeLabel.trailingAnchor],
        ]];
    }

    // 正文顶部：遮罩模式接在「报告路径行 / 退出码行」之后；既有模式接安全区（原值 12）
    UIView *headerLast = pathLabel ?: codeLabel;
    NSLayoutConstraint *textTop = (headerLast != nil)
        ? [text.topAnchor constraintEqualToAnchor:headerLast.bottomAnchor constant:10]
        : [text.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12];

    // 按钮：遮罩模式 =「重启启动器」（主）+「返回启动器」（次），照老 Air 的 PLCrashView；
    //       既有模式 =「导出日志」+「返回启动器」，一字不改。
    UIButton *primary = [UIButton buttonWithType:UIButtonTypeSystem];
    primary.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *secondary = [UIButton buttonWithType:UIButtonTypeSystem];
    secondary.translatesAutoresizingMaskIntoConstraints = NO;

    if (self.isGameCrash) {
        [primary setTitle:@"重启启动器" forState:UIControlStateNormal];
        primary.titleLabel.font = [A2Typography button];
        [primary setTitleColor:scheme.cOnPrimary forState:UIControlStateNormal];
        primary.backgroundColor = scheme.cPrimary;
        primary.layer.cornerRadius = 22.0;      // 44pt 高的胶囊
        primary.layer.cornerCurve = kCACornerCurveContinuous;
        [primary addTarget:self action:@selector(restartLauncher) forControlEvents:UIControlEventTouchUpInside];

        [secondary setTitle:@"返回启动器" forState:UIControlStateNormal];
        secondary.titleLabel.font = [A2Typography body];
        [secondary addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [primary setTitle:@"导出日志" forState:UIControlStateNormal];
        primary.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        [primary addTarget:self action:@selector(exportLog) forControlEvents:UIControlEventTouchUpInside];

        [secondary setTitle:@"返回启动器" forState:UIControlStateNormal];
        secondary.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [secondary addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
    }
    [self.view addSubview:primary];
    [self.view addSubview:secondary];

    [NSLayoutConstraint activateConstraints:@[
        textTop,
        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [text.bottomAnchor constraintEqualToAnchor:primary.topAnchor constant:-12],

        // ★按钮间距（2026-10-18 用户反馈：两个按钮靠太近）★
        //   主按钮在上、次按钮在下，中间留 24pt；
        //   两者都做成 44pt 高（iOS 最小可点区域），底部再留 20pt 安全距离。
        [primary.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [primary.heightAnchor constraintEqualToConstant:44],
        [primary.widthAnchor constraintGreaterThanOrEqualToConstant:200],
        [primary.bottomAnchor constraintEqualToAnchor:secondary.topAnchor constant:-24],

        [secondary.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [secondary.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        [secondary.heightAnchor constraintEqualToConstant:44],
        [secondary.widthAnchor constraintGreaterThanOrEqualToConstant:200],
    ]];
}

/// 分享面板导出日志文件（老 Air 同款能力：把日志拿出来看/发给别人）。
- (void)exportLog {
    NSString *path = self.logPath;
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = [A2Log previousLogPath];
    }
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [A2Log log:@"[A2-CRASH-UI] 导出失败：日志文件不存在"];
        return;
    }
    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                          applicationActivities:nil];
    if (share.popoverPresentationController != nil) {
        share.popoverPresentationController.sourceView = self.view;
        share.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds), 1, 1);
    }
    [self presentViewController:share animated:YES completion:nil];
}

/// 「返回启动器」：收起整条呈现链。
///   遮罩是挂在「游戏页」之上的 ⇒ 只 dismiss 自己会回到黑屏的游戏页。
///   所以从「启动器根 VC」dismiss 一次：它呈现的那一页（游戏页）连同上面的遮罩一起消失。
///   既有模式（本页直接在根 VC 之上）走同一句也正确 —— 它就是把本页收起来。
- (void)closeSelf {
    UIViewController *presenter = self.presentingViewController;
    while (presenter.presentingViewController != nil) presenter = presenter.presentingViewController;
    if (presenter != nil) {
        [presenter dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// 「重启启动器」：老 Air 同款 —— 先试着用 file URL 重新拉起自身（TrollStore/越狱环境有效），
///   0.4s 后无条件退出进程（拉不起来也只是退出，用户点图标即可，不会「点了没反应」）。
- (void)restartLauncher {
    [A2Log criterion:@"[A2-CRASH-UI] 用户点了「重启启动器」⇒ 退出当前进程"];
    NSURL *selfURL = [NSURL fileURLWithPath:NSBundle.mainBundle.bundlePath];
    [UIApplication.sharedApplication openURL:selfURL options:@{} completionHandler:^(BOOL ok) {
        (void)ok;   // 拉不起来也不影响下面的退出
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // ★不能直接写 exit(0)★（会让 exit 生成本地 stub ⇒ 游戏退出拦截失效）：
        //   走 a2_exit_guard_terminate_now ⇒ 调的是同一个 libSystem 原函数，行为一字不差。
        a2_exit_guard_terminate_now(0);
    });
}

@end

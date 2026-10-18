//
//  A2CrashReportViewController.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  上次启动异常结束的崩溃页（照老 Air 的 PLCrashView 思路）：
//    · 不是弹窗，而是一整页：标题 + 可滚动日志摘要 + 两个按钮
//    · 「导出日志」= 系统分享面板（文件 = 上次会话日志 lastlog.old.txt）
//    · 严格输入：调用方给什么就显示什么，不在本类里读崩溃文件
//
//  唯一调用方：A2AppDelegate didFinishLaunchingWithOptions:（检测到崩溃标记时）。
//

#import "A2CrashReportViewController.h"

#import "A2Log.h"

@interface A2CrashReportViewController ()
@property (nonatomic, copy) NSString *reportText;
@property (nonatomic, copy) NSString *logPath;
@end

@implementation A2CrashReportViewController

- (instancetype)initWithReport:(NSString *)report logPath:(NSString *)logPath {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _reportText = [report copy];
    _logPath = [logPath copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"上次启动异常结束";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *text = [[UITextView alloc] initWithFrame:CGRectZero];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.editable = NO;
    text.selectable = YES;
    text.alwaysBounceVertical = YES;
    text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    text.text = self.reportText.length ? self.reportText : @"（没有可显示的崩溃信息）";
    text.backgroundColor = UIColor.secondarySystemBackgroundColor;
    text.layer.cornerRadius = 12;
    text.clipsToBounds = YES;
    [self.view addSubview:text];

    UIButton *export = [UIButton buttonWithType:UIButtonTypeSystem];
    export.translatesAutoresizingMaskIntoConstraints = NO;
    [export setTitle:@"导出日志" forState:UIControlStateNormal];
    export.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [export addTarget:self action:@selector(exportLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:export];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"返回启动器" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [close addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [text.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [text.bottomAnchor constraintEqualToAnchor:export.topAnchor constant:-12],

        // ★按钮间距（2026-10-18 用户反馈：两个按钮靠太近）★
        //   主按钮「导出日志」在上、次按钮「返回启动器」在下，中间留 24pt；
        //   两者都做成 44pt 高（iOS 最小可点区域），底部再留 20pt 安全距离。
        [export.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [export.heightAnchor constraintEqualToConstant:44],
        [export.widthAnchor constraintGreaterThanOrEqualToConstant:200],
        [export.bottomAnchor constraintEqualToAnchor:close.topAnchor constant:-24],

        [close.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [close.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        [close.heightAnchor constraintEqualToConstant:44],
        [close.widthAnchor constraintGreaterThanOrEqualToConstant:200],
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

- (void)closeSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

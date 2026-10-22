//
//  A2LogViewController.m
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
//
//  A2LogViewController.m
//  Air2
//

#import "A2LogViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Logger.h"

@interface A2LogViewController ()
@property (nonatomic, strong) UITextView *logView;
@end

@implementation A2LogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.usesScrollContent = NO;
    self.pageTitle = @"运行日志";

    [self addTrailingButtonWithSymbol:@"square.and.arrow.up" action:^{
        [self shareLog];
    }];

    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    card.translatesAutoresizingMaskIntoConstraints = NO;

    _logView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.backgroundColor = UIColor.clearColor;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsZero;
    _logView.textContainer.lineFragmentPadding = 0;
    _logView.text = [self loadLogText];

    [card.contentView addSubview:_logView];
    [self.plainContentView addSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor
                                       constant:A2SpaceM],
        [card.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor
                                          constant:-A2SpaceM],
        [card.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2PageMargin],
        [card.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                            constant:-A2PageMargin],

        [_logView.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [_logView.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [_logView.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_logView.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// 读当前日志文件。没有日志时给出明确提示，而不是空白页。
- (NSString *)loadLogText {
    NSString *logDir = A2Logger.shared.logDirectory;
    NSArray<NSString *> *files = [NSFileManager.defaultManager
                                  contentsOfDirectoryAtPath:logDir error:nil];

    if (files.count == 0) {
        return @"暂无日志。\n\n启动器运行时的日志会写入 Documents/logs/ 目录，"
                "当前还没有生成任何日志文件。";
    }

    // 取最新的
    NSString *latest = nil;
    NSDate *latestDate = nil;
    for (NSString *f in files) {
        NSString *p = [logDir stringByAppendingPathComponent:f];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
        NSDate *d = attrs[NSFileModificationDate];
        if (!latestDate || [d compare:latestDate] == NSOrderedDescending) {
            latestDate = d;
            latest = f;
        }
    }

    if (!latest) return @"暂无日志";

    NSString *path = [logDir stringByAppendingPathComponent:latest];
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    return content.length ? content : @"日志文件为空";
}

/// 分享：把整个日志目录打包后导出（对应 ZL2 的 Logger.pack）
- (void)shareLog {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"air2_logs.txt"];
    __weak typeof(self) weakSelf = self;
    [A2Logger.shared packLogsToPath:tmp completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!success) {
            [A2Toast show:(error.localizedDescription ?: @"导出失败") inView:self.view];
            return;
        }
        [self presentShareForFile:tmp];
    }];
}

- (void)presentShareForFile:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                          applicationActivities:nil];
    vc.popoverPresentationController.sourceView = self.view;
    vc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                             CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _logView.textColor = t.cOnSurfaceVariant;
}

@end

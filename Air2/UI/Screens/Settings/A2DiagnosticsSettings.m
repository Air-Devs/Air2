//
//  A2DiagnosticsSettings.m
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
//  崩溃日志是 App 层崩溃守卫落盘的（Documents/air2_crash.log），
//  但 UI 从未读过它 —— 日志只写不读等于没有。
//  这里直读文件，不 import App 层的守卫类（依赖方向 App→UI，
//  UI 反向 import 会成环）。文件名常量与守卫实现里的落盘名
//  保持一致，改名时两处一起改。
//

#import "A2DiagnosticsSettings.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"

/// 与 App 层守卫实现的落盘名同值（分层原因见文件头注释）。
static NSString *const kCrashFileName = @"air2_crash.log";

@implementation A2DiagnosticsSettings

+ (NSString *)crashLogPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kCrashFileName];
}

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"崩溃记录"];

    NSString *path = [self crashLogPath];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    BOOL hasLog = attrs != nil;

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"exclamationmark.triangle.fill";
    row.title = @"上次崩溃日志";
    if (hasLog) {
        NSNumber *size = attrs[NSFileSize];
        NSDate *date = attrs[NSFileModificationDate];
        NSString *sizeText = [self displaySize:size.longLongValue];
        NSString *dateText = date ? [self displayDate:date] : @"";
        row.subtitle = [NSString stringWithFormat:@"%@ · %@", sizeText, dateText];
    } else {
        row.subtitle = @"无崩溃记录";
    }
    row.accessory = hasLog
        ? A2SettingsRowAccessoryDisclosure
        : A2SettingsRowAccessoryNone;
    if (hasLog) {
        row.onTap = ^{
            [self showLogFrom:host];
        };
    }
    [section addRow:row];
    section.footerText = @"崩溃时自动记录，无记录即运行正常。";
    return section;
}

+ (void)showLogFrom:(UIViewController *)host {
    NSString *log = [NSString stringWithContentsOfFile:[self crashLogPath]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (!log.length) {
        [A2Toast show:@"日志为空" inView:host.view];
        return;
    }
    // 日志可能很长（堆栈），弹窗只看前 2000 字，全文走文件 App 取。
    NSString *preview = log.length > 2000
        ? [[log substringToIndex:2000] stringByAppendingString:@"\n…（已截断）"] : log;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"上次崩溃日志"
                                                                   message:preview
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除记录"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) {
        [NSFileManager.defaultManager removeItemAtPath:[self crashLogPath] error:nil];
        [A2Toast show:@"已清除" inView:host.view];
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

+ (NSString *)displaySize:(long long)n {
    if (n < 1024) return [NSString stringWithFormat:@"%lld B", n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
}

+ (NSString *)displayDate:(NSDate *)date {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"M-d HH:mm";
    });
    return [fmt stringFromDate:date];
}

@end

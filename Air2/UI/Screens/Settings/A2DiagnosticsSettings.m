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
//  运行日志的读侧。日志由 Utils 的 A2Log 落盘（Documents/lastlog.txt，
//  上次会话留档为 lastlog.old.txt），崩溃信息也写进同一份日志。
//  这里直接调 A2Log 取路径，不再自己拼文件名 —— 层向上 UI 依赖 Utils
//  是允许的（Utils 是全层共用的叶子），路径只有一个出口。
//

#import "A2DiagnosticsSettings.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Log.h"

@implementation A2DiagnosticsSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"运行日志"];
    [section addRow:[self rowForTitle:@"本次会话日志"
                                 path:[A2Log currentLogPath]
                                 host:host]];
    [section addRow:[self rowForTitle:@"上次会话日志"
                                 path:[A2Log previousLogPath]
                                 host:host]];
    section.footerText = @"崩溃信息写入同一份日志。可在「文件」App 的 Air2 目录里打开、导出。";
    return section;
}

/// 一行对应一个日志文件：无文件则置灰不可点。
+ (A2SettingsRow *)rowForTitle:(NSString *)title
                          path:(NSString *)path
                          host:(UIViewController *)host {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"doc.text";
    row.title = title;

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    BOOL hasLog = attrs != nil;
    if (hasLog) {
        NSNumber *size = attrs[NSFileSize];
        NSDate *date = attrs[NSFileModificationDate];
        NSString *sizeText = [self displaySize:size.longLongValue];
        NSString *dateText = date ? [self displayDate:date] : @"";
        row.subtitle = [NSString stringWithFormat:@"%@ · %@", sizeText, dateText];
    } else {
        row.subtitle = @"暂无";
    }
    row.accessory = hasLog
        ? A2SettingsRowAccessoryDisclosure
        : A2SettingsRowAccessoryNone;
    if (hasLog) {
        row.onTap = ^{
            [self showLogAtPath:path title:title from:host];
        };
    }
    return row;
}

+ (void)showLogAtPath:(NSString *)path
                title:(NSString *)title
                 from:(UIViewController *)host {
    NSString *log = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (!log.length) {
        [A2Toast show:@"日志为空" inView:host.view];
        return;
    }
    // 日志可能很长（堆栈），弹窗只看前 2000 字，全文走文件 App 取。
    NSString *preview = log.length > 2000
        ? [[log substringToIndex:2000] stringByAppendingString:@"\n…（已截断）"] : log;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:preview
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel handler:nil]];
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

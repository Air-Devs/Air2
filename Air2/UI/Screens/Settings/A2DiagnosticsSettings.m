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
#import "a2_eagl_egl.h"   // Natives/Renderer —— 假 EGL 层（EGL 1.4 子集 → EAGL）的离屏自检入口

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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(title.length ? title : @"日志")
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

#pragma mark - iPhone Duo 形态模拟

+ (NSString *)duoModeText:(NSInteger)mode {
    switch (mode) {
        case 1: return @"内屏 · 整屏";
        case 2: return @"内屏 · 分屏(占一半)";
        case 3: return @"折叠 · 外屏";
        default: return @"关闭";
    }
}

+ (NSString *)duoOrientationText:(NSInteger)o {
    switch (o) {
        case 1: return @"竖屏";
        case 2: return @"横屏";
        default: return @"跟随设备";
    }
}

/// 诊断页的「Duo 形态模拟」区：点一下循环切换，下次进游戏即生效；
/// 已在游戏内则发通知让窗口立刻重排（原生侧监听 A2DuoSimChanged）。
+ (A2SettingsSection *)buildDuoSimSectionWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"iPhone Duo 形态模拟"];

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger mode = [d integerForKey:@"A2DuoSimMode"];
    NSInteger orient = [d integerForKey:@"A2DuoSimOrientation"];

    A2SettingsRow *modeRow = [[A2SettingsRow alloc] init];
    modeRow.symbolName = @"rectangle.split.2x1";
    modeRow.title = @"屏幕形态";
    modeRow.subtitle = @"模拟内屏整屏 / 分屏占一半 / 折叠外屏";
    modeRow.valueText = [self duoModeText:mode];
    modeRow.accessory = A2SettingsRowAccessoryDisclosure;
    modeRow.onTap = ^{
        NSInteger next = ([d integerForKey:@"A2DuoSimMode"] + 1) % 4;
        [d setInteger:next forKey:@"A2DuoSimMode"];
        [A2Log log:@"[A2-DUO] 形态模拟 → %@（%ld）", [self duoModeText:next], (long) next];
        [NSNotificationCenter.defaultCenter postNotificationName:@"A2DuoSimChanged" object:nil];
        [host.view setNeedsLayout];
        [A2Toast show:[NSString stringWithFormat:@"形态：%@", [self duoModeText:next]] inView:host.view];
    };
    [section addRow:modeRow];

    A2SettingsRow *orientRow = [[A2SettingsRow alloc] init];
    orientRow.symbolName = @"rectangle.portrait.rotate";
    orientRow.title = @"方向";
    orientRow.subtitle = @"模拟竖屏 / 横屏（折叠与分屏都会遇到）";
    orientRow.valueText = [self duoOrientationText:orient];
    orientRow.accessory = A2SettingsRowAccessoryDisclosure;
    orientRow.onTap = ^{
        NSInteger next = ([d integerForKey:@"A2DuoSimOrientation"] + 1) % 3;
        [d setInteger:next forKey:@"A2DuoSimOrientation"];
        [A2Log log:@"[A2-DUO] 形态方向 → %@（%ld）", [self duoOrientationText:next], (long) next];
        [NSNotificationCenter.defaultCenter postNotificationName:@"A2DuoSimChanged" object:nil];
        [A2Toast show:[NSString stringWithFormat:@"方向：%@", [self duoOrientationText:next]] inView:host.view];
    };
    [section addRow:orientRow];

    section.footerText = @"改完直接进游戏即可看到效果；游戏内切换会立即重排。用来在没有 Duo 真机的条件下验证布局。";
    return section;
}

#pragma mark - 假 EGL 自检（P1 判据入口）

/// 一行入口：点一下就在**后台线程**跑一次离屏自检（建 display/config/ES3 context/
/// 离屏 surface → 编译着色器 → 画一帧 → glReadPixels 取中心像素），结果 toast + 日志。
/// ★为什么要后台★：自检会临时把 EAGLContext 设成 current，放在主线程上做等于在 UI 线程
/// 上切 GL 上下文；后台线程各有一套 current，互不打扰（EAGL 的 current 是每线程的）。
+ (A2SettingsSection *)buildEaglSelfCheckSectionWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"假 EGL（EAGL 宿主）"];

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"triangle";
    row.title = @"假 EGL 自检";
    row.subtitle = @"离屏 ES3 三角形：EGL 1.4 子集 → EAGLContext，跑通即 P1 判据";
    row.accessory = A2SettingsRowAccessoryDisclosure;
    row.onTap = ^{
        [A2Log log:@"[A2-EAGL] 设置页触发假 EGL 自检"];
        [A2Toast show:@"假 EGL 自检运行中…" inView:host.view];
        // 串行队列：连点两下不会跑出两条并发自检（本层的注册表/current 不是为并发设计的）。
        static dispatch_queue_t queue;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            queue = dispatch_queue_create("dev.airdevs.air2.eagl.selftest", DISPATCH_QUEUE_SERIAL);
        });
        dispatch_async(queue, ^{
            int rc = a2_eagl_egl_selftest();       // ← 唯一调用点（P1）
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *text = (rc == 0)
                    ? @"假 EGL 自检通过（离屏三角形已画出）"
                    : [NSString stringWithFormat:@"假 EGL 自检失败：步 %d（详见运行日志）", rc];
                [A2Log log:@"[A2-EAGL] %@", text];
                [A2Toast show:text inView:host.view];
            });
        });
    };
    [section addRow:row];
    section.footerText = @"自检结果同时写入运行日志（grep [A2-EAGL]）：通过打 selftest PASS center=0x…，失败打具体步骤与 EGL 错误码。";
    return section;
}


@end

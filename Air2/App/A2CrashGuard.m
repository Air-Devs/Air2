//
//  A2CrashGuard.m
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

#import "A2CrashGuard.h"
#import "A2Log.h"
#import <UIKit/UIKit.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <time.h>

/// ObjC 未捕获异常处理器（前置声明，install 里要用）
static void A2HandleException(NSException *exception);

/// 信号处理器里能安全调用的东西很有限（必须异步信号安全），
/// 所以这里只用 open / write / close / snprintf / backtrace_symbols_fd，
/// 不碰 ObjC —— 路径从 A2Log 的纯 C 访问器取，也不再拼时间字符串。
/// 崩溃报告文件路径（启动时设一次，信号处理器里只读 —— 异步信号安全）
static char gA2CrashReportPath[1024] = {0};
/// 最近一次崩溃信号（0 = 没崩）；主线程靠它决定是否弹崩溃页
static volatile sig_atomic_t gA2CrashSignal = 0;

static void A2SignalHandler(int sig) {
    const char *path = a2_log_current_path();
    if (path && path[0] != '\0') {
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            char head[160];
            int n = snprintf(head, sizeof(head),
                             "\n=== 信号崩溃 ===\n信号: %d\n时间戳: %ld\n\n栈:\n",
                             sig, (long)time(NULL));
            if (n > 0) {
                size_t len = (size_t)n < sizeof(head) ? (size_t)n : sizeof(head) - 1;
                ssize_t ignored = write(fd, head, len);
                (void)ignored;
            }
            void *callstack[64];
            int frames = backtrace(callstack, 64);
            backtrace_symbols_fd(callstack, frames, fd);
            close(fd);
        }
    }

    // ★崩溃界面（2026-10-18，按用户要求）★
    //   老 Air 的做法是「进程内拦下崩溃并把界面留住」，不是等下次启动。这里照做：
    //     · 任何线程崩 ⇒ 写崩溃摘要到 Documents/.a2_crash_report.txt 并置标志
    //     · ★非主线程★崩 ⇒ 只结束该线程（pthread_exit），进程继续活着，主线程弹崩溃页
    //     · ★主线程★崩 ⇒ UIKit 在信号上下文里不能调用，只能落盘（下次启动会展示）
    {
        int fd2 = open(gA2CrashReportPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd2 >= 0) {
            char head[192];
            int n2 = snprintf(head, sizeof(head), "崩溃信号: %d\n时间戳: %ld\n\n栈:\n", sig, (long)time(NULL));
            if (n2 > 0) { ssize_t w = write(fd2, head, (size_t)n2); (void)w; }
            void *stack2[64];
            int frames2 = backtrace(stack2, 64);
            backtrace_symbols_fd(stack2, frames2, fd2);
            close(fd2);
        }
        gA2CrashSignal = sig;
    }

    if (pthread_main_np() == 0) {
        // 非主线程：让这条线程安静退出，进程留着给主线程弹崩溃页
        pthread_exit(NULL);
    }

    // 恢复默认处理器后重新触发，让系统也记录一份
    signal(sig, SIG_DFL);
    raise(sig);
}

@implementation A2CrashGuard

+ (void)install {
    // 1. ObjC 异常：可以拿到完整的 NSException 信息
    NSSetUncaughtExceptionHandler(&A2HandleException);

    // ★崩溃报告文件路径 + 主线程轮询（崩溃时非主线程退出、主线程弹页）★
    {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *p = [docs stringByAppendingPathComponent:@".a2_crash_report.txt"];
        snprintf(gA2CrashReportPath, sizeof(gA2CrashReportPath), "%s", p.UTF8String ?: "");
        // 主线程每 0.4s 看一次标志；一旦置位就把崩溃页弹出来（只弹一次）
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                  (uint64_t)(0.4 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            if (gA2CrashSignal == 0) return;
            static BOOL shown = NO;
            if (shown) return;
            shown = YES;
            NSString *path = @(gA2CrashReportPath);
            NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if (text.length > 4000) text = [text substringFromIndex:text.length - 4000];
            UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:
                                        [NSString stringWithFormat:@"游戏崩溃（信号 %d）", (int)gA2CrashSignal]
                                                                      message:text ?: @"（无崩溃信息）"
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:a animated:YES completion:nil];
        });
        dispatch_resume(timer);
    }

    // 2. 信号：捕获野指针访问、断言失败等
    signal(SIGABRT, A2SignalHandler);
    signal(SIGSEGV, A2SignalHandler);
    signal(SIGBUS,  A2SignalHandler);
    signal(SIGILL,  A2SignalHandler);
    signal(SIGFPE,  A2SignalHandler);
    signal(SIGTRAP, A2SignalHandler);
}

/// ObjC 未捕获异常处理器
static void A2HandleException(NSException *exception) {
    NSMutableString *log = [NSMutableString string];
    [log appendString:@"=== 未捕获异常 ==="];
    [log appendFormat:@"\n名称: %@", exception.name];
    [log appendFormat:@"\n原因: %@", exception.reason];
    [log appendString:@"\n调用栈:"];
    for (NSString *frame in exception.callStackSymbols) {
        [log appendFormat:@"\n  %@", frame];
    }
    [log appendFormat:@"\n用户信息: %@", exception.userInfo];

    // 用 %@ 透传，避免堆栈里的 % 被当成格式符
    [A2Log log:@"%@", log];
}

@end

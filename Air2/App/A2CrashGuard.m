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
#include <execinfo.h>
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

    // 恢复默认处理器后重新触发，让系统也记录一份
    signal(sig, SIG_DFL);
    raise(sig);
}

@implementation A2CrashGuard

+ (void)install {
    // 1. ObjC 异常：可以拿到完整的 NSException 信息
    NSSetUncaughtExceptionHandler(&A2HandleException);

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

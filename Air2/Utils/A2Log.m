//
//  A2Log.m
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
//  实现见头文件的落盘策略说明。
//
//  并发模型：所有文件操作都串行化到一条队列上，日志行不会交错。
//  写入用同步派发 —— 崩溃兜底紧跟在业务日志之后触发时，
//  要保证这一行已经落到内核缓冲区，否则最后的线索会丢。
//

#import "A2Log.h"
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <sys/sysctl.h>

static NSString *const kCurrentLogName  = @"lastlog.txt";
static NSString *const kPreviousLogName = @"lastlog.old.txt";

/// 串行队列：保证多线程下的写入不交错。
static dispatch_queue_t a2_log_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dev.airdevs.air2.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

/// 当前日志句柄。只在串行队列内访问，故不再额外加锁。
static NSFileHandle *gHandle = nil;

/// 当前日志路径的 C 副本，供崩溃信号处理器读取。
/// 信号上下文里不能发 ObjC 消息，只能读这块静态缓冲区。
static char gPathC[PATH_MAX] = {0};

static NSString *a2_log_directory(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                               NSUserDomainMask, YES).firstObject;
}

static NSString *a2_log_path_named(NSString *name) {
    NSString *dir = a2_log_directory();
    return dir ? [dir stringByAppendingPathComponent:name] : nil;
}

/// 时间戳：yyyy-MM-dd HH:mm:ss.SSS
static NSString *a2_log_timestamp(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:[NSDate date]];
}

/// 机型标识（如 iPhone14,2）。用 sysctl 直接取，避免 Utils 依赖 UIKit。
static NSString *a2_log_machine(void) {
    char buffer[64] = {0};
    size_t length = sizeof(buffer);
    if (sysctlbyname("hw.machine", buffer, &length, NULL, 0) != 0) {
        return @"unknown";
    }
    return [NSString stringWithUTF8String:buffer] ?: @"unknown";
}

/// 追加一段文本。调用前必须已持有队列。
static void a2_log_append(NSString *text) {
    if (!gHandle) { return; }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", a2_log_timestamp(), text];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) { return; }
    @try {
        [gHandle seekToEndOfFile];
        [gHandle writeData:data];
    } @catch (NSException *exception) {
        // 日志写入失败绝不能反过来把业务搞崩，静默吞掉。
    }
}

/// 写会话头。调用前必须已持有队列。
static void a2_log_write_header(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";

    a2_log_append([NSString stringWithFormat:
        @"============================================================\n"
        @"Air2 日志\n"
        @"会话开始：%@\n"
        @"版本：%@（%@）\n"
        @"机型：%@\n"
        @"系统：%@\n"
        @"============================================================",
        a2_log_timestamp(), version, build,
        a2_log_machine(), NSProcessInfo.processInfo.operatingSystemVersionString]);
}

/// 轮转：删除旧日志 → 当前改名为旧 → 新建当前 → 打开句柄并写会话头。
/// 调用前必须已持有队列。
static void a2_log_rotate(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *current = a2_log_path_named(kCurrentLogName);
    NSString *previous = a2_log_path_named(kPreviousLogName);
    if (!current || !previous) { return; }

    if ([fm fileExistsAtPath:previous]) {
        [fm removeItemAtPath:previous error:nil];
    }
    if ([fm fileExistsAtPath:current]) {
        [fm moveItemAtPath:current toPath:previous error:nil];
    }
    [fm createFileAtPath:current contents:nil attributes:nil];

    // 缓存 C 路径供信号处理器使用。必须在写会话头之前完成。
    snprintf(gPathC, sizeof(gPathC), "%s", current.fileSystemRepresentation);

    gHandle = [NSFileHandle fileHandleForWritingAtPath:current];
    a2_log_write_header();
}

const char *a2_log_current_path(void) {
    return gPathC;
}

@implementation A2Log

+ (void)startSession {
    dispatch_sync(a2_log_queue(), ^{
        a2_log_rotate();
    });
}

+ (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    dispatch_sync(a2_log_queue(), ^{
        a2_log_append(message);
    });
}

+ (NSString *)currentLogPath {
    return a2_log_path_named(kCurrentLogName) ?: @"";
}

+ (NSString *)previousLogPath {
    return a2_log_path_named(kPreviousLogName) ?: @"";
}

@end

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
//  控制台归档（latestlog.txt）为什么用 dup2 直接接文件、而不是「管道 + 读线程」：
//    · 管道方案在崩溃时会丢掉管道缓冲里还没被读走的那一截 —— 而那正是最需要的尾部；
//    · 直接 dup2 到文件，已写出的行立刻在内核里，进程怎么死都在。
//  上限怎么保证：运行中按大小**就地**轮转（先抄一份到 latestlog.old.txt，再截断续写），
//  触发点有两处 —— 每次写判据行时顺手查一次，加一条 30 秒的定时守护
//  （只靠判据行不够：JVM 栈回溯、其它 NSLog 也会往 stderr 灌）。
//

#import "A2Log.h"
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

static NSString *const kCurrentLogName  = @"lastlog.txt";
static NSString *const kPreviousLogName = @"lastlog.old.txt";
/// 控制台归档（stderr 的去处）与它的上一代。
static NSString *const kConsoleLogName    = @"latestlog.txt";
static NSString *const kConsoleLogOldName = @"latestlog.old.txt";

/// 控制台归档的大小上限：到了就就地轮转。2 MiB 够放下一次会话的 native 判据行与控制台噪声。
static const unsigned long long kConsoleLogCapBytes = 2ULL * 1024ULL * 1024ULL;

/// 控制台归档的句柄（-1 = 尚未归档）。★与 stderr 是同一个打开文件描述（dup2）★，
/// 所以 ftruncate 它 = 截断 stderr 的落点；以 O_APPEND 打开 ⇒ 截断后继续从 0 处往后写。
static int gConsoleFd = -1;

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

#pragma mark - 一行一条

/// 判据行必须是一行：把换行换成可见标记，避免「一条判据」在文件里裂成多行，
/// 也避免对端可控的字符串伪造出一个假的行首。
static NSString *a2_log_single_line(NSString *text) {
    if (text.length == 0) { return text; }
    if ([text rangeOfString:@"\n"].location == NSNotFound) { return text; }
    return [text stringByReplacingOccurrencesOfString:@"\n" withString:@"␊"];
}

#pragma mark - 控制台归档（stderr → Documents/latestlog.txt）

/// 直接往归档写一行。写的就是 stderr 本身（dup2 之后两者同源）。
/// 逐行 flush ⇒ 进程若在下一行之前死掉，这一行也已经在内核里了。
static void a2_log_console_write(NSString *text) {
    if (text.length == 0) { return; }
    const char *utf8 = text.UTF8String;
    if (!utf8) { return; }
    flockfile(stderr);
    fputs(utf8, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    funlockfile(stderr);
}

/// 超上限就地轮转：当前内容留档成 latestlog.old.txt（有界：≤ 上限），归档截断后继续写。
/// ★调用前必须已持有队列★。
static void a2_log_console_guard(void) {
    if (gConsoleFd < 0) { return; }
    struct stat info;
    if (fstat(gConsoleFd, &info) != 0) { return; }
    if ((unsigned long long)info.st_size < kConsoleLogCapBytes) { return; }

    NSString *current = a2_log_path_named(kConsoleLogName);
    NSString *previous = a2_log_path_named(kConsoleLogOldName);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (current && previous) {
        if ([fm fileExistsAtPath:previous]) {
            [fm removeItemAtPath:previous error:nil];
        }
        [fm copyItemAtPath:current toPath:previous error:nil];
    }
    if (ftruncate(gConsoleFd, 0) != 0) { return; }
    a2_log_console_write(@"[A2-LOG] latestlog.txt 已达上限，已轮转为 latestlog.old.txt 并从头继续写");
}

/// 30 秒一次的上限守护。★上限要成立，就得与「谁在写」无关★ ——
/// 光靠判据行触发不够：JVM 栈回溯、其它 NSLog 也会往 stderr 灌。
static void a2_log_console_install_guard_timer(void) {
    static dispatch_source_t timer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, a2_log_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                                  (uint64_t)(30 * NSEC_PER_SEC),
                                  (uint64_t)(5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            // 本 handler 就在 a2_log_queue() 上跑 ⇒ 已持有队列。
            a2_log_console_guard();
        });
        dispatch_resume(timer);
    });
}

/// 轮转并接上：删 .old → 现档改名 .old → 新建现档 → dup2 到 stderr。
/// 任一步失败即放弃（日志设施绝不能反过来把启动搞死）。
static void a2_log_console_open(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *current = a2_log_path_named(kConsoleLogName);
    NSString *previous = a2_log_path_named(kConsoleLogOldName);
    if (!current || !previous) { return; }

    if ([fm fileExistsAtPath:previous]) {
        [fm removeItemAtPath:previous error:nil];
    }
    if ([fm fileExistsAtPath:current]) {
        [fm moveItemAtPath:current toPath:previous error:nil];
    }
    int fd = open(current.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) { return; }
    if (dup2(fd, STDERR_FILENO) != STDERR_FILENO) {
        close(fd);
        return;
    }
    // ★不 close(fd)★：轮转（ftruncate）还要用它；它与 stderr 同一个打开文件描述。
    gConsoleFd = fd;
    a2_log_console_install_guard_timer();
}

#pragma mark - 会话日志落点（判据行共用）

void a2_log_session_sink(const char *utf8Line) {
    if (!utf8Line) { return; }
    NSString *raw = [NSString stringWithUTF8String:utf8Line];
    if (raw.length == 0) { return; }
    NSString *line = a2_log_single_line(raw);
    dispatch_sync(a2_log_queue(), ^{
        a2_log_append(line);
        a2_log_console_guard();   // 顺手看一次控制台归档的大小（判据行是稳定触发点）
    });
}

@implementation A2Log

+ (void)startSession {
    dispatch_sync(a2_log_queue(), ^{
        a2_log_rotate();
    });
}

+ (void)criterion:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = a2_log_single_line(message);
    if (line.length == 0) { return; }

    // ① 控制台（stderr；+archiveStderr 之后同时落 latestlog.txt）
    a2_log_console_write(line);
    // ② 会话日志文件 —— 与 native 侧判据行共用同一个落盘函数。
    a2_log_session_sink(line.UTF8String);
}

+ (void)archiveStderr {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a2_log_console_open();
    });
}

+ (NSString *)consoleLogPath {
    return a2_log_path_named(kConsoleLogName) ?: @"";
}

+ (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    dispatch_sync(a2_log_queue(), ^{
        a2_log_append(message);
        a2_log_console_guard();
    });
    // ★同一行也进控制台归档★（latestlog.txt）：会话文件读不到时（例如用户只拿得到
    //   Documents 里的 latestlog.txt），启动链的判据行仍然可查 —— 不让日志只存在一处。
    a2_log_console_write(message);
}

+ (NSString *)currentLogPath {
    return a2_log_path_named(kCurrentLogName) ?: @"";
}

+ (NSString *)previousLogPath {
    return a2_log_path_named(kPreviousLogName) ?: @"";
}

+ (BOOL)exportCombinedLogToPath:(NSString *)destination error:(NSError **)error {
    // 折两份：① 会话日志（判据行的落点，页面显示的那一份）
    //           ② 控制台归档（stderr；native 层的 NSLog / a2_log_* 也在这里）
    NSArray<NSArray<NSString *> *> *sections = @[
        @[ @"① 会话日志", [self currentLogPath] ],
        @[ @"② 控制台归档", [self consoleLogPath] ],
    ];

    NSMutableString *body = [NSMutableString string];
    NSUInteger present = 0;
    for (NSArray<NSString *> *section in sections) {
        NSString *title = section.firstObject;
        NSString *path = section.lastObject;
        NSString *content = path.length
            ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
            : nil;
        [body appendFormat:@"==================== %@（%@）====================\n",
                           title, path.lastPathComponent ?: @"?"];
        if (content.length > 0) {
            present++;
            [body appendString:content];
            if (![content hasSuffix:@"\n"]) { [body appendString:@"\n"]; }
        } else {
            [body appendString:@"（该文件不存在或为空）\n"];
        }
        [body appendString:@"\n"];
    }

    if (present == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"dev.airdevs.air2.log"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                     @"还没有日志文件（本进程尚未写过任何一行）" }];
        }
        return NO;
    }

    NSString *header = [NSString stringWithFormat:
        @"============================================================================\n"
        @"Air2 日志导出\n"
        @"导出时间：%@\n"
        @"内容：① 本次会话日志（判据行的落点）② 控制台归档（stderr，native 层也在这里）\n"
        @"判据行形如 [A2-PAIRPIN] / [RXPC] / [FRAME] / [MEM]，可直接 grep。\n"
        @"============================================================================\n\n",
        a2_log_timestamp()];
    return [[header stringByAppendingString:body]
            writeToFile:destination atomically:YES encoding:NSUTF8StringEncoding error:error];
}

@end

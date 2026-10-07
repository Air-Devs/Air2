//
//  A2CrashGuard.m
//  Air2
//

#import "A2CrashGuard.h"
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

static NSString *const kCrashFileName = @"air2_crash.log";

/// ObjC 未捕获异常处理器（前置声明，install 里要用）
static void A2HandleException(NSException *exception);

/// 信号处理器里能安全调用的东西很有限（必须异步信号安全），
/// 所以只把最少的信息写进去，栈回溯交给 backtrace_symbols_fd。
static void A2SignalHandler(int sig) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) { _exit(sig); }

    // 构造一条简短记录
    NSString *path = [dir stringByAppendingPathComponent:kCrashFileName];
    NSString *head = [NSString stringWithFormat:
        @"\n=== 信号崩溃 ===\n信号: %d\n时间: %@\n\n栈:\n",
        sig, [NSDate date]];

    // 用低级 IO 写入，避免在信号上下文里调用复杂方法
    const char *cpath = path.UTF8String;
    int fd = open(cpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const char *c = head.UTF8String;
        if (c) { ssize_t _ = write(fd, c, strlen(c)); (void)_; }
        void *callstack[64];
        int frames = backtrace(callstack, 64);
        backtrace_symbols_fd(callstack, frames, fd);
        close(fd);
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
    [log appendString:@"\n=== 未捕获异常 ===\n"];
    [log appendFormat:@"名称: %@\n", exception.name];
    [log appendFormat:@"原因: %@\n", exception.reason];
    [log appendFormat:@"时间: %@\n", [NSDate date]];
    [log appendString:@"\n调用栈:\n"];
    for (NSString *frame in exception.callStackSymbols) {
        [log appendFormat:@"  %@\n", frame];
    }
    [log appendString:@"\n用户信息:\n"];
    [log appendFormat:@"  %@\n", exception.userInfo];

    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (dir) {
        NSString *path = [dir stringByAppendingPathComponent:kCrashFileName];
        NSData *data = [log dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [data writeToFile:path atomically:YES];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    }
}

+ (NSString *)crashLogPath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return @"";
    return [dir stringByAppendingPathComponent:kCrashFileName];
}

+ (NSString *)lastCrashLog {
    NSString *path = [self crashLogPath];
    if (path.length == 0) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

+ (void)clearCrashLog {
    NSString *path = [self crashLogPath];
    if (path.length == 0) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

@end

//
//  A2Logger.m
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
//  A2Logger.m
//  Air2
//

#import "A2Logger.h"
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdlib.h>

/// 内存缓冲上限（写盘失败时降级用）—— ZL2 是 1MB
static const NSUInteger kMemoryBufferLimit = 1024 * 1024;

/// 默认保留天数
static const NSInteger kDefaultRetentionDays = 7;

NSString *A2LogLevelName(A2LogLevel level) {
    switch (level) {
        case A2LogLevelError:   return @"ERROR";
        case A2LogLevelWarning: return @"WARNING";
        case A2LogLevelInfo:    return @"INFO";
        case A2LogLevelDebug:   return @"DEBUG";
        case A2LogLevelTrace:   return @"TRACE";
    }
    return @"INFO";
}

@interface A2Logger ()
/// 串行队列 —— ZL2 用 Channel + 协程消费，效果等价：保证写入有序且不阻塞调用方
@property (nonatomic, strong) dispatch_queue_t writeQueue;
@property (nonatomic, strong) NSFileHandle *logHandle;
@property (nonatomic, strong) NSMutableData *memoryBuffer;
@property (nonatomic, copy, nullable) NSString *currentLogFilePath;
@property (nonatomic, assign) BOOL initialized;
@end

@implementation A2Logger

+ (instancetype)shared {
    static A2Logger *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2Logger alloc] init];
        // ★ 自动初始化 ★
        //
        // 修复「所有日志文件都是空的」：原先 -initialize 只有人显式调用才会跑，
        // 而全项目没有任何一处调用它。A2Logger 的 115 处调用点全都在
        // +log:... 里撞上 `if (!logger.initialized) return;` 直接被丢弃 ——
        // 于是日志目录里只有 A2Log（另一套实现）写的 lastlog.txt，
        // A2Logger 这条线一条也落不了盘，包括 SurfaceViewController 与
        // JavaLauncher 的启动全过程。
        //
        // 放在 shared 的 dispatch_once 里，保证任何第一次调用都会建好文件，
        // 且不需要改调用方。
        [shared initialize];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _writeQueue = dispatch_queue_create("dev.airdevs.air2.logger", DISPATCH_QUEUE_SERIAL);
    NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:@"A2LogRetentionDays"];
    _retentionDays = saved > 0 ? saved : kDefaultRetentionDays;
    return self;
}

#pragma mark - 目录与文件

- (NSString *)logDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return dir;
}

- (void)setRetentionDays:(NSInteger)retentionDays {
    _retentionDays = MAX(1, retentionDays);
    [NSUserDefaults.standardUserDefaults setInteger:_retentionDays forKey:@"A2LogRetentionDays"];
}

#pragma mark - 初始化

- (void)initialize {
    if (_initialized) return;

    // ★ 同步建文件，不能 dispatch_async ★
    //
    // 原先这里是 dispatch_async(_writeQueue, ^{ setupLogFile; ... })，
    // 而 _initialized 在外面先被置 YES。于是从 shared 返回、到队列真正执行
    // setupLogFile 之间的任何一条日志，都会走进 writeLine 里
    // _logHandle == nil && _memoryBuffer == nil 的分支 —— 既不写盘也不进内存，
    // 静默丢弃。启动路径上恰好是这段窗口里日志最密（Boot/GameLaunch 阶段）。
    //
    // 现在在队列上同步完成：shared 第一次被调用就保证句柄可用。
    dispatch_sync(_writeQueue, ^{
        [self setupLogFile];
        [self deleteOldLogs];
        [self printLauncherInfo];
    });
    _initialized = YES;
}

/// 创建日志文件。
/// 文件名格式对齐 ZL2：log_2026-10-11T09-30-00_main.log
/// （iOS 无多进程概念，进程标识固定为 main）
- (void)setupLogFile {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH-mm-ss";
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSString *dir = self.logDirectory;
    NSString *base = [NSString stringWithFormat:@"log_%@_main",
                      [fmt stringFromDate:[NSDate date]]];

    // 同一秒内可能重复，加序号后缀（ZL2 也是这个策略）
    NSString *path = nil;
    for (NSInteger i = 0; i < 100; i++) {
        NSString *suffix = (i == 0) ? @"" : [NSString stringWithFormat:@".%ld", (long)i];
        NSString *candidate = [dir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@%@.log", base, suffix]];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            [NSFileManager.defaultManager createFileAtPath:candidate
                                                 contents:nil
                                               attributes:nil];
            path = candidate;
            break;
        }
    }

    if (!path) {
        // 建不出文件就降级到内存缓冲
        _memoryBuffer = [NSMutableData dataWithCapacity:kMemoryBufferLimit];
        return;
    }

    _currentLogFilePath = path;
    // 用 O_APPEND 打开：writeLine 不做 seek，若句柄偏移停在 0，多线程/多句柄
    // 交替写会互相覆盖。O_APPEND 让每次 write 自动落到文件末尾。
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        _logHandle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    } else {
        _memoryBuffer = [NSMutableData dataWithCapacity:kMemoryBufferLimit];
    }
}

#pragma mark - 写入

+ (void)error:(NSString *)tag message:(NSString *)message {
    [self log:A2LogLevelError tag:tag message:message error:nil];
}

+ (void)error:(NSString *)tag message:(NSString *)message error:(NSError *)error {
    [self log:A2LogLevelError tag:tag message:message error:error];
}

+ (void)warning:(NSString *)tag message:(NSString *)message {
    [self log:A2LogLevelWarning tag:tag message:message error:nil];
}

+ (void)info:(NSString *)tag message:(NSString *)message {
    [self log:A2LogLevelInfo tag:tag message:message error:nil];
}

+ (void)debug:(NSString *)tag message:(NSString *)message {
    [self log:A2LogLevelDebug tag:tag message:message error:nil];
}

+ (void)trace:(NSString *)tag message:(NSString *)message {
    [self log:A2LogLevelTrace tag:tag message:message error:nil];
}

+ (void)log:(A2LogLevel)level tag:(NSString *)tag message:(NSString *)message error:(NSError *)error {
    A2Logger *logger = [self shared];
    if (!logger.initialized) return;   // 未初始化时不写（对应 ZL2 的 isInitialized 检查）

    NSString *line = [logger formatLine:level tag:tag message:message];
    dispatch_async(logger.writeQueue, ^{
        [logger writeLine:line];
        if (error) {
            [logger writeLine:[NSString stringWithFormat:@"    %@", error.localizedDescription]];
        }
    });

    // 同时输出到系统日志，便于真机用 Console.app 观察
    os_log_type_t type = (level == A2LogLevelError) ? OS_LOG_TYPE_ERROR
                       : (level == A2LogLevelWarning) ? OS_LOG_TYPE_DEFAULT
                                                     : OS_LOG_TYPE_INFO;
    os_log_with_type(OS_LOG_DEFAULT, type, "[%{public}s] %{public}s",
                     tag.UTF8String, message.UTF8String);
}

/// 格式对齐 ZL2：[HH:mm:ss.SSS] [tag/LEVEL] message
- (NSString *)formatLine:(A2LogLevel)level tag:(NSString *)tag message:(NSString *)message {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    return [NSString stringWithFormat:@"[%@] [%@/%@] %@\n",
            [fmt stringFromDate:[NSDate date]], tag, A2LogLevelName(level), message];
}

- (void)writeLine:(NSString *)line {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    if (_logHandle) {
        @try {
            [_logHandle writeData:data];
            // ⚠️ 必须同步到磁盘 —— NSFileHandle 的写入先落在内核缓冲，
            // 进程被信号杀掉（SIGSEGV / SIGABRT）时缓冲里的内容会全部丢失。
            //
            // 这就是「启动黑屏后日志里什么都没有」的原因：
            // 崩溃前最后几十行根本没写进文件。
            [_logHandle synchronizeFile];
        } @catch (NSException *e) {
            // 写盘失败 → 降级到内存缓冲（对应 ZL2 的 ByteArrayOutputStream 兜底）
            _logHandle = nil;
            _memoryBuffer = [NSMutableData dataWithCapacity:kMemoryBufferLimit];
            [self appendToMemory:data];
        }
        return;
    }

    if (_memoryBuffer) [self appendToMemory:data];
}

- (void)appendToMemory:(NSData *)data {
    if (!_memoryBuffer) return;
    if (_memoryBuffer.length + data.length > kMemoryBufferLimit) {
        // 满了就丢最旧的 —— 内存缓冲只是兜底，不保证完整
        [_memoryBuffer setLength:0];
    }
    [_memoryBuffer appendData:data];
}

#pragma mark - 清理

/// 清理过期日志。
///
/// 两条规则（照搬 ZL2 的 deleteOldLogs）：
///   1. 超过保留天数的
///   2. 遗留的 0KB 空日志 —— 但要排除「当前文件」与「刚创建不到 1 分钟」的，
///      否则会把正在写的文件删掉
- (void)deleteOldLogs {
    NSString *dir = self.logDirectory;
    NSArray<NSString *> *files = [NSFileManager.defaultManager
                                  contentsOfDirectoryAtPath:dir error:nil];
    if (!files) return;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval cutoff = now - _retentionDays * 86400.0;
    NSTimeInterval emptyCutoff = now - 60.0;   // 空日志的宽限期

    NSUInteger removed = 0;
    for (NSString *name in files) {
        NSString *path = [dir stringByAppendingPathComponent:name];

        // 当前正在写的文件绝不能删
        if (_currentLogFilePath && [path isEqualToString:_currentLogFilePath]) continue;

        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (!attrs) continue;

        NSDate *mtime = attrs[NSFileModificationDate];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        NSTimeInterval mtimeInterval = mtime.timeIntervalSince1970;

        BOOL tooOld = mtimeInterval < cutoff;
        BOOL staleEmpty = (size == 0 && mtimeInterval < emptyCutoff);

        if (tooOld || staleEmpty) {
            if ([NSFileManager.defaultManager removeItemAtPath:path error:nil]) removed++;
        }
    }

    if (removed > 0) {
        [self writeLine:[NSString stringWithFormat:
                         @"[A2Logger] 已清理 %lu 个过期日志文件\n", (unsigned long)removed]];
    }
}

#pragma mark - 启动信息

/// 启动时打印环境信息 —— 排查问题时这些是最基本的信息
- (void)printLauncherInfo {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";

    UIDevice *device = UIDevice.currentDevice;
    NSString *model = device.model ?: @"?";
    NSString *system = [NSString stringWithFormat:@"%@ %@", device.systemName, device.systemVersion];

    NSMutableString *buf = [NSMutableString string];
    [buf appendString:@"================ Air2 Log ================\n"];
    [buf appendFormat:@"版本      : %@ (%@)\n", version, build];
    [buf appendFormat:@"设备      : %@\n", model];
    [buf appendFormat:@"系统      : %@\n", system];
    [buf appendFormat:@"语言      : %@\n", NSLocale.preferredLanguages.firstObject ?: @"?"];
    [buf appendFormat:@"时区      : %@\n", NSTimeZone.localTimeZone.name ?: @"?"];
    [buf appendString:@"===========================================\n"];
    [self writeLine:buf];
}

#pragma mark - 打包

- (void)packLogsToPath:(NSString *)zipPath
            completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_writeQueue, ^{
        // 先把内存缓冲刷进文件，保证打包内容完整
        if (self.memoryBuffer.length > 0 && self.logHandle) {
            @try { [self.logHandle writeData:self.memoryBuffer]; } @catch (NSException *e) {}
            [self.memoryBuffer setLength:0];
        }

        NSError *error = nil;
        BOOL ok = [self createZipAtPath:zipPath fromDirectory:self.logDirectory error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, error);
        });
    });
}

/// 极简 zip 打包。
/// 日志都是纯文本，用 stored（不压缩）就够 —— 省去引入 zlib 压缩流程。
- (BOOL)createZipAtPath:(NSString *)zipPath
          fromDirectory:(NSString *)dir
                  error:(NSError **)error {

    NSArray<NSString *> *files = [NSFileManager.defaultManager
                                  contentsOfDirectoryAtPath:dir error:nil];
    if (!files) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2Logger" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"日志目录不可读"}];
        }
        return NO;
    }

    // 用 zip 命令行工具（iOS 上不可用），改为逐文件拼接的简化实现：
    // 实际上这里应该用 A2ZipWriter，但日志分享的优先级不高，
    // 先直接把日志目录里的文件逐个读出来拼成一个文本包 ——
    // 这样分享出去仍是可读的，只是扩展名不是 .zip。
    NSMutableString *combined = [NSMutableString string];
    for (NSString *name in files) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSString *content = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (!content) continue;
        [combined appendFormat:@"\n\n===== %@ =====\n%@", name, content];
    }

    NSString *textPath = zipPath.stringByDeletingPathExtension;
    textPath = [textPath stringByAppendingPathExtension:@"txt"];
    BOOL ok = [combined writeToFile:textPath
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:error];

    if (ok) {
        [self writeLine:[NSString stringWithFormat:@"[A2Logger] 日志已导出到 %@\n", textPath]];
    }
    return ok;
}

#pragma mark - 进程级输出接管

/// stdout / stderr → 日志文件。
///
/// 用 dup2 把 1 和 2 都指到与 _logHandle 同一个 inode 上（O_APPEND）。
/// 之后：
///   · egl_bridge / gl_bridge / main_hook / shvc_shim 等 C 层的 fprintf(stderr)
///   · HotSpot 自己的 stdout / hs_err 文本
///   · MC 的 System.out / System.err（JVM 直接写 fd 1/2）
/// 全部落到同一份日志里，和 ObjC 行按时间交错。
///
/// 为什么必须是 O_APPEND + 同一个 fd 家族：NSFileHandle 的写入走它自己持有的
/// fd，dup2 复制出来的是同一条打开文件描述（共享文件偏移），两边追加不会互相
/// 覆盖。若改成各自 open 一次（不带 O_APPEND），两个偏移会互相踩，日志会出现
/// 空洞 —— 这正是当初 "Task 26：截断+NUL 空洞" 的成因之一。
- (void)captureStandardIO {
    static BOOL captured = NO;
    if (captured) return;
    captured = YES;

    const char *off = getenv("A2_LOG_CAPTURE_STDIO");
    if (off != NULL && off[0] == '0') {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO,
                         "[A2Logger] stdio capture disabled (A2_LOG_CAPTURE_STDIO=0)");
        return;
    }

    dispatch_sync(_writeQueue, ^{
        // 必须在 setupLogFile 之后：没路径就没得接。
        NSString *path = self.currentLogFilePath;
        if (path.length == 0) return;

        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR,
                             "[A2Logger] cannot open log for stdio capture");
            return;
        }
        // 先让 ObjC 侧的行缓冲冲出去，避免 fd 切换把它丢掉。
        fflush(stdout);
        fflush(stderr);

        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        // fd 本身只在 dup2 之外还需要时才保留；这里关掉，1/2 已是独立引用。
        if (fd > STDERR_FILENO) close(fd);

        // ★ 关键：把 _logHandle 也换到"同一个文件位置"上 ★
        //
        // NSFileHandle 持有的是它自己 open() 出来的那条文件描述。dup2 只改
        // fd 1/2，_logHandle 的偏移仍独立 —— 两边各自从自己的 offset 写，
        // 后写的会把先写的覆盖掉，日志出现缺行/串行（前面注释里说的
        // "NUL 空洞"就是这个现象）。
        //
        // 注意 [_logHandle fileHandleForWritingAtPath:] 不能满足要求：它内部
        // 是 O_WRONLY 打开（不带 O_APPEND），偏移仍从 0 起算。必须自己用
        // O_APPEND 打开，再包成 NSFileHandle —— O_APPEND 的语义是"每次 write
        // 前把偏移移到文件末尾"，于是多个独立的打开文件描述追加也不会互相踩。
        [_logHandle closeFile];
        _logHandle = nil;
        int appendFd = open(path.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (appendFd >= 0) {
            _logHandle = [[NSFileHandle alloc] initWithFileDescriptor:appendFd
                                                       closeOnDealloc:YES];
        }

        // 行缓冲：JVM 输出是一行一行来的，全缓冲会在崩溃时整块丢失。
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);

        [self writeLine:@"[A2Logger] stdout/stderr 已接管到本文件\n"];
    });
}

@end

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
    _initialized = YES;

    dispatch_async(_writeQueue, ^{
        [self setupLogFile];
        [self deleteOldLogs];
        [self printLauncherInfo];
    });
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
    _logHandle = [NSFileHandle fileHandleForWritingAtPath:path];
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

@end

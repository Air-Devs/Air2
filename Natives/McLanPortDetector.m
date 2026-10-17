//
//  McLanPortDetector.m
//  Amethyst
//
//  ★ [PORT-AUTO] MC 局域网端口自动探测实现（只读日志，不 bind 端口）
//

#import "McLanPortDetector.h"

#include <stdlib.h>
#include <string.h>

/// 单次日志读取上限（只读末尾，避免大日志拖慢主循环）
static const NSUInteger kPortAutoReadCap = 8 * 1024 * 1024;
static const uint16_t    kPortAutoMinPort = 1024;    // 非特权范围
static const uint16_t    kPortAutoMaxPort = 65535;
static const NSTimeInterval kPortAutoPollInterval = 1.0;

@implementation McLanPortDetector {
    dispatch_queue_t _queue;
    dispatch_source_t _pollTimer;
    uint16_t _lastReported;
}

#pragma mark - Singleton

+ (instancetype)sharedDetector {
    static McLanPortDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("mclanport.detect", dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _lastReported = 0;
    }
    return self;
}

- (BOOL)polling {
    return _pollTimer != nil;
}

#pragma mark - 路径解析

+ (NSString *)launcherHome {
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) return @(home);
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (NSString *)resolveGameDirectoryWithInstanceName:(NSString *)instanceName {
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return @(root);
    NSString *home = [self launcherHome];
    if (home.length == 0) return nil;
    NSString *name = instanceName.length > 0 ? instanceName : @"default";
    return [NSString stringWithFormat:@"%@/instances/%@", home, name];
}

#pragma mark - 读取日志

/// 只读文件末尾 cap 字节（大日志不全量读）。
static NSData *AmePortAutoReadTail(NSString *path, NSUInteger cap) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) return nil;
    unsigned long long size = [fh seekToEndOfFile];
    unsigned long long off = (size > cap) ? (size - cap) : 0;
    [fh seekToFileOffset:off];
    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];
    return data;
}

static NSString *AmePortAutoDataToText(NSData *data) {
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return text ?: @"";
}

#pragma mark - 解析

/// 具体的「开局域网」日志形态（大小写不敏感）。取最后一次出现的匹配。
+ (NSArray<NSRegularExpression *> *)specificPatterns {
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *raw = @[
            @"(?i)started\\s+serving\\s+on\\s+port\\s+(\\d{2,5})",
            @"(?i)local\\s+game\\s+hosted\\s+on\\s+port\\s+(\\d{2,5})",
            @"(?i)(?:opening|open(?:ed)?)\\s+lan\\s+on\\s+port\\s+(\\d{2,5})",
        ];
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *p in raw) {
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
            if (re) [arr addObject:re];
        }
        patterns = arr;
    });
    return patterns;
}

/// 含「局域网」关键词的整行（兜底：形态未知时用）。
+ (NSRegularExpression *)genericLinePattern {
    static NSRegularExpression *re;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(?i)(?:serving|hosted|\\blan\\b|局域网|open\\s+to\\s+lan)" options:0 error:nil];
    });
    return re;
}

/// 取一行里【最后一个】形如端口的数字（1024..65535）；无则 0。
+ (uint16_t)lastPortInLine:(NSString *)line {
    static NSRegularExpression *numRe;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        numRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d{2,5})" options:0 error:nil];
    });
    __block uint16_t found = 0;
    [numRe enumerateMatchesInString:line options:0 range:NSMakeRange(0, line.length)
                         usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        NSRange r = [result rangeAtIndex:1];
        if (r.location == NSNotFound) return;
        NSInteger v = [[line substringWithRange:r] integerValue];
        if (v >= kPortAutoMinPort && v <= kPortAutoMaxPort) found = (uint16_t)v;
    }];
    return found;
}

+ (uint16_t)parsePortFromLogText:(NSString *)text {
    if (text.length == 0) return 0;
    __block uint16_t best = 0;
    __block NSUInteger bestLoc = NSNotFound;
    NSRange full = NSMakeRange(0, text.length);

    /* 1) 具体形态 */
    for (NSRegularExpression *re in [self specificPatterns]) {
        [re enumerateMatchesInString:text options:0 range:full
                          usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            if (result.numberOfRanges < 2) return;
            NSRange r = [result rangeAtIndex:1];
            if (r.location == NSNotFound) return;
            NSInteger v = [[text substringWithRange:r] integerValue];
            if (v < kPortAutoMinPort || v > kPortAutoMaxPort) return;
            if (bestLoc == NSNotFound || result.range.location >= bestLoc) {
                bestLoc = result.range.location;
                best = (uint16_t)v;
            }
        }];
    }

    /* 2) 兜底：含关键词的整行里取端口（仍以「最后一次出现」为准） */
    NSRegularExpression *generic = [self genericLinePattern];
    if (generic) {
        [generic enumerateMatchesInString:text options:0 range:full
                              usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            NSRange lineRange = [text lineRangeForRange:result.range];
            NSString *line = [text substringWithRange:lineRange];
            NSString *low = line.lowercaseString;
            if (![low containsString:@"port"]) return;
            uint16_t v = [McLanPortDetector lastPortInLine:line];
            if (v == 0) return;
            if (bestLoc == NSNotFound || result.range.location >= bestLoc) {
                bestLoc = result.range.location;
                best = v;
            }
        }];
    }
    return best;
}

+ (uint16_t)detectPortInLogFiles:(NSArray<NSString *> *)paths {
    NSFileManager *fm = [NSFileManager defaultManager];
    uint16_t bestPort = 0;
    NSTimeInterval bestMtime = -1;
    for (NSString *path in paths) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        NSTimeInterval mtime = [attr[NSFileModificationDate] timeIntervalSince1970];
        NSData *data = AmePortAutoReadTail(path, kPortAutoReadCap);
        NSString *text = AmePortAutoDataToText(data);
        uint16_t port = [self parsePortFromLogText:text];
        NSLog(@"[PORT-AUTO] scan path=%@ size=%lu mtime=%.0f -> port=%u",
              path, (unsigned long)data.length, mtime, port);
        /* 取「有匹配且 mtime 最新」的那份 = 最近一次开局域网 */
        if (port > 0 && mtime >= bestMtime) {
            bestMtime = mtime;
            bestPort = port;
        }
    }
    return bestPort;
}

/// 追加某个 logs 目录下的 *.log / *.txt（按 mtime 降序）。
+ (void)appendLogCandidatesInDirectory:(NSString *)logsDir to:(NSMutableArray<NSString *> *)paths {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (logsDir.length == 0 || ![fm fileExistsAtPath:logsDir isDirectory:&isDir] || !isDir) return;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:logsDir error:nil];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *name in names) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"log"] || [ext isEqualToString:@"txt"])) continue;
        NSString *full = [logsDir stringByAppendingPathComponent:name];
        NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
        NSTimeInterval mtime = [attr[NSFileModificationDate] timeIntervalSince1970];
        [entries addObject:@{@"p": full, @"m": @(mtime)}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"m"] compare:a[@"m"]];
    }];
    for (NSDictionary *e in entries) {
        NSString *p = e[@"p"];
        if (![paths containsObject:p]) [paths addObject:p];
    }
}

+ (uint16_t)detectPortInGameDirectory:(NSString *)gameDir launcherHome:(NSString *)home {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (gameDir.length > 0) {
        [paths addObject:[gameDir stringByAppendingPathComponent:@"logs/latest.log"]];
        [paths addObject:[gameDir stringByAppendingPathComponent:@"logs/latestlog.txt"]];
        [paths addObject:[gameDir stringByAppendingPathComponent:@"latestlog.txt"]];
    }
    if (home.length > 0) {
        [paths addObject:[home stringByAppendingPathComponent:@"latestlog.txt"]];
        [paths addObject:[home stringByAppendingPathComponent:@"latestlog.old.txt"]];
    }
    if (gameDir.length > 0) [self appendLogCandidatesInDirectory:[gameDir stringByAppendingPathComponent:@"logs"] to:paths];
    if (home.length > 0) [self appendLogCandidatesInDirectory:[home stringByAppendingPathComponent:@"logs"] to:paths];
    return [self detectPortInLogFiles:paths];
}

#pragma mark - 轮询

- (void)startPollingGameDirectory:(NSString *)gameDir
                     launcherHome:(NSString *)home
                          handler:(void (^)(uint16_t))handler {
    [self stopPolling];
    if (handler == nil) return;
    _lastReported = 0;
    NSLog(@"[PORT-AUTO] start polling gameDir=%@ home=%@ interval=%.1fs", gameDir ?: @"(nil)", home ?: @"(nil)", kPortAutoPollInterval);

    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_pollTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kPortAutoPollInterval * NSEC_PER_SEC),
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        uint16_t port = [McLanPortDetector detectPortInGameDirectory:gameDir launcherHome:home];
        if (port == 0) return;
        if (port == strongSelf->_lastReported) return;
        strongSelf->_lastReported = port;
        NSLog(@"[PORT-AUTO] detected MC LAN port=%u (last occurrence in logs)", port);
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(port);
        });
    });
    dispatch_resume(_pollTimer);
}

- (void)stopPolling {
    if (_pollTimer != nil) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
        _lastReported = 0;
        NSLog(@"[PORT-AUTO] stop polling");
    }
}

@end

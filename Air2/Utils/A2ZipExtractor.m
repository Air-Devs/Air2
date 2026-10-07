//
//  A2ZipExtractor.m
//  Air2
//

#import "A2ZipExtractor.h"
#import "A2ZipReader.h"

NSString *const A2ZipExtractorErrorDomain = @"A2ZipExtractor";

@interface A2ZipExtractor ()
@property (nonatomic, strong) A2ZipReader *reader;
@end

@implementation A2ZipExtractor

+ (instancetype)extractorWithReader:(A2ZipReader *)reader {
    A2ZipExtractor *extractor = [A2ZipExtractor new];
    extractor.reader = reader;
    return extractor;
}

static NSError *A2ZipExtractorError(A2ZipExtractorErrorCode code, NSString *message) {
    return [NSError errorWithDomain:A2ZipExtractorErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"解压失败"}];
}

/// 把条目名归一化成可安全落盘的相对路径，返回 nil 表示必须拒绝该条目。
///
/// 整合包是外部输入，条目名完全由打包方决定：
///   · 绝对路径会覆盖目标目录之外的文件
///   · .. 分量会向上跳出目标目录
///   · 盘符或 : 在部分文件系统上有特殊语义
/// 这几类一律拒绝。
static NSString *A2SafeRelativePath(NSString *raw) {
    if (raw.length == 0) return nil;
    if ([raw hasPrefix:@"/"] || [raw hasPrefix:@"\\"]) return nil;

    // 统一分隔符后再逐段检查
    NSString *normalized = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [normalized componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) return nil;
        if ([part containsString:@":"]) return nil;
        [parts addObject:part];
    }
    // 归一化后什么都不剩，说明是 "." 或 "./" 这类空条目
    if (parts.count == 0) return nil;
    return [parts componentsJoinedByString:@"/"];
}

- (NSArray<NSString *> *)entryNamesWithPrefix:(NSString *)prefix {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in self.reader.entryNames) {
        if (prefix.length == 0 || [name hasPrefix:prefix]) [out addObject:name];
    }
    return out;
}

- (BOOL)extractToDirectory:(NSString *)directory
               entryPrefix:(NSString *)rawPrefix
                 overwrite:(BOOL)overwrite
                  progress:(void (^)(NSUInteger, NSUInteger))progress
                     error:(NSError **)error {
    if (!self.reader) {
        if (error) *error = A2ZipExtractorError(A2ZipExtractorErrorNoReader, @"zip 读取器为空");
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:directory isDirectory:&isDir] || !isDir) {
        if (![fm createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:error]) {
            if (error && !*error) {
                *error = A2ZipExtractorError(A2ZipExtractorErrorCreateDirectory,
                                             @"创建目标目录失败");
            }
            return NO;
        }
    }

    // 前缀统一带尾斜杠，否则 "mods" 会误匹配 "mods_old/xxx"
    NSString *prefix = rawPrefix.length > 0 ? rawPrefix : nil;
    if (prefix && ![prefix hasSuffix:@"/"]) {
        prefix = [prefix stringByAppendingString:@"/"];
    }

    NSString *rootPrefix = [[directory stringByStandardizingPath] stringByAppendingString:@"/"];
    NSArray<NSString *> *names = [self entryNamesWithPrefix:prefix];
    NSUInteger total = names.count;
    NSUInteger completed = 0;

    for (NSString *name in names) {
        // 剥掉前缀，得到相对目标目录的路径
        NSString *relative = prefix.length > 0 ? [name substringFromIndex:prefix.length] : name;
        NSString *safe = A2SafeRelativePath(relative);

        // relative 为空或目录条目、以及不安全条目：跳过但计入进度，
        // 避免进度条停在最后不动
        if (safe) {
            NSString *full = [directory stringByAppendingPathComponent:safe];
            // 归一化后确认仍在目标目录内（.. 已在上面拦掉，这里是双保险）
            BOOL inside = [[full stringByStandardizingPath] hasPrefix:rootPrefix];

            if (!inside) {
                safe = nil;
            } else if (!overwrite && [fm fileExistsAtPath:full]) {
                safe = nil;   // 不需要覆盖，跳过
            } else {
                NSString *parent = [full stringByDeletingLastPathComponent];
                if (![fm createDirectoryAtPath:parent
                    withIntermediateDirectories:YES attributes:nil error:NULL]) {
                    if (error) {
                        *error = A2ZipExtractorError(A2ZipExtractorErrorCreateDirectory,
                            [NSString stringWithFormat:@"创建目录失败：%@", parent]);
                    }
                    return NO;
                }

                NSData *data = [self.reader dataForEntry:name];
                if (!data) {
                    if (error) {
                        *error = A2ZipExtractorError(A2ZipExtractorErrorReadEntry,
                            [NSString stringWithFormat:@"条目数据损坏：%@", name]);
                    }
                    return NO;
                }
                if (![data writeToFile:full options:NSDataWritingAtomic error:error]) {
                    if (error && !*error) {
                        *error = A2ZipExtractorError(A2ZipExtractorErrorWriteEntry,
                            [NSString stringWithFormat:@"写入失败：%@", safe]);
                    }
                    return NO;
                }
            }
        }

        completed++;
        if (progress) progress(completed, total);
    }

    return YES;
}

@end

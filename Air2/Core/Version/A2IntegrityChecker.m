//
//  A2IntegrityChecker.m
//  Air2
//

#import "A2IntegrityChecker.h"
#import "A2Logger.h"
#import "A2VersionIsolation.h"
#import <CommonCrypto/CommonDigest.h>

@implementation A2IntegrityIssue
@end

@implementation A2IntegrityReport
- (BOOL)clean {
    return self.issues.count == 0;
}
@end

@implementation A2IntegrityChecker

#pragma mark - SHA1

static NSString *A2SHA1OfFile(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    // 分块读 —— 客户端 jar 有几十 MB，一次读进内存会爆
    const size_t chunk = 256 * 1024;
    @try {
        while (YES) {
            @autoreleasepool {
                NSData *d = [fh readDataOfLength:chunk];
                if (d.length == 0) break;
                CC_SHA1_Update(&ctx, d.bytes, (CC_LONG)d.length);
            }
        }
    } @catch (NSException *e) {
        [fh closeFile];
        return nil;
    }
    [fh closeFile];

    unsigned char digest[20];
    CC_SHA1_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < 20; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark - 检查

- (void)checkVersion:(NSString *)versionName
            gameHome:(NSString *)gameHome
                mode:(A2IntegrityCheckMode)mode
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(A2IntegrityReport *))completion {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDate *start = [NSDate date];
        A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];

        NSMutableArray<A2IntegrityIssue *> *issues = [NSMutableArray array];
        NSInteger total = 0;
        NSInteger ok = 0;

        // ---- 收集待检查项 ----
        // 每项：[目标路径, 期望SHA1(可空), 期望大小, 类别]
        NSMutableArray<NSArray *> *items = [NSMutableArray array];

        // 1. 版本 JSON
        NSString *jsonPath = [path versionJSONPath:versionName];
        NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath];
        if (!jsonData) {
            A2IntegrityIssue *i = [A2IntegrityIssue new];
            i.path = jsonPath;
            i.kind = @"版本信息";
            i.reason = @"缺失";
            [issues addObject:i];
        } else {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];

            // 2. 客户端 jar
            NSDictionary *client = json[@"downloads"][@"client"];
            if ([client isKindOfClass:NSDictionary.class]) {
                [items addObject:@[[path versionJarPath:versionName],
                                   client[@"sha1"] ?: @"",
                                   client[@"size"] ?: @0,
                                   @"客户端"]];
            }

            // 3. 依赖库
            NSArray *libs = json[@"libraries"];
            if ([libs isKindOfClass:NSArray.class]) {
                NSString *libRoot = [path librariesHome];
                for (NSDictionary *lib in libs) {
                    if (![lib isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *art = lib[@"downloads"][@"artifact"];
                    if (![art isKindOfClass:NSDictionary.class]) continue;
                    NSString *rel = art[@"path"];
                    if (!rel.length) continue;
                    [items addObject:@[[libRoot stringByAppendingPathComponent:rel],
                                       art[@"sha1"] ?: @"",
                                       art[@"size"] ?: @0,
                                       @"依赖库"]];
                }
            }

            // 4. 资源索引 + 资源对象
            NSDictionary *assetIndex = json[@"assetIndex"];
            NSString *objectsDir = nil;
            if ([assetIndex isKindOfClass:NSDictionary.class]) {
                NSString *indexName = [NSString stringWithFormat:@"%@.json",
                                       json[@"assets"] ?: @""];
                NSString *indexPath = [[path assetsIndexesHome]
                                       stringByAppendingPathComponent:indexName];
                [items addObject:@[indexPath, assetIndex[@"sha1"] ?: @"",
                                   assetIndex[@"size"] ?: @0, @"资源索引"]];

                NSData *idx = [NSData dataWithContentsOfFile:indexPath];
                if (idx) {
                    NSDictionary *idxJson = [NSJSONSerialization JSONObjectWithData:idx
                                                                           options:0 error:nil];
                    NSDictionary *objects = idxJson[@"objects"];
                    objectsDir = [path assetsObjectsHome];
                    if ([objects isKindOfClass:NSDictionary.class] && objectsDir) {
                        for (NSString *key in objects) {
                            NSDictionary *obj = objects[key];
                            NSString *hash = obj[@"hash"];
                            if (hash.length < 2) continue;
                            NSString *sub = [hash substringToIndex:2];
                            NSString *dest = [[objectsDir stringByAppendingPathComponent:sub]
                                              stringByAppendingPathComponent:hash];
                            // 资源文件的 hash 就是 SHA1
                            [items addObject:@[dest, hash, obj[@"size"] ?: @0, @"资源"]];
                        }
                    }
                }
            }
        }

        total = (NSInteger)items.count;

        // ---- 逐个检查 ----
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSUInteger i = 0; i < items.count; i++) {
            NSArray *it = items[i];
            NSString *file = it[0];
            NSString *expectSHA = it[1];
            long long expectSize = [it[2] longLongValue];
            NSString *kind = it[3];

            if (progress) {
                progress((double)i / (double)MAX(1, total), file.lastPathComponent);
            }

            NSDictionary *attrs = [fm attributesOfItemAtPath:file error:nil];
            if (!attrs) {
                A2IntegrityIssue *issue = [A2IntegrityIssue new];
                issue.path = file;
                issue.kind = kind;
                issue.reason = @"缺失";
                issue.expectedSHA1 = expectSHA;
                issue.expectedSize = expectSize;
                [issues addObject:issue];
                continue;
            }

            // 快速档：只比大小
            long long actualSize = [attrs[NSFileSize] longLongValue];
            if (expectSize > 0 && actualSize != expectSize) {
                A2IntegrityIssue *issue = [A2IntegrityIssue new];
                issue.path = file;
                issue.kind = kind;
                issue.reason = [NSString stringWithFormat:@"大小不符（%lld ≠ %lld）",
                                actualSize, expectSize];
                issue.expectedSHA1 = expectSHA;
                issue.expectedSize = expectSize;
                [issues addObject:issue];
                continue;
            }

            // 完整档：算 SHA1
            if (mode == A2IntegrityCheckModeFull && expectSHA.length == 40) {
                NSString *actual = A2SHA1OfFile(file);
                if (!actual ||
                    [actual caseInsensitiveCompare:expectSHA] != NSOrderedSame) {
                    A2IntegrityIssue *issue = [A2IntegrityIssue new];
                    issue.path = file;
                    issue.kind = kind;
                    issue.reason = @"SHA1 不符（内容损坏）";
                    issue.expectedSHA1 = expectSHA;
                    issue.expectedSize = expectSize;
                    [issues addObject:issue];
                    continue;
                }
            }

            ok++;
        }

        A2IntegrityReport *report = [A2IntegrityReport new];
        report.totalFiles = total;
        report.okFiles = ok;
        report.issues = issues;
        report.elapsed = [[NSDate date] timeIntervalSinceDate:start];

        [A2Logger info:@"IntegrityChecker"
               message:[NSString stringWithFormat:
                        @"%@ 检查完成：%ld/%ld 正常，%lu 个问题，耗时 %.1fs（%@档）",
                        versionName, (long)ok, (long)total,
                        (unsigned long)issues.count, report.elapsed,
                        mode == A2IntegrityCheckModeFull ? @"完整" : @"快速"]];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(report);
        });
    });
}

- (NSInteger)repairReport:(A2IntegrityReport *)report {
    NSInteger removed = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (A2IntegrityIssue *issue in report.issues) {
        NSError *err = nil;
        // 只删「大小不符 / SHA1 不符」的文件。
        // 「缺失」不需要删 —— 本来就没有。
        if (![issue.reason isEqualToString:@"缺失"]) {
            if ([fm removeItemAtPath:issue.path error:&err]) removed++;
        }
    }
    [A2Logger info:@"IntegrityChecker"
           message:[NSString stringWithFormat:@"修复：删除 %ld 个损坏文件，下次启动会重新下载",
                    (long)removed]];
    return removed;
}

@end

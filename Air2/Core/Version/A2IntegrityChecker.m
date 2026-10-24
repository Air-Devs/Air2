// ============================================================================
//  A2IntegrityChecker.m — 启动前完整性核对（只读；口径对齐 PCL 的“按清单核对”）
// ============================================================================

#import "A2IntegrityChecker.h"
#import "A2Log.h"

@implementation A2IntegrityReport
@end

@implementation A2IntegrityChecker

/// 轻量 EOCD 探测：确认是 zip（PCL 也会先确认 jar 能打开）
static BOOL a2_isZipFile(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) return NO;
    unsigned long long size = [fh seekToEndOfFile];
    if (size < 22) { [fh closeFile]; return NO; }
    unsigned long long back = MIN((unsigned long long)65557, size);
    [fh seekToFileOffset:size - back];
    NSData *tail = [fh readDataToEndOfFile];
    [fh closeFile];
    static const unsigned char eocd[4] = {0x50, 0x4B, 0x05, 0x06};
    NSRange r = [tail rangeOfData:[NSData dataWithBytes:eocd length:4] options:0 range:NSMakeRange(0, tail.length)];
    return r.location != NSNotFound;
}

/// 版本 json → 合并后的 library 列表（只取带 downloads.artifact 的条目）
+ (NSArray<NSDictionary *> *)librariesFromJSON:(NSDictionary *)json {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *libs = json[@"libraries"];
    if (![libs isKindOfClass:NSArray.class]) return out;
    for (NSDictionary *lib in libs) {
        if (![lib isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *dl = lib[@"downloads"];
        NSDictionary *art = [dl isKindOfClass:NSDictionary.class] ? dl[@"artifact"] : nil;
        if (![art isKindOfClass:NSDictionary.class]) continue;   // 原生库等非必要项先跳过
        NSString *path = art[@"path"];
        if (![path isKindOfClass:NSString.class] || path.length == 0) continue;
        [out addObject:@{ @"path": path, @"size": art[@"size"] ?: @0 }];
    }
    return out;
}

+ (A2IntegrityReport *)checkVersionAtPath:(NSString *)versionDir
                                versionID:(NSString *)versionID
                                 gameHome:(NSString *)gameHome {
    A2IntegrityReport *rep = [A2IntegrityReport new];
    NSFileManager *fm = NSFileManager.defaultManager;

    // ① 客户端 jar
    NSString *jar = [versionDir stringByAppendingPathComponent:[versionID stringByAppendingPathExtension:@"jar"]];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:jar isDirectory:&isDir] || isDir) {
        rep.level = A2IntegrityLevelFatal;
        rep.fatalReason = [NSString stringWithFormat:@"缺少客户端 jar：%@", jar.lastPathComponent];
        rep.summary = rep.fatalReason;
        return rep;
    }
    unsigned long long jarSize = [[fm attributesOfItemAtPath:jar error:nil][NSFileSize] unsignedLongLongValue];
    if (jarSize < 1024) {
        rep.level = A2IntegrityLevelFatal;
        rep.fatalReason = @"客户端 jar 为空或损坏（<1KB）";
        rep.summary = rep.fatalReason;
        return rep;
    }
    if (!a2_isZipFile(jar)) {
        rep.level = A2IntegrityLevelFatal;
        rep.fatalReason = @"客户端 jar 不是有效的 zip（可能下载中断）";
        rep.summary = rep.fatalReason;
        return rep;
    }

    // ② 版本 json
    NSString *jsonPath = [versionDir stringByAppendingPathComponent:[versionID stringByAppendingPathExtension:@"json"]];
    NSData *jd = [NSData dataWithContentsOfFile:jsonPath];
    NSDictionary *json = nil;
    if (jd != nil) {
        id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) json = obj;
    }
    if (json == nil) {
        rep.level = A2IntegrityLevelFatal;
        rep.fatalReason = @"版本 json 缺失或无法解析";
        rep.summary = rep.fatalReason;
        return rep;
    }

    // ③ libraries：按 json 的 artifact 路径逐个核（PCL 口径）
    NSString *libRoot = [gameHome stringByAppendingPathComponent:@"libraries"];
    NSMutableArray *missing = [NSMutableArray array];
    NSInteger missingCount = 0;
    for (NSDictionary *item in [self librariesFromJSON:json]) {
        NSString *rel = item[@"path"];
        NSString *full = [libRoot stringByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:full]) {
            missingCount++;
            if (missing.count < 20) [missing addObject:rel.lastPathComponent];
        }
    }
    rep.missingLibraries = missing;
    rep.missingLibraryCount = missingCount;

    // ④ assets：对着 assetIndex 的 objects 抽查（全量太慢；只核存在性，不核 hash）
    NSInteger missingAssets = 0, checkedAssets = 0;
    NSDictionary *assetIdx = json[@"assetIndex"];
    NSString *idxId = [assetIdx isKindOfClass:NSDictionary.class] ? assetIdx[@"id"] : nil;
    if ([idxId isKindOfClass:NSString.class] && idxId.length > 0) {
        NSString *idxPath = [[[gameHome stringByAppendingPathComponent:@"assets/indexes"]
                              stringByAppendingPathComponent:idxId] stringByAppendingPathExtension:@"json"];
        NSData *idData = [NSData dataWithContentsOfFile:idxPath];
        NSDictionary *idx = nil;
        if (idData) {
            id obj = [NSJSONSerialization JSONObjectWithData:idData options:0 error:nil];
            if ([obj isKindOfClass:NSDictionary.class]) idx = obj;
        }
        NSDictionary *objects = idx[@"objects"];
        if ([objects isKindOfClass:NSDictionary.class]) {
            NSString *objRoot = [gameHome stringByAppendingPathComponent:@"assets/objects"];
            // 抽查上限 400 个（够判断"资源目录整体在不在"，又不拖慢启动）
            NSArray *keys = objects.allKeys;
            NSUInteger step = MAX((NSUInteger)1, keys.count / 400);
            for (NSUInteger i = 0; i < keys.count; i += step) {
                NSDictionary *o = objects[keys[i]];
                NSString *hash = o[@"hash"];
                if (![hash isKindOfClass:NSString.class] || hash.length < 3) continue;
                NSString *p = [[[objRoot stringByAppendingPathComponent:[hash substringToIndex:2]]
                                stringByAppendingPathComponent:hash] copy];
                checkedAssets++;
                if (![fm fileExistsAtPath:p]) missingAssets++;
            }
        }
    }
    rep.assetsChecked = checkedAssets;
    rep.missingAssetCount = missingAssets;

    // 结论
    if (missingCount > 0) {
        rep.level = A2IntegrityLevelWarning;
        rep.summary = [NSString stringWithFormat:@"缺少 %ld 个库（如 %@）",
                       (long)missingCount, [missing componentsJoinedByString:@", "]];
    } else if (missingAssets > 0) {
        rep.level = A2IntegrityLevelWarning;
        rep.summary = [NSString stringWithFormat:@"资源抽查：%ld/%ld 个对象缺失（可能黑屏/无音效）",
                       (long)missingAssets, (long)checkedAssets];
    } else {
        rep.level = A2IntegrityLevelOK;
        rep.summary = [NSString stringWithFormat:@"完整性 OK（jar %.1fMB，库齐全，资源抽查 %ld 个通过）",
                       jarSize / 1048576.0, (long)checkedAssets];
    }
    return rep;
}

@end

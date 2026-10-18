// ★ [VER-ISOLATE-MIGRATE] 版本隔离「数据迁移」引擎实现（纯 Foundation，可脱壳测试）。
// 详情与约束见 VersionDataMigration.h 头部注释。

#import "VersionDataMigration.h"
#include <unistd.h>     // getpid
#include <math.h>       // fabs

NSInteger const ameVDMConflictSkip = 0;
NSInteger const ameVDMConflictRename = 1;

// 本引擎自己的临时命名空间（统一前缀，便于清理且不会误删用户文件）。
static NSString *const kAmeVDMStageDirName = @".ame-iso-stage";     // 目录级暂存（<dstRoot> 下）
static NSString *const kAmeVDMTmpMarker   = @".ame-iso-tmp";        // 文件级临时后缀
static NSString *const kAmeVDMConflictTag = @".ame-conflict-";      // 冲突改名后缀

#pragma mark - 基础工具

static NSDictionary *ameVDMAttrs(NSString *path) {
    return [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
}

static unsigned long long ameVDMFileSize(NSString *path) {
    return [ameVDMAttrs(path)[NSFileSize] unsignedLongLongValue];
}

// 隐藏项（含本引擎临时文件）一律不计入 / 不搬运：游戏自身也不会读它们。
static BOOL ameVDMIsHiddenRel(NSString *rel) {
    return [rel.lastPathComponent hasPrefix:@"."];
}

/// 枚举 path 下的全部【文件】与【目录】相对路径。
/// path 为文件时：files=@[@""]（相对路径为空 = 源本身），dirs 为空。
static void ameVDMEnumerate(NSString *path,
                            NSMutableArray<NSString *> *files,
                            NSMutableArray<NSString *> *dirs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return;
    if (!isDir) { [files addObject:@""]; return; }

    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    NSString *rel;
    while ((rel = [e nextObject]) != nil) {
        if (ameVDMIsHiddenRel(rel)) { [e skipDescendants]; continue; }
        BOOL d = NO;
        NSString *full = [path stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:full isDirectory:&d]) {
            if (d) [dirs addObject:rel]; else [files addObject:rel];
        }
    }
}

/// 源文件 / 目标文件是否"内容一致"。判据：类型相同且（目录或）大小 + mtime 相同。
/// 复制时我们显式保留源 mtime（见 ameVDMApplyMtimes），故该判据对"本引擎拷贝过的
/// 文件"是精确的 ⇒ 重跑判定稳定（幂等）。这是 rsync 默认的 size+mtime 启发式；
/// 极少数「同名同大小同 mtime 但内容不同」的场景会被视为已迁移而跳过（保守不覆盖）。
static BOOL ameVDMSameContent(NSString *a, NSString *b) {
    NSDictionary *fa = ameVDMAttrs(a), *fb = ameVDMAttrs(b);
    if (!fa || !fb) return NO;
    if (![fa[NSFileType] isEqualToString:fb[NSFileType]]) return NO;
    if ([fa[NSFileType] isEqualToString:NSFileTypeDirectory]) return YES;
    if ([fa[NSFileSize] unsignedLongLongValue] != [fb[NSFileSize] unsignedLongLongValue]) return NO;
    NSDate *ma = fa[NSFileModificationDate], *mb = fb[NSFileModificationDate];
    if (ma && mb && fabs([ma timeIntervalSinceDate:mb]) > 1.0) return NO;
    return YES;
}

/// 把 stage 树里每个文件（含文件项本身）的 mtime 对齐到源，保证后续一致判定稳定。
static void ameVDMApplyMtimes(NSString *stagePath, NSString *srcPath,
                              NSArray<NSString *> *files, BOOL srcIsDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in files) {
        NSString *sp = srcIsDir && rel.length ? [srcPath stringByAppendingPathComponent:rel] : srcPath;
        NSString *dp = stagePath;
        if (srcIsDir && rel.length) dp = [stagePath stringByAppendingPathComponent:rel];
        NSDate *m = ameVDMAttrs(sp)[NSFileModificationDate];
        if (m) [fm setAttributes:@{NSFileModificationDate: m} ofItemAtPath:dp error:nil];
    }
}

// 单文件原子落盘：copyItemAtPath -> <dst>.ame-iso-tmp-<pid> -> moveItemAtPath 到 dst。
// 中断只会留下 .ame-iso-tmp-* 残片（下次运行被清理），绝不会留下半写的目标文件。
static BOOL ameVDMCopyFileAtomic(NSString *srcFile, NSString *dstFile, NSError **outErr) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [dstFile stringByDeletingLastPathComponent];
    if (parent.length) [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmp = [dstFile stringByAppendingFormat:@"%@-%d", kAmeVDMTmpMarker, (int)getpid()];
    [fm removeItemAtPath:tmp error:nil];
    if (![fm copyItemAtPath:srcFile toPath:tmp error:outErr]) { [fm removeItemAtPath:tmp error:nil]; return NO; }
    if (![fm moveItemAtPath:tmp toPath:dstFile error:outErr]) { [fm removeItemAtPath:tmp error:nil]; return NO; }
    NSDate *m = ameVDMAttrs(srcFile)[NSFileModificationDate];
    if (m) [fm setAttributes:@{NSFileModificationDate: m} ofItemAtPath:dstFile error:nil];
    return YES;
}

static NSString *ameVDMConflictPath(NSString *dstFile) {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [df stringFromDate:[NSDate date]];
    return [dstFile stringByAppendingFormat:@"%@%@", kAmeVDMConflictTag, stamp];
}

#pragma mark - 公开 API

NSArray<NSString *> *ameVDMDefaultItemNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 顺序 = 迁移/展示顺序；目录在前、散文件在后。
        names = @[@"mods", @"config", @"saves", @"resourcepacks", @"shaderpacks",
                  @"datapacks", @"logs", @"crash-reports",
                  @"options.txt", @"servers.dat", @"servers.dat_old"];
    });
    return names;
}

NSDictionary *ameVDMScanPath(NSString *path) {
    NSUInteger files = 0, dirs = 0;
    unsigned long long bytes = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (!isDir) {
            files = 1;
            bytes = ameVDMFileSize(path);
        } else {
            NSMutableArray *f = [NSMutableArray array], *d = [NSMutableArray array];
            ameVDMEnumerate(path, f, d);
            files = f.count;
            dirs = d.count;
            for (NSString *rel in f) {
                bytes += ameVDMFileSize(rel.length ? [path stringByAppendingPathComponent:rel] : path);
            }
        }
    }
    return @{@"files": @(files), @"bytes": @(bytes), @"dirs": @(dirs)};
}

NSArray<NSDictionary *> *ameVDMPlan(NSString *srcRoot, NSString *dstRoot,
                                    NSArray<NSString *> *items) {
    NSMutableArray *out = [NSMutableArray array];
    if (srcRoot.length == 0 || dstRoot.length == 0 || items.count == 0) return out;
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *name in items) {
        NSString *s = [srcRoot stringByAppendingPathComponent:name];
        NSString *d = [dstRoot stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:s isDirectory:&isDir]) continue;   // 不存在则不列

        NSMutableArray *files = [NSMutableArray array], *dirs = [NSMutableArray array];
        ameVDMEnumerate(s, files, dirs);

        NSUInteger identical = 0, conflict = 0, fresh = 0;
        unsigned long long bytes = 0;
        for (NSString *rel in files) {
            NSString *sf = (isDir && rel.length) ? [s stringByAppendingPathComponent:rel] : s;
            NSString *df = (isDir && rel.length) ? [d stringByAppendingPathComponent:rel] : d;
            BOOL dd = NO;
            if ([fm fileExistsAtPath:df isDirectory:&dd] && !dd) {
                if (ameVDMSameContent(sf, df)) identical++; else conflict++;
            } else {
                fresh++;
            }
            bytes += ameVDMFileSize(sf);
        }
        [out addObject:@{
            @"name": name, @"src": s, @"dst": d, @"isDir": @(isDir),
            @"files": @(files.count), @"bytes": @(bytes),
            @"identical": @(identical), @"conflict": @(conflict), @"new": @(fresh),
        }];
    }
    return out;
}

NSDictionary *ameVDMExecuteItem(NSString *srcRoot, NSString *dstRoot,
                                NSString *item, NSDictionary *options) {
    NSInteger policy = options[@"conflictPolicy"] ? [options[@"conflictPolicy"] integerValue]
                                                  : ameVDMConflictSkip;
    BOOL removeSource = [options[@"removeSource"] boolValue];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [srcRoot stringByAppendingPathComponent:item];
    NSString *dst = [dstRoot stringByAppendingPathComponent:item];

    NSMutableArray *errors = [NSMutableArray array];
    NSMutableDictionary *rep = [@{
        @"name": item, @"status": @"absent",
        @"copied": @0, @"identical": @0, @"conflict": @0, @"renamed": @0,
        @"bytes": @0, @"removed": @NO, @"errors": errors,
    } mutableCopy];

    BOOL srcIsDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&srcIsDir]) return rep;   // 源不存在 ⇒ absent

    NSMutableArray *files = [NSMutableArray array], *dirs = [NSMutableArray array];
    ameVDMEnumerate(src, files, dirs);

    NSUInteger copied = 0, identical = 0, renamed = 0;
    unsigned long long bytes = 0;
    NSMutableArray<NSString *> *conflictRels = [NSMutableArray array];
    NSMutableArray<NSString *> *newRels = [NSMutableArray array];

    // 1) 分类：目标已存在且一致 ⇒ 幂等跳过；已存在但不同 ⇒ 冲突；不存在 ⇒ 待复制。
    for (NSString *rel in files) {
        NSString *sf = (srcIsDir && rel.length) ? [src stringByAppendingPathComponent:rel] : src;
        NSString *df = (srcIsDir && rel.length) ? [dst stringByAppendingPathComponent:rel] : dst;
        BOOL dd = NO;
        if ([fm fileExistsAtPath:df isDirectory:&dd] && !dd) {
            if (ameVDMSameContent(sf, df)) { identical++; continue; }
            [conflictRels addObject:rel];
        } else {
            [newRels addObject:rel];
        }
        bytes += ameVDMFileSize(sf);
    }

    BOOL dstExists = [fm fileExistsAtPath:dst];

    // 2) 复制新文件。
    if (newRels.count > 0 && !dstExists) {
        // —— 目标整体不存在（首次迁移 / 上次中断未落目标）：整树落临时目录再原子改名。
        NSString *stageParent = [dstRoot stringByAppendingPathComponent:kAmeVDMStageDirName];
        NSString *stageItem = [stageParent stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@", item]];
        [fm createDirectoryAtPath:dstRoot withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:stageParent withIntermediateDirectories:YES attributes:nil error:nil];
        // ★ [VI-MIGRATE-AUTO] item 可能是嵌套相对路径（如 "mods/foo.jar"）：为 stage 与
        //   最终目标的父目录都补建中间目录，否则 copyItem/moveItem 因父目录缺失而失败
        //   （原实现只处理顶层 item，如 "mods"）。
        [fm createDirectoryAtPath:[stageItem stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:stageItem error:nil];
        NSError *err = nil;
        if (![fm copyItemAtPath:src toPath:stageItem error:&err]) {
            [errors addObject:[NSString stringWithFormat:@"%@: stage 失败 %@", item, err.localizedDescription ?: @"?"]];
            [fm removeItemAtPath:stageItem error:nil];
        } else {
            ameVDMApplyMtimes(stageItem, src, files, srcIsDir);
            NSError *err2 = nil;
            if (![fm moveItemAtPath:stageItem toPath:dst error:&err2]) {
                [errors addObject:[NSString stringWithFormat:@"%@: 原子改名失败 %@", item, err2.localizedDescription ?: @"?"]];
                [fm removeItemAtPath:stageItem error:nil];
            } else {
                copied = newRels.count;
            }
        }
        if ([fm fileExistsAtPath:stageParent]) {
            NSArray *left = [fm contentsOfDirectoryAtPath:stageParent error:nil];
            if (left.count == 0) [fm removeItemAtPath:stageParent error:nil];
        }
    } else {
        // —— 目标已存在：逐文件原子并入（dir-level rename 无法与已有目录合并）。
        for (NSString *rel in newRels) {
            NSString *sf = (srcIsDir && rel.length) ? [src stringByAppendingPathComponent:rel] : src;
            NSString *df = (srcIsDir && rel.length) ? [dst stringByAppendingPathComponent:rel] : dst;
            NSError *err = nil;
            if (ameVDMCopyFileAtomic(sf, df, &err)) {
                copied++;
            } else {
                [errors addObject:[NSString stringWithFormat:@"%@: 复制失败 %@", rel.length ? rel : item,
                                   err.localizedDescription ?: @"?"]];
            }
        }
        // 目标为空目录也补建（保真空子目录）。
        for (NSString *rel in dirs) {
            [fm createDirectoryAtPath:[dst stringByAppendingPathComponent:rel]
          withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    // 3) 冲突处理（绝不静默覆盖）。
    for (NSString *rel in conflictRels) {
        NSString *sf = (srcIsDir && rel.length) ? [src stringByAppendingPathComponent:rel] : src;
        NSString *df = (srcIsDir && rel.length) ? [dst stringByAppendingPathComponent:rel] : dst;
        if (policy == ameVDMConflictRename) {
            NSError *err = nil;
            NSString *alt = ameVDMConflictPath(df);
            if (ameVDMCopyFileAtomic(sf, alt, &err)) {
                renamed++;
                [errors addObject:[NSString stringWithFormat:@"冲突改名保留: %@ -> %@",
                                   rel.length ? rel : item, alt.lastPathComponent]];
            } else {
                [errors addObject:[NSString stringWithFormat:@"冲突改名失败 %@: %@",
                                   rel.length ? rel : item, err.localizedDescription ?: @"?"]];
            }
        } else {
            [errors addObject:[NSString stringWithFormat:@"冲突跳过（保留两边，未覆盖）: %@",
                               rel.length ? rel : item]];
        }
    }

    // 4) removeSource：只有用户明确选择 + 无冲突 + 逐文件校验通过，才删源。
    if (removeSource && copied + identical > 0) {
        if (conflictRels.count > 0) {
            [errors addObject:@"存在未解决冲突，已保留源目录（不删除用户数据）"];
        } else {
            BOOL allOk = YES;
            for (NSString *rel in files) {
                NSString *sf = (srcIsDir && rel.length) ? [src stringByAppendingPathComponent:rel] : src;
                NSString *df = (srcIsDir && rel.length) ? [dst stringByAppendingPathComponent:rel] : dst;
                if (![fm fileExistsAtPath:df] || ameVDMFileSize(sf) != ameVDMFileSize(df)) { allOk = NO; break; }
            }
            if (allOk) {
                NSError *e2 = nil;
                if ([fm removeItemAtPath:src error:&e2]) rep[@"removed"] = @YES;
                else [errors addObject:[NSString stringWithFormat:@"删除源失败: %@", e2.localizedDescription ?: @"?"]];
            } else {
                [errors addObject:@"校验未通过，已保留源目录（不删除用户数据）"];
            }
        }
    }

    rep[@"status"]    = errors.count ? @"error" : @"done";
    rep[@"copied"]    = @(copied);
    rep[@"identical"] = @(identical);
    rep[@"conflict"]  = @(conflictRels.count);
    rep[@"renamed"]   = @(renamed);
    rep[@"bytes"]     = @(bytes);
    return rep;
}

NSDictionary *ameVDMExecute(NSString *srcRoot, NSString *dstRoot,
                            NSArray<NSString *> *items, NSDictionary *options) {
    NSMutableArray *itemReports = [NSMutableArray array];
    NSUInteger copied = 0, identical = 0, conflicts = 0, renamed = 0;
    BOOL removed = NO;
    for (NSString *name in items) {
        NSDictionary *r = ameVDMExecuteItem(srcRoot, dstRoot, name, options);
        [itemReports addObject:r];
        copied     += [r[@"copied"] unsignedIntegerValue];
        identical  += [r[@"identical"] unsignedIntegerValue];
        conflicts  += [r[@"conflict"] unsignedIntegerValue];
        renamed    += [r[@"renamed"] unsignedIntegerValue];
        if ([r[@"removed"] boolValue]) removed = YES;
    }
    // ★ [VER-ISOLATE-MIGRATE] 判据行：一次迁移一行，可 grep 核对"目标=隔离 resolver 目录"。
    NSLog(@"[VER-ISOLATE-MIGRATE] migrate src=%@ dst=%@ items=%lu copied=%lu identical=%lu conflicts=%lu renamed=%lu removed=%d",
          srcRoot, dstRoot, (unsigned long)items.count, (unsigned long)copied,
          (unsigned long)identical, (unsigned long)conflicts, (unsigned long)renamed, (int)removed);
    return @{@"ok": @YES, @"copied": @(copied), @"identical": @(identical),
             @"conflicts": @(conflicts), @"renamed": @(renamed),
             @"removed": @(removed), @"items": itemReports};
}

NSInteger ameVDMCleanupStaleTemps(NSString *dstRoot, NSArray<NSString *> *items) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger n = 0;
    if (dstRoot.length == 0) return 0;

    // 目录级暂存
    NSString *stageParent = [dstRoot stringByAppendingPathComponent:kAmeVDMStageDirName];
    if ([fm fileExistsAtPath:stageParent]) {
        if ([fm removeItemAtPath:stageParent error:nil]) n++;
    }
    // 文件级残片
    for (NSString *name in items) {
        NSString *itemPath = [dstRoot stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:itemPath isDirectory:&isDir]) continue;
        if (!isDir) {
            if ([name containsString:kAmeVDMTmpMarker]) { if ([fm removeItemAtPath:itemPath error:nil]) n++; }
            continue;
        }
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:itemPath];
        NSString *rel;
        while ((rel = [e nextObject]) != nil) {
            if ([rel.lastPathComponent containsString:kAmeVDMTmpMarker]) {
                if ([fm removeItemAtPath:[itemPath stringByAppendingPathComponent:rel] error:nil]) n++;
            }
        }
    }
    return n;
}

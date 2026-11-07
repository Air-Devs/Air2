//
//  A2HomeRuntime.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页运行时数据源实现。见 A2HomeRuntime.h 顶部。
//

#import "A2HomeRuntime.h"

#import "A2Account.h"
#import "A2AccountManager.h"
#import "A2GameFiles.h"
#import "A2Log.h"
#import "A2Settings.h"
#import "A2VersionIsolation.h"

@implementation A2HomeResolvedTarget

- (instancetype)init {
    self = [super init];
    if (self) {
        _label = @"";
        _meta = @"";
        _message = @"";
        _state = A2HomeTargetStateOK;
    }
    return self;
}

- (BOOL)isUsable {
    return self.state == A2HomeTargetStateOK;
}

@end

@implementation A2HomeRuntime

+ (instancetype)shared {
    static A2HomeRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ runtime = [[A2HomeRuntime alloc] init]; });
    return runtime;
}

#pragma mark - 引用解析

- (nullable A2Version *)versionForTarget:(A2HomeCardTarget *)target {
    NSString *name = target.versionName;
    NSString *gameHome = target.gameHome;
    if (name.length == 0 || gameHome.length == 0) return nil;
    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:name] && [v.gameHome isEqualToString:gameHome]) return v;
    }
    return nil;
}

/// 游戏目录是否还在「已添加过的目录」列表里（沙盒外目录换了路径 / 被移除时书架就失效）。
- (BOOL)isGameHomeKnown:(NSString *)gameHome {
    if (gameHome.length == 0) return NO;
    NSString *current = A2VersionManager.shared.gameHome;
    if (current.length && [current isEqualToString:gameHome]) return YES;
    NSArray<NSString *> *known = A2Settings.shared.gameHomes;
    for (NSString *p in known) {
        if ([p isEqualToString:gameHome]) return YES;
    }
    return NO;
}

- (A2HomeResolvedTarget *)resolveTarget:(A2HomeCardTarget *)target kind:(A2HomeCardKind)kind {
    A2HomeResolvedTarget *r = [[A2HomeResolvedTarget alloc] init];
    // 兜底名先摆上：无论后面哪一步失败，卡片都还知道自己「原本是什么」。
    r.label = target.fallbackLabel.length ? target.fallbackLabel : target.versionName;

    if (kind == A2HomeCardKindShortcutServer) {
        r.meta = target.address ?: @"";
        if (target.address.length == 0) {
            r.state = A2HomeTargetStateVersionMissing;
            r.message = @"服务器地址已失效";
            return r;
        }
    }

    if (![self isGameHomeKnown:target.gameHome]) {
        r.state = A2HomeTargetStateGameHomeMissing;
        r.message = @"游戏目录访问权限已失效";
        return r;
    }

    A2Version *version = [self versionForTarget:target];
    if (!version) {
        r.state = A2HomeTargetStateVersionMissing;
        r.message = @"指向的版本已不存在";
        return r;
    }
    r.version = version;

    if (kind == A2HomeCardKindShortcutVersion) {
        r.label = version.name;
        r.meta = version.loaderInfo.length ? version.loaderInfo : @"原版";
        return r;
    }

    if (kind == A2HomeCardKindShortcutWorld) {
        // 存档路径**相对 gameDir**：隔离档位一变，gameDir 跟着变，这里按当前档位重新拼。
        NSString *relative = target.worldPath ?: @"";
        NSString *absolute = [version.gameDirectory stringByAppendingPathComponent:relative];
        if (relative.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:absolute]) {
            r.state = A2HomeTargetStateWorldMissing;
            r.message = @"指向的存档已不存在";
            r.meta = version.name;
            return r;
        }
        r.label = relative.lastPathComponent.length ? relative.lastPathComponent : r.label;
        r.meta = version.name;
        return r;
    }

    if (kind == A2HomeCardKindShortcutServer) {
        r.label = target.fallbackLabel.length ? target.fallbackLabel : (target.address ?: @"");
        r.meta = target.address ?: @"";
        return r;
    }

    r.meta = version.loaderInfo.length ? version.loaderInfo : @"原版";
    return r;
}

#pragma mark - 内容列表

- (NSArray<A2Version *> *)recentVersionsLimitedTo:(NSInteger)limit {
    NSArray<A2Version *> *all = A2VersionManager.shared.versions ?: @[];
    NSArray<A2Version *> *sorted = [all sortedArrayUsingComparator:^NSComparisonResult(A2Version *a, A2Version *b) {
        NSDate *da = a.lastPlayed;
        NSDate *db = b.lastPlayed;
        if (da && db) return [db compare:da];
        if (da) return NSOrderedAscending;      // 玩过的排前面
        if (db) return NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    if (limit <= 0 || (NSInteger)sorted.count <= limit) return sorted;
    return [sorted subarrayWithRange:NSMakeRange(0, (NSUInteger)limit)];
}

- (NSArray<A2Version *> *)pinnedVersions {
    NSMutableArray<A2Version *> *out = [NSMutableArray array];
    for (A2Version *v in A2VersionManager.shared.versions) {
        if (v.isolation.isPinned) [out addObject:v];
    }
    return out.copy;
}

- (NSArray<NSDictionary<NSString *, id> *> *)worldsForVersion:(A2Version *)version
                                                        error:(NSError **)error {
    if (!version) return @[];
    NSString *savesDir = [version directoryForFolder:A2VersionFolderSaves];
    A2GameFiles *files = [[A2GameFiles alloc] initWithRootPath:savesDir error:error];
    if (!files) return @[];
    NSArray<A2GameFileEntry *> *entries = [files entriesInDirectory:@"" error:error];
    NSMutableArray<A2GameFileEntry *> *dirs = [NSMutableArray array];
    for (A2GameFileEntry *e in entries) {
        if (e.isDirectory) [dirs addObject:e];
    }
    // 最近改过的排前面（用户刚玩过的存档大概率就是他要钉的那个）。
    [dirs sortUsingComparator:^NSComparisonResult(A2GameFileEntry *a, A2GameFileEntry *b) {
        NSDate *da = a.modificationDate;
        NSDate *db = b.modificationDate;
        if (da && db) return [db compare:da];
        return [a.name localizedStandardCompare:b.name];
    }];
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
    for (A2GameFileEntry *e in dirs) {
        [out addObject:@{
            @"name": e.name,
            // 相对 gameDir 的路径（"saves/<名字>"）—— 隔离换档位后仍能跟着走。
            @"path": [@"saves" stringByAppendingPathComponent:e.name],
        }];
    }
    return out.copy;
}

#pragma mark - 问候

- (NSString *)greetingTextForMode:(A2HomeGreetingMode)mode customText:(nullable NSString *)text {
    NSString *custom = [text stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (mode == A2HomeGreetingModeText) {
        return custom.length ? custom : @"欢迎回来";
    }
    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:NSDate.date];
    NSString *period = @"夜深了";
    if (hour >= 5 && hour < 11) period = @"早上好";
    else if (hour >= 11 && hour < 13) period = @"中午好";
    else if (hour >= 13 && hour < 18) period = @"下午好";
    else if (hour >= 18 && hour < 23) period = @"晚上好";
    if (custom.length) return [NSString stringWithFormat:@"%@，%@", period, custom];
    return period;
}

- (nullable NSString *)currentAccountName {
    A2Account *account = A2AccountManager.shared.currentAccount;
    return account.username.length ? account.username : nil;
}

@end

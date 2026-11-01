//
//  A2PluginBootGuard.m
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
//  见头文件。这里只有三件事：写 marker、结算 marker、清 marker。
//  「什么时候该写/该结算」由三个接线点决定，本文件不做启动流程判断。
//

#import "A2PluginBootGuard.h"

#import "A2PluginRegistry.h"

#import <TargetConditionals.h>

const NSInteger A2PluginBootGuardAutoDisableThreshold = 3;

/// marker 结构版本（**不是**注册表版本，也**不是**包 formatVersion）。
static const NSInteger A2BootGuardMarkerVersion = 1;

static NSString *const A2BootGuardMarkerVersionKey = @"version";
static NSString *const A2BootGuardMarkerPluginsKey = @"plugins";
static NSString *const A2BootGuardMarkerCountedKey = @"counted";
static NSString *const A2BootGuardMarkerLaunchedAtKey = @"launchedAt";

#pragma mark - 小工具

/// 自动停用的人话（直接进 UI，不拼错误码）。
static NSString *A2BootGuardAutoDisableReason(void) {
    return [NSString stringWithFormat:
            @"连续 %ld 次启动都没有进入游戏画面，已自动停用",
            (long)A2PluginBootGuardAutoDisableThreshold];
}

static NSString *A2BootGuardTimestamp(void) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:[NSDate date]] ?: @"";
}

/// 写 marker：建目录 → 原子写。
///
/// 用 NSDataWritingAtomic 而不是照抄注册表里的 open/fsync/rename：
/// 它的实现就是「同目录写临时文件 → rename」，语义完全够（marker 丢了最坏
/// 只是少记一次失败），再复制一份 60 行 fsync 代码只是第二个写盘实现。
static BOOL A2BootGuardWriteMarker(NSString *path, NSDictionary<NSString *, id> *marker) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        return NO;
    }
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:marker
                                                   options:(NSJSONWritingOptions)
                                                           (NSJSONWritingPrettyPrinted |
                                                            NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (!data) return NO;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) return NO;

#if TARGET_OS_IOS
    // 与插件目录同一保护等级：设备首次解锁后可读（后台/冷启动都要读）。
    [[NSFileManager defaultManager]
        setAttributes:@{NSFileProtectionKey:
                            NSFileProtectionCompleteUntilFirstUserAuthentication}
         ofItemAtPath:path
                error:NULL];
#endif
    return YES;
}

/// 读 marker。**任何**读不出来 / 结构不对的情况都返回 nil（= 当没有 marker），
/// 因为「marker 坏了就崩」比「少记一次失败」严重得多。
static NSDictionary<NSString *, id> *_Nullable A2BootGuardReadMarker(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;

    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *dictionary = (NSDictionary *)root;
    id version = dictionary[A2BootGuardMarkerVersionKey];
    if (![version isKindOfClass:NSNumber.class]) return nil;
    if ([(NSNumber *)version integerValue] != A2BootGuardMarkerVersion) return nil;

    id plugins = dictionary[A2BootGuardMarkerPluginsKey];
    if (![plugins isKindOfClass:NSArray.class]) return nil;
    for (id item in (NSArray *)plugins) {
        if (![item isKindOfClass:NSString.class]) return nil;
    }

    id counted = dictionary[A2BootGuardMarkerCountedKey];
    if (counted && ![counted isKindOfClass:NSNumber.class]) return nil;

    return dictionary;
}

#pragma mark - 看门狗

@interface A2PluginBootGuard ()
@property (nonatomic, copy) NSString *pluginsDirectory;
@property (nonatomic, copy) NSString *bootMarkerPath;
@end

@implementation A2PluginBootGuard

+ (A2PluginBootGuard *)sharedGuard {
    static A2PluginBootGuard *guard = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        guard = [[A2PluginBootGuard alloc] initWithPluginsDirectory:nil];
    });
    return guard;
}

- (instancetype)initWithPluginsDirectory:(nullable NSString *)pluginsDirectory {
    self = [super init];
    if (self) {
        NSString *directory = pluginsDirectory;
        if (!directory.length) directory = [A2PluginRegistry defaultPluginsDirectory];
        // 取不到容器目录（理论上不会发生）时退回临时目录：宁可这一轮不保护，
        // 也不要把 marker 写到根目录去。
        if (!directory.length) directory = NSTemporaryDirectory();
        _pluginsDirectory = [directory copy] ?: @"";
        _bootMarkerPath = [[_pluginsDirectory stringByAppendingPathComponent:@".state"]
                           stringByAppendingPathComponent:@"boot.json"];
    }
    return self;
}

- (A2PluginRegistry *)loadRegistry {
    A2PluginRegistry *registry =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:self.pluginsDirectory];
    if (![registry loadWithError:NULL]) return nil;
    return registry;
}

#pragma mark 结算

- (NSArray<A2PluginRegistryEntry *> *)evaluatePreviousLaunch {
    NSDictionary<NSString *, id> *marker = A2BootGuardReadMarker(self.bootMarkerPath);
    if (!marker) return @[];                                    // 没启动过 / marker 坏了
    if ([marker[A2BootGuardMarkerCountedKey] boolValue]) return @[];   // 已经结算过

    A2PluginRegistry *registry = [self loadRegistry];
    if (!registry) return @[];   // 表读不出来：不动磁盘，下次再说

    NSMutableArray<A2PluginRegistryEntry *> *autoDisabled = [NSMutableArray array];
    BOOL changed = NO;
    for (id item in (NSArray *)marker[A2BootGuardMarkerPluginsKey]) {
        A2PluginRegistryEntry *entry = [registry entryForPluginId:(NSString *)item];
        // 已经停用的插件（用户手动关的 / 上一轮自动关的）不再累加：
        // 它这一轮根本没被加载，不该替别人把计数顶上去。
        if (!entry || !entry.isEnabled) continue;

        entry.failureCount = entry.failureCount + 1;
        changed = YES;

        // 只在这一档动手：第 1、2 次只记录，**恰好**第 3 次停用。
        // 用 == 而不是 >=：第 4 次及以后归 P2 的完整安全模式，本块不再碰
        //（否则用户手动重新启用一次就会被立刻再关一次，永远救不回来）。
        if (entry.failureCount == A2PluginBootGuardAutoDisableThreshold) {
            entry.enabled = NO;
            entry.lastAutoDisabledReason = A2BootGuardAutoDisableReason();
            [autoDisabled addObject:entry];
        }
    }

    if (!changed) {
        // 上次启动用的插件都已经被停用 / 卸载了：没有要结算的东西，但 marker
        // 仍要标记成已结算，否则下次又白跑一遍。
        [self markMarkerCounted:marker];
        return @[];
    }

    if (![registry saveWithError:NULL]) {
        // 写不下去就不认这次结算：marker 保持 counted=NO，下次启动重试。
        return @[];
    }
    [self markMarkerCounted:marker];
    return autoDisabled;
}

/// 把 marker 标成「已结算」。
- (void)markMarkerCounted:(NSDictionary<NSString *, id> *)marker {
    NSMutableDictionary<NSString *, id> *updated = [marker mutableCopy];
    updated[A2BootGuardMarkerCountedKey] = @YES;
    (void)A2BootGuardWriteMarker(self.bootMarkerPath, updated);
}

#pragma mark 接线点

- (BOOL)markLaunchStarted {
    // 先结算上一次（幂等：counted=YES 的 marker 直接返回）。
    (void)[self evaluatePreviousLaunch];

    A2PluginRegistry *registry = [self loadRegistry];
    if (!registry) return NO;

    NSMutableArray<NSString *> *pluginIds = [NSMutableArray array];
    for (A2PluginRegistryEntry *entry in [registry allEntries]) {
        if (entry.isEnabled) [pluginIds addObject:entry.pluginId];
    }

    // 没有任何已启用插件 ⇒ 这一轮没有可保护的对象，连文件都不写：
    // 少了这份 marker 也判不出「谁坏了」，写它只是给每个没装插件的用户
    // 留一个空文件。
    if (pluginIds.count == 0) return YES;

    return A2BootGuardWriteMarker(self.bootMarkerPath, @{
        A2BootGuardMarkerVersionKey: @(A2BootGuardMarkerVersion),
        A2BootGuardMarkerLaunchedAtKey: A2BootGuardTimestamp(),
        A2BootGuardMarkerCountedKey: @NO,
        A2BootGuardMarkerPluginsKey: pluginIds,
    });
}

- (BOOL)markFirstFrameReached {
    BOOL ok = YES;
    A2PluginRegistry *registry = [self loadRegistry];
    if (!registry) {
        // 表读不出来：只能清 marker（至少别让下一轮替这一轮的失败背锅）。
        ok = NO;
    } else {
        BOOL changed = NO;
        for (A2PluginRegistryEntry *entry in [registry allEntries]) {
            if (entry.failureCount != 0) {
                entry.failureCount = 0;
                changed = YES;
            }
        }
        if (changed) ok = [registry saveWithError:NULL];
    }

    [[NSFileManager defaultManager] removeItemAtPath:self.bootMarkerPath error:NULL];
    return ok;
}

#pragma mark 便利入口

+ (BOOL)markLaunchStarted {
    return [self.sharedGuard markLaunchStarted];
}

+ (BOOL)markFirstFrameReached {
    return [self.sharedGuard markFirstFrameReached];
}

+ (NSArray<A2PluginRegistryEntry *> *)evaluatePreviousLaunch {
    return [self.sharedGuard evaluatePreviousLaunch];
}

@end

//
//  A2AggregateSearchService.m
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
//  聚合搜索实现 —— 扇出 / 交错合并 / 单源降级。
//
//  线程口径：
//    · A2ModrinthAPI 与 A2CurseForgeAPI 的 completion 都在主线程回调
//      （各自的 A2Main/dispatch_main_async），所以两路 leave 也在主线程；
//    · dispatch_group_notify 仍投到主队列 —— 这样「合并 + 回调」只有一个入口，
//      不必在实现里再判断当前线程。
//
//  降级口径（★宁可只给一个源的结果，也不给一个空白页★）：
//    · 源不可用（CurseForge 无 Key）→ 不发起该路请求，记 degradedReason；
//    · 源可用但请求失败 → 记 degradedReason（带错误摘要）；
//    · 所有参与的源都失败 → outcome.error 非 nil，UI 走错误态。
//

#import "A2AggregateSearchService.h"

#import "A2CurseForgeAPI.h"
#import "A2Log.h"

@interface A2AggregateSearchOutcome ()

@property (nonatomic, copy) NSArray<A2ContentItem *> *items;
@property (nonatomic, assign) NSInteger modrinthCount;
@property (nonatomic, assign) NSInteger curseForgeCount;
@property (nonatomic, copy, nullable) NSError *error;
@property (nonatomic, copy, nullable) NSString *degradedReason;
@property (nonatomic, copy) NSArray<NSNumber *> *engagedPlatforms;

@end

@implementation A2AggregateSearchOutcome
@end

#pragma mark - 合并（内部）

@interface A2AggregateSearchService ()

- (NSArray<A2ContentItem *> *)mergeCurseForge:(NSArray<A2ContentItem *> *)curseForge
                                    modrinth:(NSArray<A2ContentItem *> *)modrinth;
- (nullable NSString *)mergeKeyForItem:(A2ContentItem *)item;
- (void)appendItem:(A2ContentItem *)item
          toMerged:(NSMutableArray<A2ContentItem *> *)merged
         indexByKey:(NSMutableDictionary<NSString *, NSNumber *> *)indexByKey;
- (A2ContentFilter *)copyOfFilter:(A2ContentFilter *)filter;

@end

@implementation A2AggregateSearchService

+ (instancetype)shared {
    static A2AggregateSearchService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[A2AggregateSearchService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mergeDownloadTolerance = 0;
    }
    return self;
}

+ (BOOL)supportsAggregateForContentClass:(A2ContentClass)contentClass {
    // 「聚合」= 两家都能给这一类资源。Modrinth 没有 world（存档）⇒ 存档只能单源。
    A2ContentSource *modrinth = [A2ContentSource sourceForPlatform:A2ContentPlatformModrinth];
    A2ContentSource *curseForge = [A2ContentSource sourceForPlatform:A2ContentPlatformCurseForge];
    return [modrinth supportsContentClass:contentClass] && [curseForge supportsContentClass:contentClass];
}

#pragma mark - 检索

- (void)searchWithFilter:(A2ContentFilter *)filter
            contentClass:(A2ContentClass)contentClass
                    mode:(A2AggregateSourceMode)mode
              completion:(void (^)(A2AggregateSearchOutcome *outcome))completion {
    if (completion == nil) return;

    A2ContentSource *modrinth = [A2ContentSource sourceForPlatform:A2ContentPlatformModrinth];
    A2ContentSource *curseForge = [A2ContentSource sourceForPlatform:A2ContentPlatformCurseForge];

    BOOL wantsModrinth = (mode != A2AggregateSourceModeCurseForge);
    BOOL wantsCurseForge = (mode != A2AggregateSourceModeModrinth);

    // 该源不支持本资源大类 ⇒ 等同于「不参与」（而不是让整次检索失败）。
    BOOL modrinthSupports = [modrinth supportsContentClass:contentClass];
    BOOL curseForgeSupports = [curseForge supportsContentClass:contentClass];
    if (wantsModrinth && !modrinthSupports) wantsModrinth = NO;
    if (wantsCurseForge && !curseForgeSupports) wantsCurseForge = NO;

    // 源可用性（CurseForge 缺 Key 时 available = NO，且带原因）。
    NSMutableArray<NSString *> *degraded = [NSMutableArray array];
    if (wantsModrinth && !modrinth.isAvailable) {
        wantsModrinth = NO;
        [degraded addObject:(modrinth.unavailableReason ?: @"Modrinth 当前不可用")];
    }
    if (wantsCurseForge && !curseForge.isAvailable) {
        wantsCurseForge = NO;
        [degraded addObject:(curseForge.unavailableReason ?: @"CurseForge 当前不可用")];
    }

    if (!wantsModrinth && !wantsCurseForge) {
        A2AggregateSearchOutcome *outcome = [[A2AggregateSearchOutcome alloc] init];
        outcome.items = @[];
        outcome.engagedPlatforms = @[];
        outcome.degradedReason = degraded.count > 0 ? [degraded componentsJoinedByString:@"；"] : nil;
        outcome.error = [NSError errorWithDomain:@"A2AggregateSearch"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                       outcome.degradedReason ?: @"没有可用的资源源"}];
        [A2Log log:@"[AGG] 无可用源：mode=%ld class=%@ reason=%@",
         (long)mode, A2ClassDisplayName(contentClass), outcome.degradedReason];
        completion(outcome);
        return;
    }

    __block NSArray<A2ContentItem *> *modrinthItems = nil;
    __block NSArray<A2ContentItem *> *curseForgeItems = nil;
    __block NSError *modrinthError = nil;
    __block NSError *curseForgeError = nil;

    dispatch_group_t group = dispatch_group_create();

    if (wantsModrinth) {
        A2ContentFilter *modrinthFilter = [self copyOfFilter:filter];
        dispatch_group_enter(group);
        [modrinth searchWithFilter:modrinthFilter
                      contentClass:contentClass
                        completion:^(NSArray<A2ContentItem *> *items, NSError *error) {
            modrinthItems = items;
            modrinthError = error;
            dispatch_group_leave(group);
        }];
    }
    if (wantsCurseForge) {
        A2ContentFilter *curseForgeFilter = [self copyOfFilter:filter];
        dispatch_group_enter(group);
        [curseForge searchWithFilter:curseForgeFilter
                        contentClass:contentClass
                          completion:^(NSArray<A2ContentItem *> *items, NSError *error) {
            curseForgeItems = items;
            curseForgeError = error;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray<A2ContentItem *> *mr = [modrinthItems isKindOfClass:NSArray.class] ? modrinthItems : nil;
        NSArray<A2ContentItem *> *cf = [curseForgeItems isKindOfClass:NSArray.class] ? curseForgeItems : nil;

        // 单路失败 → 走降级说明；两路都失败 → 错误交给 UI。
        if (wantsModrinth && mr == nil && modrinthError != nil) {
            [degraded addObject:[NSString stringWithFormat:@"Modrinth：%@",
                                 modrinthError.localizedDescription ?: @"请求失败"]];
        }
        if (wantsCurseForge && cf == nil && curseForgeError != nil) {
            [degraded addObject:[NSString stringWithFormat:@"CurseForge：%@",
                                 curseForgeError.localizedDescription ?: @"请求失败"]];
        }

        A2AggregateSearchOutcome *outcome = [[A2AggregateSearchOutcome alloc] init];
        NSMutableArray<NSNumber *> *engaged = [NSMutableArray array];
        if (wantsModrinth && mr != nil) [engaged addObject:@(A2ContentPlatformModrinth)];
        if (wantsCurseForge && cf != nil) [engaged addObject:@(A2ContentPlatformCurseForge)];
        outcome.engagedPlatforms = engaged;
        outcome.modrinthCount = mr.count;
        outcome.curseForgeCount = cf.count;
        outcome.degradedReason = degraded.count > 0 ? [degraded componentsJoinedByString:@"；"] : nil;

        BOOL everythingFailed = (mr == nil && cf == nil);
        if (everythingFailed) {
            NSError *firstError = modrinthError ?: curseForgeError;
            outcome.error = firstError ?: [NSError errorWithDomain:@"A2AggregateSearch"
                                                              code:2
                                                          userInfo:@{NSLocalizedDescriptionKey:
                                                                         @"两个源都没有返回结果"}];
            outcome.items = @[];
            [A2Log log:@"[AGG] 全部失败：mode=%ld class=%@ err=%@",
             (long)mode, A2ClassDisplayName(contentClass), outcome.error.localizedDescription];
            completion(outcome);
            return;
        }

        outcome.items = [self mergeCurseForge:(cf ?: @[]) modrinth:(mr ?: @[])];

        [A2Log criterion:@"[AGG] mode=%ld class=%@ mr=%ld cf=%ld merged=%ld degraded=%@",
         (long)mode, A2ClassDisplayName(contentClass),
         (long)outcome.modrinthCount, (long)outcome.curseForgeCount,
         (long)outcome.items.count, outcome.degradedReason ?: @"(none)"];

        completion(outcome);
    });
}

#pragma mark - 合并

/// 逐条交错：同一序号 CurseForge 在前、Modrinth 在后。
/// 为什么交错而不是「一家一页」：只按一家排完再排另一家，会让第二家在翻页
/// 之前完全不可见；交错后首屏就能同时看到两个源的条目。
- (NSArray<A2ContentItem *> *)mergeCurseForge:(NSArray<A2ContentItem *> *)curseForge
                                    modrinth:(NSArray<A2ContentItem *> *)modrinth {
    NSMutableArray<A2ContentItem *> *merged =
        [NSMutableArray arrayWithCapacity:curseForge.count + modrinth.count];
    NSMutableDictionary<NSString *, NSNumber *> *indexByKey = [NSMutableDictionary dictionary];

    NSUInteger count = MAX(curseForge.count, modrinth.count);
    for (NSUInteger i = 0; i < count; i++) {
        if (i < curseForge.count) [self appendItem:curseForge[i] toMerged:merged indexByKey:indexByKey];
        if (i < modrinth.count)    [self appendItem:modrinth[i]    toMerged:merged indexByKey:indexByKey];
    }
    return merged;
}

/// 同名折叠键：只保留字母/数字并小写。
/// 空键（标题里全是符号）不参与折叠 —— 宁可贵复，不可错并。
- (nullable NSString *)mergeKeyForItem:(A2ContentItem *)item {
    NSString *title = item.title;
    if (title.length == 0) return nil;

    NSMutableString *key = [NSMutableString stringWithCapacity:title.length];
    NSCharacterSet *keep = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < title.length; i++) {
        unichar c = [title characterAtIndex:i];
        if ([keep characterIsMember:c]) {
            [key appendFormat:@"%C", c];
        }
    }
    NSString *lower = key.lowercaseString;
    return lower.length > 0 ? lower : nil;
}

- (void)appendItem:(A2ContentItem *)item
          toMerged:(NSMutableArray<A2ContentItem *> *)merged
         indexByKey:(NSMutableDictionary<NSString *, NSNumber *> *)indexByKey {
    if (item == nil) return;

    NSString *key = [self mergeKeyForItem:item];
    if (key.length == 0) {
        [merged addObject:item];
        return;
    }

    NSNumber *existingBox = indexByKey[key];
    if (existingBox == nil) {
        [merged addObject:item];
        indexByKey[key] = @(merged.count - 1);
        return;
    }

    NSUInteger index = existingBox.unsignedIntegerValue;
    if (index >= merged.count) {   // 防御：索引表与数组不同步时按新条目处理
        [merged addObject:item];
        indexByKey[key] = @(merged.count - 1);
        return;
    }

    A2ContentItem *existing = merged[index];
    // 同名两条：保留下载量更高的那条，★位置不变★（否则列表会随翻页跳动）。
    if (item.downloadCount > existing.downloadCount + self.mergeDownloadTolerance) {
        merged[index] = item;
        existing = item;
    }
    [A2Log log:@"[AGG] 折叠同名：%@ 保留=%@ 丢弃=%@",
     item.title,
     (existing.platform == A2ContentPlatformModrinth ? @"Modrinth" : @"CurseForge"),
     (item.platform == existing.platform ? @"同源副本" :
      (item.platform == A2ContentPlatformModrinth ? @"Modrinth" : @"CurseForge"))];
}

#pragma mark - 工具

/// 每路一份筛选副本 —— 两个源并发读取同一对象本身是安全的，
/// 但 offset/limit 将来若被某一路「就地修正」就会互相污染，故一开始就分家。
- (A2ContentFilter *)copyOfFilter:(A2ContentFilter *)filter {
    A2ContentFilter *copy = [A2ContentFilter defaultFilter];
    copy.query = filter.query;
    copy.gameVersion = filter.gameVersion;
    copy.loader = filter.loader;
    copy.categories = filter.categories ?: @[];
    copy.sortField = filter.sortField;
    copy.offset = filter.offset;
    copy.limit = filter.limit;
    return copy;
}

@end

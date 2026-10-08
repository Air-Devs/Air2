//
//  A2DownloadFavorites.m
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
//  见头文件：JSON 落盘 + 内存快照，读写走串行队列。
//

#import "A2DownloadFavorites.h"

NSNotificationName const A2FavoritesDidChangeNotification = @"A2FavoritesDidChangeNotification";

#pragma mark - 收藏项

@interface A2FavoriteItem ()
- (NSDictionary *)toDictionary;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;
@end

@implementation A2FavoriteItem

+ (instancetype)itemWithContentItem:(A2ContentItem *)content {
    A2FavoriteItem *item = [[A2FavoriteItem alloc] init];
    item.projectID = content.projectID ?: @"";
    item.title = content.title ?: @"";
    item.summary = content.summary ?: @"";
    item.platform = content.platform;
    item.iconURL = content.iconURL;
    item.categories = content.categories ?: @[];
    item.downloadCount = content.downloadCount;
    return item;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"projectID"] = self.projectID ?: @"";
    dict[@"title"] = self.title ?: @"";
    dict[@"summary"] = self.summary ?: @"";
    dict[@"platform"] = @(self.platform);
    if (self.iconURL.length) dict[@"iconURL"] = self.iconURL;
    dict[@"categories"] = self.categories ?: @[];
    dict[@"downloadCount"] = @(self.downloadCount);
    return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    NSString *projectID = dict[@"projectID"];
    if (![projectID isKindOfClass:NSString.class] || projectID.length == 0) return nil;

    A2FavoriteItem *item = [[A2FavoriteItem alloc] init];
    item.projectID = projectID;

    NSString *title = dict[@"title"];
    if ([title isKindOfClass:NSString.class]) item.title = title;

    NSString *summary = dict[@"summary"];
    if ([summary isKindOfClass:NSString.class]) item.summary = summary;

    NSString *iconURL = dict[@"iconURL"];
    if ([iconURL isKindOfClass:NSString.class]) item.iconURL = iconURL;

    NSNumber *platform = dict[@"platform"];
    if ([platform isKindOfClass:NSNumber.class]) item.platform = (A2ContentPlatform)platform.integerValue;

    NSArray *categories = dict[@"categories"];
    if ([categories isKindOfClass:NSArray.class]) item.categories = (NSArray<NSString *> *)categories;

    NSNumber *downloads = dict[@"downloadCount"];
    if ([downloads isKindOfClass:NSNumber.class]) item.downloadCount = downloads.longLongValue;

    return item;
}

@end

#pragma mark - 收藏存储

@implementation A2DownloadFavorites {
    NSMutableArray<A2FavoriteItem *> *_items;
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static A2DownloadFavorites *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2DownloadFavorites alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("dev.airdevs.air2.download-favorites", DISPATCH_QUEUE_SERIAL);
    _items = [NSMutableArray array];
    [self load];
    return self;
}

#pragma mark - 路径（唯一出口）

- (NSString *)favoritesPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    return [[[docs stringByAppendingPathComponent:@".minecraft"]
             stringByAppendingPathComponent:@".air_version"]
            stringByAppendingPathComponent:@"favorites.json"];
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:[self favoritesPath]];
    if (!data) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return;
    for (id entry in (NSArray *)json) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        A2FavoriteItem *item = [A2FavoriteItem fromDictionary:(NSDictionary *)entry];
        if (item) [_items addObject:item];
    }
}

- (void)persist {
    NSString *path = [self favoritesPath];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (A2FavoriteItem *item in _items) {
        [records addObject:[item toDictionary]];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
    if (data) [data writeToFile:path atomically:YES];
}

- (void)notifyChanged {
    if (NSThread.isMainThread) {
        [NSNotificationCenter.defaultCenter postNotificationName:A2FavoritesDidChangeNotification
                                                          object:self];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:A2FavoritesDidChangeNotification
                                                          object:self];
    });
}

#pragma mark - 查询

- (BOOL)isFavorite:(NSString *)projectID {
    if (projectID.length == 0) return NO;
    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        for (A2FavoriteItem *item in self->_items) {
            if ([item.projectID isEqualToString:projectID]) { found = YES; break; }
        }
    });
    return found;
}

- (NSArray<A2FavoriteItem *> *)allFavorites {
    __block NSArray<A2FavoriteItem *> *result = @[];
    dispatch_sync(_queue, ^{
        result = [self->_items copy];
    });
    return result;
}

#pragma mark - 写入

- (void)addFavorite:(A2FavoriteItem *)item {
    if (item.projectID.length == 0) return;
    dispatch_sync(_queue, ^{
        NSUInteger idx = [self->_items indexOfObjectPassingTest:^BOOL(A2FavoriteItem *e, NSUInteger i, BOOL *stop) {
            return [e.projectID isEqualToString:item.projectID];
        }];
        if (idx == NSNotFound) {
            [self->_items addObject:item];
        } else {
            self->_items[idx] = item;
        }
        [self persist];
    });
    [self notifyChanged];
}

- (void)toggleFavorite:(A2FavoriteItem *)item {
    if (item.projectID.length == 0) return;
    if ([self isFavorite:item.projectID]) {
        [self removeFavoriteWithID:item.projectID];
    } else {
        [self addFavorite:item];
    }
}

- (void)removeFavoriteWithID:(NSString *)projectID {
    if (projectID.length == 0) return;
    dispatch_sync(_queue, ^{
        NSUInteger idx = [self->_items indexOfObjectPassingTest:^BOOL(A2FavoriteItem *e, NSUInteger i, BOOL *stop) {
            return [e.projectID isEqualToString:projectID];
        }];
        if (idx == NSNotFound) return;
        [self->_items removeObjectAtIndex:idx];
        [self persist];
    });
    [self notifyChanged];
}

@end

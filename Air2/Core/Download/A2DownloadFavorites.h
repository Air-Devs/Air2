//
//  A2DownloadFavorites.h
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
//  下载收藏 —— 收藏项目的本地存储与变更广播（纯 Foundation）。
//

#import <Foundation/Foundation.h>
#import "A2ContentSource.h"

NS_ASSUME_NONNULL_BEGIN

/// 收藏变更通知。UI 收到后应重新拉取列表刷新。
extern NSNotificationName const A2FavoritesDidChangeNotification;

/// 收藏项目的快照 —— 只保留展示所需字段，不持有 A2ContentItem 对象。
@interface A2FavoriteItem : NSObject

@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, assign) A2ContentPlatform platform;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, assign) long long downloadCount;

/// 从资源项目快照构造（拷贝必要字段，不持有原对象）。
+ (instancetype)itemWithContentItem:(A2ContentItem *)content;

@end

/// 收藏存储。落盘到 Documents 下 JSON，读写走串行队列。
@interface A2DownloadFavorites : NSObject

+ (instancetype)shared;

/// 该项目是否已收藏。
- (BOOL)isFavorite:(NSString *)projectID;
/// 加入收藏（已存在则覆盖快照）。
- (void)addFavorite:(A2FavoriteItem *)item;
/// 已收藏则移除，否则加入。
- (void)toggleFavorite:(A2FavoriteItem *)item;
/// 按项目 ID 移除。
- (void)removeFavoriteWithID:(NSString *)projectID;
/// 全部收藏（按加入顺序）。
- (NSArray<A2FavoriteItem *> *)allFavorites;

@end

NS_ASSUME_NONNULL_END

//
//  PLPreferences.h
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
#import <Foundation/Foundation.h>

// 下载源偏好键（按资源类型独立）
extern NSString *const PREF_DOWNLOAD_SOURCE_MOD;
extern NSString *const PREF_DOWNLOAD_SOURCE_SHADER;
extern NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_MODPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_WORLD;
extern NSString *const PREF_DOWNLOAD_SOURCE_SERVER;
// CurseForge API Key 偏好键
extern NSString *const PREF_CURSEFORGE_API_KEY;
// Mod 更新时是否保留旧文件
extern NSString *const PREF_MOD_UPDATE_KEEP_OLD;
// 模组镜像源（official / mcim）
extern NSString *const PREF_MOD_MIRROR;

@interface PLPreferences : NSObject

@property(nonatomic) NSString *globalPath, *instancePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary *> *globalPref, *instancePref;

- (id)initWithGlobalPath:(NSString *)path;
- (id)initWithAutomaticMigrator;

- (void)toggleIsolationForced:(BOOL)forced;
- (id)getObject:(NSString *)key;
- (BOOL)setObject:(NSString *)key value:(id)value;
- (void)reset;

// 下载源管理（按类型独立）
+ (NSString *)currentDownloadSourceForType:(NSString *)type;
+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type;
// CurseForge API Key
+ (NSString *)curseForgeAPIKey;
+ (void)setCurseForgeAPIKey:(NSString *)key;
// Mod 更新旧文件保留
+ (BOOL)modUpdateKeepOld;
+ (void)setModUpdateKeepOld:(BOOL)keepOld;

@end

//
//  A2DownloadManifest.h
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
//  已下载清单 —— “装过什么”的唯一记录，供列表角标与更新提示查询。
//
//  为什么单列文件：下载散在各页面，直接扫盘太慢，清单是索引。
//  以文件存在为准：记录在但文件被手删 → 视为未装（查询时验存在）。
//  手删不同步删记录（记录是追加写，删文件走文件管理；残留记录不影响
//  判定，只占几字节，下次同文件下载时覆盖）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadManifest : NSObject

+ (instancetype)shared;

/// 记录一次成功下载（同 projectID+versionID 覆盖旧条）。
- (void)recordDownloadWithProjectID:(NSString *)projectID
                          versionID:(NSString *)versionID
                           fileName:(NSString *)fileName
                             subdir:(NSString *)subdir;

/// 该项目是否装过（任一版本文件仍在）。
- (BOOL)isProjectInstalled:(NSString *)projectID;

/// 该版本是否装过（文件仍在）。
- (BOOL)isVersionInstalled:(NSString *)projectID versionID:(NSString *)versionID;

@end

NS_ASSUME_NONNULL_END

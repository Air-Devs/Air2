//
//  A2RemoteVersions.h
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
//  远端版本清单 —— Mojang piston-meta 的版本列表。
//
//  为什么单列：安装器内部取清单只为自己用，游戏下载页需要先选版本，
//  清单获取必须先行且可独立失败（无网时选单直接报，而不是点安装才炸）。
//  只用 Foundation；与 A2GameInstaller 用同一清单地址，改地址两处一起改。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 清单里的一个版本（只取下载页要用的字段，不建全模型）。
@interface A2RemoteVersion : NSObject
/// 版本标识（如 1.21.5、24w44a）
@property (nonatomic, copy, readonly) NSString *versionID;
/// 清单原 type：release / snapshot / old_beta / old_alpha
@property (nonatomic, copy, readonly) NSString *type;
- (instancetype)initWithVersionID:(NSString *)versionID
                             type:(NSString *)type NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface A2RemoteVersions : NSObject

/// 拉取清单（清单顺序即官方排序，新版在前）。回调切主线程。
+ (void)fetchVersionsWithCompletion:(void (^)(NSArray<A2RemoteVersion *> * _Nullable versions,
                                              NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

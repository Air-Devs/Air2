//
//  A2LoaderVersionSource+Forge.h
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
//
//  A2LoaderVersionSource+Forge.h
//  Air2
//
//  Forge / NeoForge 版本列表获取（实现见 A2LoaderVersionSource+Forge.m）。
//  单独建这个分类头，是为了让 A2LoaderVersionSource.m 能看见这两个方法
//  —— 它们的实现在分类里，此前没有任何头文件声明，导致主 .m 调用时报
//  “no visible 声明 … declares the selector”。
//

#import "A2LoaderVersionSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2LoaderVersionSource (Forge)

/// 拉取指定 MC 版本的 Forge 版本列表（内部会走 BMCLAPI / 官网 HTML 两条路）
- (void)fetchForgeVersionsForMC:(NSString *)mcVersion
                     completion:(void (^)(NSArray<A2ModLoaderVersion *> *_Nullable versions,
                                          NSError *_Nullable error))completion;

/// 拉取指定 MC 版本的 NeoForge 版本列表
- (void)fetchNeoForgeVersionsForMC:(NSString *)mcVersion
                        completion:(void (^)(NSArray<A2ModLoaderVersion *> *_Nullable versions,
                                             NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

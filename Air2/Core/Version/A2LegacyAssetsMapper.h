//
//  A2LegacyAssetsMapper.h
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
//  远古版本资源映射 —— 把 content-addressed 的 assets/objects 还原成
//  1.0–1.6.4 客户端认得的**原始文件名目录树**。
//
//  为什么必须有这一步（不是可选优化）：
//    · 1.7.3 起客户端自己按 assets/indexes/<id>.json 去 objects/<hh>/<hash> 取文件；
//    · 1.6.4 的索引（legacy）带 `"virtual": true` —— 客户端只会去
//      `<assetsDir>/virtual/<indexID>/<原始路径>` 找文件；
//    · 1.0–1.5.2 的索引（pre-1.6）带 `"map_to_resources": true` —— 那时的客户端
//      根本不看 assetsDir，而是读 `<gameDir>/resources/<原始路径>`。
//    两条都是 Mojang 官方启动器替游戏做的事；不做 ⇒ 启动画面能过，但主界面
//    无音效无语言（典型症状：一片静音 + 英文界面 + 日志里成片 "Missing resource"）。
//
//  实现要点：
//    · 用**硬链接**（同卷）而不是复制 —— 749/1120 个对象，硬链接几乎零成本；
//      跨卷时回落为复制（assets 与实例目录不总在同一卷）。
//    · 幂等：目标已存在就跳过，重复启动不重复搬运。
//    · 拒绝含 ".." 或绝对路径的索引键（索引来自网络，不能当成可信路径拼接）。
//
//  ★谁调它★：Air2/Player/A2LaunchSession.m —— 建 VM 之前的后台段里，
//    仅当 A2LegacyProfile.isClassicGeneration 为 YES 时调用一次
//    （`+mapAssetsForVersionDirectory:…`），结果打一行 [A2-LEGACY] 判据行。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一次映射的统计（用于判据行与安装页提示）。
@interface A2LegacyAssetsMapResult : NSObject

/// 索引里的对象总数。
@property (nonatomic, assign) NSUInteger objectsSeen;
/// 本次新建成/新建链接的虚拟资源条目数（assets/virtual/<id>/…）。
@property (nonatomic, assign) NSUInteger createdVirtual;
/// 本次新建成/新建链接的 resources 条目数（<gameDir>/resources/…）。
@property (nonatomic, assign) NSUInteger createdResources;
/// 目标已存在而跳过的条目数。
@property (nonatomic, assign) NSUInteger skippedExisting;
/// 源对象缺失（assets/objects 里没有这个 hash）的条目数。
@property (nonatomic, assign) NSUInteger missingObjects;
/// 链接/复制失败的条目数。
@property (nonatomic, assign) NSUInteger failed;
/// 索引是否声明了 virtual / map_to_resources（都没声明时本类什么都不做）。
@property (nonatomic, assign) BOOL indexDeclaresVirtual;
@property (nonatomic, assign) BOOL indexDeclaresResourceMapping;

/// 一行可 grep 的摘要。
- (NSString *)summaryLine;

@end

@interface A2LegacyAssetsMapper : NSObject

/// 按版本目录映射（自己读 `<versionDir>/<versionID>.json` 取 assets 索引名）。
/// @param gameDir 实例游戏目录（map_to_resources 的目标是它下面的 resources/）；
///                传 nil 表示只做 virtual、不做 resources 映射。
+ (nullable A2LegacyAssetsMapResult *)mapAssetsForVersionDirectory:(NSString *)versionDirectory
                                                         versionID:(NSString *)versionID
                                                        assetsRoot:(NSString *)assetsRoot
                                                           gameDir:(nullable NSString *)gameDir
                                                             error:(NSError *_Nullable *_Nullable)error;

/// 按明确的索引名映射（安装器手里只有索引路径时用这一条）。
+ (nullable A2LegacyAssetsMapResult *)mapIndexAtPath:(NSString *)indexPath
                                              indexID:(NSString *)indexID
                                           assetsRoot:(NSString *)assetsRoot
                                              gameDir:(nullable NSString *)gameDir
                                                error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

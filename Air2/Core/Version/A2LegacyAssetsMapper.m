//
//  A2LegacyAssetsMapper.m
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
//  远古资源映射实现。判定（virtual / map_to_resources）以**索引 JSON 自己声明的字段**
//  为准，不按版本号猜 —— Mojang 的索引就是这么给的，照着做即可。
//

#import "A2LegacyAssetsMapper.h"

#import "A2LaunchPlan.h"

@implementation A2LegacyAssetsMapResult

- (NSString *)summaryLine {
    return [NSString stringWithFormat:
            @"[A2-LEGACY] assets objects=%lu virtual=%lu resources=%lu skipped=%lu missing=%lu failed=%lu flags(v=%d,r=%d)",
            (unsigned long)self.objectsSeen,
            (unsigned long)self.createdVirtual,
            (unsigned long)self.createdResources,
            (unsigned long)self.skippedExisting,
            (unsigned long)self.missingObjects,
            (unsigned long)self.failed,
            self.indexDeclaresVirtual ? 1 : 0,
            self.indexDeclaresResourceMapping ? 1 : 0];
}

@end

#pragma mark - 搬运（内部）

@interface A2LegacyAssetsMapper ()

+ (void)materializeSource:(NSString *)source
                 toTarget:(NSString *)target
                   result:(A2LegacyAssetsMapResult *)result
                 counting:(void (^)(A2LegacyAssetsMapResult *r))counting;

@end

@implementation A2LegacyAssetsMapper

+ (nullable A2LegacyAssetsMapResult *)mapAssetsForVersionDirectory:(NSString *)versionDirectory
                                                         versionID:(NSString *)versionID
                                                        assetsRoot:(NSString *)assetsRoot
                                                           gameDir:(nullable NSString *)gameDir
                                                             error:(NSError *_Nullable *_Nullable)error {
    if (versionDirectory.length == 0 || versionID.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2LegacyAssets"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"版本目录或版本名为空"}];
        }
        return nil;
    }
    if (assetsRoot.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2LegacyAssets"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"assets 目录为空"}];
        }
        return nil;
    }

    // 索引名与索引文件路径都从版本 JSON 推（与 A2LaunchPlan / A2GameInstaller 的落点口径一致）。
    NSDictionary *merged = [A2LaunchPlan mergedVersionJSONFromDirectory:versionDirectory
                                                              versionID:versionID
                                                                  error:nil];
    NSString *indexID = nil;
    id assetIndex = merged[@"assetIndex"];
    if ([assetIndex isKindOfClass:NSDictionary.class]) {
        id identifier = ((NSDictionary *)assetIndex)[@"id"];
        if ([identifier isKindOfClass:NSString.class]) indexID = identifier;
    }
    if (indexID.length == 0) {
        id assets = merged[@"assets"];
        if ([assets isKindOfClass:NSString.class]) indexID = assets;
    }
    if (indexID.length == 0) indexID = @"legacy";

    NSString *indexPath = [[assetsRoot stringByAppendingPathComponent:@"indexes"]
                           stringByAppendingPathComponent:
                           [indexID stringByAppendingPathExtension:@"json"]];

    return [self mapIndexAtPath:indexPath
                        indexID:indexID
                     assetsRoot:assetsRoot
                        gameDir:gameDir
                          error:error];
}

+ (nullable A2LegacyAssetsMapResult *)mapIndexAtPath:(NSString *)indexPath
                                              indexID:(NSString *)indexID
                                           assetsRoot:(NSString *)assetsRoot
                                              gameDir:(nullable NSString *)gameDir
                                                error:(NSError *_Nullable *_Nullable)error {
    NSData *data = [NSData dataWithContentsOfFile:indexPath];
    if (data == nil) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2LegacyAssets"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"资源索引不存在：%@", indexPath]}];
        }
        return nil;
    }

    NSDictionary *index = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![index isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2LegacyAssets"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"资源索引解析失败：%@", indexPath]}];
        }
        return nil;
    }

    A2LegacyAssetsMapResult *result = [[A2LegacyAssetsMapResult alloc] init];
    result.indexDeclaresVirtual = [index[@"virtual"] boolValue];
    result.indexDeclaresResourceMapping = [index[@"map_to_resources"] boolValue];

    NSDictionary *objects = [index[@"objects"] isKindOfClass:NSDictionary.class]
        ? index[@"objects"] : @{};
    result.objectsSeen = objects.count;

    // 两个标志都没声明 ⇒ 这不是远古索引，什么都不用做（正常返回，不算错）。
    if (!result.indexDeclaresVirtual && !result.indexDeclaresResourceMapping) {
        return result;
    }

    NSString *virtualID = indexID.length > 0 ? indexID : @"legacy";
    NSString *virtualRoot = [[assetsRoot stringByAppendingPathComponent:@"virtual"]
                             stringByAppendingPathComponent:virtualID];
    NSString *resourcesRoot = (gameDir.length > 0)
        ? [gameDir stringByAppendingPathComponent:@"resources"] : nil;
    NSString *objectsRoot = [assetsRoot stringByAppendingPathComponent:@"objects"];

    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *name in objects) {
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;

        // 索引来自网络：拒绝可疑路径，绝不把它当成可信拼接片段。
        if ([name hasPrefix:@"/"] || [name containsString:@".."]) {
            result.failed += 1;
            continue;
        }

        id entry = objects[name];
        NSString *hash = [entry isKindOfClass:NSDictionary.class] ? entry[@"hash"] : nil;
        if (![hash isKindOfClass:NSString.class] || hash.length < 2) {
            result.failed += 1;
            continue;
        }

        NSString *source = [[objectsRoot stringByAppendingPathComponent:[hash substringToIndex:2]]
                            stringByAppendingPathComponent:hash];
        if (![fm fileExistsAtPath:source]) {
            result.missingObjects += 1;   // 对象没下全：留给安装器/启动前的资源预检去补
            continue;
        }

        if (result.indexDeclaresVirtual) {
            [self materializeSource:source
                          toTarget:[virtualRoot stringByAppendingPathComponent:name]
                            result:result
                          counting:^(A2LegacyAssetsMapResult *r) { r.createdVirtual += 1; }];
        }
        if (result.indexDeclaresResourceMapping && resourcesRoot.length > 0) {
            [self materializeSource:source
                          toTarget:[resourcesRoot stringByAppendingPathComponent:name]
                            result:result
                          counting:^(A2LegacyAssetsMapResult *r) { r.createdResources += 1; }];
        }
    }

    return result;
}

#pragma mark - 搬运

/// 单个对象搬到目标：优先硬链接（同卷零拷贝），失败回落复制；目标已存在直接跳过。
+ (void)materializeSource:(NSString *)source
                 toTarget:(NSString *)target
                   result:(A2LegacyAssetsMapResult *)result
                 counting:(void (^)(A2LegacyAssetsMapResult *r))counting {
    NSFileManager *fm = NSFileManager.defaultManager;

    if ([fm fileExistsAtPath:target]) {
        result.skippedExisting += 1;
        return;
    }

    NSString *parent = [target stringByDeletingLastPathComponent];
    if (parent.length > 0 && ![fm fileExistsAtPath:parent]) {
        NSError *dirError = nil;
        if (![fm createDirectoryAtPath:parent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&dirError]) {
            result.failed += 1;
            return;
        }
    }

    NSError *linkError = nil;
    if ([fm linkItemAtPath:source toPath:target error:&linkError]) {
        if (counting) counting(result);
        return;
    }

    // 跨卷 / 文件系统不支持硬链接 ⇒ 退回复制（内容一致，只是多占一份空间）。
    NSError *copyError = nil;
    if ([fm copyItemAtPath:source toPath:target error:&copyError]) {
        if (counting) counting(result);
        return;
    }

    result.failed += 1;
}

@end

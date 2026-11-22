//
//  A2ModLoaderSelection.m
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
//  A2ModLoaderSelection.m
//  Air2
//

#import "A2ModLoaderSelection.h"

@implementation A2ModLoaderSelection

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _versions = [NSMutableDictionary dictionary];
    return self;
}

#pragma mark - 配对关系

/// API 模组 → 它需要的主加载器
+ (NSNumber *)primaryLoaderForAPI:(A2ModLoaderType)apiType {
    switch (apiType) {
        case A2ModLoaderTypeFabricAPI:       return @(A2ModLoaderTypeFabric);
        case A2ModLoaderTypeQuiltAPI:        return @(A2ModLoaderTypeQuilt);
        case A2ModLoaderTypeLegacyFabricAPI: return @(A2ModLoaderTypeLegacyFabric);
        case A2ModLoaderTypeBabricAPI:       return @(A2ModLoaderTypeBabric);
        default:                             return nil;
    }
}

+ (NSNumber *)apiForPrimaryLoader:(A2ModLoaderType)loaderType {
    switch (loaderType) {
        case A2ModLoaderTypeFabric:       return @(A2ModLoaderTypeFabricAPI);
        case A2ModLoaderTypeQuilt:        return @(A2ModLoaderTypeQuiltAPI);
        case A2ModLoaderTypeLegacyFabric: return @(A2ModLoaderTypeLegacyFabricAPI);
        case A2ModLoaderTypeBabric:       return @(A2ModLoaderTypeBabricAPI);
        default:                          return nil;
    }
}

+ (NSArray<NSNumber *> *)allPrimaryLoaders {
    return @[
        @(A2ModLoaderTypeOptiFine),
        @(A2ModLoaderTypeForge),
        @(A2ModLoaderTypeNeoForge),
        @(A2ModLoaderTypeFabric),
        @(A2ModLoaderTypeQuilt),
        @(A2ModLoaderTypeLegacyFabric),
        @(A2ModLoaderTypeBabric),
        @(A2ModLoaderTypeCleanroom),
    ];
}

+ (NSArray<NSNumber *> *)allAPIMods {
    return @[
        @(A2ModLoaderTypeFabricAPI),
        @(A2ModLoaderTypeQuiltAPI),
        @(A2ModLoaderTypeLegacyFabricAPI),
        @(A2ModLoaderTypeBabricAPI),
    ];
}

#pragma mark - 互斥判定

/// 两个类型是否互斥 —— 对照 ZL2 的 areMutuallyExclusive。
///
/// 规则：
///   1. 两个主加载器 → 互斥（Forge 与 Fabric 都要接管启动流程）
///   2. 主加载器 vs API → 只有配对的才不互斥
///   3. API vs API → 同属一个主加载器才不互斥
///   4. 其余（如 API 与不相关的主加载器）→ 不互斥
- (BOOL)typesAreMutuallyExclusive:(A2ModLoaderType)a other:(A2ModLoaderType)b {
    if (a == b) return NO;

    BOOL aIsLoader = A2ModLoaderIsLoader(a);
    BOOL bIsLoader = A2ModLoaderIsLoader(b);
    BOOL aIsAPI = A2ModLoaderIsAPIMod(a);
    BOOL bIsAPI = A2ModLoaderIsAPIMod(b);

    // 两个主加载器
    if (aIsLoader && bIsLoader) return YES;

    // 主加载器 vs API
    if (aIsLoader && bIsAPI) {
        NSNumber *required = [A2ModLoaderSelection primaryLoaderForAPI:b];
        return required.integerValue != (NSInteger)a;
    }
    if (aIsAPI && bIsLoader) {
        NSNumber *required = [A2ModLoaderSelection primaryLoaderForAPI:a];
        return required.integerValue != (NSInteger)b;
    }

    // API vs API
    if (aIsAPI && bIsAPI) {
        NSNumber *ra = [A2ModLoaderSelection primaryLoaderForAPI:a];
        NSNumber *rb = [A2ModLoaderSelection primaryLoaderForAPI:b];
        return ra.integerValue != rb.integerValue;
    }

    return NO;
}

#pragma mark - 选择

- (void)selectType:(A2ModLoaderType)type version:(NSString *)version {
    [self.versions removeObjectForKey:@(type)];
    if (version.length == 0) {
        // 取消一个主加载器时，连带取消它对应的 API 模组 ——
        // Fabric 都没了，Fabric API 留着没有意义。
        if (A2ModLoaderIsLoader(type)) {
            NSNumber *api = [A2ModLoaderSelection apiForPrimaryLoader:type];
            if (api) [self.versions removeObjectForKey:api];
        }
        return;
    }

    // 清掉与之互斥的已选项
    NSArray<NSNumber *> *keys = self.versions.allKeys;
    for (NSNumber *key in keys) {
        if ([self typesAreMutuallyExclusive:type other:(A2ModLoaderType)key.integerValue]) {
            [self.versions removeObjectForKey:key];
            // 被清掉的若是个主加载器，它的 API 也要跟着走
            if (A2ModLoaderIsLoader((A2ModLoaderType)key.integerValue)) {
                NSNumber *api = [A2ModLoaderSelection apiForPrimaryLoader:
                                 (A2ModLoaderType)key.integerValue];
                if (api) [self.versions removeObjectForKey:api];
            }
        }
    }

    self.versions[@(type)] = version;
}

- (NSNumber *)selectedLoaderType {
    for (NSNumber *key in self.versions) {
        if (A2ModLoaderIsLoader((A2ModLoaderType)key.integerValue)) return key;
    }
    return nil;
}

- (NSNumber *)selectedAPIType {
    for (NSNumber *key in self.versions) {
        if (A2ModLoaderIsAPIMod((A2ModLoaderType)key.integerValue)) return key;
    }
    return nil;
}

- (BOOL)canSelectType:(A2ModLoaderType)type {
    for (NSNumber *key in self.versions) {
        if ([self typesAreMutuallyExclusive:type
                                       other:(A2ModLoaderType)key.integerValue]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)isConflictingType:(A2ModLoaderType)type {
    return ![self canSelectType:type] && self.versions[@(type)] == nil;
}

@end

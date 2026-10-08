//
//  A2ModLoaderAPI.m
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

#import "A2ModLoaderAPI.h"

/// 各加载器的数据源（官方 + 国内镜像）
static NSString *const kFabricOfficial = @"https://meta.fabricmc.net/v2";
static NSString *const kFabricMirror   = @"https://bmclapi2.bangbang93.com/fabric-meta/v2";
static NSString *const kQuiltOfficial  = @"https://meta.quiltmc.org/v3";
static NSString *const kLegacyFabricOfficial = @"https://meta.legacyfabric.net/v2";
static NSString *const kLegacyFabricMirror   = @"https://bmclapi2.bangbang93.com/legacy-fabric-meta/v2";

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";

/// 结果返回主线程
static void A2RunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

#pragma mark - 版本模型

@implementation A2ModLoaderVersion

+ (instancetype)version:(NSString *)v stable:(BOOL)stable type:(A2ModLoaderType)type {
    A2ModLoaderVersion *m = [A2ModLoaderVersion new];
    m.version = v;
    m.stable = stable;
    m.type = type;
    return m;
}

- (NSString *)displayName {
    return [NSString stringWithFormat:@"%@ %@", [A2ModLoaderAPI displayNameForType:self.type], self.version];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2ModLoaderVersion %@ %@%@>",
            [A2ModLoaderAPI identifierForType:self.type], self.version,
            self.stable ? @"" : @" (beta)"];
}

@end

#pragma mark - API

@implementation A2ModLoaderAPI

+ (instancetype)shared {
    static A2ModLoaderAPI *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2ModLoaderAPI alloc] init];
    });
    return shared;
}

+ (NSString *)displayNameForType:(A2ModLoaderType)type {
    switch (type) {
        case A2ModLoaderTypeFabric:       return @"Fabric";
        case A2ModLoaderTypeQuilt:        return @"Quilt";
        case A2ModLoaderTypeLegacyFabric: return @"Legacy Fabric";
        case A2ModLoaderTypeForge:        return @"Forge";
        case A2ModLoaderTypeNeoForge:     return @"NeoForge";
        case A2ModLoaderTypeOptiFine:     return @"OptiFine";
    }
    return @"未知";
}

+ (NSString *)identifierForType:(A2ModLoaderType)type {
    switch (type) {
        case A2ModLoaderTypeFabric:       return @"fabric";
        case A2ModLoaderTypeQuilt:        return @"quilt";
        case A2ModLoaderTypeLegacyFabric: return @"legacy-fabric";
        case A2ModLoaderTypeForge:        return @"forge";
        case A2ModLoaderTypeNeoForge:     return @"neoforge";
        case A2ModLoaderTypeOptiFine:     return @"optifine";
    }
    return @"unknown";
}

+ (NSArray<NSNumber *> *)allLoaderTypes {
    return @[
        @(A2ModLoaderTypeFabric),
        @(A2ModLoaderTypeQuilt),
        @(A2ModLoaderTypeForge),
        @(A2ModLoaderTypeNeoForge),
        @(A2ModLoaderTypeLegacyFabric),
        @(A2ModLoaderTypeOptiFine),
    ];
}

#pragma mark - 网络

- (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return req;
}

/// 简单重试（2 次）。加载器 meta 服务偶尔抖动，重试比直接失败好。
- (void)GET:(NSString *)urlString
       retry:(NSInteger)retry
  completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {

    NSMutableURLRequest *req = [self requestWithURLString:urlString];
    if (!req) {
        A2RunOnMain(^{
            if (completion) completion(nil, [self error:@"URL 无效"]);
        });
        return;
    }

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;

        if (error || http.statusCode < 200 || http.statusCode >= 300) {
            if (retry > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [self GET:urlString retry:retry - 1 completion:completion];
                });
                return;
            }
            A2RunOnMain(^{
                if (completion) {
                    completion(nil, error ?: [self error:[NSString stringWithFormat:
                        @"HTTP %ld", (long)http.statusCode]]);
                }
            });
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2RunOnMain(^{
            if (completion) {
                completion(json, json ? nil : [self error:@"返回数据格式异常"]);
            }
        });
    }];
    [task resume];
}

- (NSError *)error:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModLoader" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - Fabric 系

/// Fabric / Quilt / LegacyFabric 的 meta 格式一致
/// （Quilt 用 v3 路径，结构兼容，这里统一处理）
- (void)fetchFabricLikeFrom:(NSString *)baseURL
                       type:(A2ModLoaderType)type
                  mcVersion:(NSString *)mcVersion
                 completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    NSString *url = [baseURL stringByAppendingPathComponent:@"versions"];

    [self GET:url retry:2 completion:^(id json, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if (![json isKindOfClass:NSDictionary.class]) {
            if (completion) completion(nil, [self error:@"数据格式异常"]);
            return;
        }

        // 先确认这个 MC 版本被该加载器支持
        NSArray *games = json[@"game"];
        BOOL supported = NO;
        if ([games isKindOfClass:NSArray.class]) {
            for (NSDictionary *g in games) {
                if ([g isKindOfClass:NSDictionary.class] &&
                    [g[@"version"] isEqualToString:mcVersion]) {
                    supported = YES;
                    break;
                }
            }
        }
        if (!supported) {
            // 不支持就返回空数组（不是错误）—— 上层据此提示「此版本无可用加载器」
            if (completion) completion(@[], nil);
            return;
        }

        NSArray *loaders = json[@"loader"];
        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
        if ([loaders isKindOfClass:NSArray.class]) {
            for (NSDictionary *l in loaders) {
                if (![l isKindOfClass:NSDictionary.class]) continue;
                NSString *v = l[@"version"];
                if (![v isKindOfClass:NSString.class]) continue;
                BOOL stable = [l[@"stable"] boolValue];
                [out addObject:[A2ModLoaderVersion version:v stable:stable type:type]];
            }
        }
        if (completion) completion(out, nil);
    }];
}

#pragma mark - Forge 系

/// Forge / NeoForge 从 maven 的版本列表取。
/// 路径格式与 Fabric 不同：需要先拉 maven-metadata.xml 或直接试 JSON。
- (void)fetchForgeLike:(A2ModLoaderType)type
             mcVersion:(NSString *)mcVersion
            completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    // NeoForge 的版本号是 「MC版本.构建号」的形式（如 21.1.72 对应 1.21.1），
    // 转换规则：1.21.1 → 21.1，1.21 → 21.0
    NSString *prefix = [self neoForgePrefixForMC:mcVersion
                                          isNeo:(type == A2ModLoaderTypeNeoForge)];

    NSString *base = (type == A2ModLoaderTypeNeoForge)
        ? @"https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge"
        : [NSString stringWithFormat:
           @"https://maven.minecraftforge.net/api/maven/versions/releases/net/minecraftforge/forge"];

    [self GET:base retry:2 completion:^(id json, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSArray *versions = dict[@"versions"];
        if (![versions isKindOfClass:NSArray.class]) {
            if (completion) completion(@[], nil);
            return;
        }

        NSMutableArray<A2ModLoaderVersion *> *out = [NSMutableArray array];
        for (id v in versions) {
            if (![v isKindOfClass:NSString.class]) continue;
            NSString *ver = v;

            // 过滤出属于该 MC 版本的构建
            if (type == A2ModLoaderTypeNeoForge) {
                if (prefix.length && ![ver hasPrefix:prefix]) continue;
            } else {
                // Forge 的版本号格式：{mcVersion}-{forgeVersion}
                if (![ver hasPrefix:[mcVersion stringByAppendingString:@"-"]]) continue;
                // 展示时去掉 MC 版本前缀
                NSRange dash = [ver rangeOfString:@"-"];
                if (dash.location != NSNotFound) {
                    ver = [ver substringFromIndex:dash.location + 1];
                }
            }
            [out addObject:[A2ModLoaderVersion version:ver stable:YES type:type]];
        }
        if (completion) completion(out, nil);
    }];
}

/// 把 MC 版本转成 NeoForge 的版本前缀
/// 1.21.1 → "21.1."   1.21 → "21.0."   1.20.4 → "20.4."
- (NSString *)neoForgePrefixForMC:(NSString *)mc isNeo:(BOOL)isNeo {
    if (!isNeo) return nil;
    NSArray<NSString *> *parts = [mc componentsSeparatedByString:@"."];
    if (parts.count < 2) return nil;

    NSString *major = parts[1];   // 21
    NSString *minor = (parts.count >= 3) ? parts[2] : @"0";
    return [NSString stringWithFormat:@"%@.%@.", major, minor];
}

#pragma mark - 统一入口

- (void)versionsForLoader:(A2ModLoaderType)type
                mcVersion:(NSString *)mcVersion
               completion:(void (^)(NSArray<A2ModLoaderVersion *> *, NSError *))completion {

    if (mcVersion.length == 0) {
        if (completion) completion(nil, [self error:@"未指定游戏版本"]);
        return;
    }

    switch (type) {
        case A2ModLoaderTypeFabric:
            [self fetchFabricLikeFrom:kFabricOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeQuilt:
            [self fetchFabricLikeFrom:kQuiltOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeLegacyFabric:
            [self fetchFabricLikeFrom:kLegacyFabricOfficial type:type
                            mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeForge:
        case A2ModLoaderTypeNeoForge:
            [self fetchForgeLike:type mcVersion:mcVersion completion:completion];
            break;

        case A2ModLoaderTypeOptiFine:
            // OptiFine 没有公开 API，需要解析下载页 HTML。
            // 这里先返回空并标记为不支持，避免给出假数据。
            if (completion) completion(@[], nil);
            break;
    }
}

@end

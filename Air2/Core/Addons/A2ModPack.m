//
//  A2ModPack.m
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
//  见头文件：只解析清单，不下载、不解压 overrides（执行层另起任务）。
//  字段缺失按“可空”处理：名字取不到就用文件名，下载地址取不到就记 nil
//  让执行层跳过而不是崩；required 语义两边对齐（CF 可选 vs MR 服务端排除）。
//

#import "A2ModPack.h"
#import "A2ZipReader.h"

NSString *const A2ModPackErrorDomain = @"A2ModPack";

static NSString *const kCFManifestName = @"manifest.json";
static NSString *const kMRIndexName = @"modrinth.index.json";

@implementation A2ModPackFile

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：无路径的文件项是非法的。
    // 保留实现体满足声明/实现一致性检查；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithRelativePath:(NSString *)relativePath
                         downloadURL:(NSString *)downloadURL
                                sha1:(NSString *)sha1
                            fileSize:(long long)fileSize
                            required:(BOOL)required {
    self = [super init];
    if (!self) return nil;
    _relativePath = [relativePath copy];
    _downloadURL = [downloadURL copy];
    _sha1 = [sha1 copy];
    _fileSize = fileSize;
    _required = required;
    return self;
}

@end

@interface A2ModPackPlan ()
@property (nonatomic, assign) A2ModPackFormat format;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *loaderID;
@property (nonatomic, copy, nullable) NSString *overridesDir;
@property (nonatomic, copy) NSArray<A2ModPackFile *> *files;
@end

@implementation A2ModPackPlan
@end

@implementation A2ModPackParser

+ (A2ModPackFormat)detectFormatOfZipAtPath:(NSString *)zipPath {
    A2ZipReader *z = [[A2ZipReader alloc] initWithPath:zipPath];
    if (!z) return A2ModPackFormatUnknown;
    // Modrinth 优先：两种清单理论上不会同包出现，万一都出现按 Modrinth 计
    // （mrpack 是更严格的格式，误判代价更小）。
    if ([z containsEntry:kMRIndexName]) return A2ModPackFormatModrinth;
    if ([z containsEntry:kCFManifestName]) return A2ModPackFormatCurseForge;
    return A2ModPackFormatUnknown;
}

+ (A2ModPackPlan *)parseZipAtPath:(NSString *)zipPath error:(NSError **)error {
    A2ZipReader *z = [[A2ZipReader alloc] initWithPath:zipPath];
    if (!z) {
        if (error) *error = [self err:A2ModPackErrorUnreadableZip message:@"打不开整合包文件"];
        return nil;
    }
    A2ModPackFormat fmt = [self detectFormatOfZipAtPath:zipPath];
    if (fmt == A2ModPackFormatModrinth) return [self parseModrinth:z error:error];
    if (fmt == A2ModPackFormatCurseForge) return [self parseCurseForge:z error:error];
    if (error) *error = [self err:A2ModPackErrorUnsupportedFormat message:@"不是支持的整合包格式"];
    return nil;
}

#pragma mark - Modrinth

+ (A2ModPackPlan *)parseModrinth:(A2ZipReader *)z error:(NSError **)error {
    NSData *data = [z dataForEntry:kMRIndexName];
    NSDictionary *json = [self selfJSONObject:data error:error];
    if (!json) return nil;
    // game 必须为 minecraft，其他游戏的包（如 Bedrock 插件包）明确拒绝。
    if (![[json[@"game"] isKindOfClass:NSString.class] ? json[@"game"] : @"" isEqualToString:@"minecraft"]) {
        if (error) *error = [self err:A2ModPackErrorBadManifest message:@"不是 Minecraft 整合包"];
        return nil;
    }
    A2ModPackPlan *plan = [A2ModPackPlan new];
    plan.format = A2ModPackFormatModrinth;
    plan.name = [json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : @"未命名整合包";
    plan.version = [json[@"versionId"] isKindOfClass:NSString.class] ? json[@"versionId"] : nil;
    NSDictionary *deps = [json[@"dependencies"] isKindOfClass:NSDictionary.class] ? json[@"dependencies"] : @{};
    id mc = deps[@"minecraft"];
    plan.gameVersion = [mc isKindOfClass:NSString.class] ? mc : nil;
    plan.overridesDir = @"overrides";

    NSMutableArray<A2ModPackFile *> *files = [NSMutableArray array];
    NSArray *raw = [json[@"files"] isKindOfClass:NSArray.class] ? json[@"files"] : @[];
    for (NSDictionary *f in raw) {
        if (![f isKindOfClass:NSDictionary.class]) continue;
        NSString *path = [f[@"path"] isKindOfClass:NSString.class] ? f[@"path"] : nil;
        if (path.length == 0) continue;
        // 服务端专属文件不装（env.server=required 且 client 不要求）。
        NSDictionary *env = [f[@"env"] isKindOfClass:NSDictionary.class] ? f[@"env"] : nil;
        NSString *server = [env[@"server"] isKindOfClass:NSString.class] ? env[@"server"] : nil;
        NSString *client = [env[@"client"] isKindOfClass:NSString.class] ? env[@"client"] : nil;
        if ([server isEqualToString:@"required"] && ![client isEqualToString:@"required"]) continue;
        NSArray *dls = [f[@"downloads"] isKindOfClass:NSArray.class] ? f[@"downloads"] : @[];
        NSString *url = [dls.firstObject isKindOfClass:NSString.class] ? dls.firstObject : nil;
        NSDictionary *hashes = [f[@"hashes"] isKindOfClass:NSDictionary.class] ? f[@"hashes"] : @{};
        NSString *sha1 = [hashes[@"sha1"] isKindOfClass:NSString.class] ? hashes[@"sha1"] : nil;
        long long size = -1;
        if ([f[@"fileSize"] respondsToSelector:@selector(longLongValue)]) size = [f[@"fileSize"] longLongValue];
        // 无下载地址的记 nil，执行层跳过并计数，而不是在这里丢掉（对账用）。
        A2ModPackFile *e = [[A2ModPackFile alloc] initWithRelativePath:path
                                                           downloadURL:url
                                                                  sha1:sha1
                                                              fileSize:size
                                                              required:YES];
        [files addObject:e];
    }
    plan.files = [files copy];
    return plan;
}

#pragma mark - CurseForge

+ (A2ModPackPlan *)parseCurseForge:(A2ZipReader *)z error:(NSError **)error {
    NSData *data = [z dataForEntry:kCFManifestName];
    NSDictionary *json = [self selfJSONObject:data error:error];
    if (!json) return nil;
    NSString *type = [json[@"manifestType"] isKindOfClass:NSString.class] ? json[@"manifestType"] : @"";
    if (![type isEqualToString:@"minecraftModpack"]) {
        if (error) *error = [self err:A2ModPackErrorBadManifest message:@"不是 Minecraft 整合包"];
        return nil;
    }
    A2ModPackPlan *plan = [A2ModPackPlan new];
    plan.format = A2ModPackFormatCurseForge;
    plan.name = [json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : @"未命名整合包";
    plan.version = [json[@"version"] isKindOfClass:NSString.class] ? json[@"version"] : nil;
    NSDictionary *mc = [json[@"minecraft"] isKindOfClass:NSDictionary.class] ? json[@"minecraft"] : @{};
    plan.gameVersion = [mc[@"version"] isKindOfClass:NSString.class] ? mc[@"version"] : nil;
    NSArray *loaders = [mc[@"modLoaders"] isKindOfClass:NSArray.class] ? mc[@"modLoaders"] : @[];
    NSDictionary *primary = nil;
    for (NSDictionary *l in loaders) {
        if (![l isKindOfClass:NSDictionary.class]) continue;
        if ([l[@"primary"] boolValue]) { primary = l; break; }
        if (!primary) primary = l;
    }
    plan.loaderID = [primary[@"id"] isKindOfClass:NSString.class] ? primary[@"id"] : nil;
    NSString *overrides = [json[@"overrides"] isKindOfClass:NSString.class] ? json[@"overrides"] : nil;
    plan.overridesDir = overrides.length ? overrides : @"overrides";

    NSMutableArray<A2ModPackFile *> *files = [NSMutableArray array];
    NSArray *raw = [json[@"files"] isKindOfClass:NSArray.class] ? json[@"files"] : @[];
    for (NSDictionary *f in raw) {
        if (![f isKindOfClass:NSDictionary.class]) continue;
        NSInteger fileID = [f[@"fileID"] integerValue];
        if (fileID == 0) continue;
        NSString *fileName = [f[@"fileName"] isKindOfClass:NSString.class] ? f[@"fileName"] : nil;
        NSString *url = [f[@"url"] isKindOfClass:NSString.class] ? f[@"url"] : nil;
        if (!url) {
            // 无直链按官方规则拼 CDN（与 ZL2 CurseForgePack 同款）。
            NSString *name = fileName.length ? fileName : [NSString stringWithFormat:@"%ld.jar", (long)fileID];
            url = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%ld/%@",
                   (long)(fileID / 1000), (long)(fileID % 1000), name];
        }
        BOOL required = YES;
        if (f[@"required"] != nil) required = [f[@"required"] boolValue];
        NSString *rel = [@"mods" stringByAppendingPathComponent:
                         fileName.length ? fileName : [NSString stringWithFormat:@"%ld.jar", (long)fileID]];
        A2ModPackFile *e = [[A2ModPackFile alloc] initWithRelativePath:rel
                                                           downloadURL:url
                                                                  sha1:nil
                                                              fileSize:-1
                                                              required:required];
        [files addObject:e];
    }
    plan.files = [files copy];
    return plan;
}

#pragma mark - 小工具

+ (NSDictionary *)selfJSONObject:(NSData *)data error:(NSError **)error {
    if (!data) {
        if (error) *error = [self err:A2ModPackErrorBadManifest message:@"清单读不出来"];
        return nil;
    }
    NSError *jsonErr = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = [self err:A2ModPackErrorBadManifest message:@"清单不是合法 JSON"];
        return nil;
    }
    return json;
}

+ (NSError *)err:(A2ModPackError)code message:(NSString *)message {
    return [NSError errorWithDomain:A2ModPackErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end

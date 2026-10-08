//
//  A2VersionInfo.m
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
//  实现见头文件的决策说明。
//

#import "A2VersionInfo.h"

NSString *A2VersionLoaderDisplayName(A2VersionLoaderKind kind) {
    switch (kind) {
        case A2VersionLoaderKindForge: return @"Forge";
        case A2VersionLoaderKindNeoForge: return @"NeoForge";
        case A2VersionLoaderKindFabric: return @"Fabric";
        case A2VersionLoaderKindLegacyFabric: return @"LegacyFabric";
        case A2VersionLoaderKindBabric: return @"Babric";
        case A2VersionLoaderKindQuilt: return @"Quilt";
        case A2VersionLoaderKindLiteLoader: return @"LiteLoader";
        case A2VersionLoaderKindCleanroom: return @"Cleanroom";
        case A2VersionLoaderKindOptiFine: return @"OptiFine";
        default: return @"Unknown";
    }
}

/// 加载器展示优先级（数字越小越靠前，只决定列表里的先后，不代表选中）。
static NSInteger A2LoaderPriority(A2VersionLoaderKind kind) {
    switch (kind) {
        case A2VersionLoaderKindForge: return 0;
        case A2VersionLoaderKindNeoForge: return 1;
        case A2VersionLoaderKindCleanroom: return 2;
        case A2VersionLoaderKindFabric: return 3;
        case A2VersionLoaderKindQuilt: return 4;
        case A2VersionLoaderKindLegacyFabric: return 5;
        case A2VersionLoaderKindBabric: return 6;
        case A2VersionLoaderKindOptiFine: return 7;
        case A2VersionLoaderKindLiteLoader: return 8;
        default: return 1000;
    }
}

@implementation A2VersionLoaderInfo

- (instancetype)initWithKind:(A2VersionLoaderKind)kind version:(NSString *)version {
    self = [super init];
    if (!self) return nil;
    _kind = kind;
    _version = [version copy] ?: @"";
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    A2VersionLoaderInfo *c = [[A2VersionLoaderInfo allocWithZone:zone] initWithKind:self.kind
                                                                            version:self.version];
    return c;
}

@end

#pragma mark - 解析辅助

/// 非空字符串才取值，否则返回 nil（json 里缺字段是常态，不抛异常）。
static NSString *A2NonEmptyString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *s = (NSString *)value;
    if (s.length == 0) return nil;
    return s;
}

/// 正则匹配样板抽出来：5 处 id 兜底只给 pattern，不各写一遍创建与判空。
static NSString *A2FirstCapture(NSString *text, NSString *pattern) {
    if (text.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:0
                                                                          error:nil];
    if (!re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:text
                                             options:0
                                               range:NSMakeRange(0, text.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSRange r = [m rangeAtIndex:1];
    if (r.location == NSNotFound) return nil;
    return [text substringWithRange:r];
}

/// Forge 新旧版号格式不同（新版形如 1.20.1-47.2.0，旧版形如 1.7.2-10.12.2.1161-mc172），
/// 按横杠数切分取段，格式对不上就原样返回，不猜。
static NSString *A2ParseForgeVersion(NSString *raw) {
    if (raw.length == 0) return @"";
    NSArray<NSString *> *dashParts = [raw componentsSeparatedByString:@"-"];
    if (dashParts.count == 2) {
        return dashParts.lastObject;
    }
    if (dashParts.count >= 3) {
        NSString *first = dashParts.firstObject;
        NSString *last = dashParts.lastObject;
        NSString *middle = dashParts[1];
        if ([last hasPrefix:@"mc"]) return middle;
        if ([first isEqualToString:last]) return middle;
    }
    return raw;
}

/// NeoForge 真实版本号藏在 game 参数里，找不到则返回 nil 由调用方回落。
static NSString *A2NeoForgeVersionFromJSON(NSDictionary *json) {
    id args = json[@"arguments"];
    if (![args isKindOfClass:NSDictionary.class]) return nil;
    id game = ((NSDictionary *)args)[@"game"];
    if (![game isKindOfClass:NSArray.class]) return nil;
    NSArray *items = (NSArray *)game;
    for (NSUInteger i = 0; i + 1 < items.count; i++) {
        id cur = items[i];
        if (![cur isKindOfClass:NSString.class]) continue;
        if (![(NSString *)cur isEqualToString:@"--fml.neoForgeVersion"]) continue;
        NSString *next = A2NonEmptyString(items[i + 1]);
        if (next) return next;
    }
    return nil;
}

static NSString *A2ExtractMinecraftVersion(NSDictionary *json, NSString *fallbackID) {
    NSString *jsonID = A2NonEmptyString(json[@"id"]) ?: fallbackID;

    id patches = json[@"patches"];
    if ([patches isKindOfClass:NSArray.class] && ((NSArray *)patches).count > 0) {
        id first = ((NSArray *)patches).firstObject;
        if ([first isKindOfClass:NSDictionary.class]) {
            NSString *v = A2NonEmptyString(((NSDictionary *)first)[@"version"]);
            if (v) return v;
        }
    }

    NSString *clientVersion = A2NonEmptyString(json[@"clientVersion"]);
    if (clientVersion) return clientVersion;

    id launchFor = json[@"launchFor"];
    if ([launchFor isKindOfClass:NSDictionary.class]) {
        id infos = ((NSDictionary *)launchFor)[@"infos"];
        if ([infos isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)infos) {
                if (![item isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *d = (NSDictionary *)item;
                if (![A2NonEmptyString(d[@"name"]) isEqualToString:@"Minecraft"]) continue;
                NSString *v = A2NonEmptyString(d[@"version"]);
                if (v) return v;
            }
        }
    }

    id libraries = json[@"libraries"];
    if ([libraries isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)libraries) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *name = A2NonEmptyString(((NSDictionary *)item)[@"name"]);
            if (!name) continue;
            NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
            if (parts.count < 3) continue;
            if (![parts[0] isEqualToString:@"net.minecraft"]) continue;
            if (!([parts[1] isEqualToString:@"client"] || [parts[1] isEqualToString:@"server"])) continue;
            if (parts[2].length > 0) return parts[2];
        }
    }

    NSString *inherits = A2NonEmptyString(json[@"inheritsFrom"]);
    if (inherits) return inherits;

    NSArray<NSString *> *patterns = @[
        @"(\\d+\\.\\d+(?:\\.\\d+)?|\\d{2}w\\d{2}[a-z])-OptiFine",
        @"(\\d+\\.\\d+(?:\\.\\d+)?|\\d{2}w\\d{2}[a-z])-forge",
        @"^(\\d+\\.\\d+(?:\\.\\d+)?)-(Forge[\\d.]*)-mc\\d+",
        @"fabric-loader-[\\w.\\-]+-(\\d+\\.\\d+(?:\\.\\d+)?|\\d{2}w\\d{2}[a-z])",
        @"quilt-loader-[\\w.\\-]+-(\\d+\\.\\d+(?:\\.\\d+)?|\\d{2}w\\d{2}[a-z])",
    ];
    for (NSString *p in patterns) {
        NSString *hit = A2FirstCapture(jsonID, p);
        if (hit) return hit;
    }
    return jsonID;
}

static NSArray<A2VersionLoaderInfo *> *A2DetectModLoaders(NSDictionary *json) {
    NSMutableArray<A2VersionLoaderInfo *> *out = [NSMutableArray array];
    BOOL hasFabric = NO;
    BOOL hasLegacy = NO;
    BOOL hasBabric = NO;
    NSString *fabricVer = nil;

    id libraries = json[@"libraries"];
    if ([libraries isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)libraries) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *name = A2NonEmptyString(((NSDictionary *)item)[@"name"]);
            if (!name) continue;
            NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
            if (parts.count < 2) continue;
            NSString *group = parts[0];
            NSString *artifact = parts[1];
            NSString *ver = parts.count >= 3 ? parts[2] : @"";

            if ([group isEqualToString:@"net.fabricmc"] &&
                [artifact isEqualToString:@"fabric-loader"]) {
                hasFabric = YES;
                fabricVer = ver;
            } else if ([group isEqualToString:@"net.legacyfabric"] &&
                       [artifact isEqualToString:@"intermediary"]) {
                hasLegacy = YES;
            } else if ([group isEqualToString:@"babric"] &&
                       [artifact isEqualToString:@"intermediary-upstream"]) {
                hasBabric = YES;
            } else if ([group isEqualToString:@"net.minecraftforge"] &&
                       ([artifact isEqualToString:@"forge"] ||
                        [artifact isEqualToString:@"fmlloader"])) {
                NSString *v = A2ParseForgeVersion(ver);
                [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:A2VersionLoaderKindForge
                                                                version:v]];
            } else if ([group isEqualToString:@"net.neoforged.fancymodloader"] &&
                       [artifact isEqualToString:@"loader"]) {
                NSString *v = A2NeoForgeVersionFromJSON(json) ?: ver;
                [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:A2VersionLoaderKindNeoForge
                                                                version:v]];
            } else if (([group isEqualToString:@"optifine"] ||
                        [group isEqualToString:@"net.optifine"]) &&
                       [artifact isEqualToString:@"OptiFine"]) {
                [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:A2VersionLoaderKindOptiFine
                                                                version:ver]];
            } else if ([group isEqualToString:@"org.quiltmc"] &&
                       [artifact isEqualToString:@"quilt-loader"]) {
                [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:A2VersionLoaderKindQuilt
                                                                version:ver]];
            } else if ([group isEqualToString:@"com.mumfrey"] &&
                       [artifact isEqualToString:@"liteloader"]) {
                [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:A2VersionLoaderKindLiteLoader
                                                                version:ver]];
            } else if ([group isEqualToString:@"com.cleanroommc"] &&
                       [artifact isEqualToString:@"cleanroom"]) {
                [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:A2VersionLoaderKindCleanroom
                                                                version:ver]];
            }
        }
    }

    if (hasFabric && fabricVer.length > 0) {
        A2VersionLoaderKind kind = A2VersionLoaderKindFabric;
        if (hasLegacy) {
            kind = A2VersionLoaderKindLegacyFabric;
        } else if (hasBabric) {
            kind = A2VersionLoaderKindBabric;
        }
        [out addObject:[[A2VersionLoaderInfo alloc] initWithKind:kind version:fabricVer]];
    }

    NSMutableArray<A2VersionLoaderInfo *> *unique = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (A2VersionLoaderInfo *info in out) {
        NSNumber *key = @(info.kind);
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [unique addObject:info];
    }
    [unique sortUsingComparator:^NSComparisonResult(A2VersionLoaderInfo *a, A2VersionLoaderInfo *b) {
        NSInteger pa = A2LoaderPriority(a.kind);
        NSInteger pb = A2LoaderPriority(b.kind);
        if (pa != pb) return pa < pb ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return unique;
}

#pragma mark - A2VersionInfo

@interface A2VersionInfo ()

@property (nonatomic, copy) NSString *minecraftVersion;
@property (nonatomic, copy) NSArray<A2VersionLoaderInfo *> *loaderInfos;

@end

@implementation A2VersionInfo

- (instancetype)initWithMinecraftVersion:(NSString *)minecraftVersion
                            loaderInfos:(NSArray<A2VersionLoaderInfo *> *)loaderInfos {
    self = [super init];
    if (!self) return nil;
    _minecraftVersion = [minecraftVersion copy] ?: @"";
    _loaderInfos = [loaderInfos copy] ?: @[];
    return self;
}

+ (instancetype)infoFromJSONDictionary:(NSDictionary *)json versionID:(NSString *)versionID {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSString *fallback = versionID.length > 0 ? versionID : A2NonEmptyString(json[@"id"]);
    if (!fallback) return nil;
    NSString *mc = A2ExtractMinecraftVersion(json, fallback);
    if (mc.length == 0) return nil;
    NSArray<A2VersionLoaderInfo *> *loaders = A2DetectModLoaders(json);
    return [[self alloc] initWithMinecraftVersion:mc loaderInfos:loaders];
}

- (NSString *)infoString {
    NSString *loaders = [self joinedLoaderStringWithSeparator:@" - "];
    if (self.minecraftVersion.length == 0) return loaders;
    if (loaders.length == 0) return self.minecraftVersion;
    return [NSString stringWithFormat:@"%@, %@", self.minecraftVersion, loaders];
}

- (NSString *)loaderDisplayString {
    NSString *s = [self joinedLoaderStringWithSeparator:@" "];
    return s.length > 0 ? s : nil;
}

/// 加载器列表拼串（sep 衔接名与版本）。两个展示串共用，避免各写一遍循环。
- (NSString *)joinedLoaderStringWithSeparator:(NSString *)sep {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (A2VersionLoaderInfo *info in self.loaderInfos) {
        NSString *name = A2VersionLoaderDisplayName(info.kind);
        [parts addObject:(info.version.length > 0
                          ? [NSString stringWithFormat:@"%@%@%@", name, sep, info.version]
                          : name)];
    }
    return [parts componentsJoinedByString:@", "];
}

- (id)copyWithZone:(NSZone *)zone {
    A2VersionInfo *c = [[A2VersionInfo allocWithZone:zone] initWithMinecraftVersion:self.minecraftVersion
                                                                       loaderInfos:self.loaderInfos];
    return c;
}

@end

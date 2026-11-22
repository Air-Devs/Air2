//
//  A2MirrorResolver.m
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

#import "A2MirrorResolver.h"
#import "A2Settings.h"

/// MCIM 镜像根（与 ZL2 用同一个）
static NSString *const kMCIMMirrorRoot = @"https://mod.mcimirror.top";

/// 可被镜像替换的 CDN 域名
///   https://edge.forgecdn.net   → CurseForge 的文件 CDN
///   https://cdn.modrinth.com    → Modrinth 的文件 CDN
/// 镜像规则。
///
/// 两种替换方式，必须区分 —— 这是之前漏掉的：
///
///  **前缀替换**（MCIM）
///    https://cdn.modrinth.com/xxx → https://mod.mcimirror.top/xxx
///    域名换了，路径不变。
///
///  **路径重映射**（BMCLAPI）
///    BMCLAPI 的路径结构完全不同，不能只换域名：
///      https://piston-meta.mojang.com/mc/game/version_manifest_v2.json
///        → https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json
///      https://launchermeta.mojang.com/mc/game/version_manifest.json
///        → https://bmclapi2.bangbang93.com/mc/game/version_manifest.json
///      https://piston-data.mojang.com/v1/objects/xx/yy
///        → https://bmclapi2.bangbang93.com/v1/objects/xx/yy
///      https://libraries.minecraft.net/org/xx/yy.jar
///        → https://bmclapi2.bangbang93.com/maven/org/xx/yy.jar   ← 注意加了 /maven
///      https://resources.download.minecraft.net/ab/abcdef
///        → https://bmclapi2.bangbang93.com/assets/ab/abcdef       ← 注意加了 /assets
///
/// 这几条规则来自 BMCLAPI 的官方文档与实际抓包验证。
/// 写错任何一条都会导致文件 404 或下到错的内容。
typedef struct {
    const char *prefix;       ///< 原始 URL 前缀
    const char *replacement;  ///< 替换后的前缀
} A2MirrorRule;

static const A2MirrorRule kMirrorRules[] = {
    // ---- MCIM：mod 平台 CDN（只换域名）----
    { "https://cdn.modrinth.com",     "https://mod.mcimirror.top" },
    { "https://edge.forgecdn.net",    "https://mod.mcimirror.top" },
    { "https://media.forgecdn.net",   "https://mod.mcimirror.top" },

    // ---- BMCLAPI：游戏本体与 Mojang 资源 ----
    { "https://launchermeta.mojang.com", "https://bmclapi2.bangbang93.com" },
    { "https://piston-meta.mojang.com",  "https://bmclapi2.bangbang93.com" },
    { "https://piston-data.mojang.com",  "https://bmclapi2.bangbang93.com" },
    // 注意这两条路径要加段，不能只换域名
    { "https://libraries.minecraft.net",              "https://bmclapi2.bangbang93.com/maven" },
    { "https://resources.download.minecraft.net",     "https://bmclapi2.bangbang93.com/assets" },

    // ---- BMCLAPI：加载器 ----
    { "https://meta.fabricmc.net",    "https://bmclapi2.bangbang93.com/fabric-meta" },
    { "https://meta.quiltmc.org",     "https://bmclapi2.bangbang93.com/quilt-meta" },
    { "https://maven.minecraftforge.net", "https://bmclapi2.bangbang93.com/maven" },
    { "https://maven.neoforged.net/releases", "https://bmclapi2.bangbang93.com/maven" },
};

static size_t kMirrorRuleCount = sizeof(kMirrorRules) / sizeof(kMirrorRules[0]);

/// 把 URL 按规则表映射成镜像地址。不匹配返回 nil。
static NSString *A2MirrorURLFor(NSString *url) {
    for (size_t i = 0; i < kMirrorRuleCount; i++) {
        NSString *prefix = [NSString stringWithUTF8String:kMirrorRules[i].prefix];
        if (![url hasPrefix:prefix]) continue;

        NSString *rest = [url substringFromIndex:prefix.length];
        NSString *replacement = [NSString stringWithUTF8String:kMirrorRules[i].replacement];
        return [replacement stringByAppendingString:rest];
    }
    return nil;
}

/// 该地址是否可镜像
static BOOL A2IsMirrorable(NSString *url) {
    return A2MirrorURLFor(url) != nil;
}

@implementation A2MirrorResolver

+ (instancetype)shared {
    static A2MirrorResolver *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2MirrorResolver alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // 存储收敛到 A2Settings（同 key，无损迁移）。
    A2Settings *s = A2Settings.shared;
    _priority = (A2MirrorPriority)s.mirrorPriority;
    _enabled = s.mirrorEnabled;
    return self;
}

- (void)setPriority:(A2MirrorPriority)priority {
    _priority = priority;
    A2Settings.shared.mirrorPriority = (NSInteger)priority;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    A2Settings.shared.mirrorEnabled = enabled;
}

#pragma mark - 网络环境检测

/// 是否在中国大陆。
///
/// 判断方式：看时区。这不是 100% 准确（用户可手动改时区），
/// 但比发一次请求去探测 IP 定位快得多，也不会泄露隐私。
/// 判断错了的代价只是「用了较慢的源」，不影响功能。
+ (BOOL)isChinaMainland {
    NSTimeZone *tz = NSTimeZone.localTimeZone;
    NSString *name = tz.name ?: @"";
    if ([name isEqualToString:@"Asia/Shanghai"]) return YES;
    if ([name isEqualToString:@"Asia/Chongqing"]) return YES;
    if ([name isEqualToString:@"Asia/Harbin"]) return YES;
    if ([name isEqualToString:@"Asia/Urumqi"]) return YES;
    if ([name isEqualToString:@"Asia/Kashgar"]) return YES;
    return NO;
}

#pragma mark - 镜像替换

+ (BOOL)isMirrorableURL:(NSString *)url {
    if (url.length == 0) return NO;
    return A2IsMirrorable(url);
}

/// 把 https://edge.forgecdn.net/xxx 替换成 https://mod.mcimirror.top/xxx
+ (nullable NSString *)mirroredURLFor:(NSString *)url {
    return A2MirrorURLFor(url);
}

- (NSArray<NSString *> *)candidateURLsForURL:(NSString *)url {
    if (url.length == 0) return @[];

    // 不启用、不在国内、或该地址不可镜像 → 原样返回
    if (!self.enabled || ![A2MirrorResolver isChinaMainland] ||
        ![A2MirrorResolver isMirrorableURL:url]) {
        return @[url];
    }

    NSString *mirrored = [A2MirrorResolver mirroredURLFor:url];
    if (mirrored.length == 0 || [mirrored isEqualToString:url]) {
        return @[url];
    }

    // 按偏好排序 —— 下载引擎会依次尝试，天然支持失败回退
    if (self.priority == A2MirrorPriorityMirrorFirst) {
        return @[mirrored, url];
    }
    return @[url, mirrored];
}

- (NSArray<NSString *> *)candidateURLsForURLs:(NSArray<NSString *> *)urls {
    if (urls.count == 0) return @[];

    // 如果整个列表都不可镜像，直接返回
    BOOL anyMirrorable = NO;
    for (NSString *u in urls) {
        if ([A2MirrorResolver isMirrorableURL:u]) { anyMirrorable = YES; break; }
    }
    if (!anyMirrorable || !self.enabled || ![A2MirrorResolver isChinaMainland]) {
        return urls;
    }

    // 把所有可镜像的地址生成镜像版本，整体按偏好插到前面或后面
    NSMutableArray<NSString *> *mirrored = [NSMutableArray array];
    for (NSString *u in urls) {
        NSString *m = [A2MirrorResolver mirroredURLFor:u];
        if (m.length > 0) [mirrored addObject:m];
    }

    if (mirrored.count == 0) return urls;

    if (self.priority == A2MirrorPriorityMirrorFirst) {
        NSMutableArray *out = [mirrored mutableCopy];
        [out addObjectsFromArray:urls];
        return out;
    }
    NSMutableArray *out = [urls mutableCopy];
    [out addObjectsFromArray:mirrored];
    return out;
}

@end

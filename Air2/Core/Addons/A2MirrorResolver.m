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

/// BMCLAPI 镜像根。
///
/// ★第三方公益镜像★（作者 bangbang93，与 Mojang / 本仓均无隶属关系）。
/// 可用性与合规风险见 `docs/DECISIONS.md` 的镜像链条目：不提供 SLA，
/// 一旦不可用必须能一键关掉（设置页「使用国内镜像加速」开关）。
static NSString *const kBMCLAPIMirrorRoot = @"https://bmclapi2.bangbang93.com";

/// MCIM 镜像根（同为第三方公益镜像，与 ZL2 用同一个）
static NSString *const kMCIMMirrorRoot = @"https://mod.mcimirror.top";

/// 官方前缀 → 镜像前缀映射表（有序：命中即返回）。
///
/// 两组镜像各管一摊：
///   · Modrinth / CurseForge 的文件 CDN → MCIM（★只换主机、不加平台前缀★，
///     与既有行为逐字节一致）；
///   · Mojang 原版分发 → BMCLAPI（路径对应关系照老线 Air 1 `PLMirrorCenter`
///     的既有约定：清单 / 版本 JSON 走镜像根、依赖库走 `/maven`、资源对象走 `/assets`。
///     只对齐「行为与参数约定」，实现是本仓自己的）。
///
/// 为什么依赖库与资源对象也要走镜像：这两类是安装阶段文件数最多的部分
/// （资源上万、库数百），官方域名在国内的单连接吞吐才是主要瓶颈 ——
/// 只镜像版本清单，对总耗时的改善可以忽略。
static NSArray<NSArray<NSString *> *> *MirrorPrefixPairs(void) {
    static NSArray<NSArray<NSString *> *> *pairs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pairs = @[
            // --- Modrinth / CurseForge 文件 CDN → MCIM ---
            @[@"https://edge.forgecdn.net", kMCIMMirrorRoot],
            @[@"https://cdn.modrinth.com", kMCIMMirrorRoot],
            // CurseForge 有时用 media 域名分发
            @[@"https://media.forgecdn.net", kMCIMMirrorRoot],

            // --- Mojang 版本清单 / 版本 JSON → BMCLAPI 根（路径原样保留）---
            @[@"https://piston-meta.mojang.com", kBMCLAPIMirrorRoot],
            @[@"https://piston-data.mojang.com", kBMCLAPIMirrorRoot],
            @[@"https://launchermeta.mojang.com", kBMCLAPIMirrorRoot],
            @[@"https://launcher.mojang.com", kBMCLAPIMirrorRoot],

            // --- Mojang 依赖库 → /maven ---
            @[@"https://libraries.minecraft.net",
              [kBMCLAPIMirrorRoot stringByAppendingString:@"/maven"]],

            // --- Mojang 资源对象 → /assets ---
            @[@"https://resources.download.minecraft.net",
              [kBMCLAPIMirrorRoot stringByAppendingString:@"/assets"]],
            @[@"http://resources.download.minecraft.net",
              [kBMCLAPIMirrorRoot stringByAppendingString:@"/assets"]],
        ];
    });
    return pairs;
}

/// 该地址对应的镜像前缀；不可镜像返回 nil。
///
/// 要求前缀后紧跟 `/`：否则 `https://cdn.modrinth.com.example/…` 这类
/// 「同前缀、异主机」的地址会被误判成可镜像，进而重写成镜像站的路径。
static NSString *MirrorPrefixForURL(NSString *url) {
    if (url.length == 0) return nil;
    for (NSArray<NSString *> *pair in MirrorPrefixPairs()) {
        NSString *official = pair.firstObject;
        if ([url hasPrefix:[official stringByAppendingString:@"/"]]) {
            return pair.lastObject;
        }
    }
    return nil;
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
/// ★判据行会把依据（时区名）与结论一起打出来，便于真机对账★。
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
    return MirrorPrefixForURL(url) != nil;
}

/// 把 https://edge.forgecdn.net/xxx 替换成 https://mod.mcimirror.top/xxx；
/// 把 https://libraries.minecraft.net/a/b.jar 替换成
/// https://bmclapi2.bangbang93.com/maven/a/b.jar（其余域名同理）。
+ (nullable NSString *)mirroredURLFor:(NSString *)url {
    NSString *mirrorPrefix = MirrorPrefixForURL(url);
    if (mirrorPrefix.length == 0) return nil;

    NSString *official = nil;
    for (NSArray<NSString *> *pair in MirrorPrefixPairs()) {
        if ([url hasPrefix:[pair.firstObject stringByAppendingString:@"/"]]) {
            official = pair.firstObject;
            break;
        }
    }
    if (official.length == 0) return nil;

    return [mirrorPrefix stringByAppendingString:[url substringFromIndex:official.length]];
}

/// 这个地址现在指向镜像还是官方（★判据行用★）。
/// 镜像再细分成 BMCLAPI / MCIM：两者的第三方来源与风险面不同，日志里要能分清。
+ (NSString *)sourceLabelForURL:(NSString *)url {
    if (![url isKindOfClass:NSString.class] || url.length == 0) return @"(空)";
    if ([url hasPrefix:kBMCLAPIMirrorRoot]) return @"mirror(bmclapi)";
    if ([url hasPrefix:kMCIMMirrorRoot]) return @"mirror(mcim)";
    return @"official";
}

/// 候选列表的纯函数实现：无单例、不读偏好 ⇒ 单测可把四种组合都真跑一遍。
+ (NSArray<NSString *> *)candidateURLsForURL:(NSString *)url
                                     enabled:(BOOL)enabled
                                    priority:(A2MirrorPriority)priority
                               chinaMainland:(BOOL)mainland {
    if (url.length == 0) return @[];

    // 不启用、不在国内、或该地址不可镜像 → 原样返回（官方单源）
    if (!enabled || !mainland) return @[url];
    if (![self isMirrorableURL:url]) return @[url];

    NSString *mirrored = [self mirroredURLFor:url];
    if (mirrored.length == 0 || [mirrored isEqualToString:url]) return @[url];

    // 按偏好排序 —— 下载引擎会依次尝试，天然支持失败回退
    if (priority == A2MirrorPriorityMirrorFirst) {
        return @[mirrored, url];
    }
    return @[url, mirrored];
}

- (NSArray<NSString *> *)candidateURLsForURL:(NSString *)url {
    return [A2MirrorResolver candidateURLsForURL:url
                                         enabled:self.enabled
                                        priority:self.priority
                                   chinaMainland:[A2MirrorResolver isChinaMainland]];
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

#pragma mark - 判据行

/// 一行判据：镜像开关 + 判定依据（时区名）+ 生效结论 + 镜像出处。
///
/// ★只返回字符串、不自己写日志★ —— 由调用方（安装器 / 下载引擎）交给 A2Log。
/// 这样本类不依赖日志门面，单测在没有日志环境时也能直接跑。
- (NSString *)auditSummary {
    BOOL mainland = [A2MirrorResolver isChinaMainland];
    NSString *tz = NSTimeZone.localTimeZone.name ?: @"(未知)";
    BOOL mirrorFirst = (self.priority == A2MirrorPriorityMirrorFirst);

    NSString *verdict = nil;
    if (!self.enabled) {
        verdict = @"off(开关关闭⇒官方单源)";
    } else if (!mainland) {
        verdict = @"off(非大陆时区⇒官方单源)";
    } else {
        verdict = mirrorFirst ? @"mirror-first(镜像优先⇒官方兜底)"
                              : @"official-first(官方优先⇒镜像兜底)";
    }

    return [NSString stringWithFormat:
            @"enabled=%d priority=%@ mainland=%d tz=%@ verdict=%@ "
            @"bmclapi=%@(第三方) mcim=%@(第三方)",
            self.enabled ? 1 : 0, mirrorFirst ? @"mirror-first" : @"official-first",
            mainland ? 1 : 0, tz, verdict, kBMCLAPIMirrorRoot, kMCIMMirrorRoot];
}

@end

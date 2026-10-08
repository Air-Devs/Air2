//
//  A2MirrorResolver.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#import "A2MirrorResolver.h"
#import "A2Settings.h"

/// MCIM 镜像根（与 ZL2 用同一个）
static NSString *const kMCIMMirrorRoot = @"https://mod.mcimirror.top";

/// 可被镜像替换的 CDN 域名
///   https://edge.forgecdn.net   → CurseForge 的文件 CDN
///   https://cdn.modrinth.com    → Modrinth 的文件 CDN
static NSArray<NSString *> *MirrorableHolders(void) {
    static NSArray<NSString *> *holders = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        holders = @[
            @"https://edge.forgecdn.net",
            @"https://cdn.modrinth.com",
            // CurseForge 有时用 media 域名分发
            @"https://media.forgecdn.net",
        ];
    });
    return holders;
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
    for (NSString *holder in MirrorableHolders()) {
        if ([url hasPrefix:holder]) return YES;
    }
    return NO;
}

/// 把 https://edge.forgecdn.net/xxx 替换成 https://mod.mcimirror.top/xxx
+ (nullable NSString *)mirroredURLFor:(NSString *)url {
    for (NSString *holder in MirrorableHolders()) {
        if ([url hasPrefix:holder]) {
            return [url stringByReplacingCharactersInRange:
                    NSMakeRange(0, holder.length) withString:kMCIMMirrorRoot];
        }
    }
    return nil;
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

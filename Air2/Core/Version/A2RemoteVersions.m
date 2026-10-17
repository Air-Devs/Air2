//
//  A2RemoteVersions.m
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
//  见头文件：与安装器同清单地址；坏条目跳过不整单失败。
//

#import "A2RemoteVersions.h"
#import "A2MirrorResolver.h"
#import "A2Log.h"

/// 与 A2GameInstaller.m 的 kVersionManifestURL 同值，改地址两处一起改。
static NSString *const kVersionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

@implementation A2RemoteVersion

- (instancetype)initWithVersionID:(NSString *)versionID
                             type:(NSString *)type
                      releaseTime:(NSDate *)releaseTime {
    self = [super init];
    if (!self) return nil;
    _versionID = [versionID copy];
    _type = [type copy];
    _releaseTime = releaseTime;
    return self;
}

@end

@implementation A2RemoteVersions

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：纯工具类不实例化。
    // 保留实现体满足声明/实现一致性检查；正常代码走不到这里。
    return nil;
}

+ (void)fetchVersionsWithCompletion:(void (^)(NSArray<A2RemoteVersion *> *, NSError *))completion {
    void (^done)(NSArray<A2RemoteVersion *> *, NSError *) = ^(NSArray<A2RemoteVersion *> *v, NSError *e) {
        if (e) [A2Log log:@"remote-versions: 拉取失败：%@", e.localizedDescription];
        else [A2Log log:@"remote-versions: 拉取到 %lu 个版本", (unsigned long)v.count];
        if ([NSThread isMainThread]) completion(v, e);
        else dispatch_async(dispatch_get_main_queue(), ^{ completion(v, e); });
    };
    [A2Log log:@"remote-versions: 拉取版本清单"];

    // 候选源与安装器同一套：镜像优先 → 官方兜底（关掉镜像或不在大陆时只剩官方）。
    NSArray<NSString *> *cands = [[A2MirrorResolver shared] candidateURLsForURL:kVersionManifestURL];
    if (cands.count == 0) cands = @[kVersionManifestURL];

    // 一次拉取复用同一个解析器：清单近千条，避免逐条新建。
    [self fetchVersionsFromCandidates:cands
                                index:0
                            lastError:nil
                                  iso:[NSISO8601DateFormatter new]
                                 done:done];
}

/// 逐候选源尝试拉清单：任一源失败（网络错 / 非 2xx / 不是 JSON / 缺 versions）就换下一个，
/// 全部耗尽才回调失败 —— 与安装期的版本清单同一条链、同一套判据。
+ (void)fetchVersionsFromCandidates:(NSArray<NSString *> *)cands
                              index:(NSUInteger)index
                          lastError:(NSError *)lastError
                                iso:(NSISO8601DateFormatter *)iso
                               done:(void (^)(NSArray<A2RemoteVersion *> *, NSError *))done {
    if (index >= cands.count) {
        done(nil, lastError ?: [self err:@"版本清单不可用：镜像与官方源均失败"]);
        return;
    }

    NSString *urlString = cands[index];
    NSString *source = [A2MirrorResolver sourceLabelForURL:urlString];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [A2Log log:@"[A2-MIRROR] stage=version-list 失败切源 source=%@ 原因=清单地址非法 url=%@",
              source, urlString];
        [self fetchVersionsFromCandidates:cands index:index + 1
                                lastError:[self err:@"清单地址非法"] iso:iso done:done];
        return;
    }

    [A2Log log:@"[A2-MIRROR] stage=version-list 候选=%lu/%lu source=%@ url=%@",
          (unsigned long)(index + 1), (unsigned long)cands.count, source, urlString];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    [req setValue:@"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)" forHTTPHeaderField:@"User-Agent"];

    [[NSURLSession.sharedSession dataTaskWithRequest:req
                                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSError *attemptError = error;
        NSArray<A2RemoteVersion *> *parsed = nil;

        if (!attemptError) {
            NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)resp).statusCode : 200;
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                                 options:0 error:&jsonErr];
            NSArray *raw = [json isKindOfClass:NSDictionary.class] ? json[@"versions"] : nil;
            if (code < 200 || code >= 300) {
                attemptError = [self err:[NSString stringWithFormat:@"服务返回 HTTP %ld（源 %@）",
                                          (long)code, source]];
            } else if (![json isKindOfClass:NSDictionary.class]) {
                attemptError = [self err:[NSString stringWithFormat:@"清单不是合法 JSON（源 %@）", source]];
            } else if (![raw isKindOfClass:NSArray.class]) {
                attemptError = [self err:[NSString stringWithFormat:@"清单缺 versions（源 %@）", source]];
            } else {
                NSMutableArray<A2RemoteVersion *> *out = [NSMutableArray array];
                for (NSDictionary *d in raw) {
                    if (![d isKindOfClass:NSDictionary.class]) continue;
                    NSString *vid = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : nil;
                    NSString *type = [d[@"type"] isKindOfClass:NSString.class] ? d[@"type"] : nil;
                    if (!vid.length || !type.length) continue;
                    // releaseTime 形如 2024-11-13T10:12:14+00:00。
                    // 解析失败只置 nil，不因此丢掉整个版本条目。
                    NSString *rt = [d[@"releaseTime"] isKindOfClass:NSString.class] ? d[@"releaseTime"] : nil;
                    NSDate *releaseTime = rt.length ? [iso dateFromString:rt] : nil;
                    [out addObject:[[A2RemoteVersion alloc] initWithVersionID:vid
                                                                         type:type
                                                                  releaseTime:releaseTime]];
                }
                parsed = [out copy];
            }
        }

        if (parsed) {
            [A2Log log:@"[A2-MIRROR] stage=version-list 采用 source=%@ url=%@", source, urlString];
            done(parsed, nil);
            return;
        }

        [A2Log log:@"[A2-MIRROR] stage=version-list 失败切源 source=%@ 原因=%@ url=%@",
              source, attemptError.localizedDescription ?: @"(未知)", urlString];
        [self fetchVersionsFromCandidates:cands index:index + 1
                                lastError:attemptError iso:iso done:done];
    }] resume];
}

+ (NSError *)err:(NSString *)message {
    return [NSError errorWithDomain:@"A2RemoteVersions" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end

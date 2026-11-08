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
#import "A2Log.h"

/// 与 A2GameInstaller.m 的 kVersionManifestURL 同值，改地址两处一起改。
static NSString *const kVersionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
/// ★421 回落用的镜像清单（内部状态，用完即清）★
static NSString *sA2ManifestURLOverride = nil;

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
    NSString *urlString = sA2ManifestURLOverride ?: kVersionManifestURL;
    if (sA2ManifestURLOverride != nil) {
        [A2Log log:@"remote-versions: 本次使用镜像清单 %@", urlString];
        sA2ManifestURLOverride = nil;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        done(nil, [self err:@"清单地址非法"]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    [req setValue:@"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)" forHTTPHeaderField:@"User-Agent"];
    // 一次拉取复用同一个解析器：清单近千条，避免逐条新建。
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { done(nil, error); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            // ★421 等异常 ⇒ 回落到 BMCLAPI 镜像再试一次★
            if (http.statusCode == 421 || http.statusCode == 403 || http.statusCode >= 500) {
                NSString *mirror = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
                [A2Log log:@"remote-versions: HTTP %ld ⇒ 回落镜像 %@", (long)http.statusCode, mirror];
                sA2ManifestURLOverride = mirror;   // 下一次进入本方法时改用它
                [self fetchVersionsWithCompletion:completion];
                return;
            }
            done(nil, [self err:[NSString stringWithFormat:@"服务返回 HTTP %ld",
                                 (long)http.statusCode]]);
            return;
        }
        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (![json isKindOfClass:NSDictionary.class]) {
            done(nil, [self err:@"清单不是合法 JSON"]);
            return;
        }
        NSArray *raw = json[@"versions"];
        if (![raw isKindOfClass:NSArray.class]) {
            done(nil, [self err:@"清单缺 versions"]);
            return;
        }
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
        done([out copy], nil);
    }] resume];
}

+ (NSError *)err:(NSString *)message {
    return [NSError errorWithDomain:@"A2RemoteVersions" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end

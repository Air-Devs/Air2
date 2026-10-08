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

/// 与 A2GameInstaller.m 的 kVersionManifestURL 同值，改地址两处一起改。
static NSString *const kVersionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

@implementation A2RemoteVersion

- (instancetype)initWithVersionID:(NSString *)versionID type:(NSString *)type {
    self = [super init];
    if (!self) return nil;
    _versionID = [versionID copy];
    _type = [type copy];
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
        if ([NSThread isMainThread]) completion(v, e);
        else dispatch_async(dispatch_get_main_queue(), ^{ completion(v, e); });
    };
    NSURL *url = [NSURL URLWithString:kVersionManifestURL];
    if (!url) {
        done(nil, [self err:@"清单地址非法"]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    [req setValue:@"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { done(nil, error); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode < 200 || http.statusCode >= 300) {
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
            [out addObject:[[A2RemoteVersion alloc] initWithVersionID:vid type:type]];
        }
        done([out copy], nil);
    }] resume];
}

+ (NSError *)err:(NSString *)message {
    return [NSError errorWithDomain:@"A2RemoteVersions" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end

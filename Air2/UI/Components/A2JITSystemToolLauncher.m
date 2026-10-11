//
//  A2JITSystemToolLauncher.m
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
//  [JIT-IMPL-2] UIApplication 落地实现。★只做两件事★：探测能否拉起、拉起。
//  拉起后的「等多久 / 怎么判成功」全部在 Player（A2JITExternalToolProvider）。
//

#import "A2JITSystemToolLauncher.h"
#import "A2JITExternalToolProvider.h"

#import <UIKit/UIKit.h>

@implementation A2JITSystemToolLauncher

- (BOOL)canOpenToolURL:(NSURL *)url {
    if (url == nil) {
        return NO;
    }
    BOOL can = [UIApplication.sharedApplication canOpenURL:url];
    if (!can) {
        // 未安装，或 scheme 未登记在 LSApplicationQueriesSchemes（后者最容易被漏）。
        NSLog(@"[A2JIT] launcher: canOpenURL(%@) = NO（未安装，或 scheme 未登记在白名单）",
              url.absoluteString);
    }
    return can;
}

- (BOOL)openToolURL:(NSURL *)url {
    if (url == nil) {
        return NO;
    }
    // iOS 10+ 统一走 openURL:options:completionHandler:（openURL: 已废弃）。
    // ★不能拿异步完成当同步返回值★：这里返回「是否已发出请求」，
    // 真正的成败由 Player 侧的有界等待 + 判据复验决定。
    if (![UIApplication.sharedApplication canOpenURL:url]) {
        NSLog(@"[A2JIT] launcher: 不拉起 %@（canOpenURL = NO）", url.absoluteString);
        return NO;
    }
    NSLog(@"[A2JIT] launcher: 拉起 %@", url.absoluteString);
    [UIApplication.sharedApplication openURL:url
                                     options:@{}
                           completionHandler:^(BOOL success) {
        NSLog(@"[A2JIT] launcher: 拉起 %@ 完成 success=%d", url.absoluteString, (int)success);
    }];
    return YES;
}

@end

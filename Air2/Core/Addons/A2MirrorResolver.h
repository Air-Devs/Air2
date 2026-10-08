//
//  A2MirrorResolver.h
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
//  下载地址的镜像替换（对应 ZL2 的 MCIMMirror）。
//
//  为什么需要：
//    CurseForge 与 Modrinth 的 CDN 在国内访问很慢甚至不通。
//    MCIM（mod.mcimirror.top）把这两个 CDN 做了反向代理，
//    把域名替换掉即可走国内节点。
//
//  策略（与 ZL2 一致）：
//    · 只在检测到中国大陆网络时启用 —— 海外用镜像反而更慢
//    · 用户可选「官方优先」或「镜像优先」
//    · 返回的是候选列表，按优先级排列，
//      下载引擎本来就是多候选依次尝试，天然兼容
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 镜像优先级
typedef NS_ENUM(NSInteger, A2MirrorPriority) {
    A2MirrorPriorityOfficialFirst = 0,   ///< 官方源优先，失败再试镜像
    A2MirrorPriorityMirrorFirst,         ///< 镜像优先，失败再回官方
};

@interface A2MirrorResolver : NSObject

+ (instancetype)shared;

/// 优先级设置
@property (nonatomic, assign) A2MirrorPriority priority;

/// 是否启用镜像（默认自动检测中国大陆网络）
@property (nonatomic, assign) BOOL enabled;

/// 把单个下载地址展开成候选列表（可能含镜像地址）。
///
/// 不可镜像的地址（如 Mojang 官方 CDN）原样返回。
- (NSArray<NSString *> *)candidateURLsForURL:(NSString *)url;

/// 批量展开
- (NSArray<NSString *> *)candidateURLsForURLs:(NSArray<NSString *> *)urls;

/// 该地址是否可被镜像
+ (BOOL)isMirrorableURL:(NSString *)url;

@end

NS_ASSUME_NONNULL_END

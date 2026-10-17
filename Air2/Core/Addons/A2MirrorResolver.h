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
//  下载地址的镜像替换（对应 ZL2 的 MCIMMirror + 老线 Air 1 的 PLMirrorCenter）。
//
//  为什么需要：
//    国内直连 Mojang（版本清单 / 依赖库 / 资源对象）与
//    CurseForge / Modrinth 的 CDN 都很慢甚至不通。
//    这里把官方域名替换成国内镜像域名，把下载流量导到镜像节点。
//
//  镜像链（两条，各管一摊）：
//    · Mojang 原版分发 → BMCLAPI（`bmclapi2.bangbang93.com`，★第三方公益镜像★）
//        piston-meta / piston-data / launchermeta / launcher.mojang.com → 镜像根
//        libraries.minecraft.net        → 镜像根 + /maven
//        resources.download.minecraft.net → 镜像根 + /assets
//    · Modrinth / CurseForge 文件 CDN → MCIM（`mod.mcimirror.top`，★第三方★）
//        edge.forgecdn.net / cdn.modrinth.com / media.forgecdn.net → 镜像根
//
//  策略（与 ZL2 / 老线一致）：
//    · 只在检测到中国大陆网络时启用 —— 海外用镜像反而更慢
//    · 用户可选「官方优先」或「镜像优先」，并在设置里★一键关掉★
//    · 返回的是候选列表，按优先级排列，
//      下载引擎本来就是多候选依次尝试，天然兼容「失败自动切源」
//
//  ★风险★：两个镜像都是第三方公益服务（非 Mojang / 非本仓），
//    不承诺可用性，也不对本仓的下载结果负责；出问题时的逃逸路径是
//    设置页的「使用国内镜像加速」开关（关掉即回官方单源）。
//    详见 docs/DECISIONS.md 的镜像链条目。
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
/// 不可镜像的地址（如已指向镜像站的地址、或本仓未登记的域名）原样返回。
- (NSArray<NSString *> *)candidateURLsForURL:(NSString *)url;

/// 批量展开
- (NSArray<NSString *> *)candidateURLsForURLs:(NSArray<NSString *> *)urls;

/// 该地址是否可被镜像
+ (BOOL)isMirrorableURL:(NSString *)url;

#pragma mark - 纯函数缝（供单测与判据使用）

/// 该地址对应的镜像地址；不可镜像返回 nil。
+ (nullable NSString *)mirroredURLFor:(NSString *)url;

/// 是否在中国大陆（依据 = 系统时区，见实现注释）。
+ (BOOL)isChinaMainland;

/// 这个地址现在指向镜像还是官方：`mirror(bmclapi)` / `mirror(mcim)` / `official`。
+ (NSString *)sourceLabelForURL:(NSString *)url;

/// 候选列表的纯函数实现：把「开关 / 优先级 / 是否大陆」当参数传进来，
/// 不读单例状态 ⇒ 单测可把四种组合（开+镜像优先 / 开+官方优先 /
/// 关 / 非大陆）逐条真跑。
+ (NSArray<NSString *> *)candidateURLsForURL:(NSString *)url
                                     enabled:(BOOL)enabled
                                    priority:(A2MirrorPriority)priority
                               chinaMainland:(BOOL)mainland;

/// 一行判据（镜像开关 + 判定依据 + 生效结论 + 镜像出处）。
/// 只返回字符串、不写日志 —— 调用方自行交给 A2Log。
- (NSString *)auditSummary;

@end

NS_ASSUME_NONNULL_END

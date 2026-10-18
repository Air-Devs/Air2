//
//  A2LegacyProfile.h
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
//  远古版本画像 —— 「这个版本属于哪一代、跑它需要什么」的**唯一判定处**。
//
//  为什么单独一个类，而不把这些 if 摊在启动链里：
//    1.0–1.6 与 1.7+ 的差异不是一处，而是五处（资源映射 / LWJGL2 API / Java 档位 /
//    渲染器语义 / JVM 参数预算）。摊在 A2LaunchSession 里就是五个互不相干的 if，
//    下次加一条（比如 1.7–1.12）没人知道该改哪。收敛成一个纯判定对象后，
//    启动链只问一次：「这个版本是 classic 吗、它接受我选的 JRE 吗」。
//
//  ★判定依据全部来自版本 JSON 本身★（不猜、不看 UI）：
//    · `type`：old_alpha / old_beta ⇒ classic（Mojang 对 Alpha/Beta 的原始分类）；
//    · `id` 的数值形态：1.x 且 minor ≤ 6 ⇒ classic；1.x 且 minor ≤ 12 ⇒ 需要 LWJGL2 API；
//      rd- / c0. / inf- / indev- / in- / a1. / b1. 前缀 ⇒ classic（Mojang 远古快照的 id 形态）；
//    · `assets` / `assetIndex.id`：pre-1.6 ⇒ 需要 map_to_resources；legacy ⇒ 需要 virtual。
//
//  ★谁调它★：
//    · Air2/Player/A2LaunchSession.m —— 启动前闸门（JRE 档位 / 渲染器语义 / LWJGL2 兼容层）
//      与 VM 参数追加（`jvmCompatOptions`）；
//    · Air2/Core/Version/A2GameInstaller.m —— 装库时跳过 `org.lwjgl.*` 的桌面/安卓原生 jar
//      （它们在 iOS 上无用，且会把 classpath 上的 org.lwjgl.* 抢先占掉）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 版本世代。只分两档 —— 判定「要不要走远古兼容轨」用不到更细的粒度。
typedef NS_ENUM(NSInteger, A2LegacyGeneration) {
    A2LegacyGenerationModern = 0,  ///< 1.7 及以后（含年份制 26.x）
    A2LegacyGenerationClassic,     ///< 1.0–1.6.4 以及 Alpha/Beta/Infdev/Indev
};

@interface A2LegacyProfile : NSObject

/// 从磁盘版本目录读取（内部走 A2LaunchPlan 的 inheritsFrom 合并，不另写一份合并逻辑）。
+ (nullable instancetype)profileForVersionDirectory:(NSString *)versionDirectory
                                          versionID:(NSString *)versionID;

/// 从已合并的版本 JSON 读取（安装器手里只有 json 时用这一条）。
+ (instancetype)profileForVersionJSON:(NSDictionary *)mergedJSON
                            versionID:(NSString *)versionID;

@property (nonatomic, assign, readonly) A2LegacyGeneration generation;
/// generation == Classic 的便捷读法。
@property (nonatomic, assign, readonly) BOOL isClassicGeneration;

@property (nonatomic, copy, readonly) NSString *versionID;
@property (nonatomic, copy, readonly) NSString *mainClass;

/// assets 索引名（`pre-1.6` / `legacy` / `5` …；取不到为 nil）。
@property (nonatomic, copy, readonly, nullable) NSString *assetsIndexID;

/// 该版本的客户端需要 LWJGL 2 的 API 面（org.lwjgl.opengl.Display / input / util.glu）。
/// 1.13 起才改用 LWJGL 3，故 1.12.2 及更早恒为 YES。
@property (nonatomic, assign, readonly) BOOL requiresLWJGL2Compat;

/// 允许的 Java 大版本上限；0 表示不限。1.12.2 及更早只能 Java 8（LWJGL2 与字节码档位都按 8 编译）。
@property (nonatomic, assign, readonly) NSInteger maxJavaMajor;

/// 建议堆上限（MB）；0 表示不额外限制。Classic 世代取 192（见实现里的理由）。
@property (nonatomic, assign, readonly) NSInteger heapCapMB;

/// 所选 JRE 大版本是否可用于本版本。major <= 0（取不到档位）按「不判定」放行。
- (BOOL)acceptsJavaMajorVersion:(NSInteger)major;

/// 该渲染器能否跑 1.0–1.6 的固定管线（GL 1.x immediate mode）。
/// gl4es 家族（含 NG-GL4ES）可以；Metal 直通后端 / MobileGL / ANGLE / MoltenVK 不行。
+ (BOOL)rendererSupportsFixedPipeline:(NSString *)rendererIdentifier;

/// 远古轨道要追加的 VM 参数（Xms / CodeCache 预算）。非 classic 返回空数组。
- (NSArray<NSString *> *)jvmCompatOptions;

/// 一行可 grep 的判据行内容（启动链直接打进日志，便于真机复盘）。
- (NSString *)diagnosticLine;

@end

NS_ASSUME_NONNULL_END

//
//  A2LaunchMemory.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Utils —— ★启动内存预算★（设备可用内存 → 安全堆顶 → `-Xmx`；档位 → 参数集策略）。
//
//  为什么放在 Utils（叶子层）：
//    · 全层可依赖它，它不反向依赖任何业务层 ⇒ Core/Player/UI 都能用同一份策略，不各写一遍；
//    · 只 import Foundation ⇒ 能被 tests/Plan 的 clang 直编直跑（真实现，不是文本镜像）。
//
//  ★本类只做「纯计算与策略」★，不碰系统接口也不碰 UI：
//    · 「进程可安全申请内存」的**采集**在 Bridge（`A2LaunchRunner.currentMemoryProbe`）——
//      那里才是启动链唯一与系统接口相邻的层（同 `currentRuntimeFacts` 的落点）；
//    · 采集结果封成下面这个值对象传进来，于是本类可被单测逐例断言。
//
//  ★取值口径的出处★（★只对齐老线的行为/参数约定，不抄它的实现★）：
//    ceiling  = os_proc_available_memory() − 原生预留（老线 `Natives/LauncherPreferences.m`
//               ame173：实测 iPhone X available=1807MB ⇒ 607MB 安全顶，判据行 `[Task173] safe heap ceiling=`）；
//    fallback = 物理内存 × 0.6，且不低于 1024MB（老线同函数的 fallback 分支）。
//    ★老线在权威路径上不留下限（「堆小只是慢，超顶是死」）；本类对两条路径都留 256MB 下限，
//      因为 A2LaunchPlan 拿到的 memoryMB 直接进 `-Xmx`，负数/0 会让 JVM 直接起不来。★
//
//  ★判据行★（默认可见，由 Player 打）：`[MEM] ceiling=…MB -> -Xmx…MB (source=<api|default>) …`。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 档位

/// 内存档位（设置里暴露；存 NSInteger，读点见 A2Settings.memoryMode）。
typedef NS_ENUM(NSInteger, A2LaunchMemoryMode) {
    /// 自动：按设备可用内存动态定 `-Xmx`（默认）。
    A2LaunchMemoryModeAuto = 0,
    /// 手动：用设置里的固定 MB；★仍受安全堆顶钳制★（超顶 = 被 iOS jetsam 直接杀）。
    A2LaunchMemoryModeManual = 1,
};

#pragma mark - 探测值对象

/// 一次内存探测的读数（★纯值对象，不可变★）。
/// `availableMB` = 0 表示这次没拿到权威读数（老系统/模拟器），此时走 default 回退。
@interface A2MemoryProbe : NSObject

/// 进程可安全申请的内存（MB）；0 = 没拿到（见 `source`）。
@property (nonatomic, assign, readonly) NSInteger availableMB;
/// 物理内存（MB）；0 = 没拿到。
@property (nonatomic, assign, readonly) NSInteger physicalMB;

+ (instancetype)probeWithAvailableMB:(NSInteger)availableMB physicalMB:(NSInteger)physicalMB;

/// 这次安全顶的**来源**：`api` = 有权威读数；`default` = 走了回退（物理内存比例 / 默认值）。
- (NSString *)source;

@end

#pragma mark - 预算常量（★每个值都能说出「为什么是这个值」★）

/// 堆下限（MB）。出处：`A2SettingsMinRAMMB`（=256，对应 ZL2 ramAllocation min）——
/// 再低 JVM 起不来，且任何设备都拿得出 256MB。
FOUNDATION_EXPORT const NSInteger A2LaunchMemoryMinXmxMB;
/// 堆上限保护（MB）。★未真机标定★：iOS 单进程吃不到更大的堆；arm64 堆 < 32G 才保持压缩指针
/// （`-XX:+UseCompressedOops` 生效区）。取 4096 作保守天花板，防止配置/读数异常造出离谱 `-Xmx`。
FOUNDATION_EXPORT const NSInteger A2LaunchMemoryMaxXmxMB;
/// 原生预留（MB）。出处：老线 `LauncherPreferences.m` ame173 —— JVM 非堆 + 渲染面 + 系统开销。
FOUNDATION_EXPORT const NSInteger A2LaunchMemoryNativeReserveMB;
/// 物理内存比例（fallback 用）。出处：老线同函数 fallback 分支 `physMB * 0.6`。
FOUNDATION_EXPORT const double A2LaunchMemoryPhysicalRatio;
/// 无任何读数时的默认堆上限（MB），同时是 fallback 分支的下限。出处：老线 fallback 的 1024 保底。
FOUNDATION_EXPORT const NSInteger A2LaunchMemoryDefaultXmxMB;

#pragma mark - 预算

@interface A2LaunchMemory : NSObject

/// ★纯函数★：由一次探测算「设备安全堆顶」（MB）。
/// available > 0 ⇒ 权威路径（available − 原生预留）；否则用物理内存 × 比例（不低于默认值）。
/// 两条路径的结果都钳到 [`A2LaunchMemoryMinXmxMB`, `A2LaunchMemoryMaxXmxMB`]。
+ (NSInteger)safeHeapCeilingMBForProbe:(A2MemoryProbe *)probe;

/// ★纯函数★：由安全顶 + 档位 + 用户值算最终 `-Xmx`（MB）。
/// 手动档取用户值，但★钳到安全顶★（超顶的设备上，堆顶下不来就是被 jetsam 杀）；
/// 自动档（或手动没给值）直接取安全顶。结果再钳到 [min, max]。
+ (NSInteger)xmxMBWithCeilingMB:(NSInteger)ceilingMB
                           mode:(A2LaunchMemoryMode)mode
                    requestedMB:(NSInteger)requestedMB;

/// ★档位判据的唯一实现★：Java 17+ 才启用 G1 调优。
/// 出处：老线 `JavaLauncher.m:2407` —— 「Java 8 的 G1 不够成熟，保持默认 SerialGC」。
/// ★A2LaunchPlan 与 `[MEM]` 判据行都调它，避免「>=17」这个字面量在两处各写一遍★。
+ (BOOL)usesG1TuningForJavaMajorVersion:(NSInteger)javaMajorVersion;

/// 该 Java 大版本实际用的 GC 名（`G1` / `default`）—— 只给判据行用，不参与参数拼装。
+ (NSString *)gcNameForJavaMajorVersion:(NSInteger)javaMajorVersion;

@end

NS_ASSUME_NONNULL_END

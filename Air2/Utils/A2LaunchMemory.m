//
//  A2LaunchMemory.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★只用 Foundation★（Utils 叶子层；也正是这样它才能被 clang 单测直编直跑）。
//

#import "A2LaunchMemory.h"

const NSInteger A2LaunchMemoryMinXmxMB = 256;
const NSInteger A2LaunchMemoryMaxXmxMB = 4096;
const NSInteger A2LaunchMemoryNativeReserveMB = 1200;
const double A2LaunchMemoryPhysicalRatio = 0.6;
const NSInteger A2LaunchMemoryDefaultXmxMB = 1024;

@implementation A2MemoryProbe

+ (instancetype)probeWithAvailableMB:(NSInteger)availableMB physicalMB:(NSInteger)physicalMB {
    A2MemoryProbe *probe = [[A2MemoryProbe alloc] init];
    probe->_availableMB = availableMB;
    probe->_physicalMB = physicalMB;
    return probe;
}

- (NSString *)source {
    // 有权威读数就是 api；其余（含两个读数都没有）都是 default —— 判据行按这个如实标。
    return (self.availableMB > 0) ? @"api" : @"default";
}

@end

@implementation A2LaunchMemory

+ (NSInteger)safeHeapCeilingMBForProbe:(A2MemoryProbe *)probe {
    NSInteger ceiling = 0;

    if (probe.availableMB > 0) {
        // 权威路径：进程当前可安全申请的内存 − 原生预留。
        ceiling = probe.availableMB - A2LaunchMemoryNativeReserveMB;
    } else if (probe.physicalMB > 0) {
        // fallback ①：物理内存 × 比例（读数不可信时的保守估算）。
        ceiling = (NSInteger)(probe.physicalMB * A2LaunchMemoryPhysicalRatio);
        if (ceiling < A2LaunchMemoryDefaultXmxMB) ceiling = A2LaunchMemoryDefaultXmxMB;
    } else {
        // fallback ②：连物理内存都拿不到 ⇒ 用默认值（如实标 source=default）。
        ceiling = A2LaunchMemoryDefaultXmxMB;
    }

    // 下限/上限保护（两条路径统一）：下限保证 JVM 起得来，上限防离谱值。
    if (ceiling < A2LaunchMemoryMinXmxMB) ceiling = A2LaunchMemoryMinXmxMB;
    if (ceiling > A2LaunchMemoryMaxXmxMB) ceiling = A2LaunchMemoryMaxXmxMB;
    return ceiling;
}

+ (NSInteger)xmxMBWithCeilingMB:(NSInteger)ceilingMB
                           mode:(A2LaunchMemoryMode)mode
                    requestedMB:(NSInteger)requestedMB {
    NSInteger requested = 0;
    if (mode == A2LaunchMemoryModeManual && requestedMB > 0) {
        requested = requestedMB;
    }

    // 手动档用用户值；自动档（或手动没给值）用安全顶。
    NSInteger xmx = (requested > 0) ? requested : ceilingMB;
    // ★安全顶是硬边界★：手动配置再大也压回安全顶（超顶 = iOS jetsam 直接杀，无 Java 异常）。
    if (xmx > ceilingMB) xmx = ceilingMB;
    if (xmx < A2LaunchMemoryMinXmxMB) xmx = A2LaunchMemoryMinXmxMB;
    if (xmx > A2LaunchMemoryMaxXmxMB) xmx = A2LaunchMemoryMaxXmxMB;
    return xmx;
}

+ (BOOL)usesG1TuningForJavaMajorVersion:(NSInteger)javaMajorVersion {
    return javaMajorVersion >= 17;
}

+ (NSString *)gcNameForJavaMajorVersion:(NSInteger)javaMajorVersion {
    return [self usesG1TuningForJavaMajorVersion:javaMajorVersion] ? @"G1" : @"default";
}

@end

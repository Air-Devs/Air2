//
//  A2PluginLaunchChainRisk.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★只做判定与文案，不弹窗、不写盘、不碰 registry★。
//

#import "A2PluginLaunchChainRisk.h"

#import "A2PluginPermissionStore.h"   // 权限目录：人话名称（文案不在本文件另抄一份）

/// 判据集合的**声明顺序**（= 弹窗名单的顺序，见头文件「顺序固定」）。
/// ★新增/删除一项只改这里★：`A2PluginLaunchChainPermissionIds()` 与
/// `A2PluginLaunchChainPermissionsForManifest:` 都从这一个数组派生。
static NSArray<NSString *> *A2LaunchChainPermissionOrder(void) {
    static NSArray<NSString *> *order = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        order = @[
            @"launch.args",        // 追加裸 JVM 参数（含 -javaagent）
            @"launch.gameArgs",    // 追加游戏自身参数（--server 等）
            @"launch.classpath",   // 改类路径
            @"launch.env.code",    // 以代码形式改启动环境变量
            @"java.agent",         // 注入 javaagent（字节码级接管）
            @"native.code",        // 注入原生代码
        ];
    });
    return order;
}

NSSet<NSString *> *A2PluginLaunchChainPermissionIds(void) {
    return [NSSet setWithArray:A2LaunchChainPermissionOrder()];
}

NSArray<NSString *> *A2PluginLaunchChainPermissionsForManifest(A2PluginManifest *manifest) {
    if (manifest == nil) return @[];
    // ★按判据集合的顺序走、逐个问 manifest★：结果顺序不随 manifest 的书写顺序变化。
    NSSet<NSString *> *requested = [NSSet setWithArray:(manifest.permissions ?: @[])];
    NSMutableArray<NSString *> *hit = [NSMutableArray array];
    for (NSString *permissionId in A2LaunchChainPermissionOrder()) {
        if ([requested containsObject:permissionId]) [hit addObject:permissionId];
    }
    return hit;
}

NSString *A2PluginLaunchChainPermissionNames(NSArray<NSString *> *permissionIds) {
    if (permissionIds.count == 0) return @"";
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:permissionIds.count];
    for (NSString *permissionId in permissionIds) {
        // 目录里的人话名称是唯一来源；目录没有的（如尚未登记的 `native.code`）回退到 id，
        // 不编一个不存在的名字（编了就等于替它向用户承诺了它并不具备的语义）。
        A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
        NSString *name = info.shortName.length ? info.shortName : permissionId;
        [names addObject:name];
    }
    return [names componentsJoinedByString:@"、"];
}

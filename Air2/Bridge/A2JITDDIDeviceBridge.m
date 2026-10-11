//
//  A2JITDDIDeviceBridge.m
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
//  [JIT-DDI-1] 骨架实现：★如实报「不可用 / 未接入」，绝不假成功★。
//  设备侧查询 / 个性化请求 / image_mounter 挂载属下一阶段（docs/JIT-PROVISIONING.md §4.2）。
//

#import "A2JITDDIDeviceBridge.h"

/// 骨架统一原因（供日志与 UI 直接展示；点名「缺什么」）。
static NSString *const kA2DDIBridgeNotWired =
    @"设备侧 DDI 查询未接入（Bridge → Natives 尚未落地）：本进程无法读设备侧已挂载镜像，"
    @"也无法使用 image_mounter 服务（docs/JIT-PROVISIONING.md §4.2）";

@implementation A2JITDDIDeviceBridge

#pragma mark - 设备侧查询

- (A2JITDDIVerdict)deviceDDIVerdictWithEvidence:(NSString *_Nullable *_Nullable)evidenceOut {
    // ★不猜★：查不到设备侧有没有挂载镜像 ⇒ 如实回 Unknown（不是 Missing、也不是 Present）。
    if (evidenceOut) {
        *evidenceOut = kA2DDIBridgeNotWired;
    }
    NSLog(@"[A2JIT] ddi bridge: deviceDDIVerdict ⇒ Unknown（未接入：%s）",
          kA2DDIBridgeNotWired.UTF8String);
    return A2JITDDIVerdictUnknown;
}

#pragma mark - 机制调用点（全部如实回 NO + 确切缺什么）

- (BOOL)fetchPersonalizedImageForRequirement:(A2JITDDIRequirement *)requirement
                                      reason:(NSString *_Nullable *_Nullable)reasonOut {
    NSLog(@"[A2JIT] ddi bridge: fetchPersonalizedImage ⇒ NO（未接入）require=%@",
          [requirement displayVersion]);
    if (reasonOut) {
        *reasonOut = @"联网取 DDI 未接入：需要 (1) 与「自动配对」同一套的 RPPairing 隧道"
                     @"（RSD + pair-verify + TLS-PSK，本仓尚未落地）；"
                     @"(2) 经该隧道调用设备 image_mounter 的客户端能力；"
                     @"(3) 镜像文件集来源的选型（★第三方镜像仓 vs Apple 分发，需拍板★）——"
                     @"三者齐备才谈得上「取到并挂载」，机制经 Bridge → Natives 落地"
                     @"（docs/JIT-PROVISIONING.md §3.4 / §4.2）";
    }
    return NO;
}

- (BOOL)mountImageAtPath:(NSString *)imagePath
           trustcachePath:(nullable NSString *)trustcachePath
                  reason:(NSString *_Nullable *_Nullable)reasonOut {
    NSLog(@"[A2JIT] ddi bridge: mountImage ⇒ NO（未接入）path=%@ trustcache=%@",
          imagePath.lastPathComponent, trustcachePath ? @"有" : @"无");
    if (reasonOut) {
        *reasonOut = @"挂载 DDI 未接入：需经 RPPairing 隧道调用设备的 image_mounter 服务"
                     @"（cryptex / personalized 两种方式，按系统版本选），"
                     @"并具备相应能力（本进程为沙盒 App，未接线）——"
                     @"若确认需要额外特权，会在此点名缺什么";
    }
    return NO;
}

@end

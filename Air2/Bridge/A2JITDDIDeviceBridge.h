//
//  A2JITDDIDeviceBridge.h
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
//  Bridge —— DDI 的【设备侧】查询接线点（协议 A2JITDDIDeviceQuery 的实现）。
//
//  为什么在 Bridge：依赖严格单向 App → UI → Player → Core → Bridge → Natives（ADR-002）。
//  ★Bridge 是唯一与 Natives 相邻的层★；「读设备侧已挂载镜像 / 请求 Apple 个性化端点 /
//  经 image_mounter 挂载」只能发生在 Bridge → Natives。Player 侧只认协议。
//
//  ★[JIT-DDI-1] 本类当前是【骨架】★：真实现（个性化请求 + image_mounter 挂载）
//  属下一阶段（docs/JIT-PROVISIONING.md §4.2），且【是否需要特权尚未在真机确认】。
//  骨架★必须如实报「不可用 / 未接入」并写明确切缺什么★——
//  绝不假成功（不谎报「设备侧已挂载」，也不谎报「已经取到 DDI」）。
//
//  下一阶段的落点（本单只定调用点与如实失败文案，不实现）：
//    1. Natives/Support 新增最小实现：经既有 lockdown / 隧道能力查 image_mounter 服务与已挂载镜像；
//    2. 个性化 DDI：向 Apple 官方 personalization（TSS）端点提交请求（★访问 Apple 官方服务，
//       不是「上云」★：请求直达 Apple，不经任何第三方服务器），需要设备的 UniqueChipID 等
//       个性化参数，并校验返回的签名材料；
//    3. 挂载 / 卸载经 image_mounter；★若需特权而当前环境不具备 ⇒ 如实阻断并点名缺什么★。
//
//  合规：零第三方；★只参考公开文档与公开实现的行为描述，未搬运任何第三方代码★。
//

#import <Foundation/Foundation.h>
#import "A2JITDDI.h"

NS_ASSUME_NONNULL_BEGIN

/// DDI 设备侧查询的 Bridge 骨架（真实现经 Bridge → Natives 落地）。
@interface A2JITDDIDeviceBridge : NSObject <A2JITDDIDeviceQuery>
@end

NS_ASSUME_NONNULL_END

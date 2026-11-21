//
//  A2Renderer.h
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
//  渲染后端描述 —— 纯数据，不含加载逻辑。
//
//  为什么是纯数据：
//    真正的 dylib 加载与 Metal 层管理在 Natives（他人负责），
//    Core 只收敛“有哪些后端、怎么选”的决策（学 ZL2 Renderers 的
//    注册表决策，用 ObjC 重写，不照抄实现）。UI 在后端就绪前
//    不加选择入口（见 A2SettingsSections 的宁缺毋滥约束）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 已知桥接家族（来自 Amethyst Natives/ctxbridges 的三座桥，仅作词汇表，
/// 不代表本仓库已带二进制；是否可用由 Natives 注册时决定）。
FOUNDATION_EXPORT NSString *const A2RendererBridgeGL;   // gl_bridge
FOUNDATION_EXPORT NSString *const A2RendererBridgeOSMesa; // osm_bridge
FOUNDATION_EXPORT NSString *const A2RendererBridgeVulkan; // vk_bridge

@interface A2Renderer : NSObject <NSCopying>

/// 唯一标识（如 @"gl"）。注册时去重依据。
@property (nonatomic, copy, readonly) NSString *identifier;

/// 展示名（如 @"OpenGL"）。仅供未来 UI 使用，Core 不依赖它。
@property (nonatomic, copy, readonly) NSString *displayName;

/// 对应 dylib 文件名（如 @"libGL.dylib"），Natives 填写；未知则 nil。
@property (nonatomic, copy, readonly, nullable) NSString *dylibName;

/// 备注（如最低版本要求），可为空。
@property (nonatomic, copy, readonly, nullable) NSString *notes;

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                         dylibName:(nullable NSString *)dylibName
                             notes:(nullable NSString *)notes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// 渲染后端注册表 —— 启动流程消费的唯一入口。
///
/// 决策（对齐 ZL2 Renderers）：
///   · 按 identifier 去重，后注册的同名直接拒绝（返回 NO）。
///   · 解析顺序：版本级覆盖 > 全局设置 > 首个已注册 > nil。
///   · 找不到且 allowFallback 时回落到首个，避免启动直接失败。
@interface A2Renderers : NSObject

+ (instancetype)shared;

/// 清空（单测/重建用）。生产代码不调。
- (void)resetForTesting;

/// 注册一个后端。identifier 已存在返回 NO，否则 YES。
- (BOOL)registerRenderer:(A2Renderer *)renderer;

/// 全部已注册标识（注册顺序）。
- (NSArray<NSString *> *)allIdentifiers;

/// 取描述，未注册返回 nil。
- (nullable A2Renderer *)rendererForIdentifier:(NSString *)identifier;

/// 解析最终使用的标识。
/// @param versionRenderer 版本级覆盖（可 nil/空串表示跟随全局）。
/// @param globalRenderer 全局设置（可 nil/空串）。
/// @param allowFallback 找不到时是否回落到首个已注册。
/// @return 有效标识，或 nil（一个都没注册）。
- (nullable NSString *)resolveEffectiveIdentifierWithVersionRenderer:(nullable NSString *)versionRenderer
                                                     globalRenderer:(nullable NSString *)globalRenderer
                                                      allowFallback:(BOOL)allowFallback;

@end

NS_ASSUME_NONNULL_END

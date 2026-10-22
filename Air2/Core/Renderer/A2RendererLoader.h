//
//  A2RendererLoader.h
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
//
//  A2RendererLoader.h
//  Air2
//
//  渲染器库的加载器 —— 按库布局决定 dlopen 顺序。
//
//  三种布局的加载方式差异很大，不能统一处理：
//
//  **combined**（MobileGlues / NG-GL4ES）
//      一次 dlopen，同一个句柄同时提供 gl* 与 egl* 符号。
//      RTLD_GLOBAL 让后续 dlsym 能取到符号。
//
//  **separate**（Zink / VirGL）
//      先 dlopen EGL 且必须 RTLD_GLOBAL ——
//      GL 库在加载时会在全局符号表里找 eglGetDisplay 这些，
//      顺序反了会报 "symbol not found"。
//
//  **glOnly**
//      只加载 GL。
//
//  为什么单独做成类而不是在插件里加个方法：
//    加载逻辑将来要与启动流程（Bridge 层）对接，
//    它需要独立、可测试，不依赖 UI 或插件管理。
//

#import <Foundation/Foundation.h>
#import "A2RendererPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// 已加载的渲染器句柄
@interface A2RendererHandle : NSObject

/// GL 库句柄（dlopen 返回的 void*）
@property (nonatomic, assign, readonly) void *glHandle;
/// EGL 库句柄。合并库时与 glHandle 相同。
@property (nonatomic, assign, readonly) void *eglHandle;
/// 使用的布局
@property (nonatomic, assign, readonly) A2RendererLibraryLayout layout;
/// 加载时应用的环境变量
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *appliedEnv;

/// 从 GL 库取符号（找不到返回 NULL）
- (nullable void *)symbolGL:(const char *)name;
/// 从 EGL 库取符号
- (nullable void *)symbolEGL:(const char *)name;

@end

@interface A2RendererLoader : NSObject

/// 加载一个渲染器插件。
///
/// ⚠️ 会先 setenv 传入的环境变量再 dlopen ——
/// 有些库在 __attribute__((constructor)) 里读环境变量决定行为，
/// 加载后再设就晚了。
///
/// @param plugin 渲染器插件
/// @param env 环境变量（来自 A2RendererRegistry environmentForRenderer:）
- (nullable A2RendererHandle *)loadPlugin:(A2RendererPlugin *)plugin
                              environment:(NSDictionary<NSString *, NSString *> *)env
                                    error:(NSError **)error;

/// 加载内置渲染器（直接给两个库路径）
- (nullable A2RendererHandle *)loadLibrariesAtGLPath:(NSString *)glPath
                                             eglPath:(nullable NSString *)eglPath
                                              layout:(A2RendererLibraryLayout)layout
                                         environment:(NSDictionary<NSString *, NSString *> *)env
                                               error:(NSError **)error;

/// 卸载
- (void)unload:(A2RendererHandle *)handle;

@end

NS_ASSUME_NONNULL_END

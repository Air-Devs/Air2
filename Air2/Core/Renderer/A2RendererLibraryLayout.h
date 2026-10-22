//
//  A2RendererLibraryLayout.h
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
//  A2RendererLibraryLayout.h
//  Air2
//
//  渲染器的库布局 —— iOS 上各家形态不同，必须显式区分。
//
//  Android 上的事实：FCL/ZL2 里 GL 与 EGL 总是两个独立的 .so
//  （libgl4es_114.so + libEGL.so，或 libOSMesa_81.so + libEGL.so）。
//  所以它们的 manifest 里是 glName / eglName 两个必填字段。
//
//  iOS 上不是这样：
//
//    **MobileGlues**  —— GL 与 EGL 编在同一个 dylib 里
//                        （libMobileGlues.dylib，同时导出 gl* 与 egl* 符号）
//    **NG-GL4ES**     —— 同样是合并库
//    **Zink / VirGL** —— GL 一个、EGL 一个，分开的
//
//  如果只用一个「eglPath 可不填」来表达，语义是含糊的：
//  不填到底是「这个渲染器不需要 EGL」还是「共用 GL 库」？
//  加载逻辑要做不同的事，不能靠猜。
//
//  所以引入 A2RendererLibraryLayout 显式区分三种形态。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2RendererLibraryLayout) {
    /// 单个合并库：同一个 dylib 同时导出 GL 与 EGL 符号。
    /// 加载时只需 dlopen 一次，两个函数表都从这个句柄取。
    /// 例：MobileGlues、NG-GL4ES
    A2RendererLibraryLayoutCombined = 0,

    /// GL 与 EGL 分成两个库。
    /// 加载时先 dlopen EGL（带 RTLD_GLOBAL，让 GL 库能解析到它），再 dlopen GL。
    /// 例：Zink（libglxshim + libEGL_mesa）、VirGL（libOSMesa + libEGL）
    A2RendererLibraryLayoutSeparate,

    /// 只有 GL，不需要 EGL（如纯离屏渲染的 OSMesa 直连）。
    /// 例：部分旧版 OSMesa 桥
    A2RendererLibraryLayoutGLOny,
};

/// 该布局是否需要单独的 EGL 库
FOUNDATION_EXPORT BOOL A2RendererLayoutHasSeparateEGL(A2RendererLibraryLayout layout);
/// 该布局的加载顺序说明（给日志与文档用）
FOUNDATION_EXPORT NSString *A2RendererLayoutDescription(A2RendererLibraryLayout layout);

NS_ASSUME_NONNULL_END

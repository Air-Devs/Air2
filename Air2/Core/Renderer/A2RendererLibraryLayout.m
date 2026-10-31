//
//  A2RendererLibraryLayout.m
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
//  A2RendererLibraryLayout.m
//  Air2
//

#import "A2RendererLibraryLayout.h"

BOOL A2RendererLayoutHasSeparateEGL(A2RendererLibraryLayout layout) {
    return layout == A2RendererLibraryLayoutSeparate;
}

NSString *A2RendererLayoutDescription(A2RendererLibraryLayout layout) {
    switch (layout) {
        case A2RendererLibraryLayoutCombined:
            return @"合并库（同一个 dylib 导出 GL 与 EGL）";
        case A2RendererLibraryLayoutSeparate:
            return @"分离库（GL 与 EGL 各一个 dylib，先 EGL 后 GL）";
        case A2RendererLibraryLayoutGLOny:
            return @"仅 GL（不需要 EGL）";
    }
    return @"未知布局";
}

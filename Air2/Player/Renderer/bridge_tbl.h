//
//  bridge_tbl.h
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
#pragma once

#include <stdlib.h>
#include "gl_bridge.h"
#include "osm_bridge.h"
#include "vk_bridge.h"

typedef union {
    gl_render_window_t gl;
    osm_render_window_t osm;
    vk_render_window_t vk;
} basic_render_window_t;

typedef basic_render_window_t* (*br_init_context_t)(basic_render_window_t* share);
typedef void (*br_make_current_t)(basic_render_window_t* bundle);
typedef basic_render_window_t* (*br_get_current_t)();

// ★ 这些是【声明】，实体定义在 egl_bridge.m（bridge_tbl_defs）★
//
// 原先这里是【定义】，而本头文件被 4 个 .m 包含
// （egl_bridge.m / osm_bridge.m / gl_bridge.m / vk_bridge.m），
// 于是每个编译单元各生成一份实体。链接器平时靠"隐藏符号各取各的"侥幸通过，
// 但主二进制一旦用 -exported_symbols_list 导出它们，就变成强符号并报：
//
//     ld: 7 duplicate symbols
//     duplicate symbol '_br_make_current' in:
//         egl_bridge.o / osm_bridge.o / gl_bridge.o / vk_bridge.o
//     duplicate symbol '_br_swap_buffers'  in: ...
//     duplicate symbol '_br_init_context'  in: ...
//     duplicate symbol '_br_init'           in: ...
//     duplicate symbol '_br_swap_interval'  in: ...
//
// 顺带修掉一个更隐蔽的问题：currentBundle 原先是 static __thread，
// 每个编译单元一份 —— gl_bridge.m 赋值的那份，egl_bridge.m 里的
// br_get_current() 根本看不到，pojavGetCurrentContext() 会一直返回 NULL。
// 改成全局唯一实体后，渲染器设置的当前窗口对所有桥接层一致可见。
extern bool (*br_init)();
extern br_init_context_t br_init_context;
extern br_make_current_t br_make_current;
extern void (*br_swap_buffers)();
extern void (*br_setup_window)();
extern void (*br_swap_interval)(int swapInterval);
extern void (*br_terminate)();

extern __thread basic_render_window_t* currentBundle;
static inline basic_render_window_t* br_get_current() {
    return currentBundle;
}

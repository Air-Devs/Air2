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

bool (*br_init)();
br_init_context_t br_init_context;
br_make_current_t br_make_current;
//br_get_current_t br_get_current = NULL;
void (*br_swap_buffers)();
void (*br_setup_window)();
void (*br_swap_interval)(int swapInterval);
void (*br_terminate)();

static __thread basic_render_window_t* currentBundle;
static inline basic_render_window_t* br_get_current() {
    return currentBundle;
}

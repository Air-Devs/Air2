//
//  osm_bridge.h
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

#import <QuartzCore/QuartzCore.h>
#include <EGL/egl.h>
#include <GL/osmesa.h>

typedef struct {
    GLboolean (*OSMesaMakeCurrent) (OSMesaContext ctx, void *buffer, GLenum type, GLsizei width, GLsizei height);
    OSMesaContext (*OSMesaGetCurrentContext) (void);
OSMesaContext  (*OSMesaCreateContext) (GLenum format, OSMesaContext sharelist);
    void (*OSMesaDestroyContext) (OSMesaContext ctx);
    void (*OSMesaPixelStore) ( GLint pname, GLint value );
    GLubyte* (*glGetString) (GLenum name);
    void (*glFinish) (void);
    void (*glClearColor) (GLclampf red, GLclampf green, GLclampf blue, GLclampf alpha);
    void (*glClear) (GLbitfield mask);
} osmesa_library;

typedef struct {
    OSMesaContext context;
    uint32_t width, height;
    CGColorSpaceRef color_space;
    void* buffer;
} osm_render_window_t;

void osm_swap_buffers();
void set_osm_bridge_tbl();

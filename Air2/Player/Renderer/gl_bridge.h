//
//  gl_bridge.h
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

#include <EGL/egl.h>

typedef struct {
    PFNEGLBINDAPIPROC eglBindAPI;
    PFNEGLCHOOSECONFIGPROC eglChooseConfig;
    PFNEGLCREATECONTEXTPROC eglCreateContext;
    PFNEGLCREATEWINDOWSURFACEPROC eglCreateWindowSurface;
    PFNEGLDESTROYCONTEXTPROC eglDestroyContext;
    PFNEGLDESTROYSURFACEPROC eglDestroySurface;
    PFNEGLGETCONFIGATTRIBPROC eglGetConfigAttrib;
    PFNEGLGETCONFIGSPROC eglGetConfigs;
    PFNEGLGETCURRENTCONTEXTPROC eglGetCurrentContext;
    PFNEGLGETCURRENTSURFACEPROC eglGetCurrentSurface;
    PFNEGLGETDISPLAYPROC eglGetDisplay;
    PFNEGLGETERRORPROC eglGetError;
    PFNEGLGETPLATFORMDISPLAYPROC eglGetPlatformDisplay;
    PFNEGLINITIALIZEPROC eglInitialize;
    PFNEGLMAKECURRENTPROC eglMakeCurrent;
    PFNEGLQUERYSTRINGPROC eglQueryString;
    PFNEGLQUERYSURFACEPROC eglQuerySurface;
    PFNEGLRELEASETHREADPROC eglReleaseThread;
    PFNEGLSWAPBUFFERSPROC eglSwapBuffers;
    PFNEGLSWAPINTERVALPROC eglSwapInterval;
    PFNEGLTERMINATEPROC eglTerminate;
} egl_library;

typedef struct {
    //struct ANativeWindow *nativeSurface;
    EGLConfig  config;
    EGLint     format;
    EGLContext context;
    EGLSurface surface;
} gl_render_window_t;

void set_gl_bridge_tbl();

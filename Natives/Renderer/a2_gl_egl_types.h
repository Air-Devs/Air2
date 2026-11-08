// SPDX-License-Identifier: GPL-3.0-or-later
//  Air2 —— EGL 基础类型与常量（★只留类型，不含任何实现★）
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  ★来历★：这些 typedef/常量和 A2FakeEglWindowSize 原来放在 a2_eagl_egl.h 里，
//  随「停止 EAGL 支持、彻底移除假 EGL」一起迁到这里 —— 桥（a2_gl_bridge.m）仍然需要
//  EGL 句柄类型与配置常量来调用 MG/ANGLE 的 egl*，但它不需要、也不应该再看见
//  假 EGL 的实现或 engage/selftest 之类的入口。
//
//  谁用：Natives/Renderer/a2_gl_bridge.m（唯一的 EGL 建面/交换处）。
//  不再提供：egl* 的**定义**（那属于后端库：MG / ANGLE）与 a2_eagl_egl_* 系列入口。

#ifndef A2_GL_EGL_TYPES_H
#define A2_GL_EGL_TYPES_H

#include <stdint.h>

// 基础类型（EGL 1.4 §2.1；指针型句柄在本层都是「不透明句柄」）
// ---------------------------------------------------------------------------
typedef unsigned int   EGLBoolean;
typedef unsigned int   EGLenum;
typedef int32_t        EGLint;
typedef void *         EGLDisplay;
typedef void *         EGLConfig;
typedef void *         EGLSurface;
typedef void *         EGLContext;
typedef void *         EGLClientBuffer;
typedef void *         EGLNativeDisplayType;
typedef void *         EGLNativePixmapType;
typedef void *         EGLNativeWindowType;
typedef void (*         __eglMustCastToProperFunctionPointerType)(void);
typedef intptr_t       EGLAttrib;      // EGL 1.5（eglGetPlatformDisplay 用）
typedef int64_t        EGLTime;        // EGL 1.5（eglClientWaitSync 用）

// ---------------------------------------------------------------------------
// 布尔 / 空句柄
// ---------------------------------------------------------------------------
#define EGL_FALSE                       0
#define EGL_TRUE                        1
#define EGL_NO_DISPLAY                  ((EGLDisplay)0)
#define EGL_NO_CONTEXT                  ((EGLContext)0)
#define EGL_NO_SURFACE                  ((EGLSurface)0)
#define EGL_DEFAULT_DISPLAY             ((EGLNativeDisplayType)0)
#define EGL_DONT_CARE                   ((EGLint)-1)

// ---------------------------------------------------------------------------
// 错误码（EGL 1.4 §2.2.2）—— `eglGetError` 返回，读后清零
// ---------------------------------------------------------------------------
#define EGL_SUCCESS                     0x3000
#define EGL_NOT_INITIALIZED             0x3001
#define EGL_BAD_ACCESS                  0x3002
#define EGL_BAD_ALLOC                   0x3003
#define EGL_BAD_ATTRIBUTE               0x3004
#define EGL_BAD_CONFIG                  0x3005
#define EGL_BAD_CONTEXT                 0x3006
#define EGL_BAD_CURRENT_SURFACE         0x3007
#define EGL_BAD_DISPLAY                 0x3008
#define EGL_BAD_MATCH                   0x3009
#define EGL_BAD_NATIVE_PIXMAP           0x300A
#define EGL_BAD_NATIVE_WINDOW           0x300B
#define EGL_BAD_PARAMETER               0x300C
#define EGL_BAD_SURFACE                 0x300D
#define EGL_CONTEXT_LOST                0x300E

// ---------------------------------------------------------------------------
// 配置属性（EGL 1.4 §3.4）
// ---------------------------------------------------------------------------
#define EGL_BUFFER_SIZE                 0x3020
#define EGL_ALPHA_SIZE                  0x3021
#define EGL_BLUE_SIZE                   0x3022
#define EGL_GREEN_SIZE                  0x3023
#define EGL_RED_SIZE                    0x3024
#define EGL_DEPTH_SIZE                  0x3025
#define EGL_STENCIL_SIZE                0x3026
#define EGL_CONFIG_CAVEAT               0x3027
#define EGL_CONFIG_ID                   0x3028
#define EGL_LEVEL                       0x3029
#define EGL_MAX_PBUFFER_HEIGHT          0x302A
#define EGL_MAX_PBUFFER_PIXELS          0x302B
#define EGL_MAX_PBUFFER_WIDTH           0x302C
#define EGL_NATIVE_RENDERABLE           0x302D
#define EGL_NATIVE_VISUAL_ID            0x302E
#define EGL_NATIVE_VISUAL_TYPE          0x302F
#define EGL_PRESERVED_RESOURCES         0x3030
#define EGL_SAMPLES                     0x3031
#define EGL_SAMPLE_BUFFERS              0x3032
#define EGL_SURFACE_TYPE                0x3033
#define EGL_TRANSPARENT_TYPE            0x3034
#define EGL_TRANSPARENT_BLUE_VALUE      0x3035
#define EGL_TRANSPARENT_GREEN_VALUE     0x3036
#define EGL_TRANSPARENT_RED_VALUE       0x3037
#define EGL_NONE                        0x3038
#define EGL_BIND_TO_TEXTURE_RGB         0x3039
#define EGL_BIND_TO_TEXTURE_RGBA        0x303A
#define EGL_MIN_SWAP_INTERVAL           0x303B
#define EGL_MAX_SWAP_INTERVAL           0x303C
#define EGL_LUMINANCE_SIZE              0x303D
#define EGL_ALPHA_MASK_SIZE             0x303E
#define EGL_COLOR_BUFFER_TYPE           0x303F
#define EGL_RENDERABLE_TYPE             0x3040
#define EGL_MATCH_NATIVE_PIXMAP         0x3041
#define EGL_CONFORMANT                  0x3042

// surface_type / renderable_type 的位
#define EGL_PBUFFER_BIT                 0x0001
#define EGL_PIXMAP_BIT                  0x0002
#define EGL_WINDOW_BIT                  0x0004
#define EGL_OPENGL_ES_BIT               0x0001
#define EGL_OPENGL_ES2_BIT              0x0004
#define EGL_OPENGL_ES3_BIT              0x0040
#define EGL_OPENGL_ES3_BIT_KHR          EGL_OPENGL_ES3_BIT

// 没有多重采样的那个 config 一定给出的取值
#define EGL_MULTISAMPLE_RESOLVE_DEFAULT 0x309A
#define EGL_RGB_BUFFER                  0x308E
#define EGL_LUMINANCE_BUFFER            0x308F

// ---------------------------------------------------------------------------
// 上下文属性 / 查询目标
// ---------------------------------------------------------------------------
#define EGL_CONTEXT_CLIENT_VERSION      0x3098
#define EGL_CONTEXT_CLIENT_TYPE         0x3097
#define EGL_CONTEXT_MAJOR_VERSION       0x3098
#define EGL_CONTEXT_MINOR_VERSION       0x30FB
#define EGL_CONTEXT_OPENGL_DEBUG        0x31B0
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD

#define EGL_VENDOR                      0x3053
#define EGL_VERSION                     0x3054
#define EGL_EXTENSIONS                  0x3055
#define EGL_HEIGHT                      0x3056
#define EGL_WIDTH                       0x3057
#define EGL_LARGEST_PBUFFER             0x3058
#define EGL_DRAW                        0x3059
#define EGL_READ                        0x305A
#define EGL_CORE_NATIVE_ENGINE          0x305B
#define EGL_TEXTURE_FORMAT              0x3080
#define EGL_TEXTURE_TARGET              0x3081
#define EGL_MIPMAP_TEXTURE              0x3082
#define EGL_MIPMAP_LEVEL                0x3083
#define EGL_BACK_BUFFER                 0x3084
#define EGL_SINGLE_BUFFER               0x3085
#define EGL_RENDER_BUFFER               0x3086
#define EGL_COLORSPACE                  0x3087
#define EGL_ALPHA_FORMAT                0x3088
#define EGL_NO_TEXTURE                  0x305C
#define EGL_TEXTURE                     0x305F
#define EGL_SWAP_BEHAVIOR               0x3093
#define EGL_MULTISAMPLE_RESOLVE         0x3099
#define EGL_BUFFER_PRESERVED            0x3094
#define EGL_BUFFER_DESTROYED            0x3095
#define EGL_CLIENT_APIS                 0x308D

// ---------------------------------------------------------------------------
// 客户端 API（eglBindAPI / eglQueryAPI）
// ---------------------------------------------------------------------------
#define EGL_OPENGL_ES_API               0x30A0
#define EGL_OPENVG_API                  0x30A1
#define EGL_OPENGL_API                  0x30A2

// （原来的「类型与常量守卫」#endif 属于旧头文件，本文件用 A2_GL_EGL_TYPES_H 自己的守卫）

#ifdef __cplusplus
extern "C" {
#endif

// ===========================================================================
//  上屏（P2）：原生窗口 = 宿主图层
// ---------------------------------------------------------------------------
//  EGL 的 window surface 尺寸来自**真实原生窗口**。本层有两种窗口形态，靠
//  结构体里的 `layer` 字段区分（★同一个结构体，不改名、不另造平行类型★）：
//
//  ① 离屏（P1 原行为）：`layer = NULL` ⇒ 宽高必须给出；本层自建 renderbuffer + FBO，
//     `eglSwapBuffers` = `glFlush`（不上屏）。
//  ② 上屏（P2）：`layer = 宿主图层指针`（CALayer / UIView / 已经是 CAEAGLLayer 都行）
//     ⇒ 本层把它的（或挂在它上面的一块）CAEAGLLayer 作为 drawable，
//     颜色 renderbuffer 由 `EAGLContext -renderbufferStorage:fromDrawable:` 建，
//     `eglSwapBuffers` = `-presentRenderbuffer:`（★真正上屏★）。
//     此时宽高只作**创建前的初始提示**：真正的 drawable 尺寸以实现回报的
//     `GL_RENDERBUFFER_WIDTH/HEIGHT` 为准（`eglQuerySurface` 如实报它）。
//
//      A2FakeEglWindowSize win = { 0, 0, hostLayer };
//      eglCreateWindowSurface(dpy, cfg, &win, NULL);
//
//  传 NULL 指针 ⇒ EGL_BAD_NATIVE_WINDOW（本层不猜尺寸、不给默认值）。
//  宽高必须 > 0 且 ≤ EGL_MAX_PBUFFER_DIM（16384，系统 GLES3 的 renderbuffer 上限）；
//  上屏形态下宽高给 0 也接受（尺寸来自图层）。
// ===========================================================================
typedef struct {
    EGLint width;
    EGLint height;
    /// 宿主图层（见上）；NULL = 离屏。只借指针，不接管所有权（本层自己建的
    /// CAEAGLLayer 由本层持有并在 surface 销毁时摘掉）。
    void *layer;
} A2FakeEglWindowSize;

#endif  // A2_GL_EGL_TYPES_H

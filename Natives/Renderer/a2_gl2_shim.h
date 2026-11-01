// ============================================================================
//  Natives/Renderer/a2_gl2_shim.h
//  Air2 —— ★自研固定管线（GL2 → GLES3）最小实现★：给 LWJGL2 时代（≤1.12.2）的
//          立即模式 / 客户端顶点数组 / 矩阵栈 / 光源-纹理状态 提供落地实现，
//          绘制统一落成 GLES3 的「VBO + 着色器」。
// ----------------------------------------------------------------------------
//  分层：Natives/Renderer（同 a2_gl_bridge.*：EGL/GL 桥的同一层）。
//
//  ★它接在哪（不允许有「没人调」的符号）★
//    · `a2_gl2_shim_enabled()`  ← `Natives/Renderer/a2_gl_bridge.m`
//                                  `a2_gl_bridge_gles_getprocaddress()`（渲染器解析器入口）；
//                                  `Natives/Renderer/a2_eagl_egl.m`
//                                  `eglGetProcAddress()`（宿主假 EGL 解析器入口）；
//                                  `Air2/Player/A2LaunchSession.m`
//                                  `A2DefaultRendererForVersion()`（档位判据行）。
//    · `a2_gl2_shim_lookup()`   ← 上面两个解析器入口各一处 + `Natives/Renderer/a2_gl2_jni_bind.m`
//                                 的 7 个 JNI 转发各一处（★LWJGL 的 GL11 native 抢占★，见该文件头）。
//
//  ★默认关闭★：只有环境变量 `A2_GL2_SHIM=1` 才启用（见 .m 的 `a2_gl2_shim_enabled`）。
//    关闭时两个入口都不改变任何既有行为（返回 NULL ⇒ 调用方照旧走原逻辑）。
//
//  ★本层不碰 EGL/表面★：上下文由 `a2_gl_bridge` 建好；本层只在**当前上下文**里
//    取 GLES3 入口（`dlsym(RTLD_DEFAULT, …)`，与 a2_eagl_egl.m 的口径一致：
//    不 link OpenGLES.framework，避免把系统 GLES 塞进 flat namespace）。
// ============================================================================
#ifndef A2_GL2_SHIM_H
#define A2_GL2_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 自研固定管线档位是否启用（★唯一判据★：环境变量 `A2_GL2_SHIM`，值为 "0"/空/未设 ⇒ 关）。
/// 幂等（首次调用读一次环境变量并打一行 `[A2-GL2]` 判据，之后只读缓存）。
/// 调用点见文件头注释（三处）。
int a2_gl2_shim_enabled(void);

/// 按 GL 入口名取本层实现。
/// @param name GL 入口名（如 "glBegin"）。NULL ⇒ 直接返回 NULL。
/// @return 非空 = 本层实现该入口（调用方直接把它交给渲染器）；NULL = 本层不实现（调用方走原逻辑）。
/// 未启用 / 未实现的名字都返回 NULL ⇒ 调用方行为与接入前完全一致。
void *a2_gl2_shim_lookup(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* A2_GL2_SHIM_H */

//
//  a2_gl2_backend_gl4es.h
//  Air2
//
//  ★C 路线后端★：JNI 接管层保留（用来绕开 LWJGL 写死的 libGLESv2），
//  固定管线的**实现**交给 gl4es（libgl4es_114.dylib）。
//
//  为什么不是「选 gl4es 当渲染器」：
//    state.db 里 2026-10-25 的交接记录已经证明 —— 只要让 LWJGL 自己绑 GL，
//    调用就会落到 libGLESv2/ANGLE 的 GLES1State 上崩掉；改 libname、加白名单、
//    给 KW 打空桩全都无效。唯一有效的做法是我们这一层先把入口抢下来
//    （a2_gl2_jni_bind 的 RegisterNatives），再决定把调用转给谁。
//
//  调用点：
//    · `a2_gl2_shim_lookup()`（Natives/Renderer/a2_gl2_shim.m）—— 唯一调用 `a2gl4_symbol`
//    · `A2LaunchSession` 在 1.12 档位设 `A2_GL2_BACKEND=gl4es`
//

#ifndef A2_GL2_BACKEND_GL4ES_H
#define A2_GL2_BACKEND_GL4ES_H

#ifdef __cplusplus
extern "C" {
#endif

/// 是否走 gl4es 后端（读 A2_GL2_BACKEND=gl4es）
int a2gl4_backend_enabled(void);

/// 按 GL 入口名取 gl4es 里的实现；取不到返回 NULL（调用方继续走原逻辑）。
/// 只对「 gl4es 能提供、且我们确实想让它接管」的名字返回非空。
void *a2gl4_symbol(const char *name);

/// 一次性加载 libgl4es_114.dylib（幂等）。成功返回 1。
int a2gl4_load(void);

#ifdef __cplusplus
}
#endif

#endif /* A2_GL2_BACKEND_GL4ES_H */

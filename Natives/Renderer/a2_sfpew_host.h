// ============================================================================
//  Natives/Renderer/a2_sfpew_host.h
//  Air2 —— ★[A2-SFPEW] SimpleFPEWrapper 宿主接入面（完全隔离的固定管线档位）★
// ----------------------------------------------------------------------------
//  分层：Natives/Renderer（docs/ARCHITECTURE.md §Natives：「Renderer/ — Metal 层管理、
//        EGL/GL 桥、surface 生命周期」）。本文件与 `a2_gl_bridge.*` 同层且只被它调用。
//
//  ★本文件只做一件事★：按上游（SimpleFPEWrapper / LGPL-3.0）接入契约把
//  `libSimpleFPEWrapper.dylib` 载入并把**它接管的那一半**交还给桥：
//    ① 建面（display/config/surface/context）**不归它** —— 仍由 `a2_gl_bridge.m` 用宿主的
//       EGL 库（包内 ANGLE `Frameworks/libEGL.framework/libEGL`）做；
//    ② `dlopen(…, RTLD_LOCAL)`，且不靠静态构造函数初始化（本层不调任何 init 入口）；
//    ③ GL 入口一律先问它的 `eglGetProcAddress`（不允许混用系统解析到的 `glBegin`）；
//    ④ `eglMakeCurrent` / `eglSwapBuffers` 用它的实现；
//    ⑤ 后端 EGL 库名由环境变量 `SFPEW_EGL` 指定（上游默认 `libEGL.so`，iOS 上必然失败）。
//
//  ★默认不生效（本档位完全隔离）★
//    唯一入口是 `a2_gl_bridge_attach` 的 ①c，判据 `a2_sfpew_host_is_identifier(rendererName)`。
//    不选这一档 ⇒ 不 dlopen SFPEW、不读写 `SFPEW_EGL`、不留句柄、不留任何全局状态。
//
//  ★叠加形态（兼容层，默认关）★：`a2_sfpew_host_set_compat_layer(1)` 后，①d 会在
//    **已选渲染器之上**再加载一次 SFPEW（后端 = 该渲染器自己的 dylib），GL 解析先问它，
//    makeCurrent/swapBuffers 也交给它转交（⑤b 判据 `gSfpewTier`）；
//    建面/上下文版本仍归原渲染器 ⇒ 与独立档位互不替代、互不叠加（已选独立档位时 ①d 不执行）。
//
//  ★调用点（逐个登记，不留「没人调」的符号）★
//    · `a2_sfpew_host_is_identifier`      ← a2_gl_bridge.m:`a2_gl_bridge_attach` ①c（唯一判据）
//    · `a2_sfpew_host_load`               ← a2_gl_bridge.m:`a2_gl_bridge_attach` ①c（失败即阻断）
//    · `a2_sfpew_host_handle`             ← a2_gl_bridge.m:`a2_gl_bridge_attach` ④（承接句柄，不重复 dlopen）
//    · `a2_sfpew_host_getprocaddress`     ← a2_gl_bridge.m:`a2_gl_bridge_gl_symbol`（⑦ 帧动作入口）
//                                           与 `a2_gl_bridge_gles_getprocaddress`（解析器出口）
//    · `a2_sfpew_host_egl_make_current`   ← a2_gl_bridge.m:`a2_gl_bridge_attach` ⑤b（替换 gEglMakeCurrent）
//    · `a2_sfpew_host_egl_swap_buffers`   ← a2_gl_bridge.m:`a2_gl_bridge_attach` ⑤b（替换 gEglSwapBuffers）
//    · `a2_sfpew_host_compat_layer_enabled` ← a2_gl_bridge.m:`a2_gl_bridge_attach` ①d（兼容层判据）
//    · `a2_sfpew_host_load_compat`        ← 同上 ①d（失败只记日志，不阻断启动）
//    · `a2_sfpew_host_set_compat_layer`   ← Air2/Bridge/A2LaunchRunner.m（把 Player 的开关下发）
//    · `A2SFPEWHostDylibName`             ← 同上 ①c / a2_renderer.m:`a2_renderer_load_named`（不加载只校验）
//                                            / Air2/Core 的候选表（标识 = dylib 文件名）
// ============================================================================
#ifndef A2_SFPEW_HOST_H
#define A2_SFPEW_HOST_H

#import <Foundation/Foundation.h>

/// ★档位标识 = dylib 文件名★（与 `A2RendererCatalog` 的候选标识逐字相同，
/// 也是 `-Dorg.lwjgl.opengl.libname` 去掉 `lib`/`.dylib` 后的来源）。
extern const char *const A2SFPEWHostDylibName;

/// ★后端 EGL 的相对路径★（包内 ANGLE）—— 与 `a2_gl_bridge.m` 的
/// `A2GlBridgeEglLibraryRelPath` 同一个文件；写在这里是因为 `SFPEW_EGL` 由本层设置。
extern const char *const A2SFPEWHostBackendEglRelPath;

/// ★环境变量名★（上游 `backend/loader.cpp` 读它；默认值是 Android 的 `libEGL.so`）。
extern const char *const A2SFPEWHostEnvKey;

/// 已选后端是否就是这个档位（纯字符串精确比较：不碰文件 / 不 dlopen / 不碰 EGL）。
int a2_sfpew_host_is_identifier(const char *rendererName);

/// 加载 SFPEW 并取它接管的三个 EGL 入口。
/// @param frameworksPath `<App>/Frameworks`（SFPEW 本体与后端 EGL 都在它下面）
/// @return 0 = 就绪；-1 = frameworksPath 为空；-2 = dlopen 失败（原因见日志）；-3 = 缺入口
/// 幂等：同一进程重复调用直接复用上次句柄（表面改绑会重复 attach，但不是新镜像）。
/// ★副作用只在「本档位真的要加载」时发生★：写 `SFPEW_EGL` + dlopen。
int a2_sfpew_host_load(NSString *frameworksPath);

/// 已加载的句柄（未加载 ⇒ NULL）。调用点见文件头的「调用点」表（④ 用它注册后端本体）。
void *a2_sfpew_host_handle(void);

// ---------------------------------------------------------------------------
//  ★[A2-SFPEW] 兼容层（叠加在已选渲染器之上，★默认关★）★
// ---------------------------------------------------------------------------
//  与上面的「独立档位」是两件事，互不替代：
//    · 独立档位：渲染器**就是** SFPEW（①c，建面/换页也归它）；
//    · 兼容层  ：渲染器仍是用户选的那个（MG / GL4ES / KW …），SFPEW 只叠在它上面
//                接管 GL 解析（`gSfpewTier` 的那两个解析出口），建面/换页一字不动。
//  ★为什么开关放在本层★：判据（实例开关 / FPE 模组）在上层，但「加载与句柄」只有这里能做；
//   GL 桥按本层的状态位决定解析顺序，因此上层只需在启动前调用一次 setter。
//  ★默认 0 ⇒ 不加载 / 不写 SFPEW_EGL / 不留句柄★：不开这个开关时与接入前逐位一致。

/// 兼容层开关当前值（0 = 关，1 = 开）。GL 桥 `a2_gl_bridge_attach` 的 ①d 读它。
int a2_sfpew_host_compat_layer_enabled(void);

/// 写入兼容层开关（唯一写点：Bridge 的 `A2LaunchRunner`，把 Player 解析好的开关下发）。
void a2_sfpew_host_set_compat_layer(int enabled);

/// 按兼容层方式加载 SFPEW：`SFPEW_EGL` 指向**已选渲染器自己的 dylib**
/// （上游 `backend/loader.cpp` 的后端 EGL 就是这个用途；README「接入时要先知道的」：
///  iOS 上必须传自定义后端路径，可选 `libEGL.framework/libEGL` 或 MobileGlues 的 dylib）。
/// @param frameworksPath    `<App>/Frameworks`
/// @param backendDylibPath 已选渲染器的 dylib 绝对路径（空 ⇒ 退到包内 ANGLE，与独立档位同一后端）
/// @return 同 `a2_sfpew_host_load`（0 就绪 / -1 路径空 / -2 dlopen 失败 / -3 缺入口）
/// 幂等：同一进程重复调用复用同一句柄（表面改绑会重复 attach）。
int a2_sfpew_host_load_compat(NSString *frameworksPath, NSString *backendDylibPath);

/// GL 入口解析（契约③）：先问 SFPEW 的 `eglGetProcAddress`，再退到它自己的 `dlsym`。
/// 未加载 / 未命中 ⇒ NULL（调用方按原逻辑继续，不猜）。
void *a2_sfpew_host_getprocaddress(const char *name);

/// 契约④：`eglMakeCurrent` / `eglSwapBuffers` 走 SFPEW 的实现（参数就是 EGL 规范句柄）。
/// 未加载 ⇒ 返回 0（EGL_FALSE），与「没有实现」一致，不假装成功。
unsigned int a2_sfpew_host_egl_make_current(void *dpy, void *draw, void *read, void *ctx);
unsigned int a2_sfpew_host_egl_swap_buffers(void *dpy, void *surf);

#endif /* A2_SFPEW_HOST_H */

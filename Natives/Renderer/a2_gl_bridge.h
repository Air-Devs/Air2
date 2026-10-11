// ============================================================================
//  Natives/Renderer/a2_gl_bridge.h
//  Air2 —— ★GL 桥★：把一个「中立宿主表面」接成一条**可用的 GL 上下文**
// ----------------------------------------------------------------------------
//  分层：本文件属 Natives/Renderer（见 docs/ARCHITECTURE.md §Natives：
//        「Renderer/ — Metal 层管理、EGL/GL 桥、surface 生命周期」）。
//
//  ★本层只做一件事★：按**已选的渲染后端名**去 `<App>/Frameworks/` 加载它需要的
//  库（EGL/GLES 兼容底 + 后端本体），用 EGL 建出 display/config/context/surface，
//  取到函数指针表，并在**帧回调**里执行一次 `glClear` 作为「上下文真的可用」的可判据动作。
//
//  ★与渲染器解耦（本文件的硬约束）★
//    · 只认识「已选渲染器名」这一个字符串，不认识任何后端内部符号/私有接口；
//    · 不含 Metal 专有逻辑（不建 Metal 图层、不碰 Metal 设备、不 import Metal 框架 ——
//      机器判据：见 tests/Natives 的「Metal 专有 API 命中 = 0」断言）；
//    · 不引入任何渲染器实现（本层不实现后端，只把它接上）；
//    · 对上层只暴露一个【中立宿主/表面结构】(A2GlHostSurface)：原生窗口句柄、
//      像素格式、尺寸、帧回调、已选渲染器名 —— 就这五样，多一样都不加。
//      其中前三样直接**复用**既有 `Natives/Input/a2_glfw_window.h` 的中立表面描述
//      `A2GlfwSurface`（★不另造一个平行的 surface 结构★，同 [A2-OWNGLFW-NATIVE-1]
//      的「渲染器解耦唯一交接面」定位）。
//
//  ★为什么现在才有它（缺口③）★：`[RENDER-WIRE]`/`[RENDER-SEL]` 只做到「选 + dlopen」
//    （见 Natives/Renderer/a2_renderer.*），选中的后端**拿不到表面、也建不出上下文**
//    ⇒ 用户能看到列表、能选中，但出不了画面。本文件补的正是这一段：
//    「后端真的能拿到 surface 并建出可用的 GL 上下文」。
//
//  ★调用点（唯一）★：`Air2/Bridge/A2LaunchRunner.m` 的
//    `+launchWithPlanPath:…`（在 `a2_renderer_load_named` 之后、组 java 命令行之前）。
//    Bridge 是唯一与 Natives 相邻的层（同 [LAUNCH-PLAN] 决策 2）。
//
//  ★阻断口径（不静默回退）★
//    · 选中的后端**不是** EGL/GL 系（如主推的 Metal）⇒ 返回 `A2GlBridgeSkipped`，
//      **不阻断**（它的建面归它自己；本层不假装能替它建面、也不替换成别的后端）；
//    · 选中的后端是 EGL/GL 系，但缺库 / 无表面 / EGL 建面失败 ⇒ 返回负值，
//      调用方据此**如实阻断启动**（不得静默换一个渲染器继续）。
// ============================================================================
#ifndef A2_GL_BRIDGE_H
#define A2_GL_BRIDGE_H

#import <Foundation/Foundation.h>

#include "a2_glfw_window.h"   // ★复用既有中立表面描述 A2GlfwSurface★（窗口句柄/像素格式/尺寸）
#import "a2_renderer.h"       // ★复用既有渲染器名常量★ A2RendererCompatDylibName（不重复字面量）

// ---------------------------------------------------------------------------
// 判据锚点 / 兼容底库名（★出包后应能在主二进制里扫到，作为「这层真的随包」的机器判据★）
// ---------------------------------------------------------------------------

/// 本层的日志/判据前缀（★判据锚点★：真机 grep `[A2-GLBRIDGE]`）。
extern const char *const A2GlBridgeJudgementTag;

/// ★EGL 兼容底★（ANGLE 系）在主包 `Frameworks/` 下的相对路径 —— 建面要用它的 EGL。
/// 与随包物 `Libraries/Frameworks/libEGL.framework/libEGL`（见 [RENDER-SEL] 的 GL4ES 依赖）同源。
extern const char *const A2GlBridgeEglLibraryRelPath;

/// ★GLESv2 兼容底★（ANGLE 系）在主包 `Frameworks/` 下的相对路径 —— EGL 上下文的 GL 实现。
extern const char *const A2GlBridgeGlesLibraryRelPath;

// ---------------------------------------------------------------------------
// ★中立宿主 / 表面接口★（本层与上层之间唯一的交接面）
// ---------------------------------------------------------------------------
// 只含五样（★多一样都不加★）：
//   ① 原生窗口句柄  ┐
//   ② 像素格式      ├─ 复用 A2GlfwSurface（既有中立表面描述，不另造）
//   ③ 尺寸          ┘
//   ④ 帧回调        ── 每帧末尾由本层回调（宿主可空）
//   ⑤ 已选渲染器名  ── `A2SelectedRendererPrefKey` 的值 = dylib 文件名
//
// 帧回调签名：宿主在每帧末尾要做的事（如计数/日志）。本层先做完自己的帧动作
// （`glClear` + `eglSwapBuffers`）再回调它 —— 因此它**看不到**任何 GL 类型。
typedef void (*A2GlFrameCallback)(void *user);

typedef struct A2GlHostSurface {
    A2GlfwSurface      surface;        ///< 原生窗口句柄 + 像素格式 + 尺寸（A2GlfwSurface 本体）
    const char        *rendererName;   ///< 已选渲染器名（dylib 文件名；空/nil ⇒ 按未选处理）
    A2GlFrameCallback  frameCallback;  ///< 每帧回调（可空）
    void              *frameUser;      ///< 帧回调的透传参数
} A2GlHostSurface;

// ---------------------------------------------------------------------------
// 返回码（★区分「不归我管」与「该管但没管成」★ —— 前者不阻断，后者阻断）
// ---------------------------------------------------------------------------
enum {
    A2GlBridgeOK              =  0,  ///< 已建出可用的 GL 上下文（且已渲染过一帧）
    A2GlBridgeSkipped         =  1,  ///< 该后端不是 EGL/GL 系 ⇒ 本层不负责（调用方**不阻断**）
    A2GlBridgeErrMissingLib   = -1,  ///< 包内缺该后端/兼容底所需的库文件（未内置）
    A2GlBridgeErrLoadFailed   = -2,  ///< 库文件在但 dlopen 失败（原因见日志行）
    A2GlBridgeErrNoSurface    = -3,  ///< 宿主未给出有效的原生窗口句柄
    A2GlBridgeErrEgl          = -4,  ///< EGL display/config/context/surface 建面失败（或取不到 GL 入口）
};

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/// 该后端是否属 EGL/GL 系（= 本层负责建面的那类）。
/// 纯逻辑（不碰文件/不 dlopen/不碰 EGL）⇒ 可在无 EGL 的机器（如 macOS 单测）上直接判。
/// 调用点：`a2_gl_bridge_attach`（内部先判）+ tests/Natives。
int a2_gl_bridge_backend_is_egl(const char *rendererName);

/// 依据 `host->rendererName` 去 `<frameworksPath>/` 加载对应库、建 EGL display/context/surface、
/// 取函数指针表，并渲染**一帧**（帧内做一次 `glClear` 作为可判据的可用性证据）。
///
/// @param host           中立宿主/表面（见 A2GlHostSurface；`rendererName` 只在本次调用内使用）
/// @param frameworksPath `<App>/Frameworks`（与 `-Djava.library.path` 同一目录）
/// @return 见上方返回码枚举。OK(0)=可用；Skipped(1)=不归本层管（调用方不阻断）；负值=该管没管成（调用方阻断）。
int a2_gl_bridge_attach(const A2GlHostSurface *host, NSString *frameworksPath);

#endif /* A2_GL_BRIDGE_H */

// ============================================================================
//  Natives/Renderer/a2_renderer.h
//  Air2 —— 渲染后端「显式选择 + 加载」的单一入口
// ----------------------------------------------------------------------------
//  分层：本文件属 Natives/Renderer（见 docs/ARCHITECTURE.md §Natives：
//        「Renderer/ — Metal 层管理、EGL/GL 桥、surface 生命周期」）。
//
//  单一职责：本文件【只做「选哪个渲染后端 dylib」+「把它 dlopen 起来」】。
//    · 不解析版本/账号（那是 Core 的业务）；
//    · 不拼路径（frameworksPath 由上层按 §3.4 单点拼装后传入，与
//      `-Djava.library.path` 同一目录）；
//    · 不含任何 Metal/GL 具体逻辑（那是 libmetallum.dylib 自己的事）。
//
//  ★为什么需要它（接线缺口）★：libmetallum.dylib 虽随包（[RT-BUNDLE]），但启动链里
//    **没有任何一步引用它** —— 出包后主二进制里扫不到这个渲染器名。本文件把
//    「选 + 加载」这一步显式化，调用点唯一：`Air2/Bridge/A2LaunchRunner.m`
//    （Bridge 是唯一与 Natives 相邻的层，同 [LAUNCH-PLAN] 决策 2）。
//
//  ★开关★：无独立开关 —— 本函数只在自研启动链里被调用，而那条链整体由
//    `debug.rt_p1_runtime`（默认关）决定 ⇒ 开箱行为不变（见 docs/ARCHITECTURE.md [RENDER-WIRE]）。
// ============================================================================
#ifndef A2_RENDERER_H
#define A2_RENDERER_H

#import <Foundation/Foundation.h>

/// ★主推渲染后端★（自研 Metal）的 dylib 文件名。
/// ★判据锚点★：出包后应能在主二进制里扫到本串，作为「启动路径真的引用渲染器」的机器判据。
/// 对应随仓物 `Libraries/Renderers/libmetallum.dylib` → `<App>/Frameworks/`（见 [RT-BUNDLE]）。
extern const char *const A2RendererMetalDylibName;

/// ★兼容底渲染后端★（GL4ES：旧版 MC 的 GL→GLES 转译层）的 dylib 文件名。
/// 对应随仓物 `Libraries/Renderers/libgl4es_114.dylib` → `<App>/Frameworks/`（见 [RENDER-SEL]）。
/// 取值与老线 `runtime_native/Natives/utils.h` 的 `RENDERER_NAME_GL4ES` 逐字相同（同一份血统）。
extern const char *const A2RendererCompatDylibName;

/// ★宿主 EGL 后端（系统 GLES 3.0 / EAGL）★ 的标识 = `libeagl.dylib`。
///
/// ★它不是包内的库★：EGL 那一半（假 EGL 1.4 子集 → EAGLContext/CAEAGLLayer）
/// 就编在本二进制里（`Natives/Renderer/a2_eagl_egl.m`），GL 层是 MobileGlues。
/// 与 Core 的 `A2RendererHostEGLDylibName`（`Air2/Core/Renderer/A2RendererCatalog.h`）
/// 逐字相同 —— Natives 不认识 Core、Core 也反向依赖不了本层，所以是**同一份字面量的两处声明**
/// （与 `A2GlBridgeKryptonDylibName` 同一做法；`tests/Runtime` 有「两处必须一致」的断言）。
/// 取值即 `A2SelectedRendererPrefKey` 存进 NSUserDefaults 的值。
extern const char *const A2RendererHostEAGLDylibName;

/// 显式选择并加载指定渲染后端（`<frameworksPath>/<dylibName>`）。
///
/// ★调用点唯一★：`Air2/Bridge/A2LaunchRunner.m` 的 `+launchWithPlanPath:…`。
/// 谁决定 dylibName：`Air2/Player/A2LaunchSession.m`（读 NSUserDefaults 的
/// `A2SelectedRendererPrefKey`，缺省回落主推 `A2RendererMetalDylibName`）。
///
/// 幂等：重复调用安全（dyld 对已加载镜像返回同一 handle）。
/// 不致死：任何一步失败都只打默认可见日志并返回负值，绝不 abort/抛异常。
///
/// @param dylibName   渲染后端 dylib 的文件名；空/nil ⇒ 按主推（`A2RendererMetalDylibName`）处理。
/// @param frameworksPath `<App>/Frameworks`（与 `-Djava.library.path` 同一目录）。
/// @return 0 = 已加载（或此前已加载）；
///         -1 = ★包内缺该 dylib（未内置）★；
///         -2 = frameworksPath 为空（上层未解析出 `<App>/Frameworks`）；
///         -3 = dlopen 失败（文件在但加载不起来，原因见日志行）。
int a2_renderer_load_named(NSString *dylibName, NSString *frameworksPath);

/// 显式选择并加载 Metal 渲染后端（`<frameworksPath>/<A2RendererMetalDylibName>`）。
///
/// ★历史语义保持★（返回码与日志串不动作）：
/// 幂等：重复调用安全（dyld 对已加载镜像返回同一 handle）。
/// 不致死：任何一步失败都只打默认可见日志并返回 -1，绝不 abort/抛异常。
///
/// @param frameworksPath `<App>/Frameworks`（与 `-Djava.library.path` 同一目录）；空 ⇒ 直接判失败。
/// @return 0 = 已加载（或此前已加载）；-1 = 未找到 / 加载失败（原因见日志行）。

#endif /* A2_RENDERER_H */

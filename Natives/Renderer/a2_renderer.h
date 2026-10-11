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
/// 对应随包物 `Libraries/Renderers/libmetallum.dylib` → `<App>/Frameworks/`（见 [RT-BUNDLE]）。
extern const char *const A2RendererMetalDylibName;

/// 显式选择并加载 Metal 渲染后端（`<frameworksPath>/<A2RendererMetalDylibName>`）。
///
/// 幂等：重复调用安全（dyld 对已加载镜像返回同一 handle）。
/// 不致死：任何一步失败都只打默认可见日志并返回 -1，绝不 abort/抛异常。
///
/// @param frameworksPath `<App>/Frameworks`（与 `-Djava.library.path` 同一目录）；空 ⇒ 直接判失败。
/// @return 0 = 已加载（或此前已加载）；-1 = 未找到 / 加载失败（原因见日志行）。
int a2_renderer_load_metal(NSString *frameworksPath);

#endif /* A2_RENDERER_H */

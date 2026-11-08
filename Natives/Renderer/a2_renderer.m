// ============================================================================
//  Natives/Renderer/a2_renderer.m
//  Air2 —— 渲染后端「显式选择 + 加载」实现（见同名头文件的职责说明）
// ----------------------------------------------------------------------------
//  实现要点：
//    · dlopen 旗标对齐老链的既有做法（Natives/egl_bridge.m 加载渲染器用 RTLD_GLOBAL，
//      不强制 RTLD_NOW）—— 惰性绑定避免因个别未用到的符号而整库加载失败；
//    · 只 dlopen，不 dlsym 任何函数名：本层不认识渲染器的内部符号（那是它自己的接口），
//      猜符号名会把「接线」变成「猜契约」；
//    · ★「未内置」与「加载失败」分开报★：前者是构建产物缺件（用户要能看懂缺什么），
//      后者是文件在但 dlopen 拒了（dlerror 有原文）—— 两种都阻断启动，但不混为一谈。
// ============================================================================
#import "a2_renderer.h"
#import "a2_log.h"
#import "a2_sfpew_host.h" // ★[A2-SFPEW] 固定管线档位★：本层只校验存在，加载归 GL 桥（RTLD_LOCAL）

#include <dlfcn.h>
#include <string.h>   // strcmp（宿主 EGL 后端的精确比较）

const char *const A2RendererMetalDylibName   = "libmetallum.dylib";
const char *const A2RendererCompatDylibName  = "libgl4es_114.dylib";
const char *const A2RendererHostEAGLDylibName = "libeagl.dylib";

int a2_renderer_load_named(NSString *dylibName, NSString *frameworksPath) {
    // 空名 ⇒ 主推（上层没给就是「没选」，按主推走；判据行由 A2LaunchSession 打明来源）。
    NSString *name = (dylibName.length > 0)
        ? dylibName
        : [NSString stringWithUTF8String:A2RendererMetalDylibName];

    // ★EAGL（宿主假 EGL）已于 2026-11-08 彻底移除★：不再有 `libeagl.dylib` 这一档，
    //   EGL 层一律来自后端库（MG / ANGLE）。走到这里只可能是旧配置残留 ⇒ 如实拒绝，
    //   而不是静默回退成别的渲染器（那会让人以为选的是 A，实际跑的是 B）。
    if (strcmp(name.UTF8String, A2RendererHostEAGLDylibName) == 0) {
        a2_log_f(@"[A2-RENDERER] ★已移除★ 宿主 EAGL 渲染器（%s）不再支持；请在设置里改选 Metal / MobileGlues",
                 name.UTF8String);
        return -2;
    }

    if (frameworksPath.length == 0) {
        a2_log_f(@"[A2-RENDERER] 渲染后端未选择：frameworksPath 为空（上层未解析出 <App>/Frameworks）");
        return -2;
    }

    NSString *path = [frameworksPath stringByAppendingPathComponent:name];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // ★未内置★：如实报「缺哪个文件、期望在哪」——不静默回退到别的渲染器。
        a2_log_f(@"[A2-RENDERER] 渲染后端未内置：包内缺 %s（期望 %s）⇒ 阻断启动",
                 name.UTF8String, path.UTF8String);
        return -1;
    }

    // ★[A2-SFPEW] 固定管线档位：★本层不 dlopen★ —— 上游接入契约要求 `dlopen(RTLD_LOCAL)`，且
    //   加载点唯一 = `a2_sfpew_host_load`（`a2_gl_bridge_attach` 的 ①c，在建 EGL 面之前）。
    //   本函数恒用 RTLD_GLOBAL ⇒ 会把它的 567 个 `gl*` 推进 flat namespace，和兼容底的解析抢符号
    //   （契约②明确禁止）。文件存在性已由上面那条判据兜住（缺件仍按未内置阻断）。
    if (strcmp(name.UTF8String, A2SFPEWHostDylibName) == 0) {
        a2_log_f(@"[A2-RENDERER] 已选择 SFPEW 档位：%s（本层不 dlopen —— 由 GL 桥以 RTLD_LOCAL 加载）",
                 path.UTF8String);
        return 0;
    }

    // RTLD_GLOBAL：与老链一致（渲染器符号需对后续 dlopen 的库可见）。
    /* ★RTLD_NOW★：渲染器可能是 Swift 写的（libmetallum 强依赖 libswiftCore）
       ⇒ 延迟绑定会让 Swift 元数据在首次发消息时才解析，解析不到就 objc brk（.ips 实证 SIGTRAP@realizeClassWithoutSwift） */
    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (handle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"[A2-RENDERER] 渲染后端 dlopen 失败：%s（%s）", path.UTF8String, err ? err : "(dlerror 无输出)");
        return -3;
    }

    a2_log_f(@"[A2-RENDERER] 已显式选择并加载渲染后端：%s <- %s handle=%p",
             name.UTF8String, path.UTF8String, handle);
    return 0;
}


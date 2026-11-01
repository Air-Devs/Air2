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
#import "a2_eagl_egl.h"   // ★宿主 EGL 后端★：选到它时由本层接管进程里的 egl*
#import "a2_sfpew_host.h" // ★[A2-SFPEW] 固定管线档位★：本层只校验存在，加载归 GL 桥（RTLD_LOCAL）

#include <dlfcn.h>
#include <stdlib.h>   // getenv（加载模式开关 A2_GL_RTLD）
#include <string.h>   // strcmp（宿主 EGL 后端的精确比较）

const char *const A2RendererMetalDylibName   = "libmetallum.dylib";
const char *const A2RendererCompatDylibName  = "libgl4es_114.dylib";
const char *const A2RendererHostEAGLDylibName = "libeagl.dylib";

int a2_renderer_uses_global_rtld(void) {
    const char *v = getenv("A2_GL_RTLD");
    if (v == NULL || v[0] == '\0') return 0;   // 默认 LOCAL
    return (strcmp(v, "global") == 0 || strcmp(v, "GLOBAL") == 0 || strcmp(v, "1") == 0);
}

int a2_renderer_dlopen_flags(void) {
    return RTLD_LAZY | (a2_renderer_uses_global_rtld() ? RTLD_GLOBAL : RTLD_LOCAL);
}

int a2_renderer_load_named(NSString *dylibName, NSString *frameworksPath) {
    // 空名 ⇒ 主推（上层没给就是「没选」，按主推走；判据行由 A2LaunchSession 打明来源）。
    NSString *name = (dylibName.length > 0)
        ? dylibName
        : [NSString stringWithUTF8String:A2RendererMetalDylibName];

    // ★宿主 EGL 后端（系统 GLES 3.0 / EAGL）★：没有包内 dylib 可 dlopen —— 这一层的 EGL
    //   就编在主二进制里。这里做的是「宣告接管 + 如实记一行」，返回 0（= 已就绪），
    //   ★不是「跳过加载」★：`a2_eagl_egl_engage()` 之后本进程的 egl* 才真的走本层
    //   （之前一律让路给真 EGL）；GL 层（MobileGlues）由 GL 桥按同一标识加载。
    if (strcmp(name.UTF8String, A2RendererHostEAGLDylibName) == 0) {
        a2_eagl_egl_engage();
        a2_log_f(@"[A2-RENDERER] 已选择宿主 EGL 后端：%s（EGL=本二进制假 EGL，engaged=%d；"
                 @"包内无此 dylib 是设计如此，GL 层由 GL 桥加载）",
                 name.UTF8String, (int)a2_eagl_egl_is_engaged());
        return 0;
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
    //   本层的统一旗标对它是错的口径（它恒为 RTLD_LOCAL，且 567 个 gl* 不许进 flat namespace）。
    if (strcmp(name.UTF8String, A2SFPEWHostDylibName) == 0) {
        a2_log_f(@"[A2-RENDERER] 已选择 SFPEW 档位：%s（本层不 dlopen —— 由 GL 桥以 RTLD_LOCAL 加载）",
                 path.UTF8String);
        return 0;
    }

    // ★加载旗标★：默认 `RTLD_LOCAL`（`a2_renderer_dlopen_flags()` 的唯一产地）——
    //   渲染器的 `gl*`/`egl*` 不进进程 flat namespace；下游各自按句柄解析
    //   （MG 靠 `MG_DIRECTORY_PATH` 自己 dlopen ANGLE，LWJGL 靠 `org.lwjgl.opengl.libname`）。
    //   回退：环境变量 `A2_GL_RTLD=global`（不用重编）。
    void *handle = dlopen(path.UTF8String, a2_renderer_dlopen_flags());
    if (handle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"[A2-RENDERER] 渲染后端 dlopen 失败：%s（%s）", path.UTF8String, err ? err : "(dlerror 无输出)");
        return -3;
    }

    a2_log_f(@"[A2-RENDERER] 已显式选择并加载渲染后端：%s <- %s handle=%p",
             name.UTF8String, path.UTF8String, handle);
    return 0;
}


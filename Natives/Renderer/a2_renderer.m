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

#include <dlfcn.h>

const char *const A2RendererMetalDylibName  = "libmetallum.dylib";
const char *const A2RendererCompatDylibName = "libgl4es_114.dylib";

int a2_renderer_load_named(NSString *dylibName, NSString *frameworksPath) {
    // 空名 ⇒ 主推（上层没给就是「没选」，按主推走；判据行由 A2LaunchSession 打明来源）。
    NSString *name = (dylibName.length > 0)
        ? dylibName
        : [NSString stringWithUTF8String:A2RendererMetalDylibName];

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

    // RTLD_GLOBAL：与老链一致（渲染器符号需对后续 dlopen 的库可见）。
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"[A2-RENDERER] 渲染后端 dlopen 失败：%s（%s）", path.UTF8String, err ? err : "(dlerror 无输出)");
        return -3;
    }

    a2_log_f(@"[A2-RENDERER] 已显式选择并加载渲染后端：%s <- %s handle=%p",
             name.UTF8String, path.UTF8String, handle);
    return 0;
}


// ============================================================================
//  Natives/Renderer/a2_renderer.m
//  Air2 —— 渲染后端「显式选择 + 加载」实现（见同名头文件的职责说明）
// ----------------------------------------------------------------------------
//  实现要点：
//    · dlopen 旗标对齐老链的既有做法（Natives/egl_bridge.m 加载渲染器用 RTLD_GLOBAL，
//      不强制 RTLD_NOW）—— 惰性绑定避免因个别未用到的符号而整库加载失败；
//    · 只 dlopen，不 dlsym 任何函数名：本层不认识渲染器的内部符号（那是它自己的接口），
//      猜符号名会把「接线」变成「猜契约」。
// ============================================================================
#import "a2_renderer.h"
#import "a2_log.h"

#include <dlfcn.h>

const char *const A2RendererMetalDylibName = "libmetallum.dylib";

int a2_renderer_load_metal(NSString *frameworksPath) {
    if (frameworksPath.length == 0) {
        a2_log_f(@"[A2-RENDERER] Metal 后端未选择：frameworksPath 为空（上层未解析出 <App>/Frameworks）");
        return -1;
    }

    NSString *path = [frameworksPath stringByAppendingPathComponent:
                      [NSString stringWithUTF8String:A2RendererMetalDylibName]];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        a2_log_f(@"[A2-RENDERER] Metal 后端未加载：包内缺 %s（期望 %s）", A2RendererMetalDylibName, path.UTF8String);
        return -1;
    }

    // RTLD_GLOBAL：与老链一致（渲染器符号需对后续 dlopen 的库可见）。
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"[A2-RENDERER] Metal 后端 dlopen 失败：%s（%s）", path.UTF8String, err ? err : "(dlerror 无输出)");
        return -1;
    }

    a2_log_f(@"[A2-RENDERER] 已显式选择并加载 Metal 后端：%s <- %s handle=%p",
             A2RendererMetalDylibName, path.UTF8String, handle);
    return 0;
}

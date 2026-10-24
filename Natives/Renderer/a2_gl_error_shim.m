// ============================================================================
//  Natives/Renderer/a2_gl_error_shim.m
//  Air2 —— ★MobileGlues 的 glGetError 保护★
// ----------------------------------------------------------------------------
//  真机证据（26.2 + MobileGlues）：
//    # A fatal error has been detected by the Java Runtime Environment:
//    10  libmobileglues.dylib  0x…  glGetError + 24      ← SIGSEGV
//     4  libjvm.dylib  os::abort
//  即 MG 的 glGetError 在它的跳转表就绪前被调用 ⇒ 直接崩（黑屏其实是被 abort）。
//  我们自己的帧回调早就在 MG 下跳过它了（a2_gl_bridge.m），但 MC/LWJGL 自己调的
//  那次不经过我们 ⇒ 这里在 dlsym 层拦一刀：MG 后备下把 "glGetError" 解析成
//  返回 0 的桩（GL 错误码本来就只是诊断用途，跳过不影响渲染正确性）。
//
//  安全性：
//    · 只有 gA2GlErrorShimEnabled=1（= 当前后端是 MobileGlues）时才替换；
//    · 其它后端/其它符号一律原样交给系统 dlsym。
// ============================================================================

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string.h>

extern int gA2GlErrorShimEnabled;

static unsigned int a2_glGetError_stub(void) {
    return 0;   // GL_NO_ERROR
}

// 真正的 dlsym：用 dlvsym 取（dlvsym 不在我们的 interpose 列表里，不会递归）
static void *(*a2_real_dlsym)(void *, const char *);
static dispatch_once_t a2_once;

static void a2_shim_init(void) {
    a2_real_dlsym = (void *(*)(void *, const char *))dlvsym(RTLD_NEXT, "dlsym", NULL);
    if (a2_real_dlsym == NULL) {
        a2_real_dlsym = (void *(*)(void *, const char *))dlvsym(RTLD_DEFAULT, "dlsym", NULL);
    }
}

__attribute__((used))
static void *a2_dlsym_interposed(void *handle, const char *symbol) {
    dispatch_once(&a2_once, ^{ a2_shim_init(); });
    if (symbol != NULL && a2_real_dlsym != NULL) {
        if (gA2GlErrorShimEnabled && strcmp(symbol, "glGetError") == 0) {
            return (void *)a2_glGetError_stub;
        }
        return a2_real_dlsym(handle, symbol);
    }
    return NULL;
}

// dyld 级 interpose（不需要 fishhook；对 dlopen 进来的镜像同样生效）
__attribute__((used))
static struct {
    const void *replacement;
    const void *replacee;
} a2_dlsym_interpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&a2_dlsym_interposed,
    (const void *)&dlsym
};

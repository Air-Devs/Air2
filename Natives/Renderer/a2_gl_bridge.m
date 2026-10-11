// ============================================================================
//  Natives/Renderer/a2_gl_bridge.m
//  Air2 —— ★GL 桥★实现（职责/边界见同名头文件）
// ----------------------------------------------------------------------------
//  实现要点：
//    · 只用 dlopen/dlsym 取库与符号 —— 不把 EGL/GLES/GL4ES **链接**进主二进制
//      （它们随包在 Frameworks/，运行期按 `-Djava.library.path` 同一目录解析）；
//      因此本文件不 import 任何 EGL/GL 头，只按 Khronos 公开 ABI 自声明最小类型
//      （EGLDisplay=void* 等 + 常量数值，属事实性接口约定，非任何实现搬运）。
//    · 兼容底（EGL/GLES + GL4ES）的 rpath 已指向 `@executable_path/Frameworks`
//      （见随仓件 LC_LOAD_DYLIB：libgl4es → @rpath/libEGL.framework/libEGL、
//      @rpath/libGLESv2.framework/libGLESv2）⇒ 只要三者同目录即可解析。
//    · 归一化「可渲染句柄」：宿主给的是承载视图（UIView）时取其 `layer`
//      （★通用 CALayer，非 Metal 专有★）；已是 CALayer 的对象原样使用。
//      ★本层不 import UIKit/QuartzCore/Metal★ —— 只经 ObjC 运行时取 `layer`。
//    · 一切失败只**记日志 + 返回码**，绝不 abort/抛异常；上层据此如实阻断。
//
//  净室：本文件按 EGL/Khronos 公开行为约定与 Apple 公开文档独立编写，
//        只**读**老线（runtime_native）的既有约定（EGLNativeWindowType 取 layer 的
//        行为事实），未复制其任何代码。
// ============================================================================
#import "a2_gl_bridge.h"
#import "a2_log.h"

#import <objc/message.h>   // objc_msgSend（动态取 layer 用；不 import UIKit）
#import <dlfcn.h>
#include <string.h>
#include <stdint.h>

// ---------------------------------------------------------------------------
// 常量（判据锚点 / 库相对路径）
// ---------------------------------------------------------------------------
const char *const A2GlBridgeJudgementTag        = "[A2-GLBRIDGE]";
const char *const A2GlBridgeEglLibraryRelPath   = "libEGL.framework/libEGL";
const char *const A2GlBridgeGlesLibraryRelPath  = "libGLESv2.framework/libGLESv2";

// ---------------------------------------------------------------------------
// EGL/GL 最小类型与常量（Khronos 公开 ABI 的事实性数值；本层不 import 其头文件）
// ---------------------------------------------------------------------------
typedef void     *A2EGLDisplay;
typedef void     *A2EGLConfig;
typedef void     *A2EGLContext;
typedef void     *A2EGLSurface;
typedef void     *A2EGLNativeWindowType;
typedef int32_t   A2EGLint;
typedef uint32_t  A2EGLBoolean;
typedef uint32_t  A2EGLenum;

typedef A2EGLDisplay  (*A2PFN_eglGetDisplay)(void *displayId);
typedef A2EGLBoolean  (*A2PFN_eglInitialize)(A2EGLDisplay, A2EGLint *, A2EGLint *);
typedef A2EGLBoolean  (*A2PFN_eglBindAPI)(A2EGLenum);
typedef A2EGLBoolean  (*A2PFN_eglChooseConfig)(A2EGLDisplay, const A2EGLint *, A2EGLConfig *, A2EGLint, A2EGLint *);
typedef A2EGLContext  (*A2PFN_eglCreateContext)(A2EGLDisplay, A2EGLConfig, A2EGLContext, const A2EGLint *);
typedef A2EGLSurface  (*A2PFN_eglCreateWindowSurface)(A2EGLDisplay, A2EGLConfig, A2EGLNativeWindowType, const A2EGLint *);
typedef A2EGLBoolean  (*A2PFN_eglMakeCurrent)(A2EGLDisplay, A2EGLSurface, A2EGLSurface, A2EGLContext);
typedef A2EGLBoolean  (*A2PFN_eglSwapBuffers)(A2EGLDisplay, A2EGLSurface);
typedef A2EGLint      (*A2PFN_eglGetError)(void);
typedef void         *(*A2PFN_eglGetProcAddress)(const char *);
typedef A2EGLBoolean  (*A2PFN_eglDestroySurface)(A2EGLDisplay, A2EGLSurface);
typedef A2EGLBoolean  (*A2PFN_eglDestroyContext)(A2EGLDisplay, A2EGLContext);
typedef A2EGLBoolean  (*A2PFN_eglTerminate)(A2EGLDisplay);

typedef void      (*A2PFN_glClear)(uint32_t);
typedef void      (*A2PFN_glClearColor)(float, float, float, float);
typedef uint32_t  (*A2PFN_glGetError)(void);

#define A2_EGL_DEFAULT_DISPLAY       ((void *)0)
#define A2_EGL_NO_DISPLAY            ((A2EGLDisplay)0)
#define A2_EGL_NO_CONTEXT            ((A2EGLContext)0)
#define A2_EGL_NO_SURFACE            ((A2EGLSurface)0)
#define A2_EGL_SUCCESS               0x3000
#define A2_EGL_OPENGL_ES_API         0x30A0
#define A2_EGL_OPENGL_ES2_BIT        0x0004
#define A2_EGL_SURFACE_TYPE          0x3033
#define A2_EGL_WINDOW_BIT            0x0004
#define A2_EGL_RENDERABLE_TYPE       0x3040
#define A2_EGL_RED_SIZE              0x3024
#define A2_EGL_GREEN_SIZE            0x3023
#define A2_EGL_BLUE_SIZE             0x3022
#define A2_EGL_ALPHA_SIZE            0x3021
#define A2_EGL_DEPTH_SIZE            0x3025
#define A2_EGL_STENCIL_SIZE          0x3026
#define A2_EGL_NONE                  0x3038
#define A2_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define A2_EGL_WIDTH                 0x3057
#define A2_EGL_HEIGHT                0x3056
#define A2_GL_COLOR_BUFFER_BIT       0x00004000

// ---------------------------------------------------------------------------
// 桥状态（一次性：attach 成功后驻留到进程结束/再次 attach）
// ---------------------------------------------------------------------------
static void *gEglHandle  = NULL;
static void *gGlesHandle = NULL;
static void *gRendererHandle = NULL;   // 后端本体（compat 底 = libgl4es_114.dylib）

static A2EGLDisplay gDpy = A2_EGL_NO_DISPLAY;
static A2EGLConfig  gCfg = NULL;
static A2EGLContext gCtx = A2_EGL_NO_CONTEXT;
static A2EGLSurface gSurf = A2_EGL_NO_SURFACE;

static A2PFN_eglGetDisplay        gEglGetDisplay = NULL;
static A2PFN_eglInitialize        gEglInitialize = NULL;
static A2PFN_eglBindAPI           gEglBindAPI = NULL;
static A2PFN_eglChooseConfig      gEglChooseConfig = NULL;
static A2PFN_eglCreateContext     gEglCreateContext = NULL;
static A2PFN_eglCreateWindowSurface gEglCreateWindowSurface = NULL;
static A2PFN_eglMakeCurrent       gEglMakeCurrent = NULL;
static A2PFN_eglSwapBuffers       gEglSwapBuffers = NULL;
static A2PFN_eglGetError          gEglGetError = NULL;
static A2PFN_eglGetProcAddress    gEglGetProcAddress = NULL;
static A2PFN_eglDestroySurface    gEglDestroySurface = NULL;
static A2PFN_eglDestroyContext    gEglDestroyContext = NULL;
static A2PFN_eglTerminate         gEglTerminate = NULL;

static A2PFN_glClear      gGLClear = NULL;
static A2PFN_glClearColor gGLClearColor = NULL;
static A2PFN_glGetError   gGLGetError = NULL;

static int   gAttached = 0;
static int   gFrameCount = 0;
static int   gWidthPixels = 0;
static int   gHeightPixels = 0;
static A2GlFrameCallback gFrameCb = NULL;
static void *gFrameUser = NULL;

// ============================================================================
//  内部：清理 / 归一化句柄 / 取符号 / 帧动作
// ============================================================================

/// 释放本层持有的 EGL/GL 资源与 dylib 句柄（幂等）。
/// 调用点：attach 的「已附着」重入路径 + 各失败路径（不留半成品）。
static void a2_gl_bridge_teardown(void) {
    if (gEglMakeCurrent != NULL && gDpy != A2_EGL_NO_DISPLAY) {
        gEglMakeCurrent(gDpy, A2_EGL_NO_SURFACE, A2_EGL_NO_SURFACE, A2_EGL_NO_CONTEXT);
    }
    if (gEglDestroySurface != NULL && gDpy != A2_EGL_NO_DISPLAY && gSurf != A2_EGL_NO_SURFACE) {
        gEglDestroySurface(gDpy, gSurf);
    }
    if (gEglDestroyContext != NULL && gDpy != A2_EGL_NO_DISPLAY && gCtx != A2_EGL_NO_CONTEXT) {
        gEglDestroyContext(gDpy, gCtx);
    }
    if (gEglTerminate != NULL && gDpy != A2_EGL_NO_DISPLAY) {
        gEglTerminate(gDpy);
    }
    if (gRendererHandle != NULL) { dlclose(gRendererHandle); gRendererHandle = NULL; }
    if (gGlesHandle != NULL)     { dlclose(gGlesHandle);     gGlesHandle = NULL; }
    if (gEglHandle != NULL)      { dlclose(gEglHandle);      gEglHandle = NULL; }

    gDpy = A2_EGL_NO_DISPLAY; gCfg = NULL;
    gCtx = A2_EGL_NO_CONTEXT; gSurf = A2_EGL_NO_SURFACE;
    gEglGetDisplay = NULL; gEglInitialize = NULL; gEglBindAPI = NULL;
    gEglChooseConfig = NULL; gEglCreateContext = NULL; gEglCreateWindowSurface = NULL;
    gEglMakeCurrent = NULL; gEglSwapBuffers = NULL; gEglGetError = NULL;
    gEglGetProcAddress = NULL; gEglDestroySurface = NULL; gEglDestroyContext = NULL;
    gEglTerminate = NULL;
    gGLClear = NULL; gGLClearColor = NULL; gGLGetError = NULL;
    gAttached = 0; gFrameCount = 0;
    gFrameCb = NULL; gFrameUser = NULL;
    gWidthPixels = 0; gHeightPixels = 0;
}

/// 把宿主的「承载视图」归一化成 EGL 期望的可渲染句柄（layer）。
/// 为什么经 ObjC 运行时而不是 import UIKit/QuartzCore：本层要保持中立
/// （不认识 UIKit，也不认识任何图形后端）；`layer` 是通用 Core Animation 概念。
static void *a2_gl_bridge_renderable_handle(void *nativeView) {
    if (nativeView == NULL) return NULL;
    id obj = (__bridge id)nativeView;
    SEL layerSel = NSSelectorFromString(@"layer");
    if (obj != nil && [obj respondsToSelector:layerSel]) {
        id (*sendLayer)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id layer = sendLayer(obj, layerSel);
        if (layer != nil) return (__bridge void *)layer;
    }
    return nativeView;   // 本来就是 layer（或别的可渲染对象）⇒ 原样使用
}

/// 从 EGL 库取一个**必需**符号；缺则记名并返回 NULL。
static void *a2_gl_bridge_egl_symbol(void *handle, const char *name, int *missing) {
    void *sym = dlsym(handle, name);
    if (sym == NULL && missing != NULL) {
        a2_log_f(@"%s ★阻断★：EGL 兼容底缺符号 %s（dlopen 成功但取不到 ⇒ 该库不是可用实现）",
                 A2GlBridgeJudgementTag, name);
        *missing = 1;
    }
    return sym;
}

/// ★帧回调体★：本层每帧做一次可判据的可用性动作 —— `glClear`（+ `eglSwapBuffers`），
/// 再回调宿主提供的 frameCallback（若给了）。调用点：a2_gl_bridge_attach（附着后立即渲染一帧）。
///
/// 为什么清成透明 (0,0,0,0) 而不是实色：宿主表面当前是承载游戏的宿主窗口，
/// 实色清屏会让 UI 整块变黑（可见破坏）；透明清屏同样能证明「上下文可用」，
/// 且视觉上通常无变化 —— 证据由本函数的判据行 + glGetError 承担。
static void a2_gl_bridge_frame_work(void) {
    if (!gAttached) return;

    gFrameCount++;
    uint32_t glErr = 0;

    if (gGLClearColor != NULL) gGLClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    if (gGLClear != NULL)      gGLClear(A2_GL_COLOR_BUFFER_BIT);
    if (gEglSwapBuffers != NULL) gEglSwapBuffers(gDpy, gSurf);
    if (gGLGetError != NULL)   glErr = gGLGetError();

    a2_log_f(@"%s 帧回调 #%d 已执行 glClear（color=0,0,0,0；%dx%d 像素）glGetError=0x%x ⇒ %s（surface=%p）",
             A2GlBridgeJudgementTag, gFrameCount, gWidthPixels, gHeightPixels, (unsigned)glErr,
             (glErr == 0) ? @"GL 上下文可用" : @"★GL 上下文报错★",
             (void *)gSurf);

    if (gFrameCb != NULL) gFrameCb(gFrameUser);
}

// ============================================================================
//  公开 API
// ============================================================================

int a2_gl_bridge_backend_is_egl(const char *rendererName) {
    if (rendererName == NULL || rendererName[0] == '\0') return 0;
    // ★后端词汇表唯一来源是 a2_renderer.h 的常量★（不重复字面量）。
    // 将来多一个 EGL/GL 系后端 ⇒ 只在这里加一行比较。
    return (strcmp(rendererName, A2RendererCompatDylibName) == 0) ? 1 : 0;
}

int a2_gl_bridge_attach(const A2GlHostSurface *host, NSString *frameworksPath) {
    if (host == NULL) {
        a2_log_f(@"%s ★阻断★：宿主表面为空（调用方未传 host）", A2GlBridgeJudgementTag);
        return A2GlBridgeErrNoSurface;
    }

    const char *rendererName = host->rendererName;

    // ---- ① 后端判定：不是 EGL/GL 系 ⇒ 本层不负责（★不阻断、也不替换成别的后端★）----
    if (!a2_gl_bridge_backend_is_egl(rendererName)) {
        a2_log_f(@"%s 后端判定：selected=%s ⇒ 非 EGL/GL 系，本桥不负责其建面（跳过；其建面归该后端自身）",
                 A2GlBridgeJudgementTag,
                 (rendererName != NULL && rendererName[0] != '\0') ? rendererName : "(未选/空)");
        return A2GlBridgeSkipped;
    }
    a2_log_f(@"%s 后端判定：selected=%s ⇒ EGL/GL 系，本桥负责建面", A2GlBridgeJudgementTag, rendererName);

    // ---- 重入：先彻底清掉上一次（不留半成品）----
    if (gAttached) {
        a2_log_f(@"%s 已附着 ⇒ 先释放上一次的 EGL/GL 资源再重建", A2GlBridgeJudgementTag);
        a2_gl_bridge_teardown();
    }

    // ---- ② 原生窗口句柄 ----
    void *renderable = a2_gl_bridge_renderable_handle(host->surface.nativeView);
    if (renderable == NULL) {
        a2_log_f(@"%s ★阻断★：宿主未给出原生窗口句柄（nativeView=NULL；表面=%dx%d 点/%dx%d 像素）⇒ 无法建面",
                 A2GlBridgeJudgementTag,
                 host->surface.widthPoints, host->surface.heightPoints,
                 host->surface.widthPixels, host->surface.heightPixels);
        return A2GlBridgeErrNoSurface;
    }

    // ---- ③ 库路径（三段：EGL 兼容底 / GLES 兼容底 / 后端本体），逐个查存在 ----
    if (frameworksPath.length == 0) {
        a2_log_f(@"%s ★阻断★：frameworksPath 为空（上层未解析出 <App>/Frameworks）⇒ 无法定位兼容底",
                 A2GlBridgeJudgementTag);
        return A2GlBridgeErrMissingLib;
    }
    NSString *eglPath      = [frameworksPath stringByAppendingPathComponent:
                              [NSString stringWithUTF8String:A2GlBridgeEglLibraryRelPath]];
    NSString *glesPath     = [frameworksPath stringByAppendingPathComponent:
                              [NSString stringWithUTF8String:A2GlBridgeGlesLibraryRelPath]];
    NSString *rendererPath = [frameworksPath stringByAppendingPathComponent:
                              [NSString stringWithUTF8String:rendererName]];

    NSArray<NSString *> *needed = @[ eglPath, glesPath, rendererPath ];
    for (NSString *p in needed) {
        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir] || isDir) {
            a2_log_f(@"%s ★阻断★：包内缺该后端所需的库 %s（未内置）⇒ 不静默回退到默认渲染器",
                     A2GlBridgeJudgementTag, p.UTF8String);
            return A2GlBridgeErrMissingLib;
        }
    }

    // ---- ④ dlopen（RTLD_LAZY|RTLD_GLOBAL：与 a2_renderer 同款旗标；符号对后续库可见）----
    gEglHandle      = dlopen(eglPath.UTF8String,      RTLD_LAZY | RTLD_GLOBAL);
    if (gEglHandle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"%s ★阻断★：EGL 兼容底 dlopen 失败 %s（%s）",
                 A2GlBridgeJudgementTag, eglPath.UTF8String, err ? err : "(dlerror 无输出)");
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    gGlesHandle     = dlopen(glesPath.UTF8String,     RTLD_LAZY | RTLD_GLOBAL);
    if (gGlesHandle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"%s ★阻断★：GLESv2 兼容底 dlopen 失败 %s（%s）",
                 A2GlBridgeJudgementTag, glesPath.UTF8String, err ? err : "(dlerror 无输出)");
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    // 后端本体（compat 底 = libgl4es_114.dylib）：RTLD_GLOBAL 让 MC 后续能直接解析到它的 GL 符号。
    gRendererHandle = dlopen(rendererPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (gRendererHandle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"%s ★阻断★：后端本体 dlopen 失败 %s（%s）",
                 A2GlBridgeJudgementTag, rendererPath.UTF8String, err ? err : "(dlerror 无输出)");
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    a2_log_f(@"%s 已加载兼容底：EGL=%s handle=%p；GLESv2=%s handle=%p；后端=%s handle=%p",
             A2GlBridgeJudgementTag, eglPath.UTF8String, gEglHandle,
             glesPath.UTF8String, gGlesHandle, rendererName, gRendererHandle);

    // ---- ⑤ 取 EGL 函数指针表（必需符号缺一即判加载失败）----
    int missing = 0;
    gEglGetDisplay          = (A2PFN_eglGetDisplay)a2_gl_bridge_egl_symbol(gEglHandle, "eglGetDisplay", &missing);
    gEglInitialize          = (A2PFN_eglInitialize)a2_gl_bridge_egl_symbol(gEglHandle, "eglInitialize", &missing);
    gEglChooseConfig        = (A2PFN_eglChooseConfig)a2_gl_bridge_egl_symbol(gEglHandle, "eglChooseConfig", &missing);
    gEglCreateContext       = (A2PFN_eglCreateContext)a2_gl_bridge_egl_symbol(gEglHandle, "eglCreateContext", &missing);
    gEglCreateWindowSurface = (A2PFN_eglCreateWindowSurface)a2_gl_bridge_egl_symbol(gEglHandle, "eglCreateWindowSurface", &missing);
    gEglMakeCurrent         = (A2PFN_eglMakeCurrent)a2_gl_bridge_egl_symbol(gEglHandle, "eglMakeCurrent", &missing);
    gEglGetError            = (A2PFN_eglGetError)a2_gl_bridge_egl_symbol(gEglHandle, "eglGetError", &missing);
    if (missing) {
        a2_log_f(@"%s ★阻断★：EGL 函数指针表不全（见上一行点名的符号）", A2GlBridgeJudgementTag);
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    // 可选符号（缺了只影响能力，不影响建面主路径）：各自失败即静默留空，不打"阻断"。
    gEglBindAPI           = (A2PFN_eglBindAPI)dlsym(gEglHandle, "eglBindAPI");
    gEglSwapBuffers       = (A2PFN_eglSwapBuffers)dlsym(gEglHandle, "eglSwapBuffers");
    gEglGetProcAddress    = (A2PFN_eglGetProcAddress)dlsym(gEglHandle, "eglGetProcAddress");
    gEglDestroySurface    = (A2PFN_eglDestroySurface)dlsym(gEglHandle, "eglDestroySurface");
    gEglDestroyContext    = (A2PFN_eglDestroyContext)dlsym(gEglHandle, "eglDestroyContext");
    gEglTerminate         = (A2PFN_eglTerminate)dlsym(gEglHandle, "eglTerminate");

    // ---- ⑥ 建 EGL display / config / context / surface ----
    gDpy = gEglGetDisplay(A2_EGL_DEFAULT_DISPLAY);
    if (gDpy == A2_EGL_NO_DISPLAY) {
        a2_log_f(@"%s ★阻断★：EGL 建面失败：eglGetDisplay 返回 NO_DISPLAY（eglError=0x%x）",
                 A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
        a2_gl_bridge_teardown();
        return A2GlBridgeErrEgl;
    }
    {
        A2EGLint major = 0, minor = 0;
        if (!gEglInitialize(gDpy, &major, &minor)) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglInitialize 返回 false（eglError=0x%x）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
        a2_log_f(@"%s EGL 显示已初始化：version=%d.%d display=%p", A2GlBridgeJudgementTag,
                 (int)major, (int)minor, (void *)gDpy);
    }
    if (gEglBindAPI != NULL) gEglBindAPI(A2_EGL_OPENGL_ES_API);

    {
        const A2EGLint cfgAttribs[] = {
            A2_EGL_SURFACE_TYPE,    A2_EGL_WINDOW_BIT,
            A2_EGL_RENDERABLE_TYPE, A2_EGL_OPENGL_ES2_BIT,
            A2_EGL_RED_SIZE,        8,
            A2_EGL_GREEN_SIZE,      8,
            A2_EGL_BLUE_SIZE,       8,
            A2_EGL_ALPHA_SIZE,      8,
            A2_EGL_DEPTH_SIZE,      24,
            A2_EGL_STENCIL_SIZE,    8,
            A2_EGL_NONE
        };
        A2EGLint numCfg = 0;
        if (!gEglChooseConfig(gDpy, cfgAttribs, &gCfg, 1, &numCfg) || numCfg < 1 || gCfg == NULL) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglChooseConfig 无可用配置（eglError=0x%x）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
    }

    {
        const A2EGLint ctxAttribs[] = { A2_EGL_CONTEXT_CLIENT_VERSION, 2, A2_EGL_NONE };
        gCtx = gEglCreateContext(gDpy, gCfg, A2_EGL_NO_CONTEXT, ctxAttribs);
        if (gCtx == A2_EGL_NO_CONTEXT) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglCreateContext 返回 NO_CONTEXT（eglError=0x%x）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
    }

    {
        // 先带尺寸建；若实现不接受 EGL_WIDTH/HEIGHT（非核心 EGL 属性）再退到无属性。
        const A2EGLint surfAttribs[] = {
            A2_EGL_WIDTH,  (A2EGLint)host->surface.widthPixels,
            A2_EGL_HEIGHT, (A2EGLint)host->surface.heightPixels,
            A2_EGL_NONE
        };
        gSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)renderable, surfAttribs);
        if (gSurf == A2_EGL_NO_SURFACE) {
            A2EGLint e1 = gEglGetError ? gEglGetError() : 0;
            a2_log_f(@"%s EGL 建面：带尺寸(%dx%d 像素)失败 eglError=0x%x ⇒ 退到无属性重试",
                     A2GlBridgeJudgementTag, host->surface.widthPixels, host->surface.heightPixels, (unsigned)e1);
            gSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)renderable, NULL);
        }
        if (gSurf == A2_EGL_NO_SURFACE) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglCreateWindowSurface 返回 NO_SURFACE（eglError=0x%x；句柄=%p 像素格式=%d）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0),
                     renderable, host->surface.pixelFormat);
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
    }

    if (!gEglMakeCurrent(gDpy, gSurf, gSurf, gCtx)) {
        a2_log_f(@"%s ★阻断★：EGL 建面失败：eglMakeCurrent 返回 false（eglError=0x%x）",
                 A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
        a2_gl_bridge_teardown();
        return A2GlBridgeErrEgl;
    }

    a2_log_f(@"%s EGL 就绪：display=%p config=%p context=%p surface=%p（%dx%d 像素；像素格式=%d）",
             A2GlBridgeJudgementTag, (void *)gDpy, (void *)gCfg, (void *)gCtx, (void *)gSurf,
             host->surface.widthPixels, host->surface.heightPixels, host->surface.pixelFormat);

    // ---- ⑦ 取 GL 函数指针（glClear 必需；优先 eglGetProcAddress，回落 dlsym(GLESv2)）----
    void *pClear = gEglGetProcAddress ? gEglGetProcAddress("glClear") : NULL;
    void *pClearColor = gEglGetProcAddress ? gEglGetProcAddress("glClearColor") : NULL;
    void *pGetError = gEglGetProcAddress ? gEglGetProcAddress("glGetError") : NULL;
    if (pClear == NULL)      pClear      = dlsym(gGlesHandle, "glClear");
    if (pClearColor == NULL) pClearColor = dlsym(gGlesHandle, "glClearColor");
    if (pGetError == NULL)   pGetError   = dlsym(gGlesHandle, "glGetError");

    if (pClear == NULL) {
        a2_log_f(@"%s ★阻断★：取不到 GL 入口 glClear（eglGetProcAddress 与 dlsym(GLESv2) 都失败）⇒ 上下文不可判据",
                 A2GlBridgeJudgementTag);
        a2_gl_bridge_teardown();
        return A2GlBridgeErrEgl;
    }
    gGLClear      = (A2PFN_glClear)pClear;
    gGLClearColor = (A2PFN_glClearColor)pClearColor;   // 可空（缺则只清默认色）
    gGLGetError   = (A2PFN_glGetError)pGetError;       // 可空（缺则判据行只报 0 未知）

    // ---- ⑧ 附着并渲染一帧（帧内 glClear 作可用性判据）----
    gAttached = 1;
    gFrameCount = 0;
    gWidthPixels = host->surface.widthPixels;
    gHeightPixels = host->surface.heightPixels;
    gFrameCb = host->frameCallback;
    gFrameUser = host->frameUser;

    a2_log_f(@"%s 附着完成：后端=%s 已接上宿主表面（帧回调=%s）",
             A2GlBridgeJudgementTag, rendererName,
             (gFrameCb != NULL) ? "宿主已提供" : "宿主未提供");
    a2_gl_bridge_frame_work();
    return A2GlBridgeOK;
}

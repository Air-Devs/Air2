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
#include <pthread.h>
#import "a2_gl_bridge.h"
#import "a2_log.h"
#import "a2_frame_perf.h"   // ★[FRAME-PERF] 与渲染器无关的帧性能判据（本文件的帧动作每帧记一次）
#import "A2JITEnvironment.h"   // ★[A2PROBE]★ a2_jit_probe_arm（把 KW/ANGLE 的 glLoadIdentity 交给脚本布断点）

#import <objc/message.h>   // objc_msgSend（动态取 layer 用；不 import UIKit）
#import <dlfcn.h>
#include <unistd.h>       // usleep（首次 make_current 等宿主视图就绪的有界等待）
#include <string.h>
#include <stdint.h>

// ---------------------------------------------------------------------------
// 常量（判据锚点 / 库相对路径）
// ---------------------------------------------------------------------------
const char *const A2GlBridgeJudgementTag        = "[A2-GLBRIDGE]";
const char *const A2GlBridgeEglLibraryRelPath   = "libEGL.framework/libEGL";
const char *const A2GlBridgeGlesLibraryRelPath  = "libGLESv2.framework/libGLESv2";

/// ★NG-GL4ES / KW★ 的 dylib 文件名（= 渲染器清单里的标识，见 `A2RendererCatalog`）。
/// Natives 不认识 Core、Core 也反向依赖不了本层（分层）⇒ 这里是字面量，
/// 与 `a2_renderer.h` 的 `A2RendererMetalDylibName` / `A2RendererCompatDylibName` 同一做法。
static const char *const A2GlBridgeKryptonDylibName = "libnggl4es_kw.dylib";

/// ★A2KWUseES1 的编译期默认值★（A/B 出包时只改这一处，或用命令行 `-DA2_KW_USE_ES1_DEFAULT=1`）
///   0 = 请求 ES3（现状默认）  1 = 请求 ES1  2 = 请求 ES2
///   运行期仍由偏好键 `A2KWContextMode`（String: es1/es2/es3）覆盖；兼容旧键 A2KWUseES1（Boolean）。
#ifndef A2_KW_CONTEXT_MODE_DEFAULT
#define A2_KW_CONTEXT_MODE_DEFAULT 0
#endif
/// D 包用：1 ⇒ 在 initialize_gl4es 之前注入 LIBGL_ES=3 / LIBGL_GL=21（gl4es 血统的 shader 模拟开关）
#ifndef A2_KW_ENV_HINT_DEFAULT
#define A2_KW_ENV_HINT_DEFAULT 0
#endif

/// 偏好键名（运行期覆盖用；只影响 NG-GL4ES / KW 的上下文版本）
static NSString *const A2GlBridgeKWUseES1Key = @"A2KWUseES1";
static NSString *const A2GlBridgeKWContextModeKey = @"A2KWContextMode";

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
typedef A2EGLBoolean  (*A2PFN_eglQuerySurface)(A2EGLDisplay, A2EGLSurface, A2EGLint, A2EGLint *);

typedef void      (*A2PFN_glClear)(uint32_t);
typedef void      (*A2PFN_glClearColor)(float, float, float, float);
typedef uint32_t  (*A2PFN_glGetError)(void);
typedef void      (*A2PFN_glViewport)(int, int, int, int);
typedef void      (*A2PFN_glScissor)(int, int, int, int);
typedef void      (*A2PFN_glEnable)(uint32_t);
typedef void      (*A2PFN_glDisable)(uint32_t);
typedef void      (*A2PFN_glGetIntegerv)(uint32_t, int *);

// ---- ★gl4es 家族（NG-GL4ES / KW）的宿主契约★（上游原型都是 `void f(void)`）----
//  · `set_getprocaddress(void *(*)(const char *))`：把 GLES 入口解析器交给 gl4es。
//    该变体是 `-DNOEGL` 编的 —— 它不建自己的 EGL、也不 dlopen GLESv2 去摸入口，
//    不注册就只能退到 `dlsym(RTLD_NEXT)`，而 ANGLE 比它先加载 ⇒ 一个入口都找不到。
//  · `initialize_gl4es(void)`：`-DNO_INIT_CONSTRUCTOR` 把构造器关掉之后，初始化是宿主的责任。
//    漏掉的表现是「不崩但黑屏 / GL 调用全空」，所以本桥在 context current 之后立刻调它。
typedef void      (*A2PFN_initialize_gl4es)(void);
typedef void      (*A2PFN_set_getprocaddress)(void *(*)(const char *));

#define A2_EGL_DEFAULT_DISPLAY       ((void *)0)
#define A2_EGL_NO_DISPLAY            ((A2EGLDisplay)0)
#define A2_EGL_NO_CONTEXT            ((A2EGLContext)0)
#define A2_EGL_NO_SURFACE            ((A2EGLSurface)0)
#define A2_EGL_SUCCESS               0x3000
#define A2_EGL_OPENGL_ES_API         0x30A0
// ★对齐老 Air `Natives/ctxbridges/gl_bridge.m:1697`（926629869）★：KW 走 `EGL_OPENGL_ES3_BIT`（0x40），
//   不是 ES2_BIT（0x4）。老 Air 给 1.7.10 与 1.20 建的是同一个 ES3 config + ES3 上下文，不做版本分档。
#define A2_EGL_OPENGL_ES3_BIT        0x40
#define A2_EGL_OPENGL_ES2_BIT        0x0004
#define A2_EGL_SURFACE_TYPE          0x3033
#define A2_EGL_WINDOW_BIT            0x0004
#define A2_EGL_PBUFFER_BIT           0x0001
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
#define A2_GL_SCISSOR_BOX            0x0C10
#define A2_GL_SCISSOR_TEST           0x0C11

// ---------------------------------------------------------------------------
// 桥状态（一次性：attach 成功后驻留到进程结束/再次 attach）
// ---------------------------------------------------------------------------
/// 当前后端的 dylib 名（attach 时记录；帧回调据此跳过危险调用）。
static char gBackendName[96] = {0};

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
static A2PFN_eglQuerySurface      gEglQuerySurface = NULL;

static A2PFN_glClear      gGLClear = NULL;
static A2PFN_glClearColor gGLClearColor = NULL;
static A2PFN_glGetError   gGLGetError = NULL;

static A2PFN_glViewport    gGLViewport = NULL;
static A2PFN_glScissor     gGLScissor = NULL;
static A2PFN_glEnable      gGLEnable = NULL;
static A2PFN_glDisable     gGLDisable = NULL;
static A2PFN_glGetIntegerv gGLGetIntegerv = NULL;

static int   gAttached = 0;
static int   gFrameCount = 0;
static int   gWidthPixels = 0;
static int   gHeightPixels = 0;
static int   gSurfaceWidthPixels  = 0;   // eglQuerySurface 回报的实际 drawable 宽（0 = 实现未回报）
static int   gSurfaceHeightPixels = 0;   // 同上（高）
static A2GlFrameCallback gFrameCb = NULL;
static void *gFrameUser = NULL;

/// 已经显式 `initialize_gl4es()` 过的镜像（gl4es 内部只认第一次初始化 ⇒ 重入 attach 时不重复调）。
static void *gKryptonInitedHandle = NULL;

// ---- ★首次 make_current 的表面改绑状态★（见 a2_gl_bridge_ensure_game_view_surface）----
/// 0 = 还没做过（每次 make_current 都会尝试）；1 = 已完成（含「本来就绑在同一图层」）；
/// 2 = 已放弃（改绑失败 ⇒ 只打警告，后续 make_current 不再动）。
static int   gRebindState = 0;
/// 「宿主视图还没就绪」这条提示只打一次（视图在主队列异步建出，make_current 会反复进来）。
static int   gRebindWaitLogged = 0;
/// 当前 EGL 表面绑着的**可渲染句柄**（图层）—— 改绑前用它判「是不是已经绑在 GLFW 宿主视图上」。
static void *gBoundRenderable = NULL;

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
    if (gRendererHandle != NULL) {
        dlclose(gRendererHandle);
        gRendererHandle = NULL;
        gKryptonInitedHandle = NULL;   // 镜像已关 ⇒ 下次 attach 必须重新初始化
    }
    if (gGlesHandle != NULL)     { dlclose(gGlesHandle);     gGlesHandle = NULL; }
    if (gEglHandle != NULL)      { dlclose(gEglHandle);      gEglHandle = NULL; }

    gDpy = A2_EGL_NO_DISPLAY; gCfg = NULL;
    gCtx = A2_EGL_NO_CONTEXT; gSurf = A2_EGL_NO_SURFACE;
    gEglGetDisplay = NULL; gEglInitialize = NULL; gEglBindAPI = NULL;
    gEglChooseConfig = NULL; gEglCreateContext = NULL; gEglCreateWindowSurface = NULL;
    gEglMakeCurrent = NULL; gEglSwapBuffers = NULL; gEglGetError = NULL;
    gEglGetProcAddress = NULL; gEglDestroySurface = NULL; gEglDestroyContext = NULL;
    gEglTerminate = NULL; gEglQuerySurface = NULL;
    gGLClear = NULL; gGLClearColor = NULL; gGLGetError = NULL;
    gGLViewport = NULL; gGLScissor = NULL; gGLEnable = NULL; gGLDisable = NULL; gGLGetIntegerv = NULL;
    gAttached = 0; gFrameCount = 0;
    gFrameCb = NULL; gFrameUser = NULL;
    gWidthPixels = 0; gHeightPixels = 0;
    gSurfaceWidthPixels = 0; gSurfaceHeightPixels = 0;
    gBoundRenderable = NULL;          // 表面已销毁 ⇒ 不再有「绑着的图层」
    gRebindState = 0;                 // 下次 attach 后允许再改绑一次
    gRebindWaitLogged = 0;
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

/// CGSize 的内存布局（宽/高两个 CGFloat；arm64 上 CGFloat = double）。
/// ★为什么自己声明★：本层不 import UIKit/QuartzCore（见文件头），而 `setDrawableSize:`
/// 收的正是 CGSize —— 用同布局的结构体经 objc_msgSend 传过去，不引入框架头。
typedef struct { double width; double height; } A2GlBridgeLayerSize;

/// 宿主窗口层级（`windowLevel`）——★只用于判据行★：取不到回报 -1，不猜、不补默认值。
static double a2_gl_bridge_window_level(void *nativeWindow) {
    if (nativeWindow == NULL) return -1.0;
    id win = (__bridge id)nativeWindow;
    SEL levelSel = NSSelectorFromString(@"windowLevel");
    if (win != nil && [win respondsToSelector:levelSel]) {
        double (*getLevel)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
        return getLevel(win, levelSel);
    }
    return -1.0;
}

/// ★把 drawable 的尺寸口径统一到「像素」★ —— 初始化宿主图层的 contentsScale / drawableSize。
/// 调用点：`a2_gl_bridge_attach` 的 ⑥0b（在两条建面路径之前，只此一处）。
///
/// ★为什么必须有★ 真机（1.20.1 + MobileGlues）：本层请求 2622x1206 像素（点 874x402 × scale 3.0），
///   实现只回报 874x402 —— 正好是点尺寸。原因在宿主图层：实现按 `bounds × contentsScale`
///   决定 drawable，而 UIWindow 根视图的 contentsScale 仍是 1.0 ⇒ 请求与实得差 3 倍。
///   这里把 contentsScale（= 像素/点，含渲染倍率）与 drawableSize（= 像素）都设进去，
///   让「请求值 / 图层口径 / 实现回报」三者同源。
///
/// 返回 1 = 图层接受了像素口径（两个入口至少设进去一个）；0 = 宿主只能给点尺寸。
static int a2_gl_bridge_align_drawable(void *renderable, int wPx, int hPx,
                                       int wPoints, float contentScale) {
    if (renderable == NULL || wPx <= 0 || hPx <= 0) return 0;
    id layer = (__bridge id)renderable;

    // 目标倍率 = 像素 / 点（= 屏幕 scale × 渲染倍率）；点宽缺失时退回宿主给的 contentScale。
    double targetScale = (wPoints > 0) ? ((double)wPx / (double)wPoints) : (double)contentScale;
    if (targetScale <= 0.0) targetScale = 1.0;

    BOOL scaleApplied = NO;
    SEL setScaleSel = NSSelectorFromString(@"setContentsScale:");
    if ([layer respondsToSelector:setScaleSel]) {
        void (*sendScale)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
        sendScale(layer, setScaleSel, targetScale);
        scaleApplied = YES;
    }

    BOOL drawableApplied = NO;
    SEL setDrawableSel = NSSelectorFromString(@"setDrawableSize:");
    if ([layer respondsToSelector:setDrawableSel]) {           // CAEAGLLayer 才有；普通 CALayer 没有
        void (*sendDrawable)(id, SEL, A2GlBridgeLayerSize) =
            (void (*)(id, SEL, A2GlBridgeLayerSize))objc_msgSend;
        A2GlBridgeLayerSize want = { (double)wPx, (double)hPx };
        sendDrawable(layer, setDrawableSel, want);
        drawableApplied = YES;
    }

    // ★读回实际值★（不假装设成功）：判据行同时给出「设了什么」与「图层现在是什么」。
    double backScale = -1.0;
    SEL scaleSel = NSSelectorFromString(@"contentsScale");
    if ([layer respondsToSelector:scaleSel]) {
        double (*getScale)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
        backScale = getScale(layer, scaleSel);
    }
    A2GlBridgeLayerSize backDrawable = { -1.0, -1.0 };
    SEL drawableSel = NSSelectorFromString(@"drawableSize");
    if ([layer respondsToSelector:drawableSel]) {
        A2GlBridgeLayerSize (*getDrawable)(id, SEL) =
            (A2GlBridgeLayerSize (*)(id, SEL))objc_msgSend;
        backDrawable = getDrawable(layer, drawableSel);
    }

    // ★格式约定★：a2_log_f 走 vsnprintf ⇒ 只认 %s，类名必须 .UTF8String（%@ 是 A2Log 的格式）。
    a2_log_f(@"%s drawable 口径：请求=%dx%d 像素（点宽=%d；目标倍率=%.2f）；图层=%s "
             @"setContentsScale=%s（读回 %.2f）；setDrawableSize=%s（读回 %.0fx%.0f）",
             A2GlBridgeJudgementTag, wPx, hPx, wPoints, targetScale,
             NSStringFromClass([layer class]).UTF8String,
             scaleApplied ? "已设" : "无此入口", backScale,
             drawableApplied ? "已设" : "无此入口", backDrawable.width, backDrawable.height);

    return (scaleApplied || drawableApplied) ? 1 : 0;
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

/// 当前后端是否 = ★NG-GL4ES / KW★（那一支需要宿主「注册解析器 + 显式初始化」）。
/// ★精确比较，不做模糊匹配★：`libnggl4es.dylib`（老的那支，自带 constructor）不能命中。
static int a2_gl_bridge_is_krypton(void) {
    return (gBackendName[0] != '\0' && strcmp(gBackendName, A2GlBridgeKryptonDylibName) == 0);
}

/// 当前后端是否 = ★MobileGlues★（唯一判据来源：dylib 名子串 `mobileglues`）。
/// ★两处共用，不许各自写字面量★：① 依赖库的加载旗标（② 与 ④）；② MG 的符号归属核对（④a2）。
static int a2_gl_bridge_is_mobileglues(void) {
    return (gBackendName[0] != '\0' && strstr(gBackendName, "mobileglues") != NULL);
}

/// 交给 gl4es 的 GLES 入口解析器 —— 它在 `-DNOEGL` 下**唯一**的入口来源。
/// 顺序固定：已 RTLD_GLOBAL 的 GLESv2（ANGLE）→ EGL → eglGetProcAddress。
/// ★只解析 GLES/EGL 入口，不碰 `gl*` 包装层★：包装层符号由 LWJGL 从后端本体取（名字解析面 1328 个 gl*）。
// ★GL 入口 trace（诊断）★：给 KW 解析到的 4 个查询函数套壳，打 enter/exit + 线程 id。
//   目的：1.7.10 在 `GL caps init` 之后卡死，靠“有 enter 没 exit”精确定位到具体调用。
typedef const unsigned char *(*A2PFN_glGetString)(unsigned int);
typedef const unsigned char *(*A2PFN_glGetStringi)(unsigned int, unsigned int);
typedef void               (*A2PFN_glGetIntegerv)(unsigned int, int *);
typedef unsigned int       (*A2PFN_glGetError)(void);
static A2PFN_glGetString  gRealGLGetString  = NULL;
static A2PFN_glGetStringi gRealGLGetStringi = NULL;
static A2PFN_glGetIntegerv gRealGLGetIntegerv = NULL;
static A2PFN_glGetError   gRealGLGetError   = NULL;
static volatile int32_t   gGLTraceCalls     = 0;
static volatile int32_t   gKryptonGLES1Rejected = 0;
static volatile int32_t   gKryptonResolveLogCount = 0;

#define A2_GL_TRACE_MAX_CALLS 400   // 只在开头疯狂阶段打日志，避免刷爆

static const unsigned char *a2_trace_glGetString(unsigned int name) {
    int n = __sync_fetch_and_add(&gGLTraceCalls, 1);
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] -> enter glGetString(0x%x) tid=%p", name, (void *)pthread_self());
    const unsigned char *r = (gRealGLGetString != NULL) ? gRealGLGetString(name) : NULL;
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] <- exit  glGetString(0x%x) = %s", name, r ? (const char *)r : "(null)");
    return r;
}

static const unsigned char *a2_trace_glGetStringi(unsigned int name, unsigned int index) {
    int n = __sync_fetch_and_add(&gGLTraceCalls, 1);
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] -> enter glGetStringi(0x%x, %u) tid=%p", name, index, (void *)pthread_self());
    const unsigned char *r = (gRealGLGetStringi != NULL) ? gRealGLGetStringi(name, index) : NULL;
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] <- exit  glGetStringi(0x%x, %u) = %s", name, index, r ? (const char *)r : "(null)");
    return r;
}

static void a2_trace_glGetIntegerv(unsigned int pname, int *data) {
    int n = __sync_fetch_and_add(&gGLTraceCalls, 1);
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] -> enter glGetIntegerv(0x%x) tid=%p", pname, (void *)pthread_self());
    if (gRealGLGetIntegerv != NULL) gRealGLGetIntegerv(pname, data);
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] <- exit  glGetIntegerv(0x%x) = %d", pname, (data != NULL) ? *data : -1);
}

static unsigned int a2_trace_glGetError(void) {
    int n = __sync_fetch_and_add(&gGLTraceCalls, 1);
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] -> enter glGetError tid=%p", (void *)pthread_self());
    unsigned int e = (gRealGLGetError != NULL) ? gRealGLGetError() : 0u;
    if (n < A2_GL_TRACE_MAX_CALLS)
        a2_log_f(@"[A2-GL-TRACE] <- exit  glGetError = 0x%x", e);
    return e;
}

// ---------------------------------------------------------------------------
// ★GLES1 固定管线「空实现桩」★ —— KW 拒绝分支的返回物（真机 lastlog-87 的修因）
// ---------------------------------------------------------------------------
//  证据链：`[A2-GL-PTR] glLoadMatrixf: KW=0x127622e08 ANGLE=0x1281b2a28 resolver=0x0`
//    ⇒ ① KW 与 ANGLE 的地址不同（不是全局符号抢先命中）；
//      ② 我们的解析器确实拒绝了（返回 NULL）；
//      ③ 崩溃却仍落在 ANGLE 的 `gl::GLES1State::loadMatrix`。
//    ⇒ MC 拿到的既不是 KW 也不是我们 ⇒ KW 在拿到 NULL 后**回落到宿主 eglGetProcAddress**
//      （= ANGLE 的 libEGL），把 ANGLE 的 GLES1 入口又拿了回去。
//  修法：拒绝时不再给 NULL，改给**我们自己的空实现**（非空指针 ⇒ KW 不再去问 EGL）。
//        KW 的固定管线本来就由它自带的 FPE 负责（老 Air 的行为），宿主侧这些入口纯属冗余。
//  签名：逐条按 Khronos GLES1 公开原型声明 —— **不能**用统一的无参转调顶替
//        （调用方按真实原型摆参数寄存器/栈，签名对不上即 UB）。这些入口**没有一个是变参**。
// ---------------------------------------------------------------------------

/// 桩调用记账（★去重：每个名字只在首次被调用时打一行★，避免逐帧刷屏）
#define A2_GL_STUB_MAX_NAMES 128
static char             gGLStubSeen[A2_GL_STUB_MAX_NAMES][40];
static int              gGLStubSeenCount = 0;
static volatile int32_t gGLStubCalls     = 0;   // 累计调用次数（判据可核对「桩确实被用上了」）
static pthread_mutex_t  gGLStubLock      = PTHREAD_MUTEX_INITIALIZER;

/// 记录一次桩调用。首见才输出判据行：`[A2-GL-STUB] <name> 被调用（KW 固定管线回落）`
/// 走 a2_log_criterion（判据行统一出口）⇒ 同时进控制台与「运行日志」页读的那份 lastlog.txt。
static void a2_gl_stub_note(const char *name) {
    __sync_fetch_and_add(&gGLStubCalls, 1);
    int firstTime = 0;
    pthread_mutex_lock(&gGLStubLock);
    int seen = 0;
    for (int i = 0; i < gGLStubSeenCount; i++) {
        if (strncmp(gGLStubSeen[i], name, 39) == 0) { seen = 1; break; }
    }
    if (!seen && gGLStubSeenCount < A2_GL_STUB_MAX_NAMES) {
        strncpy(gGLStubSeen[gGLStubSeenCount], name, 39);
        gGLStubSeen[gGLStubSeenCount][39] = '\0';
        gGLStubSeenCount++;
        firstTime = 1;
    }
    pthread_mutex_unlock(&gGLStubLock);
    if (firstTime) a2_log_criterion(@"[A2-GL-STUB] %s 被调用（KW 固定管线回落）", name);
}

// —— 桩体生成宏：每个桩只做「记账 + return」，参数只为对齐 ABI，故逐个 (void) 掉 ——
#define A2_STUB0(n) static void a2_glstub_##n(void) \
    { a2_gl_stub_note(#n); }
#define A2_STUB1(n, T1) static void a2_glstub_##n(T1 a1) \
    { (void)a1; a2_gl_stub_note(#n); }
#define A2_STUB2(n, T1, T2) static void a2_glstub_##n(T1 a1, T2 a2) \
    { (void)a1; (void)a2; a2_gl_stub_note(#n); }
#define A2_STUB3(n, T1, T2, T3) static void a2_glstub_##n(T1 a1, T2 a2, T3 a3) \
    { (void)a1; (void)a2; (void)a3; a2_gl_stub_note(#n); }
#define A2_STUB4(n, T1, T2, T3, T4) static void a2_glstub_##n(T1 a1, T2 a2, T3 a3, T4 a4) \
    { (void)a1; (void)a2; (void)a3; (void)a4; a2_gl_stub_note(#n); }
#define A2_STUB6(n, T) static void a2_glstub_##n(T a1, T a2, T a3, T a4, T a5, T a6) \
    { (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; a2_gl_stub_note(#n); }

// —— 分量族：生成 <p>2<s>/<p>3<s>/<p>4<s> 与向量版 <p>2<s>v… （const T *）——
#define A2_STUB_FAMILY_234(p, s, T) \
    A2_STUB2(p##2##s, T, T) A2_STUB3(p##3##s, T, T, T) A2_STUB4(p##4##s, T, T, T, T) \
    A2_STUB1(p##2##s##v, const T *) A2_STUB1(p##3##s##v, const T *) A2_STUB1(p##4##s##v, const T *)
#define A2_STUB_FAMILY_34(p, s, T) \
    A2_STUB3(p##3##s, T, T, T) A2_STUB4(p##4##s, T, T, T, T) \
    A2_STUB1(p##3##s##v, const T *) A2_STUB1(p##4##s##v, const T *)

// 顶点：float/double/int/short（GLES1 允许 float 以外用「x/s/i」入口，名字不变）
A2_STUB_FAMILY_234(glVertex, f, float)
A2_STUB_FAMILY_234(glVertex, d, double)
A2_STUB_FAMILY_234(glVertex, i, int)
A2_STUB_FAMILY_234(glVertex, s, short)
// 纹理坐标：2/3/4 分量 + 1 分量
A2_STUB_FAMILY_234(glTexCoord, f, float)
A2_STUB_FAMILY_234(glTexCoord, d, double)
A2_STUB1(glTexCoord1f, float) A2_STUB1(glTexCoord1fv, const float *)
A2_STUB1(glTexCoord1d, double) A2_STUB1(glTexCoord1dv, const double *)
// 颜色：GLES1 只有 3/4 分量
A2_STUB_FAMILY_34(glColor, f, float)
A2_STUB_FAMILY_34(glColor, d, double)
A2_STUB_FAMILY_34(glColor, i, int)
A2_STUB_FAMILY_34(glColor, ub, unsigned char)
// 法线：只有 3 分量
A2_STUB3(glNormal3f, float, float, float) A2_STUB1(glNormal3fv, const float *)
A2_STUB3(glNormal3d, double, double, double) A2_STUB1(glNormal3dv, const double *)
A2_STUB3(glNormal3i, int, int, int) A2_STUB1(glNormal3iv, const int *)
A2_STUB3(glNormal3s, short, short, short) A2_STUB1(glNormal3sv, const short *)
// 光栅位置
A2_STUB_FAMILY_234(glRasterPos, f, float)
A2_STUB_FAMILY_234(glRasterPos, d, double)
// 索引（颜色表；ES1 已弃用但仍可能被索要）
A2_STUB1(glIndexf, float) A2_STUB1(glIndexfv, const float *)
A2_STUB1(glIndexd, double) A2_STUB1(glIndexdv, const double *)
A2_STUB1(glIndexi, int) A2_STUB1(glIndexiv, const int *)
A2_STUB1(glIndexs, short) A2_STUB1(glIndexsv, const short *)
A2_STUB1(glIndexub, unsigned char) A2_STUB1(glIndexubv, const unsigned char *)
// 矩阵栈 / 投影（glOrtho/glFrustum 的 GLdouble 版与 GLES1 的 f 版都在）
A2_STUB1(glMatrixMode, unsigned int)
A2_STUB0(glLoadIdentity)
A2_STUB1(glLoadMatrixf, const float *) A2_STUB1(glLoadMatrixd, const double *)
A2_STUB1(glMultMatrixf, const float *) A2_STUB1(glMultMatrixd, const double *)
A2_STUB0(glPushMatrix) A2_STUB0(glPopMatrix)
A2_STUB6(glOrtho, double) A2_STUB6(glOrthof, float)
A2_STUB6(glFrustum, double) A2_STUB6(glFrustumf, float)
// 立即模式 / 客户端状态 / 光照状态
A2_STUB1(glBegin, unsigned int) A2_STUB0(glEnd)
A2_STUB1(glEnableClientState, unsigned int) A2_STUB1(glDisableClientState, unsigned int)
A2_STUB1(glShadeModel, unsigned int)
A2_STUB2(glAlphaFunc, unsigned int, float)
A2_STUB2(glClipPlane, unsigned int, const double *)

/// ★兜底桩★：前缀命中但未逐个登记的名字（如 glVertex4sv 之外的冷门变体）。
/// GLES1 这批入口**全部**是 void 返回、只收标量/指针参数、**无变参** ⇒ `void(void)` 原型
/// 在 arm64/x86_64 上忽略参数是安全的。正常路径不应落到这里（落到了=该补登记）。
static void a2_glstub_unlisted(void) { a2_gl_stub_note("(未登记的 GLES1 入口)"); }

// —— 名字 → 桩 的表（精确匹配；前缀命中但表里没有 ⇒ 兜底桩）——
typedef struct { const char *name; void *fn; } A2GLStubEntry;
#define A2_STUB_ENTRY(n) { #n, (void *)a2_glstub_##n },
#define A2_STUB_ENTRIES_234(p, s) \
    A2_STUB_ENTRY(p##2##s) A2_STUB_ENTRY(p##3##s) A2_STUB_ENTRY(p##4##s) \
    A2_STUB_ENTRY(p##2##s##v) A2_STUB_ENTRY(p##3##s##v) A2_STUB_ENTRY(p##4##s##v)
#define A2_STUB_ENTRIES_34(p, s) \
    A2_STUB_ENTRY(p##3##s) A2_STUB_ENTRY(p##4##s) \
    A2_STUB_ENTRY(p##3##s##v) A2_STUB_ENTRY(p##4##s##v)

static const A2GLStubEntry kGLStubs[] = {
    A2_STUB_ENTRIES_234(glVertex, f) A2_STUB_ENTRIES_234(glVertex, d)
    A2_STUB_ENTRIES_234(glVertex, i) A2_STUB_ENTRIES_234(glVertex, s)
    A2_STUB_ENTRIES_234(glTexCoord, f) A2_STUB_ENTRIES_234(glTexCoord, d)
    A2_STUB_ENTRY(glTexCoord1f) A2_STUB_ENTRY(glTexCoord1fv)
    A2_STUB_ENTRY(glTexCoord1d) A2_STUB_ENTRY(glTexCoord1dv)
    A2_STUB_ENTRIES_34(glColor, f) A2_STUB_ENTRIES_34(glColor, d)
    A2_STUB_ENTRIES_34(glColor, i) A2_STUB_ENTRIES_34(glColor, ub)
    A2_STUB_ENTRY(glNormal3f) A2_STUB_ENTRY(glNormal3fv)
    A2_STUB_ENTRY(glNormal3d) A2_STUB_ENTRY(glNormal3dv)
    A2_STUB_ENTRY(glNormal3i) A2_STUB_ENTRY(glNormal3iv)
    A2_STUB_ENTRY(glNormal3s) A2_STUB_ENTRY(glNormal3sv)
    A2_STUB_ENTRIES_234(glRasterPos, f) A2_STUB_ENTRIES_234(glRasterPos, d)
    A2_STUB_ENTRY(glIndexf) A2_STUB_ENTRY(glIndexfv)
    A2_STUB_ENTRY(glIndexd) A2_STUB_ENTRY(glIndexdv)
    A2_STUB_ENTRY(glIndexi) A2_STUB_ENTRY(glIndexiv)
    A2_STUB_ENTRY(glIndexs) A2_STUB_ENTRY(glIndexsv)
    A2_STUB_ENTRY(glIndexub) A2_STUB_ENTRY(glIndexubv)
    A2_STUB_ENTRY(glMatrixMode) A2_STUB_ENTRY(glLoadIdentity)
    A2_STUB_ENTRY(glLoadMatrixf) A2_STUB_ENTRY(glLoadMatrixd)
    A2_STUB_ENTRY(glMultMatrixf) A2_STUB_ENTRY(glMultMatrixd)
    A2_STUB_ENTRY(glPushMatrix) A2_STUB_ENTRY(glPopMatrix)
    A2_STUB_ENTRY(glOrtho) A2_STUB_ENTRY(glOrthof)
    A2_STUB_ENTRY(glFrustum) A2_STUB_ENTRY(glFrustumf)
    A2_STUB_ENTRY(glBegin) A2_STUB_ENTRY(glEnd)
    A2_STUB_ENTRY(glEnableClientState) A2_STUB_ENTRY(glDisableClientState)
    A2_STUB_ENTRY(glShadeModel) A2_STUB_ENTRY(glAlphaFunc) A2_STUB_ENTRY(glClipPlane)
    { NULL, NULL }
};

/// 查桩：命中返回非空函数指针；未登记返回 NULL（调用方退到兜底桩）。
static void *a2_gl_stub_lookup(const char *name) {
    for (int i = 0; kGLStubs[i].name != NULL; i++) {
        if (strcmp(kGLStubs[i].name, name) == 0) return kGLStubs[i].fn;
    }
    return NULL;
}

static void *a2_gl_bridge_gles_getprocaddress(const char *name) {
    if (name == NULL) return NULL;
    void *sym = NULL;
    if (gGlesHandle != NULL) sym = dlsym(gGlesHandle, name);
    if (sym == NULL && gEglHandle != NULL) sym = dlsym(gEglHandle, name);
    if (sym == NULL && gEglGetProcAddress != NULL) sym = gEglGetProcAddress(name);
    if (sym == NULL) return NULL;

    // ★KW 后端：把解析器命中的每个名字都打出来（限前 200 条）★
    //   目的：1.7.10 崩在 ANGLE 的 ContextPrivateLoadIdentity，而我们的 21 条 GLES1 前缀表没命中
    //   （桩计数 0）⇒ 说明 KW 要的是表外的变体名字，落到了兜底 dlsym(GLESv2)。先看清名字再补表。
    if (a2_gl_bridge_is_krypton() && gKryptonResolveLogCount < 200) {
        gKryptonResolveLogCount++;
        a2_log_f(@"[A2-GL-RESOLVE] KW 请求 %s -> %p（宿主=%s）", name, sym,
                 (gGlesHandle != NULL && sym == dlsym(gGlesHandle, name)) ? "ANGLE" : "其它");
    }

    // ★KW 白名单★（真机 lastlog-94）：黑名单挡不住 KW 使用的变体（它拿到 ANGLE 的 glLoadMatrixf
    //   后就崩在 gl::ContextPrivateLoadIdentity）。改为「只放行真 ES3 入口，其余一律空桩」。
    if (a2_gl_bridge_is_krypton()) {
        static const char *const kWL[] = {
            "Shader","Program","Buffer","Texture","Framebuffer","Renderbuffer",
            "Vertex","Uniform","Draw","String","Error","Integerv","Floatv","Booleanv",
            "Clear","Viewport","Scissor","Enable","Disable","Blend","Depth","Stencil",
            "Cull","PixelStore","ReadPixels","Finish","Flush","Hint","LineWidth",
            "ColorMask","PolygonOffset","FrontFace","ActiveTexture","Get","TexImage",
            "TexSubImage","TexParameter","GenerateMipmap","Delete","Create","Gen","Bind",
            "Link","Validate","Attach","Detach","IsEnabled","GetShader","GetProgram", NULL
        };
        BOOL allowed = NO;
        for (int i = 0; kWL[i] != NULL && !allowed; i++) {
            if (strstr(name, kWL[i]) != NULL) allowed = YES;
        }
        if (!allowed) {
            static char logged[64][48]; static int n = 0; BOOL seen = NO;
            for (int k = 0; k < n; k++) if (strncmp(logged[k], name, 47) == 0) { seen = YES; break; }
            if (!seen && n < 64) { strncpy(logged[n], name, 47); logged[n][47]=0; n++; }
            a2_log_f(@"[A2-GL-WL] KW 非 ES3 入口 ⇒ 空桩：%s", name);
            return (void *)a2_glstub_unlisted;
        }
    }

    // ★拒绝把宿主 ANGLE 的 GLES1 固定管线入口交给 KW★
    //   真机证据（lastlog-83，1.7.10）：KW 初始化正常、桥附着正常，到加载画面时崩在
    //   `gl::GLES1State::loadMatrix(angle::Mat4 const&)+0x58`（ANGLE 的 libGLESv2）。
    //   成因：KW 向宿主解析器索取 GL 1.x 固定管线入口，我们把它指向了 ANGLE 的 GLES1 实现，
    //   而 ANGLE 的 GLES1 状态只在 ES1 上下文里才初始化 ⇒ 空指针 ⇒ SIGBUS。
    //   KW 自带 FPE（fpe.c）能实现这些入口，拿不到宿主实现就会回落到自己那套 —— 这正是老 Air 的行为。
    //   ⇒ 这里对这些名字一律返回 NULL，让 KW 走自己的 FPE。
    static const char *const kGLES1OnlyPrefixes[] = {
        "glMatrixMode", "glLoadIdentity", "glLoadMatrix", "glMultMatrix",
        "glPushMatrix", "glPopMatrix", "glOrtho", "glFrustum",
        "glBegin", "glEnd", "glVertex", "glTexCoord", "glColor", "glNormal",
        "glRasterPos", "glEnableClientState", "glDisableClientState",
        "glShadeModel", "glAlphaFunc", "glClipPlane", "glIndex",
        NULL
    };
    for (int i = 0; kGLES1OnlyPrefixes[i] != NULL; i++) {
        size_t n = strlen(kGLES1OnlyPrefixes[i]);
        if (strncmp(name, kGLES1OnlyPrefixes[i], n) == 0) {
            if (a2_gl_bridge_is_krypton()) {
                // ★拒绝 = 不给宿主实现，但**也不能给 NULL**★（lastlog-87：给 NULL 时 KW 会回落到
                //   宿主 eglGetProcAddress 拿回 ANGLE 的同类入口，崩点原样复现）
                //   ⇒ 改喂我们自己的空实现桩：非空指针 ⇒ KW 不再问 EGL；固定管线由它的 FPE 负责。
                void *stub = a2_gl_stub_lookup(name);
                static char logged[64][40]; static int loggedCount = 0;
                int seen = 0;
                for (int k = 0; k < loggedCount; k++) if (strncmp(logged[k], name, 39) == 0) { seen = 1; break; }
                if (!seen && loggedCount < 64) {
                    strncpy(logged[loggedCount], name, 39); logged[loggedCount][39] = '\0'; loggedCount++;
                    ++gKryptonGLES1Rejected;
                    if (stub != NULL) {
                        a2_log_f(@"[A2-GL-BRIDGE] KW 拒绝宿主 GLES1 入口：%s ⇒ 返回空实现桩（阻断 eglGetProcAddress 回落）", name);
                    } else {
                        a2_log_f(@"[A2-GL-BRIDGE] KW 拒绝宿主 GLES1 入口：%s ⇒ 返回兜底空实现桩（未逐个登记；同 ABI：void 返回、无变参）", name);
                    }
                }
                return (stub != NULL) ? stub : (void *)a2_glstub_unlisted;
            }
            return NULL;
        }
    }

    // ★GL 入口 trace（诊断用）★：1.7.10 + KW 真机表现是「过了 GL caps init 之后卡死」，
    //   而那一串调用正是 glGetString/glGetStringi/glGetIntegerv/glGetError。
    //   在这里把宿主 GLES 的这 4 个入口换成带进出日志的壳 —— 只影响 KW（走本解析器）。
    //   判据：出现 `-> enter` 但没有对应 `exit` 的那一行就是卡点。
    if (strcmp(name, "glGetString") == 0)      { if (gRealGLGetString == NULL) gRealGLGetString = (A2PFN_glGetString)sym; return (void *)a2_trace_glGetString; }
    if (strcmp(name, "glGetStringi") == 0)     { if (gRealGLGetStringi == NULL) gRealGLGetStringi = (A2PFN_glGetStringi)sym; return (void *)a2_trace_glGetStringi; }
    if (strcmp(name, "glGetIntegerv") == 0)    { if (gRealGLGetIntegerv == NULL) gRealGLGetIntegerv = (A2PFN_glGetIntegerv)sym; return (void *)a2_trace_glGetIntegerv; }
    if (strcmp(name, "glGetError") == 0)       { if (gRealGLGetError == NULL) gRealGLGetError = (A2PFN_glGetError)sym; return (void *)a2_trace_glGetError; }
    return sym;
}

/// ★显式初始化 NG-GL4ES / KW★ —— 必须在**游戏 context 成为 current 之后**调用（见 attach ⑥a）。
/// 上游原型是 `void initialize_gl4es(void)`（无返回值），所以这里的 rc 只回答「调用成没成」：
///   0  = 已调用（本轮；或同一镜像此前已初始化过）
///  -1  = 库没导出 `initialize_gl4es`（装了别的构建 ⇒ 不能假装初始化过）
static int a2_gl_bridge_krypton_initialize(void) {
    if (gRendererHandle == NULL) return -1;
    A2PFN_initialize_gl4es init =
        (A2PFN_initialize_gl4es)dlsym(gRendererHandle, "initialize_gl4es");
    if (init == NULL) return -1;
    if (gKryptonInitedHandle == gRendererHandle) return 0;   // 同一镜像已初始化（gl4es 只认第一次）
    init();
    gKryptonInitedHandle = gRendererHandle;
    return 0;
}

// ============================================================================
//  ★首次 make_current：把桥表面改绑到 GLFW 游戏宿主视图★
// ============================================================================
// 真因（真机实证，上一单）：本桥在 JVM 启动前附着到**启动器根视图**的图层；而游戏页是
//   `Natives/Input/a2_glfw_window.m` 用「全屏 modal + 黑底 gameRoot」盖上去的 `A2GlfwView`
//   ⇒ 桥照常出帧，画面却被那层黑底整块盖住（有上下文、有帧、屏幕上仍是黑的）。
// 修法：游戏真的开始用这份上下文时（Java 侧 `glfwMakeContextCurrent` → `a2_gl_bridge_make_current`），
//   若当前绑定图层**不是** GLFW 宿主视图的图层，就把 EGL 的 window surface 改挂到该视图的图层上。
//
// ★不另写渲染路径★：改挂只用 attach 里同一批 EGL 入口（eglCreateWindowSurface / eglMakeCurrent /
//   eglDestroySurface）；context、config、drawable 像素口径全不动。
// ★幂等★：`gRebindState` 为 1/2 时直接返回 ⇒ 后续 make_current 不再碰表面。
// ★不阻断★：任何一步失败只打警告，并**保留原表面**继续跑（旧绑定仍在，最多还是被黑底盖住）。
//
// 调用点（两处，都是「把上下文设为当前」的那一点）：
//   ① `a2_gl_bridge_make_current`（GLFW 的 MakeContextCurrent）；
//   ② `a2_gl_bridge_frame_work`（帧回调借上下文之前）—— 视图由主队列异步建出，首次 make_current
//      可能早于视图就绪；两个入口共用同一份状态，先到先改绑、之后就再也不动。
// ★视图时序★：MC 建窗后**只调一次** MakeContextCurrent，而视图是异步建的 ⇒ 非主线程上第一次进来
//   时会做一次**有界等待**（≤500ms）等视图就绪；主线程上不等（视图就在主队列上建）。

/// CGRect 的内存布局（4 个 CGFloat；arm64 上 CGFloat = double）。
/// ★为什么自己声明★：同 `A2GlBridgeLayerSize` —— 本层不 import UIKit/QuartzCore。
typedef struct { double x, y, width, height; } A2GlBridgeRect;

/// 取视图的 bounds（取不到回全 0，不猜）。
static A2GlBridgeRect a2_gl_bridge_view_bounds(void *view) {
    A2GlBridgeRect r = { 0.0, 0.0, 0.0, 0.0 };
    if (view == NULL) return r;
    id obj = (__bridge id)view;
    SEL sel = NSSelectorFromString(@"bounds");
    if (obj != nil && [obj respondsToSelector:sel]) {
        A2GlBridgeRect (*getBounds)(id, SEL) = (A2GlBridgeRect (*)(id, SEL))objc_msgSend;
        r = getBounds(obj, sel);
    }
    return r;
}

/// 视图所在的窗口（只用于判据行的 windowLevel；取不到回 NULL）。
static void *a2_gl_bridge_view_window(void *view) {
    if (view == NULL) return NULL;
    id obj = (__bridge id)view;
    SEL sel = NSSelectorFromString(@"window");
    if (obj == nil || ![obj respondsToSelector:sel]) return NULL;
    id (*sendWindow)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id win = sendWindow(obj, sel);
    return (__bridge void *)win;
}

/// 见上：首次 make_current 时把表面改挂到 GLFW 宿主视图（只做一次）。
static void a2_gl_bridge_ensure_game_view_surface(void) {
    if (gRebindState != 0) return;                        // 已成 / 已放弃 ⇒ 不再动表面
    if (!gAttached || gEglCreateWindowSurface == NULL || gEglMakeCurrent == NULL ||
        gDpy == A2_EGL_NO_DISPLAY || gCfg == NULL || gCtx == A2_EGL_NO_CONTEXT) {
        return;                                           // 未附着 / 入口不全：不参与（attach 自会报）
    }

    void *gameView = a2_glfw_window_game_view();
    if (gameView == NULL && ![NSThread isMainThread]) {
        // ★有界等待（只在非主线程做）★
        //   宿主视图由主队列**异步**建出（a2_glfw_window.m 的建窗 UIKit 段），而 MC 在建窗后
        //   只调一次 `glfwMakeContextCurrent` ⇒ 这一次如果视图还没好，可能就再没有第二次机会。
        //   这里最多等 500ms（100 × 5ms）只等「视图就绪」这一刻；到点仍没有 ⇒ 照常先返回、
        //   继续用原表面（不阻断启动），并留给后续 make_current 再试。
        //   ★主线程上不等★：视图正是在主队列上建的，主线程等自己只会白等（还会拖慢启动）。
        for (int i = 0; i < 100 && gameView == NULL; i++) {
            usleep(5 * 1000);
            gameView = a2_glfw_window_game_view();
        }
    }
    if (gameView == NULL) {
        // ★不置 gRebindState★：留给下一次 make_current 再试；提示只打一次，避免每帧刷日志。
        if (!gRebindWaitLogged) {
            gRebindWaitLogged = 1;
            a2_log_f(@"[A2-GLBRIDGE] 首次 makeCurrent：GLFW 宿主视图尚未就绪（视图在主队列异步创建）"
                     @"⇒ 本次仍用现有表面，下次 makeCurrent 再改绑");
        }
        return;
    }
    gRebindWaitLogged = 1;

    void *want = a2_gl_bridge_renderable_handle(gameView);
    if (want == NULL) {
        a2_log_f(@"[A2-GLBRIDGE] ★警告★：改绑跳过 —— GLFW 宿主视图取不到可渲染图层（view=%p）；继续用原表面",
                 gameView);
        gRebindState = 2;
        return;
    }
    if (want == gBoundRenderable) {                       // 已经绑在同一图层上
        gRebindState = 1;
        a2_log_f(@"[A2-GLBRIDGE] 首次 makeCurrent：当前绑定图层就是 GLFW 宿主视图（renderable=%p）⇒ 不改绑",
                 want);
        return;
    }

    // ---- ① 图层口径对齐（与 attach ⑥0b 同一套口径；只对**新**图层做）----
    A2GlBridgeRect b = a2_gl_bridge_view_bounds(gameView);
    int ptsW = (int) (b.width + 0.5);
    if (gWidthPixels > 0 && gHeightPixels > 0) {
        a2_gl_bridge_align_drawable(want, gWidthPixels, gHeightPixels, ptsW,
                                    (ptsW > 0) ? ((double) gWidthPixels / (double) ptsW) : 1.0);
    }

    // ---- ② 先建新面、再切、最后销毁旧面（任何一步失败都保留旧面）----
    A2EGLSurface newSurf = A2_EGL_NO_SURFACE;
    if (a2_gl_bridge_is_krypton()) {
        // KW 家族在 attach 里就是「NULL 属性」（对齐老 Air 建面顺序）⇒ 这里保持一致。
        newSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)want, NULL);
    } else {
        const A2EGLint surfAttribs[] = {
            A2_EGL_WIDTH,  (A2EGLint)gWidthPixels,
            A2_EGL_HEIGHT, (A2EGLint)gHeightPixels,
            A2_EGL_NONE
        };
        if (gWidthPixels > 0 && gHeightPixels > 0) {
            newSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)want, surfAttribs);
        }
        if (newSurf == A2_EGL_NO_SURFACE) {               // 实现不认 EGL_WIDTH/HEIGHT ⇒ 退到无属性
            newSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)want, NULL);
        }
    }
    if (newSurf == A2_EGL_NO_SURFACE) {
        a2_log_f(@"[A2-GLBRIDGE] ★警告★：改绑失败 —— eglCreateWindowSurface(GLFW 宿主视图) 返回 NO_SURFACE"
                 @"（eglError=0x%x；句柄=%p）⇒ 继续用原表面，不阻断启动",
                 (unsigned) (gEglGetError ? gEglGetError() : 0), want);
        gRebindState = 2;
        return;
    }
    if (!gEglMakeCurrent(gDpy, newSurf, newSurf, gCtx)) {
        a2_log_f(@"[A2-GLBRIDGE] ★警告★：改绑失败 —— 新表面 eglMakeCurrent 返回 false（eglError=0x%x；"
                 @"surface=%p）⇒ 销毁新面，继续用原表面，不阻断启动",
                 (unsigned) (gEglGetError ? gEglGetError() : 0), (void *)newSurf);
        if (gEglDestroySurface != NULL) gEglDestroySurface(gDpy, newSurf);
        gRebindState = 2;
        return;
    }

    A2EGLSurface oldSurf = gSurf;
    gSurf = newSurf;                                      // ★此后的 make_current / 帧动作都用新面★
    gBoundRenderable = want;
    if (gEglDestroySurface != NULL && oldSurf != A2_EGL_NO_SURFACE) {
        gEglDestroySurface(gDpy, oldSurf);                // 旧的（启动器图层）面此时已不是当前面
    }
    gRebindState = 1;

    // ★判据行（真机 grep 这一行即可确认改绑生效）★
    a2_log_f(@"[A2-GLBRIDGE] ★重绑到 GLFW 宿主视图★ view=%s level=%.0f bounds=%.0fx%.0f（首次 make_current）",
             NSStringFromClass([(__bridge id) gameView class]).UTF8String,
             a2_gl_bridge_window_level(a2_gl_bridge_view_window(gameView)),
             b.width, b.height);
}

/// ★帧回调体★：本层每帧做一次可判据的可用性动作，并按**当前渲染倍率的 drawable 像素尺寸**
/// 清屏/呈现（[FRAME-PERF]）。调用点：`a2_gl_bridge_attach`（附着后立即渲染一帧）与
/// `a2_gl_bridge_present_frame`（启动链的基线帧循环）。
///
/// ★缩小的是这里的像素数，不是逻辑尺寸★：宿主表面里点尺寸（widthPoints/heightPoints）没动，
/// drawable 像素（gWidthPixels/gHeightPixels）已是「表面像素 × 渲染倍率」——
/// 本函数把这些像素设进 viewport/scissor、再清屏，就是「分辨率缩放真的落到帧上」的那一处。
///
/// ★为什么清成透明 (0,0,0,0) 而不是实色★：宿主表面当前是承载游戏的宿主窗口，
/// 实色清屏会让 UI 整块变黑（可见破坏）；透明清屏同样能证明「上下文可用」，
/// 且视觉上通常无变化 —— 证据由 scissor 读回 + 判据行 + glGetError 承担。
static void a2_gl_bridge_frame_work(void) {
    if (!gAttached) return;

    // ★首次 make_current 的表面改绑★（游戏页盖在黑底上 ⇒ 必须改挂到 GLFW 宿主视图）
    a2_gl_bridge_ensure_game_view_surface();

    // ★2026-10-18 真机证据★ EGL 上下文同一时刻只能绑在【一个】线程上。
    //   我们过去在附着时 eglMakeCurrent 后一直占着它 ⇒ MC 渲染线程调
    //   glfwMakeContextCurrent 得到 FAILED ⇒ MC 侧 GL.createCapabilities 抛
    //   "There is no OpenGL context current in the current thread"。
    //   ⇒ 本层每帧【借用】上下文：进来绑定，画完立刻归还（NO_SURFACE/NO_CONTEXT）。
    if (gEglMakeCurrent != NULL) gEglMakeCurrent(gDpy, gSurf, gSurf, gCtx);

    gFrameCount++;
    uint32_t glErr = 0;

    const int w = gWidthPixels;    // = 缩放后的 drawable 宽（像素）
    const int h = gHeightPixels;   // = 缩放后的 drawable 高（像素）

    // ---- ① 按缩放后的像素尺寸设 viewport / scissor（清屏与后续绘制都落在这个区域里）----
    if (gGLViewport != NULL) gGLViewport(0, 0, w, h);
    if (gGLEnable != NULL)   gGLEnable(A2_GL_SCISSOR_TEST);
    if (gGLScissor != NULL)  gGLScissor(0, 0, w, h);

    if (gGLClearColor != NULL) gGLClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    if (gGLClear != NULL)      gGLClear(A2_GL_COLOR_BUFFER_BIT);

    // ---- ② ★可核对证据★：读回 scissor box（= 本帧真正被清屏/绘制的像素区域）----
    //   与 gWidthPixels/gHeightPixels 一致 ⇒ 「本帧确实按缩放尺寸清屏」有据可查；
    //   实现不提供 glGetIntegerv/glScissor 时退回报请求值，并在判据行点明「无读回」。
    int clearW = w, clearH = h;
    BOOL boxReadBack = NO;
    if (gGLGetIntegerv != NULL && gGLScissor != NULL) {
        int scissorBox[4] = { 0, 0, 0, 0 };
        gGLGetIntegerv(A2_GL_SCISSOR_BOX, scissorBox);
        clearW = scissorBox[2];
        clearH = scissorBox[3];
        boxReadBack = YES;
    }
    if (gGLDisable != NULL) gGLDisable(A2_GL_SCISSOR_TEST);   // ★还原状态★：不把 scissor 留给后续使用者

    if (gEglSwapBuffers != NULL) gEglSwapBuffers(gDpy, gSurf);
    // ★2026-10-18 真机证据★ 渲染器 = MobileGlues 时 glGetError 会打进它尚未初始化的
    //   跳转表 ⇒ pc=0x0 SIGSEGV（libmobileglues.dylib+0x3e4f8 glGetError+0x14）。
    //   这句只为打判据行，不值得为它崩，所以该后端下跳过（其余后端照旧）。
    //   ★判据来源只有一处★（a2_gl_bridge_is_mobileglues），不各写一份字面量。
    BOOL backendIsMG = (a2_gl_bridge_is_mobileglues() != 0);
    if (gGLGetError != NULL && !backendIsMG) glErr = gGLGetError();

    // ---- ③ 记进帧性能判据（中立数值；draw=1 = 本帧一次清屏；shaderNew=0 = 本层不建着色器/管线）----
    a2_frame_perf_record_frame(1, 0, (gEglSwapBuffers != NULL) ? 1 : 0, clearW, clearH);

    // ★首帧通知★ 第 60 帧（约 1 秒）时通知 UI 撤启动遮罩：此时游戏确实在画了。
    if (gFrameCount == 60) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"A2GameFirstFrame" object:nil];
        });
    }
    a2_log_f(@"%s 帧回调 #%d 已按缩放尺寸清屏/呈现（drawable=%dx%d 像素；scissor 读回=%dx%d %s）"
             "glGetError=0x%x ⇒ %s（surface=%p）",
             A2GlBridgeJudgementTag, gFrameCount, w, h, clearW, clearH,
             boxReadBack ? "[已读回]" : "[实现无读回，报请求值]",
             (unsigned)glErr,
             (glErr == 0) ? "GL 上下文可用" : "★GL 上下文报错★",
             (void *)gSurf);

    if (gFrameCb != NULL) gFrameCb(gFrameUser);

    // ★归还上下文★：把本线程的 current 解绑，MC 的渲染线程才绑得上。
    if (gEglMakeCurrent != NULL) gEglMakeCurrent(gDpy, NULL, NULL, NULL);
}

// ============================================================================
//  公开 API
// ============================================================================

// ★2026-10-18 真机证据★ MC 报 "There is no OpenGL context current in the current thread"
//   （GL.createCapabilities ← GlDevice.<init> ← Minecraft.<init>）。
//   原因：EGL 上下文只在建窗口的线程里创建过，Java 渲染线程从未 eglMakeCurrent。
//   本函数把已有上下文设为【调用线程】的当前上下文 —— 由 GLFW 桥的 MakeContextCurrent 调用。
int a2_gl_bridge_make_current(void) {
    if (gEglMakeCurrent == NULL || gDpy == A2_EGL_NO_DISPLAY || gCtx == A2_EGL_NO_CONTEXT) {
        a2_log_f(@"[A2-GLBRIDGE] makeCurrent 跳过：display/context 未就绪");
        return -1;
    }
    // ★首次 make_current：若还绑在启动器图层上，先把表面改挂到 GLFW 宿主视图★（只做一次）
    a2_gl_bridge_ensure_game_view_surface();
    A2EGLBoolean ok = gEglMakeCurrent(gDpy, gSurf, gSurf, gCtx);
    a2_log_f(@"[A2-GLBRIDGE] makeCurrent -> %s", ok ? "OK" : "FAILED");
    return ok ? 0 : -2;
}

void a2_gl_bridge_present_frame(void) {
    // 未附着（例如所选后端不是 EGL/GL 系 ⇒ attach 返回 Skipped）⇒ 无操作：
    // 不产帧、不记数（帧性能判据会如实报 frames=0）。
    a2_gl_bridge_frame_work();
}

int a2_gl_bridge_backend_is_egl(const char *rendererName) {
    if (rendererName == NULL || rendererName[0] == '\0') return 0;
    // ★后端词汇表唯一来源是 a2_renderer.h 的常量★（不重复字面量）。
    // 将来多一个 EGL/GL 系后端 ⇒ 只在这里加一行比较。
    //
    // ★2026-10-18 真机证据★ 只要后端最终把 GL 调用落到 ANGLE/GLES，就必须先有 EGL 上下文：
    //   MC 的 `Minecraft.<init> → new GlDevice() → GL.createCapabilities()` 无条件执行，
    //   而 LWJGL 会向 GLFW 要"当前上下文"，拿不到就抛
    //   `IllegalStateException: There is no OpenGL context current in the current thread`。
    //   metallum 是 GL→Metal 翻译器，同样需要这个上下文对象（它接管的是 GL 入口，不是 GLFW）。
    //   只把 Vulkan 直通类（MoltenVK）排除在外。
    // 注：A2RendererCompatDylibName 是 NSString 常量，不是编译期字面量 ⇒ 这里用字面量（值相同）。
    const char *kEglBackends[] = {
        "libgl4es_114.dylib",
        "libmetallum.dylib",         // Metal（自研）
        "libmobileglues.dylib",
        "libnggl4es.dylib",
        "libnggl4es_kw.dylib",       // NG-GL4ES / KW（≤1.12.2 默认；宿主必须显式 initialize_gl4es）
        "libtinygl4angle.dylib",
    };
    for (size_t i = 0; i < sizeof(kEglBackends) / sizeof(kEglBackends[0]); i++) {
        if (kEglBackends[i] != NULL && strcmp(rendererName, kEglBackends[i]) == 0) return 1;
    }
    return 0;
}

int a2_gl_bridge_attach(const A2GlHostSurface *host, NSString *frameworksPath) {
    if (host == NULL) {
        a2_log_f(@"%s ★阻断★：宿主表面为空（调用方未传 host）", A2GlBridgeJudgementTag);
        return A2GlBridgeErrNoSurface;
    }

    const char *rendererName = host->rendererName;
    if (rendererName != NULL) {
        snprintf(gBackendName, sizeof(gBackendName), "%s", rendererName);
    }

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
    gBoundRenderable = renderable;   // ★本面绑着的图层★（首次 make_current 据此判要不要改挂到游戏宿主视图）

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

    // ---- ④ dlopen（EGL/GLES 兼容底的旗标按后端定：见下；后端本体恒 RTLD_GLOBAL）----
    // ★KW 时用 RTLD_LOCAL★（真机 lastlog-84）：ANGLE 的 libGLESv2 若以 GLOBAL 加载，
    //   它导出的 GLES1 入口（glLoadMatrixf 等）会被 MC/LWJGL 的 dlsym(RTLD_DEFAULT) 抢先命中，
    //   从而绕过 KW 自带 FPE，直接崩在 ANGLE 的 GLES1State（未初始化）。⇒ 只让 KW 自己全局可见。
    // ★MG 时同样 LOCAL★（真机 lastlog-101）：MG 2.0.16 加载后自己取证报
    //   `[MG] SYMBOL THEFT: flat namespace resolves glFramebufferTexture2D/glTexImage2D/glDrawArrays
    //    to 0x12669a…, this layer's export is 0x125b6… -- the application is calling someone else`
    //   —— 那些 0x12669a… 全在 ANGLE(libGLESv2) 的映像里（MG 自己的导出在 0x125b6…/0x125b8…），
    //   就是我们以 RTLD_GLOBAL 加载的兼容底把 gl* 抢进了 flat namespace。
    //   ⇒ MG 后端下 EGL/GLES 一律 RTLD_LOCAL：flat namespace 里只剩 MG 自己的 gl* 导出。
    //   MG 要 ES 驱动入口时不靠 flat namespace（它自己按 handle 解析 / 走 eglGetProcAddress），
    //   兼容底仍由本桥按句柄 dlsym 使用 ⇒ 改 LOCAL 不影响建面。
    // ★KW 沿用原来的模糊判定★（`strstr`）：`libnggl4es.dylib`（老的那支）与
    //   `libnggl4es_kw.dylib` 都按 KW 处理 —— 这是 lastlog-84 起的行为，不在本单里改口径。
    const BOOL a2BackendIsKW = (strstr(rendererName, "krypton") != NULL) || (strstr(rendererName, "nggl4es") != NULL);
    const BOOL a2BackendIsMG = a2_gl_bridge_is_mobileglues();
    const BOOL a2DepFlagsLocal = (a2BackendIsKW || a2BackendIsMG);
    const int a2GlDepFlags = RTLD_LAZY | (a2DepFlagsLocal ? RTLD_LOCAL : RTLD_GLOBAL);
    a2_log_f(@"[A2-GLBRIDGE] 依赖加载旗标：%s（后端=%s）",
             a2DepFlagsLocal ? "RTLD_LOCAL" : "RTLD_GLOBAL", gBackendName);
    if (a2DepFlagsLocal) {
        a2_log_f(@"[A2-GLBRIDGE] 旗标理由：%s ⇒ 不让兼容底的 gl* 进 flat namespace（防符号被抢）",
                 a2BackendIsKW ? "KW 要自己的 GLES1 入口生效"
                               : "MG 自己导出整套 gl*（真机 SYMBOL THEFT 即此因）");
    }

    gEglHandle      = dlopen(eglPath.UTF8String,      a2GlDepFlags);
    if (gEglHandle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"%s ★阻断★：EGL 兼容底 dlopen 失败 %s（%s）",
                 A2GlBridgeJudgementTag, eglPath.UTF8String, err ? err : "(dlerror 无输出)");
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    gGlesHandle     = dlopen(glesPath.UTF8String,     a2GlDepFlags);
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

    if (a2BackendIsMG) {
        // ---- ④a2 ★符号归属核对★（MG 自己要报 SYMBOL THEFT 的那件事，我们自己也取一份证据）----
        //   真机 lastlog-101：`[MG] SYMBOL THEFT … the application is calling someone else`。
        //   本行直接回答「flat namespace 里这个 gl* 归谁」—— 与 MG 自己的报错互为旁证，
        //   也用来验证 ④ 的 RTLD_LOCAL 到底有没有把 ANGLE 的导出挡在全局命名空间外。
        void *ownSym  = dlsym(gRendererHandle, "glTexImage2D");
        void *flatSym = dlsym(RTLD_DEFAULT, "glTexImage2D");
        a2_log_f(@"%s 符号归属核对：glTexImage2D 后端导出=%p / flat=%p ⇒ %s",
                 A2GlBridgeJudgementTag, ownSym, flatSym,
                 (ownSym != NULL && flatSym == ownSym)
                     ? "归 MG 自己（未被抢）"
                     : "★被别的库抢走★（flat namespace 里还有别的导出者：查是否有库以 GLOBAL 抢先加载）");
    }

    // ---- ④b ★NG-GL4ES / KW：gl4es 血统的运行时开关（无条件，对齐老 Air）★ ----
    //   老 Air 在 JavaLauncher 里**无条件全局**设这两个（`Natives/JavaLauncher.m:469` / `:472`）：
    //   ① `LIBGL_NOINTOVLHACK=1`：关掉 gl4es 的「重载函数 hack」包装层（`src/gl/init.c:504` 读它）；
    //   ② `LIBGL_NORMALIZE=1`：修 GL4ES 1.1.5+ 的 banner/羊白色偏差（`src/gl/init.c:696` 读它）。
    //   两者都由 `initialize_gl4es()` 读环境变量 ⇒ 必须在下游 ⑥a 的 init 之前设好。
    //   ★不设 LIBGL_ES / LIBGL_GL★：老 Air 从不设，KW 的档位来自编译期 `-DDEFAULT_ES=3`
    //   （`src/gl/init.c:214-224`：未设/非法 ⇒ 落回 DEFAULT_ES=3）。
    //   ★解析器（set_getprocaddress）不在这里注册★：老 Air 在 makeCurrent **之后**才注册
    //   （`gl4es_family_boot.m:79-83`），见下游 ⑥a 之前那段。
    if (a2_gl_bridge_is_krypton()) {
        setenv("LIBGL_NOINTOVLHACK", "1", 1);
        setenv("LIBGL_NORMALIZE", "1", 1);
    }

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
    gEglQuerySurface      = (A2PFN_eglQuerySurface)dlsym(gEglHandle, "eglQuerySurface");

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

    // ★本段起 isKrypton 是「只改 KW 那条路径」的唯一开关★：KW（NG-GL4ES）按老 Air 的口径走，
    //   其它后端（metallum / MG / MobileGlues …）的 config、surface、顺序**一字不动**。
    const BOOL isKrypton = a2_gl_bridge_is_krypton();

    {
        // ★NG-GL4ES / KW 的 config：逐条对齐老 Air `Natives/ctxbridges/gl_bridge.m:1690-1698`（926629869）★
        //   · `EGL_SURFACE_TYPE = WINDOW|PBUFFER`（老 Air :1696 两项都给）
        //   · `EGL_RENDERABLE_TYPE = EGL_OPENGL_ES3_BIT (0x40)`（老 Air :1697 —— ★P0★：曾经误用 ES2_BIT）
        //   · RGBA=8/8/8/8、`EGL_DEPTH_SIZE = 24`（老 Air :1690-1695）
        //   · **不加** `EGL_STENCIL_SIZE`（老 Air 的 attribs 里没有这一项）
        const A2EGLint cfgAttribsKrypton[] = {
            A2_EGL_SURFACE_TYPE,    A2_EGL_WINDOW_BIT | A2_EGL_PBUFFER_BIT,
            A2_EGL_RENDERABLE_TYPE, A2_EGL_OPENGL_ES3_BIT,
            A2_EGL_RED_SIZE,        8,
            A2_EGL_GREEN_SIZE,      8,
            A2_EGL_BLUE_SIZE,       8,
            A2_EGL_ALPHA_SIZE,      8,
            A2_EGL_DEPTH_SIZE,      24,
            A2_EGL_NONE
        };
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
        if (!gEglChooseConfig(gDpy, isKrypton ? cfgAttribsKrypton : cfgAttribs, &gCfg, 1, &numCfg)
            || numCfg < 1 || gCfg == NULL) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglChooseConfig 无可用配置（eglError=0x%x）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
    }

    // ---- ⑥0b ★drawable 尺寸口径统一★（真机 1.20.1+MobileGlues：请求 2622x1206 / 实现 874x402）----
    // 口径：drawable 像素 = 宿主窗口 bounds（点）× screen.scale（渲染倍率已在上层乘进 widthPixels）。
    // ★三处必须是同一份值★：① 向实现请求的 EGL_WIDTH/EGL_HEIGHT；② 宿主图层的
    //   contentsScale / drawableSize；③ 本层 viewport/清屏区域（⑧ 的 gWidthPixels/gHeightPixels）。
    // 若宿主只能给点尺寸（图层不接受像素口径），请求值也一律改用点 —— 绝不「请求 3 倍、实得 1 倍」。
    int drawableW = host->surface.widthPixels;
    int drawableH = host->surface.heightPixels;
    if (drawableW <= 0 || drawableH <= 0) {
        drawableW = host->surface.widthPoints;
        drawableH = host->surface.heightPoints;
        a2_log_f(@"%s 宿主未给像素尺寸 ⇒ 请求值与 drawable 一律改用点尺寸（%dx%d）",
                 A2GlBridgeJudgementTag, drawableW, drawableH);
    }
    if (!a2_gl_bridge_align_drawable(renderable, drawableW, drawableH,
                                     host->surface.widthPoints, host->surface.contentScaleX)) {
        // 句柄既不认 contentsScale 也不认 drawableSize（或它根本不是图层）
        // ⇒ 实现只能按点尺寸建 drawable，请求值跟着改用点，两边保持一致。
        if (drawableW != host->surface.widthPoints || drawableH != host->surface.heightPoints) {
            a2_log_f(@"%s ★宿主只能给点尺寸★：请求值由 %dx%d 像素改用 %dx%d 点（两边必须一致）",
                     A2GlBridgeJudgementTag, drawableW, drawableH,
                     host->surface.widthPoints, host->surface.heightPoints);
            drawableW = host->surface.widthPoints;
            drawableH = host->surface.heightPoints;
        }
    }
    a2_log_f(@"%s drawable 目标=%dx%d 像素；点=%dx%d；scale=%.2f；宿主窗口 level=%.0f",
             A2GlBridgeJudgementTag, drawableW, drawableH,
             host->surface.widthPoints, host->surface.heightPoints,
             (double)host->surface.contentScaleX,
             a2_gl_bridge_window_level(host->surface.nativeWindow));

    // ---- ⑥0 ★NG-GL4ES / KW：surface 先于 context（对齐老 Air 建面顺序）★ ----
    //   老 Air `gl_bridge.m:1838`（eglCreateWindowSurface）在建 context 的 `:1875` **之前**，
    //   且 gl4es 家族传的是 **NULL** 属性（只有 MobileGL 才显式给 EGL_WIDTH/HEIGHT）⇒
    //   KW 这里也直接 NULL，不做「先带尺寸、失败再退」的多余尝试。
    if (isKrypton) {
        gSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)renderable, NULL);
        if (gSurf == A2_EGL_NO_SURFACE) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglCreateWindowSurface(NULL 属性) 返回 NO_SURFACE"
                     @"（eglError=0x%x；句柄=%p 像素格式=%d）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0),
                     renderable, host->surface.pixelFormat);
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
    }

    {
        // ★NG-GL4ES / KW 是 `-DDEFAULT_ES=3` 编的★（上游口径：只在 GLES3 上转译，绕开 ANGLE 的
        //   GLES1 路径）⇒ 它要 ES3 上下文；其它后端仍然只要 ES2（行为一字不改）。
        //   实现上先按需版本建、被拒再退 ES2 —— 退回去时**如实记一行**，不假装拿到了 ES3。
        //
        // ★A/B 探针：偏好键 `A2KWUseES1`（Boolean，默认 NO）★
        //   NO  ⇒ 请求 ES3（现状）
        //   YES ⇒ 请求 ES1（EGL_OPENGL_ES_API + client version 1；验证「谁在用 GLES1 入口、
        //         而 ANGLE 的 GLES1 状态未初始化」这条假设）
        //   只作用于 NG-GL4ES / KW；键不存在时用编译期默认 A2_KW_CONTEXT_MODE_DEFAULT（A/B 两包靠它分叉）。
        // ★KW 上下文模式（三档）★：A2KWContextMode = "es1" | "es2" | "es3"（缺省看编译期宏）。
        //   真机历史：ES3 ⇒ KW 调 GLES1 撞 ANGLE GLES1State 崩；ES1 ⇒ 只有 GL ES1.1 能力、MC 拒启；
        //   ES2 与「ES3+shader 模拟」两条路待验。
        NSInteger kwMode = A2_KW_CONTEXT_MODE_DEFAULT;   // 0=ES3 1=ES1 2=ES2
        {
            id m = [NSUserDefaults.standardUserDefaults objectForKey:A2GlBridgeKWContextModeKey];
            if ([m isKindOfClass:NSString.class]) {
                NSString *s = [(NSString *)m lowercaseString];
                if ([s isEqualToString:@"es1"]) kwMode = 1;
                else if ([s isEqualToString:@"es2"]) kwMode = 2;
                else if ([s isEqualToString:@"es3"]) kwMode = 0;
            } else if (m != nil) {
                // 兼容旧键 A2KWUseES1
                kwMode = [NSUserDefaults.standardUserDefaults boolForKey:A2GlBridgeKWUseES1Key] ? 1 : 0;
            }
        }
        if (isKrypton) {
            a2_log_f(@"[A2-GL-BRIDGE] KW 上下文模式=%s（键 A2KWContextMode；0=ES3 1=ES1 2=ES2）",
                     (kwMode == 1) ? "ES1" : ((kwMode == 2) ? "ES2" : "ES3"));
        }
        const A2EGLint wantVersion = isKrypton ? (kwMode == 1 ? 1 : (kwMode == 2 ? 2 : 3)) : 2;
        A2EGLint gotVersion = wantVersion;   // ★实际拿到的版本★（回退时为 fbVersion，日志按它记，不假装）
        const A2EGLint ctxAttribs[] = { A2_EGL_CONTEXT_CLIENT_VERSION, wantVersion, A2_EGL_NONE };
        gCtx = gEglCreateContext(gDpy, gCfg, A2_EGL_NO_CONTEXT, ctxAttribs);
        if (gCtx == A2_EGL_NO_CONTEXT && wantVersion != 2) {
            // ES1 被拒时**退到基线 ES3**（而不是 ES2）：KW 是 DEFAULT_ES=3 编的，ES2 是它没测过的
            // 第三态 ⇒ 退 ES2 会让 A/B 比不出东西；退 ES3 才等于「回到 A 包现状」。
            const A2EGLint fbVersion = (wantVersion == 1) ? 3 : 2;
            a2_log_f(@"[A2-RENDERER] NG-GL4ES 上下文：ES%ld 被拒（eglError=0x%x）⇒ 退 ES%ld 重试"
                     @"（GLES3 转译路径可能不可用）", (long)wantVersion,
                     (unsigned)(gEglGetError ? gEglGetError() : 0), (long)fbVersion);
            const A2EGLint ctxAttribs2[] = { A2_EGL_CONTEXT_CLIENT_VERSION, fbVersion, A2_EGL_NONE };
            gCtx = gEglCreateContext(gDpy, gCfg, A2_EGL_NO_CONTEXT, ctxAttribs2);
            if (gCtx != A2_EGL_NO_CONTEXT) gotVersion = fbVersion;
        }
        if (gCtx == A2_EGL_NO_CONTEXT) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglCreateContext 返回 NO_CONTEXT（eglError=0x%x）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
        if (wantVersion != 2) {
            a2_log_f(@"[A2-RENDERER] NG-GL4ES 上下文就绪：请求 client version=ES%ld 实得=ES%ld context=%p",
                     (long)wantVersion, (long)gotVersion, (void *)gCtx);
        }
    }

    // ---- ⑥1 其余后端：surface（KW 已在 ⑥0 建过，属性为 NULL）----
    if (!isKrypton) {
        // 先带尺寸建；若实现不接受 EGL_WIDTH/HEIGHT（非核心 EGL 属性）再退到无属性。
        const A2EGLint surfAttribs[] = {
            A2_EGL_WIDTH,  (A2EGLint)drawableW,
            A2_EGL_HEIGHT, (A2EGLint)drawableH,
            A2_EGL_NONE
        };
        gSurf = gEglCreateWindowSurface(gDpy, gCfg, (A2EGLNativeWindowType)renderable, surfAttribs);
        if (gSurf == A2_EGL_NO_SURFACE) {
            A2EGLint e1 = gEglGetError ? gEglGetError() : 0;
            a2_log_f(@"%s EGL 建面：带尺寸(%dx%d 像素)失败 eglError=0x%x ⇒ 退到无属性重试",
                     A2GlBridgeJudgementTag, drawableW, drawableH, (unsigned)e1);
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

    // ---- ⑥a ★NG-GL4ES / KW：makeCurrent 之后注册解析器 → 再显式初始化（NO_INIT_CONSTRUCTOR）★ ----
    //   顺序就是老 Air 的契约：`gl4es_family_boot.m:79-83` 先 `set_getprocaddress(resolver)`、
    //   再 `initialize_gl4es()`，而它的调用点 `egl_bridge.m:973` 严格在 `br_make_current` 成功**之后**。
    //   本桥此前在建 context 之前注册（语义等价但顺序不同）⇒ 现按老 Air 收拢到 makeCurrent 之后，
    //   与「库已 dlopen → context 已 current → 注册解析器 → init」这条验证过的链路一致。
    //   `initialize_gl4es()` 是 `-DNO_INIT_CONSTRUCTOR` 后唯一的初始化入口：漏了「不崩但黑屏」（GL 入口全空）。
    if (isKrypton) {
        A2PFN_set_getprocaddress setResolver =
            (A2PFN_set_getprocaddress)dlsym(gRendererHandle, "set_getprocaddress");
        if (setResolver == NULL) {
            a2_log_f(@"[A2-RENDERER] NG-GL4ES 初始化 rc=-1：缺 set_getprocaddress 入口"
                     @"（%s 不是预期的构建）⇒ 阻断", rendererName);
            a2_gl_bridge_teardown();
            return A2GlBridgeErrLoadFailed;
        }
        setResolver(a2_gl_bridge_gles_getprocaddress);

        // ★一处汇总判据行★（真机 grep 这一串即可确认四处对齐都生效）
        a2_log_f(@"[A2-GL-BRIDGE] KW 对齐老Air：NOINTOVLHACK/NORMALIZE 已设；config=ES3_BIT；"
                 @"surface=NULL；init 顺序=after-makeCurrent");

        // ★D 包用★：在初始化之前注入 gl4es 血统的运行时开关，让它用 shader 模拟 GL2.1
        //   而不是把固定管线调用直通给 ANGLE 的 GLES1 实现（真机：ES3 下直通会 SIGBUS）。
        //   ★默认关闭★：老 Air 从不设 LIBGL_ES/LIBGL_GL，档位来自编译期 -DDEFAULT_ES=3。
        if (A2_KW_ENV_HINT_DEFAULT != 0) {
            setenv("LIBGL_ES", "3", 1);
            setenv("LIBGL_GL", "21", 1);
            a2_log_f(@"[A2-GL-BRIDGE] KW env LIBGL_ES=3 LIBGL_GL=21（编译期 A2_KW_ENV_HINT_DEFAULT=1）");
        }
        int initRC = a2_gl_bridge_krypton_initialize();
        a2_log_f(@"[A2-RENDERER] NG-GL4ES 初始化 rc=%d（backend=%s；context=%p 已 current）%s",
                 initRC, rendererName, (void *)gCtx,
                 (initRC == 0) ? " ⇒ 已在宿主 context 上初始化" : " ⇒ ★阻断：缺 initialize_gl4es 入口★");
        if (initRC != 0) {
            a2_gl_bridge_teardown();
            return A2GlBridgeErrLoadFailed;
        }

        // ★函数指针取证★（真机 lastlog-83/84/86 同一个崩点：ANGLE 的 gl::GLES1State::loadMatrix）
        //   已知：不是 KW 二进制、不是全局符号、不是 KW 通过解析器索取。
        //   ⇒ 打印同一名字在「KW 本体 / ANGLE / 我们的解析器」三处的地址，判断 MC 实际拿到的是谁。
        {
            void *kwLM  = dlsym(gRendererHandle, "glLoadMatrixf");
            void *angLM = (gGlesHandle != NULL) ? dlsym(gGlesHandle, "glLoadMatrixf") : NULL;
            void *resLM = a2_gl_bridge_gles_getprocaddress("glLoadMatrixf");
            a2_log_f(@"[A2-GL-PTR] glLoadMatrixf: KW=%p ANGLE=%p resolver=%p"
                     @"（本轮期望：resolver = 我们的空实现桩，既不是 0 也不是 ANGLE）",
                     kwLM, angLM, resLM);
            a2_log_f(@"[A2-GL-PTR] 空桩表 %d 条；KW 已拒绝 %d 个宿主 GLES1 入口；桩累计被调用 %d 次",
                     (int)(sizeof(kGLStubs) / sizeof(kGLStubs[0]) - 1), (int)gKryptonGLES1Rejected,
                     (int)gGLStubCalls);
            void *kwI = dlsym(gRendererHandle, "initialize_gl4es");
            void *kwS = dlsym(gRendererHandle, "set_getprocaddress");
            a2_log_f(@"[A2-GL-PTR] KW 本体 initialize_gl4es=%p set_getprocaddress=%p handle=%p",
                     kwI, kwS, gRendererHandle);
            // ★同一手法查 glLoadIdentity★：hs_err 栈显示 MC 的 GL11.glLoadIdentity 落到了 ANGLE。
            //   若 KW 侧为 NULL ⇒ KW 没导出它，LWJGL 才会回落到别的镜像（修法明确）。
            void *kwLI  = dlsym(gRendererHandle, "glLoadIdentity");
            void *angLI = (gGlesHandle != NULL) ? dlsym(gGlesHandle, "glLoadIdentity") : NULL;
            a2_log_f(@"[A2-GL-PTR] glLoadIdentity: KW=%p ANGLE=%p（KW 为 NULL ⇒ LWJGL 必须回落）",
                     kwLI, angLI);
            // ★[A2PROBE]★ 把这两个地址交给 StikDebug 脚本布 Z0（开关 a2jit.probeGL，默认关）。
            //   用途：上面这行只说「各自在哪」，探针回答「到底被调到了谁」——脚本在 pc 命中时
            //   打 `[A2PROBE] HIT pc=… lr=… x0=… x1=…`（不下 lldb、不抢调试器）。
            //   ★无条件调用一次★：开关 / JIT 就绪 / 只布一次全在 a2_jit_probe_arm 里判，
            //   开关关着 ⇒ 立刻返回，本层行为与改动前逐字一致。
            a2_jit_probe_arm((uintptr_t)kwLI, (uintptr_t)angLI);
        }
    }

    // ---- ⑥b [FRAME-PERF] 回报实际 drawable 尺寸（可核对：与「请求的缩放后尺寸」是否一致）----
    // 为什么单独查一次：部分实现在 iOS 上按图层的点尺寸 × 缩放决定 drawable，会**忽略**请求尺寸。
    // ★量不到就不声称量到了★：回报为 0 就说明「实现没回报」，不假装等于请求值。
    // ★两边必须一致★：实现回报的就是 drawable 的真实像素 ⇒ 一旦与请求不同，以它为准
    //   （⑧ 的 gWidthPixels/gHeightPixels 改用实际值），否则 viewport/清屏会盖不住或溢出。
    gSurfaceWidthPixels = 0;
    gSurfaceHeightPixels = 0;
    if (gEglQuerySurface != NULL) {
        A2EGLint qw = 0, qh = 0;
        if (gEglQuerySurface(gDpy, gSurf, A2_EGL_WIDTH, &qw))  gSurfaceWidthPixels  = (int)qw;
        if (gEglQuerySurface(gDpy, gSurf, A2_EGL_HEIGHT, &qh)) gSurfaceHeightPixels = (int)qh;
    }
    a2_log_f(@"%s drawable 尺寸核对：请求=%dx%d 像素（点=%dx%d；scale=%.2f；宿主窗口 level=%.0f）；"
             @"实现回报=%dx%d 像素%s",
             A2GlBridgeJudgementTag,
             drawableW, drawableH,
             host->surface.widthPoints, host->surface.heightPoints,
             (double)host->surface.contentScaleX,
             a2_gl_bridge_window_level(host->surface.nativeWindow),
             gSurfaceWidthPixels, gSurfaceHeightPixels,
             (gEglQuerySurface == NULL) ? "（实现未提供查询入口）" : "");
    if (gSurfaceWidthPixels > 0 && gSurfaceHeightPixels > 0 &&
        (gSurfaceWidthPixels != drawableW || gSurfaceHeightPixels != drawableH)) {
        a2_log_f(@"%s ★尺寸不一致★：请求=%dx%d 实际 drawable=%dx%d ⇒ viewport/清屏改用实际像素"
                 @"（两边必须一致；差 %.2f 倍，宿主图层口径见上面「drawable 口径」那行）",
                 A2GlBridgeJudgementTag, drawableW, drawableH,
                 gSurfaceWidthPixels, gSurfaceHeightPixels,
                 (double)drawableW / (double)gSurfaceWidthPixels);
        drawableW = gSurfaceWidthPixels;
        drawableH = gSurfaceHeightPixels;
    }

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

    // ---- ⑦b [FRAME-PERF] 取「按缩放尺寸清屏」所需的可选入口 ----
    // 缺了不影响建面/清屏主路径：viewport/scissor 退化为「清整个 drawable」，
    // scissor 读回缺失时判据行如实点明「实现无读回，报请求值」。
    void *pViewport  = gEglGetProcAddress ? gEglGetProcAddress("glViewport") : NULL;
    void *pScissor   = gEglGetProcAddress ? gEglGetProcAddress("glScissor") : NULL;
    void *pEnable    = gEglGetProcAddress ? gEglGetProcAddress("glEnable") : NULL;
    void *pDisable   = gEglGetProcAddress ? gEglGetProcAddress("glDisable") : NULL;
    void *pGetInt    = gEglGetProcAddress ? gEglGetProcAddress("glGetIntegerv") : NULL;
    if (pViewport == NULL) pViewport = dlsym(gGlesHandle, "glViewport");
    if (pScissor  == NULL) pScissor  = dlsym(gGlesHandle, "glScissor");
    if (pEnable   == NULL) pEnable   = dlsym(gGlesHandle, "glEnable");
    if (pDisable  == NULL) pDisable  = dlsym(gGlesHandle, "glDisable");
    if (pGetInt   == NULL) pGetInt   = dlsym(gGlesHandle, "glGetIntegerv");
    gGLViewport    = (A2PFN_glViewport)pViewport;
    gGLScissor     = (A2PFN_glScissor)pScissor;
    gGLEnable      = (A2PFN_glEnable)pEnable;
    gGLDisable     = (A2PFN_glDisable)pDisable;
    gGLGetIntegerv = (A2PFN_glGetIntegerv)pGetInt;

    // ---- ⑧ 附着并渲染一帧（帧内 glClear 作可用性判据）----
    gAttached = 1;
    gFrameCount = 0;
    gWidthPixels = drawableW;      // ★与请求/图层/实现回报同一份值★（见 ⑥0b / ⑥b）
    gHeightPixels = drawableH;
    gFrameCb = host->frameCallback;
    gFrameUser = host->frameUser;

    a2_log_f(@"%s 附着完成：后端=%s 已接上宿主表面（drawable=%dx%d 像素；帧回调=%s）",
             A2GlBridgeJudgementTag, rendererName, gWidthPixels, gHeightPixels,
             (gFrameCb != NULL) ? "宿主已提供" : "宿主未提供");
    a2_gl_bridge_frame_work();
    return A2GlBridgeOK;
}

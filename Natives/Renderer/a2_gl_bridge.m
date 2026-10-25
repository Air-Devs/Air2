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
#import "a2_frame_perf.h"   // ★[FRAME-PERF] 与渲染器无关的帧性能判据（本文件的帧动作每帧记一次）

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

/// ★NG-GL4ES / KW★ 的 dylib 文件名（= 渲染器清单里的标识，见 `A2RendererCatalog`）。
/// Natives 不认识 Core、Core 也反向依赖不了本层（分层）⇒ 这里是字面量，
/// 与 `a2_renderer.h` 的 `A2RendererMetalDylibName` / `A2RendererCompatDylibName` 同一做法。
static const char *const A2GlBridgeKryptonDylibName = "libnggl4es_kw.dylib";

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

/// 当前后端是否 = ★NG-GL4ES / KW★（那一支需要宿主「注册解析器 + 显式初始化」）。
/// ★精确比较，不做模糊匹配★：`libnggl4es.dylib`（老的那支，自带 constructor）不能命中。
static int a2_gl_bridge_is_krypton(void) {
    return (gBackendName[0] != '\0' && strcmp(gBackendName, A2GlBridgeKryptonDylibName) == 0);
}

/// 交给 gl4es 的 GLES 入口解析器 —— 它在 `-DNOEGL` 下**唯一**的入口来源。
/// 顺序固定：已 RTLD_GLOBAL 的 GLESv2（ANGLE）→ EGL → eglGetProcAddress。
/// ★只解析 GLES/EGL 入口，不碰 `gl*` 包装层★：包装层符号由 LWJGL 从后端本体取（名字解析面 1328 个 gl*）。
static void *a2_gl_bridge_gles_getprocaddress(const char *name) {
    if (name == NULL) return NULL;
    void *sym = NULL;
    if (gGlesHandle != NULL) sym = dlsym(gGlesHandle, name);
    if (sym == NULL && gEglHandle != NULL) sym = dlsym(gEglHandle, name);
    if (sym == NULL && gEglGetProcAddress != NULL) sym = gEglGetProcAddress(name);
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
    BOOL backendIsMG = (strstr(gBackendName, "mobileglues") != NULL);
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
    // ★MobileGlues★ 它的 glGetError 在跳转表就绪前被调用会 SIGSEGV
    //   （真机: libmobileglues.dylib glGetError+24 → libjvm os::abort ⇒ "黑屏"）。
    //   加载成功后把该函数改写为 return 0（诊断用接口，恒 0 不影响渲染正确性）。
    if (gRendererHandle != NULL && strstr(gBackendName, "mobileglues") != NULL) {
        extern void a2_gl_error_shim_install_for_handle(void *handle);
        a2_gl_error_shim_install_for_handle(gRendererHandle);
    }
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

    // ---- ④b ★NG-GL4ES / KW：先把宿主解析器交给它★（必须在建面/初始化之前）----
    //   这一支是 `-DNOEGL` 编的：不注册解析器就只能退到 `dlsym(RTLD_NEXT)`，而 ANGLE 比它先加载
    //   ⇒ 一个 GLES 入口都摸不到（后续 initialize_gl4es 探测硬件扩展时全空）。
    if (a2_gl_bridge_is_krypton()) {
        A2PFN_set_getprocaddress setResolver =
            (A2PFN_set_getprocaddress)dlsym(gRendererHandle, "set_getprocaddress");
        if (setResolver == NULL) {
            a2_log_f(@"[A2-RENDERER] NG-GL4ES 初始化 rc=-1：缺 set_getprocaddress 入口"
                     @"（%s 不是预期的构建）⇒ 阻断", rendererName);
            a2_gl_bridge_teardown();
            return A2GlBridgeErrLoadFailed;
        }
        setResolver(a2_gl_bridge_gles_getprocaddress);
        a2_log_f(@"[A2-RENDERER] NG-GL4ES 已注册宿主 GLES 解析器（GLESv2=ANGLE，handle=%p）", gGlesHandle);
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
        // ★NG-GL4ES / KW 是 `-DDEFAULT_ES=3` 编的★（上游口径：只在 GLES3 上转译，绕开 ANGLE 的
        //   GLES1 路径）⇒ 它要 ES3 上下文；其它后端仍然只要 ES2（行为一字不改）。
        //   实现上先按需版本建、被拒再退 ES2 —— 退回去时**如实记一行**，不假装拿到了 ES3。
        const A2EGLint wantVersion = a2_gl_bridge_is_krypton() ? 3 : 2;
        const A2EGLint ctxAttribs[] = { A2_EGL_CONTEXT_CLIENT_VERSION, wantVersion, A2_EGL_NONE };
        gCtx = gEglCreateContext(gDpy, gCfg, A2_EGL_NO_CONTEXT, ctxAttribs);
        if (gCtx == A2_EGL_NO_CONTEXT && wantVersion != 2) {
            a2_log_f(@"[A2-RENDERER] NG-GL4ES 上下文：ES%ld 被拒（eglError=0x%x）⇒ 退 ES2 重试"
                     @"（GLES3 转译路径可能不可用）", (long)wantVersion,
                     (unsigned)(gEglGetError ? gEglGetError() : 0));
            const A2EGLint ctxAttribs2[] = { A2_EGL_CONTEXT_CLIENT_VERSION, 2, A2_EGL_NONE };
            gCtx = gEglCreateContext(gDpy, gCfg, A2_EGL_NO_CONTEXT, ctxAttribs2);
        }
        if (gCtx == A2_EGL_NO_CONTEXT) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglCreateContext 返回 NO_CONTEXT（eglError=0x%x）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0));
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
        if (wantVersion != 2) {
            a2_log_f(@"[A2-RENDERER] NG-GL4ES 上下文就绪：请求 client version=ES%ld context=%p",
                     (long)wantVersion, (void *)gCtx);
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

    // ---- ⑥a ★NG-GL4ES / KW 显式初始化（NO_INIT_CONSTRUCTOR）★ ----
    //   位置就是判据：① 库已 dlopen ② 解析器已注册 ③ context 刚 make current 成功。
    //   上游用 `-DNO_INIT_CONSTRUCTOR` 把构造器关掉了 ⇒ 不调这一步「不崩但黑屏」（GL 入口全空），
    //   所以本桥把调用与返回码都打成判据行，真机 grep `[A2-RENDERER] NG-GL4ES 初始化 rc=` 即可。
    if (a2_gl_bridge_is_krypton()) {
        int initRC = a2_gl_bridge_krypton_initialize();
        a2_log_f(@"[A2-RENDERER] NG-GL4ES 初始化 rc=%d（backend=%s；context=%p 已 current）%s",
                 initRC, rendererName, (void *)gCtx,
                 (initRC == 0) ? " ⇒ 已在宿主 context 上初始化" : " ⇒ ★阻断：缺 initialize_gl4es 入口★");
        if (initRC != 0) {
            a2_gl_bridge_teardown();
            return A2GlBridgeErrLoadFailed;
        }
    }

    // ---- ⑥b [FRAME-PERF] 回报实际 drawable 尺寸（可核对：与「请求的缩放后尺寸」是否一致）----
    // 为什么单独查一次：部分实现在 iOS 上按图层的点尺寸 × 缩放决定 drawable，会**忽略**请求尺寸。
    // ★量不到就不声称量到了★：回报为 0 就说明「实现没回报」，不假装等于请求值。
    // （帧判据行里的 `clear=` 是本层按请求的缩放尺寸显式设进 scissor 的区域 ⇒ 缩放仍生效。）
    gSurfaceWidthPixels = 0;
    gSurfaceHeightPixels = 0;
    if (gEglQuerySurface != NULL) {
        A2EGLint qw = 0, qh = 0;
        if (gEglQuerySurface(gDpy, gSurf, A2_EGL_WIDTH, &qw))  gSurfaceWidthPixels  = (int)qw;
        if (gEglQuerySurface(gDpy, gSurf, A2_EGL_HEIGHT, &qh)) gSurfaceHeightPixels = (int)qh;
    }
    a2_log_f(@"%s drawable 尺寸核对：请求=%dx%d 像素（已含渲染倍率）；实现回报=%dx%d 像素%s",
             A2GlBridgeJudgementTag,
             host->surface.widthPixels, host->surface.heightPixels,
             gSurfaceWidthPixels, gSurfaceHeightPixels,
             (gEglQuerySurface == NULL) ? "（实现未提供查询入口）" : "");

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

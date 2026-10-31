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
#import "a2_eagl_egl.h"        // ★宿主 EGL 后端★：A2FakeEglWindowSize（上屏建面的实参）

#import <objc/message.h>   // objc_msgSend（动态取 layer 用；不 import UIKit）
#import <dlfcn.h>
#include <unistd.h>       // usleep（首次 make_current 等宿主视图就绪的有界等待）
#include <time.h>         // clock_gettime(CLOCK_MONOTONIC)（MG 引导的耗时判据）
#include <string.h>
#include <stdint.h>
#include <mach-o/dyld.h>  // _dyld_image_count / _dyld_get_image_header（④a2 interpose 的目标镜像）
#include <mach-o/loader.h>   // struct mach_header（dyld_dynamic_interpose 的第一个实参）

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
typedef A2EGLBoolean  (*A2PFN_eglGetConfigAttrib)(A2EGLDisplay, A2EGLConfig, A2EGLint, A2EGLint *);

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

/// ★宿主 EGL 后端★（`libeagl.dylib`）：EGL 由本二进制提供（假 EGL → EAGL），GL 层是 MobileGlues。
/// 建面/上下文版本/库来源都据此分叉；attach 时置位，teardown 清零。
static int   gHostEgl = 0;

/// ★建面用的 EGL 入口从哪来★（★全项目只有两个值、一个产地★：attach 的 MG 探测；teardown 复位）。
typedef enum {
    A2GlBridgeEglSourceAngle = 0,   ///< 非 MG 自带 —— ANGLE 兼容底（`Frameworks/libEGL.framework/libEGL`）或宿主假 EGL（主镜像）
    A2GlBridgeEglSourceMG    = 1,   ///< 渲染器自带 —— `libmobileglues.dylib` 自己导出整套 `egl*`
} A2GlBridgeEglSource;

/// 当前 EGL 源（见 `A2GlBridgeEglSource`）。★只经 `a2_gl_bridge_egl_source()` 读，不在别处判★。
static A2GlBridgeEglSource gEglSource = A2GlBridgeEglSourceAngle;

/// ★MG 自带 EGL 的探测结果★（`a2_gl_bridge_use_own_egl()` 是唯一写点，teardown 复位）。
/// 只服务于「两层判据行」（EGL 门面 / 宿主），不参与任何控制流判断（控制流只读 `gEglSource`）。
static int         gMgEglEntriesGot   = 0;    // MG 真身里 dlsym 到的 egl* 入口数（应 = 清单总数）
static int         gMgEglEntriesTotal = 0;    // 清单总数（`kMgEglEntryNames`，13）
static const char *gMgEglFirstMissing = NULL; // MG 缺的第一个入口名（门面回退 ANGLE 时点名用；指向静态字面量）

/// ★MG 引导 `mg_init_gles`★（老 Air 同款；见 `tree510/Natives/ctxbridges/gl_bridge.m:1215/1381/1534`）。
///   · 上游原型 `void mg_init_gles(void)`：内部做 **caps 检测**（glGetString / glGetIntegerv …）
///     ⇒ ★必须在真实上下文生效之后调用★（老 Air 是在 `gl_make_current` 里、`eglMakeCurrent`
///     成功之后调，同文件 :1203-1206 的注释就是这个约束）；
///   · 真机 lastlog-108（1.20.1 + MG，包 96e8e14）：本桥附着 rc=0、帧回调在跑，游戏日志却停在
///     `Backend library: LWJGL version 3.4.1-snapshot` 之后 ⇒ LWJGL 的 `GL.createCapabilities`
///     卡死 —— 我们从未调它 ⇒ MG 内部那套状态（当门面用的函数表 / caps）一直是空的；
///   · 符号在 MG 加载后 dlsym（`a2_gl_bridge_load_mg_init_symbol`，唯一产地），
///     调用在「上下文成为 current」的两处（attach ⑥ / `a2_gl_bridge_make_current` 成功之后）。
typedef void (*A2PFN_mg_init_gles)(void);
static A2PFN_mg_init_gles gMgInitGles     = NULL;   // MG 本体里的 `mg_init_gles`
static int                gMgInitGlesDone = 0;      // 0 = 未调过；1 = 已调过（★幂等：整个进程只引导一次★）

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
static A2PFN_eglGetConfigAttrib   gEglGetConfigAttrib = NULL;   // 只用于把「选定配置的位深」打进判据行

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
    // ★句柄各自独立★（MG 门面下也不再有别名）：gEglHandle/gGlesHandle = ANGLE 的两份，
    //   gRendererHandle = 后端本体。仍保留「与本体同一镜像就不重复 dlclose」的比较 ——
    //   那是对同一镜像 dlopen 两次时引用计数的保险（别多减一次）。
    void *rendererHandleBefore = gRendererHandle;
    if (gRendererHandle != NULL) {
        dlclose(gRendererHandle);
        gRendererHandle = NULL;
        gKryptonInitedHandle = NULL;   // 镜像已关 ⇒ 下次 attach 必须重新初始化
    }
    if (gGlesHandle != NULL)     { if (gGlesHandle != rendererHandleBefore) dlclose(gGlesHandle); gGlesHandle = NULL; }
    // ★宿主 EGL 后端的 gEglHandle 是 dlopen(NULL)（主镜像句柄）★：不能 dlclose（那会试图卸载主二进制）。
    if (gEglHandle != NULL)      { if (!gHostEgl && gEglHandle != rendererHandleBefore) dlclose(gEglHandle); gEglHandle = NULL; }
    gHostEgl = 0;
    gEglSource = A2GlBridgeEglSourceAngle;   // ★EGL 源随句柄一起释放★：下次 attach 必须重新判（不留上一轮的结论）
    gMgEglEntriesGot = 0;                    // ★探测结果同理★：不留上一轮的数字（否则判据行会报别的后端/上一轮的入口数）
    gMgEglEntriesTotal = 0;
    gMgEglFirstMissing = NULL;
    // ★MG 引导状态随镜像一起复位★：teardown 已 dlclose MG 本体 ⇒ 下次 attach 是新镜像，必须重新
    //   dlsym 并重新引导（与 `gKryptonInitedHandle` 同一口径：不留上一轮的「已初始化」结论）。
    gMgInitGles = NULL;
    gMgInitGlesDone = 0;

    gDpy = A2_EGL_NO_DISPLAY; gCfg = NULL;
    gCtx = A2_EGL_NO_CONTEXT; gSurf = A2_EGL_NO_SURFACE;
    gEglGetDisplay = NULL; gEglInitialize = NULL; gEglBindAPI = NULL;
    gEglChooseConfig = NULL; gEglCreateContext = NULL; gEglCreateWindowSurface = NULL;
    gEglMakeCurrent = NULL; gEglSwapBuffers = NULL; gEglGetError = NULL;
    gEglGetProcAddress = NULL; gEglDestroySurface = NULL; gEglDestroyContext = NULL;
    gEglTerminate = NULL; gEglQuerySurface = NULL;
    gEglGetConfigAttrib = NULL;
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

// ---- ★EGL 源：MG 自带 / ANGLE 兼容底★（见 `A2GlBridgeEglSource`）----

/// ★EGL 源唯一判据★ —— 所有取 `egl*` 函数指针的地方都先问它，**不另写第二套判断**。
static A2GlBridgeEglSource a2_gl_bridge_egl_source(void) {
    return gEglSource;
}

/// ★EGL 入口句柄的唯一产地★：按 `a2_gl_bridge_egl_source()` 决定从哪个镜像解析 `egl*`。
///   · MG 源 ⇒ 渲染器自己的句柄（MG 导出的 `egl*`，与它内部那套 GL 状态同源）；
///   · 其余   ⇒ `gEglHandle`（ANGLE 兼容底，或宿主 EGL 后端的主镜像假 EGL）。
static void *a2_gl_bridge_egl_entry_handle(void) {
    return (a2_gl_bridge_egl_source() == A2GlBridgeEglSourceMG) ? gRendererHandle : gEglHandle;
}

/// ★EGL 入口表的完整性判据★（返回**第一个**空入口名；全有 ⇒ NULL）—— 唯一产地。
/// 为什么必须单列：入口表只有两态（⑤ 一次填齐 / teardown 一次清空），半张表 = 上一轮中途失败；
/// 此时任何 `egl*` 解引用都可能崩在空指针上（真机 iOS 16.7：键鼠窗触发相位改绑后再跑 attach
/// ⇒ SIGSEGV in `a2_gl_bridge_attach`）。★判据只此一处★，两处调用点都不另写比较：
///   ① attach 开头（重入 teardown 之前 —— 缺入口就**不 teardown**，旧表面保持可用）；
///   ② attach ⑤ 的必需符号装配处（`missing` 成立时用它点名「缺谁、因此中止」）。
static const char *a2_gl_bridge_egl_entry_missing(void) {
    if (gEglGetDisplay          == NULL) return "eglGetDisplay";
    if (gEglInitialize          == NULL) return "eglInitialize";
    if (gEglChooseConfig        == NULL) return "eglChooseConfig";
    if (gEglCreateContext       == NULL) return "eglCreateContext";
    if (gEglMakeCurrent         == NULL) return "eglMakeCurrent";
    if (gEglCreateWindowSurface == NULL) return "eglCreateWindowSurface";
    if (gEglSwapBuffers         == NULL) return "eglSwapBuffers";
    return NULL;
}

/// ★GL 入口的唯一取法★（调用点：attach ⑦ / ⑦b 的 8 个帧动作入口）。
///   顺序：① 门面的 `eglGetProcAddress`（句柄同 `a2_gl_bridge_egl_entry_handle()`）；
///        ② 同一个门面句柄上 `dlsym`；③ 最后才退到宿主 GLESv2（ANGLE / 系统 OpenGLES）。
/// ★为什么必须先从门面取★：MG 当门面时，`gl*` 必须来自 MG（与它内部那套 GL 状态同源）；
///   直接拿宿主 ANGLE 的 `gl*` 会让「MC 的调用」与「MG 的状态」分离 —— 真机 SYMBOL THEFT
///   （`the application is calling someone else`）与随后 SIGBUS 就是这件事。
/// ★不另写判定★：门面是谁完全由 `a2_gl_bridge_egl_entry_handle()` 决定，这里不判后端名。
static void *a2_gl_bridge_gl_symbol(const char *name) {
    if (name == NULL) return NULL;
    void *facade = a2_gl_bridge_egl_entry_handle();
    void *sym = (gEglGetProcAddress != NULL) ? gEglGetProcAddress(name) : NULL;
    if (sym == NULL && facade != NULL) sym = dlsym(facade, name);
    if (sym == NULL && gGlesHandle != NULL && gGlesHandle != facade) sym = dlsym(gGlesHandle, name);
    return sym;
}

/// ★MG 自带 EGL 的入口清单★（13 个；缺任何一个都不认「MG 自带」）。
/// 为什么要求整表而不是只要建面那 7 个：半套 EGL（能建上下文、不能换页/销毁/取 proc）
/// 会把崩点从「建不出面（有清晰日志）」挪到「跑起来之后（真机 SIGBUS）」，比直接回退更难定位。
static const char *const kMgEglEntryNames[] = {
    "eglGetDisplay", "eglInitialize", "eglChooseConfig", "eglGetConfigAttrib",
    "eglCreateContext", "eglCreateWindowSurface", "eglMakeCurrent", "eglSwapBuffers",
    "eglDestroySurface", "eglDestroyContext", "eglTerminate", "eglGetError",
    "eglGetProcAddress",
    NULL
};

/// ★MG 自带 EGL 探测★（`gEglSource` 的唯一判定写点；返回值 = 是否采用 MG 自带 EGL 当**门面**）。
///
/// ★两层栈的口径★：MG 导出的整套 `egl*` 只是**门面**（façade），它自己不建宿主 ——
///   真机 lastlog-104：只把 MG 当 EGL 源、并把 ANGLE 跳过之后，MG 自己报
///   `EGL entry point eglGetDisplay is not available in the backend library`，随后 SIGSEGV 循环。
///   ⇒ 本层同时加载 ANGLE（`libEGL`/`libGLESv2`，RTLD_GLOBAL）当**宿主**，MG 的门面才有落地实现；
///   而我们自己的 `egl*` 调用仍优先走门面（本函数的结论），见 `a2_gl_bridge_egl_entry_handle()`。
///   ⇒ 本函数只回答「门面是谁」，宿主恒为 ANGLE（`gHostEgl` 那条宿主假 EGL 分支除外）。
///
/// 依据①（做法对齐）：老 Air `Natives/ctxbridges/egl_bridge.m:260-285` 的 `dlsym_EGL()` 就是先到
///   **渲染器自己的句柄**里 dlsym 整套 `egl*`，取不到才回退兼容底。
/// 依据②（真机症状同向）：MG 2.0.16 自己导出 eglGetDisplay/eglInitialize/eglCreateContext/
///   eglMakeCurrent/eglGetProcAddress，而本桥用 ANGLE 的 libEGL 建上下文、只把 MG 当 GL 库
///   ⇒ 两套运行时不同源：MG 崩在 `[libmobileglues.dylib+0x3e4e4] glGetError`（SIGBUS），
///   它自己还报 `SYMBOL THEFT …`（flat namespace 里的 gl* 归 ANGLE 不归它）。
static int a2_gl_bridge_use_own_egl(void) {
    // ★宿主 EGL 后端（libeagl.dylib）**不得**采用 MG 自带 EGL★：那一条链的 EGL 层就是本二进制里的
    //   假 EGL（CAEAGLLayer 上屏的唯一实现）。若让 `egl*` 归 MG，`eglCreateWindowSurface` 就不再
    //   走本层的假 EGL ⇒ 上屏链断（画面出不来，且日志只看到 MG 自己的 EGL）。
    //   ⇒ 这条判据优先级最高，与 gHostEgl 绑定（attach ①b 置位）。
    if (gHostEgl) {
        gEglSource = A2GlBridgeEglSourceAngle;
        a2_log_criterion(@"[A2-GLBRIDGE] EGL 门面=主镜像假 EGL（libeagl.dylib 必须由本层接管 egl*）；宿主=本二进制（CAEAGLLayer）");
        return 0;
    }
    if (gRendererHandle == NULL) return 0;
    int got = 0, total = 0;
    const char *firstMissing = NULL;
    for (int i = 0; kMgEglEntryNames[i] != NULL; i++) {
        total++;
        if (dlsym(gRendererHandle, kMgEglEntryNames[i]) != NULL) got++;
        else if (firstMissing == NULL) firstMissing = kMgEglEntryNames[i];
    }
    // ★探测结果存档★（只给两层判据行用；控制流仍然只读 `gEglSource`）
    gMgEglEntriesGot   = got;
    gMgEglEntriesTotal = total;
    gMgEglFirstMissing = firstMissing;
    if (firstMissing != NULL) {
        gEglSource = A2GlBridgeEglSourceAngle;
        a2_log_criterion(@"[A2-GLBRIDGE] MG 自带 EGL 不全：缺入口 %s（%d/%d）⇒ 门面回退 ANGLE",
                         firstMissing, got, total);
        return 0;
    }
    gEglSource = A2GlBridgeEglSourceMG;
    a2_log_criterion(@"[A2-GLBRIDGE] MG 自带 EGL 齐备：%d/%d 入口 ⇒ 采用 MG 当门面（宿主 ANGLE 由 ④ 加载，两层都在）",
                     got, total);
    return 1;
}

/// ★两层判据行（EGL 门面 / 宿主）★ —— 真机 grep 这一行即可判读「egl* 是谁的、宿主是谁」。
/// 调用点：`a2_gl_bridge_attach` 的 ④ 之后**一次**（此时门面句柄与 ANGLE 宿主句柄都已落地，
/// 也只有这时才能同时报出「门面入口数」与「宿主已 RTLD_GLOBAL」）。
/// ★只报事实★：门面=MG 时点明入口数与自己那份句柄；门面=ANGLE 时点名 MG 缺的那一个入口。
static void a2_gl_bridge_log_egl_layers(void) {
    if (a2_gl_bridge_egl_source() == A2GlBridgeEglSourceMG) {
        a2_log_criterion(@"[A2-GLBRIDGE] EGL 门面=MG（%d/%d 入口，句柄=%p）；"
                         @"宿主=ANGLE（libEGL/libGLESv2 已 RTLD_GLOBAL）",
                         gMgEglEntriesGot, gMgEglEntriesTotal, gRendererHandle);
    } else if (gMgEglFirstMissing == NULL && gMgEglEntriesGot > 0) {
        // ★MG 入口是齐的、却没被采用★：只可能是 ④a4 的归属核对把它退回去了（见该处日志）。
        a2_log_criterion(@"[A2-GLBRIDGE] EGL 门面=ANGLE（MG 自带 EGL %d/%d 齐备，但归属不对 ⇒ 已退回 ANGLE 建面）；"
                         @"宿主=ANGLE 同镜像",
                         gMgEglEntriesGot, gMgEglEntriesTotal);
    } else {
        a2_log_criterion(@"[A2-GLBRIDGE] EGL 门面=ANGLE（MG 缺 %s）；"
                         @"宿主=ANGLE（libEGL/libGLESv2 已 RTLD_GLOBAL）",
                         (gMgEglFirstMissing != NULL) ? gMgEglFirstMissing : "(no entry probed)");
    }
}

/// 加载后端本体（EGL/GL 层的镜像）：RTLD_GLOBAL 让 MC 后续能直接解析到它的 GL 符号。
/// ★两处调用，同一个动作★：① MG 先加载 —— 要问它要 EGL 门面入口（③0，顺序是契约）；
/// ② ④ 里再补一次（其余后端在这里才真正加载；MG 已加载 ⇒ 幂等直接成功）。
/// 已加载则直接成功（不会重复 dlopen）。
static int a2_gl_bridge_open_renderer(const char *rendererPath) {
    if (gRendererHandle != NULL) return 1;
    gRendererHandle = dlopen(rendererPath, RTLD_LAZY | RTLD_GLOBAL);
    if (gRendererHandle == NULL) {
        const char *err = dlerror();
        a2_log_f(@"%s ★阻断★：后端本体 dlopen 失败 %s（%s）",
                 A2GlBridgeJudgementTag, rendererPath, err ? err : "(dlerror 无输出)");
        return 0;
    }
    return 1;
}

// ---------------------------------------------------------------------------
//  ★加载顺序（ANGLE → MG → 其它）与符号归属核对★
// ---------------------------------------------------------------------------
//  真机 lastlog-105（1.20.1 + MG + java-21，包 0ff9416）：
//    `[A2-GLBRIDGE] 符号归属核对：glTexImage2D 后端导出=0x12bcd9a84 / flat=0x26a9eacf4 ⇒ ★被别的库抢走★`
//    `EGL entry point eglGetDisplay is not available in the backend library`   ← MG 自报
//  ⇒ flat 那枚地址落在 **dyld 共享缓存**（系统 OpenGLES），不是 ANGLE。MG 把「抢到 glTexImage2D 的
//    那个镜像」当成 backend library，而系统 GLES 没有 EGL ⇒ MG 初始化失败；本桥随后继续用空指针
//    ⇒ SIGSEGV（`a2_gl_bridge_attach + 2860`）。
//  ⇒ 修法三条：① ANGLE 的 libEGL/libGLESv2 ★必须在 MG 本体之前★ 以 RTLD_GLOBAL 进 flat namespace；
//              ② MG 后端 ★不 dlopen 系统 OpenGLES★（系统 GLES 只留给宿主 EGL / EAGL 后端）；
//              ③ 已解析的 `gl*` 抢不回来（lastlog-11：系统 GLES 在 dyld 共享缓存里，任何 dlopen 顺序
//                 都改不动它）⇒ 用 **dyld 动态 interpose** 把 `gl*` 改指 MG 自己的导出（见 ④a2）。
//  ⇒ 加载完再用 `dladdr()` 逐符号核对归属 —— 不走「指针相等」那套：它只能回答「同不同源」，
//    答不了「归哪个镜像」（lastlog-105 正是这两者分家）。

/// ★符号归属分类★（判据只有一条：`dladdr()` 给出的镜像路径子串 —— 不比地址高低、不看加载先后）。
typedef enum {
    A2GlBridgeSymbolOwnerNone = 0,    ///< flat namespace 里取不到这个符号
    A2GlBridgeSymbolOwnerAngle,       ///< ANGLE：`…/libEGL.framework/libEGL` 或 `…/libGLESv2.framework/libGLESv2`
    A2GlBridgeSymbolOwnerMG,          ///< MobileGlues：`…/libmobileglues.dylib`
    A2GlBridgeSymbolOwnerSystemGles,  ///< 系统 GLES：`…/OpenGLES.framework/OpenGLES`（dyld 共享缓存）
    A2GlBridgeSymbolOwnerOther,       ///< 其它镜像 / `dladdr` 取不到路径（不猜）
} A2GlBridgeSymbolOwner;

/// ★加载顺序：ANGLE 先行★（MG 后端专有；调用点：`a2_gl_bridge_attach` 的 ③0，MG 本体之前**一次**）。
/// 句柄落在 `gEglHandle` / `gGlesHandle`（与 ④ 同一个产地 ⇒ teardown 的释放口径不变，不新增第三对句柄）。
/// 幂等：已加载直接成功（`dlopen` 返回同一句柄，不重复计数）。
/// 返回 1 = 两份都已在 flat namespace（RTLD_GLOBAL）；0 = 缺任意一份（已打阻断行，调用方据此中止）。
static int a2_gl_bridge_load_angle_first(NSString *eglPath, NSString *glesPath) {
    if (eglPath == nil || glesPath == nil) {
        a2_log_f(@"[A2-GLBRIDGE] ★阻断★：MG 后端要求 ANGLE 先行，但 EGL/GLESv2 路径缺失（frameworksPath 未解析）");
        return 0;
    }
    if (gEglHandle == NULL) {
        gEglHandle = dlopen(eglPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (gEglHandle == NULL) {
            const char *err = dlerror();
            a2_log_f(@"[A2-GLBRIDGE] ★阻断★：ANGLE libEGL 先行加载失败 %s（%s）",
                     eglPath.UTF8String, err ? err : "(dlerror 无输出)");
            return 0;
        }
    }
    if (gGlesHandle == NULL) {
        gGlesHandle = dlopen(glesPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (gGlesHandle == NULL) {
            const char *err = dlerror();
            a2_log_f(@"[A2-GLBRIDGE] ★阻断★：ANGLE libGLESv2 先行加载失败 %s（%s）",
                     glesPath.UTF8String, err ? err : "(dlerror 无输出)");
            return 0;
        }
    }
    a2_log_f(@"[A2-GLBRIDGE] 加载顺序=ANGLE→MG→其它：ANGLE 先入 flat namespace（RTLD_GLOBAL）"
             @"libEGL handle=%p；libGLESv2 handle=%p",
             gEglHandle, gGlesHandle);
    return 1;
}

/// ★符号归属取法★（唯一产地：`dlsym(RTLD_DEFAULT)` + `dladdr`）。
/// `addrOut` 回填 flat namespace 里那枚地址（取不到 = NULL）；返回值只按镜像路径分类。
static A2GlBridgeSymbolOwner a2_gl_bridge_symbol_owner(const char *name, void **addrOut) {
    void *addr = (name != NULL) ? dlsym(RTLD_DEFAULT, name) : NULL;
    if (addrOut != NULL) *addrOut = addr;
    if (addr == NULL) return A2GlBridgeSymbolOwnerNone;
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(addr, &info) == 0 || info.dli_fname == NULL || info.dli_fname[0] == '\0') {
        return A2GlBridgeSymbolOwnerOther;   // 地址不属于任何镜像路径（汇编桩等）⇒ 归「其它」，不猜
    }
    if (strstr(info.dli_fname, "libEGL.framework") != NULL ||
        strstr(info.dli_fname, "libGLESv2.framework") != NULL) {
        return A2GlBridgeSymbolOwnerAngle;
    }
    if (strstr(info.dli_fname, "libmobileglues") != NULL) return A2GlBridgeSymbolOwnerMG;
    if (strstr(info.dli_fname, "OpenGLES.framework") != NULL) return A2GlBridgeSymbolOwnerSystemGles;
    return A2GlBridgeSymbolOwnerOther;
}

/// 归属标签（★日志锚点 `归属=`★；取值 ANGLE / 系统GLES / MG / 其它 / 无符号）。
static const char *a2_gl_bridge_owner_label(A2GlBridgeSymbolOwner owner) {
    switch (owner) {
        case A2GlBridgeSymbolOwnerAngle:      return "ANGLE";
        case A2GlBridgeSymbolOwnerSystemGles: return "系统GLES";
        case A2GlBridgeSymbolOwnerMG:         return "MG";
        case A2GlBridgeSymbolOwnerOther:      return "其它";
        case A2GlBridgeSymbolOwnerNone:       break;
    }
    return "无符号";
}

/// 该归属是否「可用」（★判据只有一条：不是系统 GLES★）。
///   · MG 后端下 flat 的 `egl*` 归 MG 是常态（MG 自带那套 `egl*` 就是门面）；
///   · `gl*` 归 MG 是 ④a2 interpose 的**目标态**（MG 自己的导出，没有符号被抢的问题）；
///   · 归 ANGLE 同样可用（ANGLE 是宿主，`gl*` 走它也能建面）。
/// ★唯一不可用的是系统 OpenGLES★：它没有 EGL ⇒ MG 会自报
///   `EGL entry point eglGetDisplay is not available in the backend library`（真机 lastlog-105 / 11）。
static int a2_gl_bridge_owner_usable(A2GlBridgeSymbolOwner owner) {
    return (owner == A2GlBridgeSymbolOwnerAngle || owner == A2GlBridgeSymbolOwnerMG);
}

/// 核对**一行**（调用点：`a2_gl_bridge_verify_angle_ownership` 的两行）。格式固定、便于 grep：
///   `[A2-GLBRIDGE] 归属核对 <符号> flat=0x… 归属=ANGLE|系统GLES|其它`
///   `[A2-GLBRIDGE] 归属核对 <符号> flat=0x… 归属=…（MG=0x…）`   ← 传了 MG 自带导出时才带括号
static A2GlBridgeSymbolOwner a2_gl_bridge_log_owner(const char *name, void *mgOwnExport) {
    void *addr = NULL;
    A2GlBridgeSymbolOwner owner = a2_gl_bridge_symbol_owner(name, &addr);
    if (mgOwnExport != NULL) {
        a2_log_f(@"[A2-GLBRIDGE] 归属核对 %s flat=%p 归属=%s（MG=%p）",
                 name, addr, a2_gl_bridge_owner_label(owner), mgOwnExport);
    } else {
        a2_log_f(@"[A2-GLBRIDGE] 归属核对 %s flat=%p 归属=%s",
                 name, addr, a2_gl_bridge_owner_label(owner));
    }
    return owner;
}

/// ★归属纠正（重试一次；调用点：`a2_gl_bridge_verify_angle_ownership` 发现归属不对时）★。
///  ① 「若可控」放掉一份系统 OpenGLES 的句柄：`RTLD_NOLOAD` 只取**已加载**镜像的句柄
///     （不触发新加载），紧随的 `dlclose` 把引用计数配平 —— 共享缓存镜像真卸得掉就卸，
///     卸不掉也无害（不改变本进程已解析的绑定）。
///  ② 再以 **RTLD_GLOBAL** dlopen ANGLE 两份（幂等）：`dlopen` 的 +1 由紧跟的 `dlclose` 配平，
///     镜像本身仍由 `gEglHandle`/`gGlesHandle` 持有 ⇒ 不会真卸载，只是把 GLOBAL 归属再确认一次。
static void a2_gl_bridge_reassert_angle_global(NSString *eglPath, NSString *glesPath) {
    const char *systemGlesPath = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES";
    void *sysHandle = dlopen(systemGlesPath, RTLD_LAZY | RTLD_NOLOAD);
    if (sysHandle != NULL) {
        dlclose(sysHandle);
        a2_log_f(@"[A2-GLBRIDGE] 归属纠正①：系统 OpenGLES 句柄=%p 已释放一份（RTLD_NOLOAD 配对 dlclose）",
                 sysHandle);
    } else {
        a2_log_f(@"[A2-GLBRIDGE] 归属纠正①：系统 OpenGLES 当前未加载（无抢占句柄可放）");
    }
    NSString *anglePaths[2] = { eglPath, glesPath };
    for (int i = 0; i < 2; i++) {
        if (anglePaths[i] == nil) continue;
        void *h = dlopen(anglePaths[i].UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (h != NULL) dlclose(h);   // ★配平引用计数★（镜像仍由 gEglHandle/gGlesHandle 持有）
        a2_log_f(@"[A2-GLBRIDGE] 归属纠正②：%s 再次 RTLD_GLOBAL dlopen ⇒ %s",
                 anglePaths[i].UTF8String, (h != NULL) ? "OK（句柄已配平）" : "FAILED");
    }
}

/// ★两行归属核对 + 一次重试★（调用点：`a2_gl_bridge_attach` 的 ④a3，MG 后端**一次**）。
/// 判据：flat namespace 的 `eglGetDisplay` 与 `glTexImage2D` **都不落在系统 GLES** 上
///   （见 `a2_gl_bridge_owner_usable`：ANGLE / MG 都可用）。历史口径「必须归 ANGLE」已废：
///   真机 lastlog-11 里 `eglGetDisplay` 归 MG 是常态（MG 自带 egl* 就是门面），
///   而 `gl*` 归 MG 正是 ④a2 interpose 想要的结果 —— 用「必须 ANGLE」会把刚抢回来的状态再否掉。
/// 归属不可用 ⇒ 重试一次（`a2_gl_bridge_reassert_angle_global`）；仍不可用 ⇒ 打 `★归属仍不对★`。
///
/// @return 1 = 归属可用（MG 门面可以拿来建面）；0 = 仍不可用（调用方据此**退回 ANGLE 建面**，见 attach ④a4）。
///   ★返回值只回答「MG 门面能不能用」★：`glTexImage2D` 落在系统 GLES 时 MG 的 `egl*` 必然拿不到
///   backend library（真机 iOS 16.7：`归属=系统GLES` ⇒ MG 自报 `EGL entry point eglGetDisplay is not
///   available in the backend library`），继续在它上面建面只会拿到空指针 ⇒ 崩。
static int a2_gl_bridge_verify_angle_ownership(NSString *eglPath, NSString *glesPath) {
    // MG 自己的 `glTexImage2D` 导出（对照项，不参与判定）：flat 与它相同 ⇒ 说明 ④a2 的 interpose 生效了。
    void *mgGlTexImage2D = (gRendererHandle != NULL) ? dlsym(gRendererHandle, "glTexImage2D") : NULL;
    A2GlBridgeSymbolOwner eglOwner = a2_gl_bridge_log_owner("eglGetDisplay", NULL);
    A2GlBridgeSymbolOwner glOwner  = a2_gl_bridge_log_owner("glTexImage2D", mgGlTexImage2D);
    if (a2_gl_bridge_owner_usable(eglOwner) && a2_gl_bridge_owner_usable(glOwner)) {
        a2_log_criterion(@"[A2-GLBRIDGE] 归属核对结论：EGL=%s / GL=%s（★都不是系统 GLES★）⇒ 门面=MG 可用（宿主=ANGLE）",
                         a2_gl_bridge_owner_label(eglOwner), a2_gl_bridge_owner_label(glOwner));
        return 1;
    }
    a2_log_f(@"[A2-GLBRIDGE] 归属不对（eglGetDisplay=%s / glTexImage2D=%s）⇒ 重试一次",
             a2_gl_bridge_owner_label(eglOwner), a2_gl_bridge_owner_label(glOwner));
    a2_gl_bridge_reassert_angle_global(eglPath, glesPath);
    A2GlBridgeSymbolOwner eglOwnerRetry = a2_gl_bridge_log_owner("eglGetDisplay", NULL);
    A2GlBridgeSymbolOwner glOwnerRetry  = a2_gl_bridge_log_owner("glTexImage2D", mgGlTexImage2D);
    if (a2_gl_bridge_owner_usable(eglOwnerRetry) && a2_gl_bridge_owner_usable(glOwnerRetry)) {
        a2_log_criterion(@"[A2-GLBRIDGE] 归属核对结论（重试后）：EGL=%s / GL=%s（★都不是系统 GLES★）",
                         a2_gl_bridge_owner_label(eglOwnerRetry), a2_gl_bridge_owner_label(glOwnerRetry));
        return 1;
    }
    a2_log_f(@"[A2-GLBRIDGE] ★归属仍不对★ eglGetDisplay=%s / glTexImage2D=%s ⇒ 不阻断启动，"
             @"但 MG 门面不再用来建面（见下一行「退回 ANGLE 建面」）",
             a2_gl_bridge_owner_label(eglOwnerRetry), a2_gl_bridge_owner_label(glOwnerRetry));
    return 0;
}

// ---------------------------------------------------------------------------
//  ★dyld 动态 interpose：把 flat namespace 里的 `gl*` 抢回 MG★（attach ④a2）
// ---------------------------------------------------------------------------
//  真机 lastlog-11（1.20.1 + MG + java-21，包 cd148e2）：
//    `归属核对 eglGetDisplay flat=0x12a50decc 归属=MG`
//    `归属核对 glTexImage2D flat=0x26a9eacf4 归属=系统GLES（MG=0x12a4d9a84）`
//    `★归属仍不对★ ⇒ ★退回 ANGLE 建面★`（存活 96s 不崩，但屏上无画面）
//  ⇒ `0x26a9eacf4` 落在 **dyld 共享缓存**里的 `OpenGLES.framework`：共享缓存早于任何 dylib 映射，
//    flat namespace 里它永远排在前面 ⇒「先加载 ANGLE」（③0）与「dlclose 系统 GLES」
//    （`a2_gl_bridge_reassert_angle_global` ①）都改不动已解析的绑定 —— 两次实测无效。
//  ⇒ 还剩一条能改绑定的手段：dyld 的动态 interpose（libdyld 导出、私有头 `dyld_priv.h` 口径：
//    `{replacement, replacee}` 元组表 + 目标镜像的 mach_header ⇒「Update all bindings on specified image」）。
//    本层用它把 `gl*` 的解析结果/绑定点改指 MG **自己的导出**。
//  ★符号只在私有头里、公开 SDK 不声明★ ⇒ 一律 `dlsym` 取函数指针；取不到就如实打日志、保持原回退。

/// 一条 interpose 元组（= `dyld_priv.h` 的 `struct dyld_interpose_tuple`；本层不 import 私有头，
/// 只按它公开的字段顺序自声明，属事实性 ABI 约定）。
typedef struct {
    const void *replacement;   ///< 新实现：MG 自己的导出（`dlsym(gRendererHandle, …)`）
    const void *replacee;      ///< 被替换的旧实现：当前 flat namespace 里那枚（= 系统 GLES）
} A2GlBridgeInterposeTuple;

/// `dyld_dynamic_interpose` 的函数原型（★私有符号★，见 https://…/dyld_priv.h，不链接、只 dlsym）。
typedef void (*A2PFN_dyld_dynamic_interpose)(const struct mach_header *mh,
                                             const A2GlBridgeInterposeTuple *array,
                                             size_t count);

/// ★参与 interpose 的 GL 入口清单★：MG 后端建面/绘制主路径上的 `gl*`（顺序即日志顺序）。
/// 只放**MG 自己导出**的入口：`replacement` 取不到就跳过（见 `a2_gl_bridge_interpose_gl_to_mg` 的计数）。
/// ★不加 `egl*`★：MG 的 `egl*` 只是门面，宿主是 ANGLE，把 `egl*` 也改指 MG 会绕开宿主。
static const char *const kMgInterposeEntryNames[] = {
    "glTexImage2D", "glDrawArrays", "glDrawElements",
    "glGenTextures", "glBindTexture", "glTexParameteri",
    "glGenBuffers", "glBindBuffer", "glBufferData",
    "glCreateShader", "glShaderSource", "glCompileShader",
    "glCreateProgram", "glAttachShader", "glLinkProgram", "glUseProgram",
    "glGetUniformLocation", "glGetAttribLocation", "glUniformMatrix4fv",
    "glVertexAttribPointer", "glEnableVertexAttribArray",
    "glGenFramebuffers", "glBindFramebuffer", "glFramebufferTexture2D",
    "glGenRenderbuffers", "glBindRenderbuffer", "glRenderbufferStorage",
    "glViewport", "glScissor", "glEnable", "glDisable",
    "glClear", "glClearColor", "glReadPixels", "glGetError",
    "glGetIntegerv", "glGetString", "glPixelStorei",
    "glBlendFunc", "glDepthFunc", "glCullFace",
    "glDeleteTextures", "glDeleteBuffers", "glDeleteShader", "glDeleteProgram",
    NULL
};

/// ★元组表存活期★：dyld 只保存指向这张表的**指针**（`dyld_priv.h` 未承诺拷贝）⇒ 必须静态存储，
/// 不能放栈上。表长 = 清单长度（含 NULL 结尾项，多出的那格不用）。
static A2GlBridgeInterposeTuple gMgInterposeTuples[
    sizeof(kMgInterposeEntryNames) / sizeof(kMgInterposeEntryNames[0])];

/// interpose 的安装状态（★幂等★：attach 重试时不重复装第二遍）。
/// 0 = 未尝试；1 = 已装且归属已翻转；2 = 不可用 / 装上了但归属没翻转（两种情况都走 ④a4 的原回退）。
static int gMgInterposeState = 0;

/// 取 `dyld_dynamic_interpose` 函数指针（★私有符号：公开 SDK 不声明、也不能链接★）。
/// 两路：① `dlsym(RTLD_DEFAULT)`（libdyld 常驻，flat 查找就能命中）；
///       ② 已加载的 libdyld 句柄（`RTLD_NOLOAD` 只取句柄、不触发加载），句柄由紧跟的 `dlclose` 配平。
/// @return NULL = 该系统的 libdyld 没导出这个符号（调用方据此走原回退）。
static A2PFN_dyld_dynamic_interpose a2_gl_bridge_resolve_dyld_interpose(void) {
    void *sym = dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose");
    if (sym == NULL) {
        void *dyldHandle = dlopen("/usr/lib/libdyld.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (dyldHandle != NULL) {
            sym = dlsym(dyldHandle, "dyld_dynamic_interpose");
            dlclose(dyldHandle);   // ★配平 NOLOAD 的引用★（libdyld 常驻，不会真被卸）
        }
    }
    return (A2PFN_dyld_dynamic_interpose)sym;
}

/// MG 镜像的 `mach_header`（★唯一取法：任一 MG 导出的地址 → `dladdr` 的 `dli_fbase`★；
/// 与 Chromium / 老 Air 在 `dyld_dynamic_interpose` 上的取法一致，不去扫 `_dyld_get_image_header` 猜名字）。
/// @return NULL = MG 未加载或没有可用导出（调用方据此放弃 interpose）。
static const struct mach_header *a2_gl_bridge_mg_image_header(void) {
    if (gRendererHandle == NULL) return NULL;
    void *anyExport = dlsym(gRendererHandle, "glTexImage2D");
    if (anyExport == NULL) return NULL;
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(anyExport, &info) == 0 || info.dli_fbase == NULL) return NULL;
    return (const struct mach_header *)info.dli_fbase;
}

/// 该镜像是否参与 interpose（★只改「本进程自己加载的镜像」★）：
///   · 跳过 dyld 共享缓存（`/System/`、`/usr/lib/`）：那里的页是**跨进程共享**的，改绑定点不安全，
///     而且系统 OpenGLES 正是我们要顶掉的那一份；
///   · 跳过 ANGLE 两份（宿主）：它们内部必须调自己的实现，改指 MG 才是真错乱。
static int a2_gl_bridge_image_interposable(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    if (strncmp(path, "/System/", 8) == 0) return 0;
    if (strncmp(path, "/usr/lib/", 9) == 0) return 0;
    if (strstr(path, "libEGL.framework") != NULL || strstr(path, "libGLESv2.framework") != NULL) return 0;
    return 1;
}

/// ★安装 `gl*` → MG 的动态 interpose★（调用点：`a2_gl_bridge_attach` 的 ④a2，MG 后端**一次**）。
/// 做两件事（对齐 dyld 的两种生效路径，哪条能通都算成功）：
///   ① 建元组表 `{replacement=MG 导出, replacee=当前 flat 那枚}` ⇒ 之后 flat 查找（dlsym）能命中 MG；
///   ② 逐个「本进程自己加载的镜像」调 `dyld_dynamic_interpose` ⇒ 已解析的绑定点改指 MG
///      （dyld 口径是逐镜像改，不是全局；共享缓存/ANGLE 见 `a2_gl_bridge_image_interposable`）。
/// ★失败即回退，不阻断、不崩★：取不到函数指针 / 取不到 MG 的 mach_header / 元组表为空 ⇒ 打
///   `★interpose 不可用★`；装上了但 flat 归属没翻转 ⇒ 打「已装但归属未翻转」。两种都保持
///   attach ④a4 的「退回 ANGLE 建面」。★幂等★：装过就不再装。
static void a2_gl_bridge_interpose_gl_to_mg(void) {
    if (gMgInterposeState != 0) return;
    gMgInterposeState = 2;   // ★先按「没成」记账★：下面任何一步失败都落在这条，成功才改 1

    A2PFN_dyld_dynamic_interpose interpose = a2_gl_bridge_resolve_dyld_interpose();
    if (interpose == NULL) {
        a2_log_criterion(@"[A2-GLBRIDGE] ★interpose 不可用★ 取不到 dyld_dynamic_interpose"
                         @"（RTLD_DEFAULT 与 libdyld 句柄都试过）⇒ 保持「退回 ANGLE 建面」，不崩");
        return;
    }
    const struct mach_header *mgHeader = a2_gl_bridge_mg_image_header();
    if (mgHeader == NULL) {
        a2_log_criterion(@"[A2-GLBRIDGE] ★interpose 不可用★ 取不到 MG 的 mach_header"
                         @"（dlsym/dladdr 都拿不到 MG 导出）⇒ 保持「退回 ANGLE 建面」，不崩");
        return;
    }

    // ---- 元组表：MG 有该导出、且与 flat 那枚不同源才收（同源 = 已经指向 MG，收了也是空转）----
    size_t count = 0, skipped = 0;
    const int namesTotal = (int)(sizeof(kMgInterposeEntryNames) / sizeof(kMgInterposeEntryNames[0])) - 1;
    for (int i = 0; i < namesTotal; i++) {
        void *replacement = dlsym(gRendererHandle, kMgInterposeEntryNames[i]);
        void *replacee    = dlsym(RTLD_DEFAULT,    kMgInterposeEntryNames[i]);
        if (replacement == NULL || replacee == NULL || replacement == replacee) { skipped++; continue; }
        gMgInterposeTuples[count].replacement = replacement;
        gMgInterposeTuples[count].replacee    = replacee;
        count++;
    }
    if (count == 0) {
        a2_log_criterion(@"[A2-GLBRIDGE] ★interpose 不可用★ 元组表为空（清单 %d 条全被跳过："
                         @"MG 无该导出或已与 flat 同源）⇒ 保持「退回 ANGLE 建面」，不崩", namesTotal);
        return;
    }
    a2_log_f(@"[A2-GLBRIDGE] interpose 表：%d 条（清单 %d 条 / 跳过 %d 条）；MG mach_header=%p",
             (int)count, namesTotal, (int)skipped, (const void *)mgHeader);

    // ---- 逐镜像安装（★快照式遍历★：attach 在启动链单线程段内，遍历期间不会有新镜像加载）----
    int images = 0;
    const uint32_t total = _dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        if (hdr == NULL) continue;
        if (!a2_gl_bridge_image_interposable(_dyld_get_image_name(i))) continue;
        interpose(hdr, gMgInterposeTuples, count);
        images++;
    }
    a2_log_f(@"[A2-GLBRIDGE] interpose 已安装：%d 条元组 × %d 个镜像（共 %u 个镜像，其余因共享缓存/ANGLE 跳过）",
             (int)count, images, (unsigned)total);

    // ---- 生效判据：flat 里 `glTexImage2D` 是否已归 MG（唯一可判据的事实；不猜）----
    void *flat = NULL;
    A2GlBridgeSymbolOwner owner = a2_gl_bridge_symbol_owner("glTexImage2D", &flat);
    if (owner == A2GlBridgeSymbolOwnerMG) {
        gMgInterposeState = 1;
        a2_log_criterion(@"[A2-GLBRIDGE] interpose 生效：glTexImage2D flat=%p 归属=MG（%d 个入口）",
                         flat, (int)count);
        return;
    }
    a2_log_criterion(@"[A2-GLBRIDGE] interpose 已装但归属未翻转：glTexImage2D flat=%p 归属=%s（%d 个入口）"
                     @"⇒ 保持「退回 ANGLE 建面」，不崩",
                     flat, a2_gl_bridge_owner_label(owner), (int)count);
}

/// 当前后端是否 = ★NG-GL4ES / KW★（那一支需要宿主「注册解析器 + 显式初始化」）。
/// ★精确比较，不做模糊匹配★：`libnggl4es.dylib`（老的那支，自带 constructor）不能命中。
static int a2_gl_bridge_is_krypton(void) {
    return (gBackendName[0] != '\0' && strcmp(gBackendName, A2GlBridgeKryptonDylibName) == 0);
}

/// 当前后端是否 = ★MobileGlues★（唯一判据来源：dylib 名子串 `mobileglues`）。
/// ★两处共用，不许各自写字面量★：① 依赖库的加载旗标（④）；② MG 的归属核对（④a3）。
static int a2_gl_bridge_is_mobileglues(void) {
    return (gBackendName[0] != '\0' && strstr(gBackendName, "mobileglues") != NULL);
}

/// 已选后端是否 = ★宿主 EGL 后端★（`libeagl.dylib`：EGL 由本二进制提供，GL 层 = MobileGlues）。
/// ★精确比较★：其它后端名里不会出现这个标识，模糊匹配只会误伤。
static int a2_gl_bridge_backend_is_host_egl(const char *rendererName) {
    return (rendererName != NULL && rendererName[0] != '\0' &&
            strcmp(rendererName, A2RendererHostEAGLDylibName) == 0);
}

/// ★建面用的 native window 实参★（★唯一产地★，attach 与改绑两处共用）。
///   · 普通后端：EGL 实现自己认识图层，直接把图层指针当 native window；
///   · 宿主 EGL 后端：包成 `A2FakeEglWindowSize{宽, 高, 图层}` —— 假 EGL 据此走
///     CAEAGLLayer + `-presentRenderbuffer:`（上屏），而不再是离屏 FBO。
/// `box == NULL` ⇒ 普通后端。★box 必须活到 eglCreateWindowSurface 返回之后★（调用方栈变量即可）。
/// ★给真 EGL（ANGLE/Metal）准备它认的图层★
///   真机证据（0eead9a）：交给 ANGLE 的是 CALayer ⇒ eglCreateWindowSurface 带属性报
///   EGL_BAD_ATTRIBUTE(0x3004)、退回无属性返回 surface=0x1（假表面），
///   随后每帧采样中心像素恒为 R0 G0 B0 A0 —— 游戏根本没往这块表面画。
///   ANGLE 的 Metal 后端只认 CAMetalLayer，所以宿主图层不是它时，现挂一层子层并返回。
///
/// ★实现约束（踩过）★：这里**不能**用裸 objc_msgSend 传结构体（CGRect）——
///   clang 对那写法会直接崩且不给诊断，整个 target 编译失败。改用 KVC/NSValue 与
///   performSelector:，全程只传对象。
/// ★图层可见性核对 + 强制可见★（真机 8d9f052：class=CAMetalLayer、像素逐帧变化，但屏幕全黑）
/// 到这一步渲染已无嫌疑，只剩「这个层没被合成」。这里把决定性状态打出来并强制修正：
///   view 是否在窗口里 / view.hidden / view.alpha / layer.hidden / layer.opacity /
///   layer.frame / zPosition / 父层类名
/// 修正：hidden=NO、opacity=1、zPosition=1000，并把 view 提到窗口子视图最前。
static void a2_gl_bridge_force_layer_visible(void *viewPtr, void *layerPtr) {
    if (layerPtr == NULL) return;
    id layer = (__bridge id)layerPtr;
    id view  = (__bridge id)viewPtr;
    @try {
        id win = nil;
        if (view != nil && [view respondsToSelector:NSSelectorFromString(@"window")]) {
            win = [view performSelector:NSSelectorFromString(@"window")];
        }
        NSValue *vframe = [view valueForKey:@"frame"];
        NSNumber *vhidden = [view valueForKey:@"hidden"];
        NSNumber *valpha  = [view valueForKey:@"alpha"];
        NSValue *lframe = [layer valueForKey:@"frame"];
        NSNumber *lhidden = [layer valueForKey:@"hidden"];
        NSNumber *lopacity = [layer valueForKey:@"opacity"];
        // ★窗口链判据★（a2_log_f 不支持 %@，全部用 %s）
        NSNumber *winHidden = nil, *winLevel = nil, *winKey = nil, *winAlpha = nil;
        NSValue *winBounds = nil;
        @try { winHidden = [win valueForKey:@"hidden"]; } @catch (__unused NSException *e) {}
        @try { winLevel  = [win valueForKey:@"windowLevel"]; } @catch (__unused NSException *e) {}
        @try { winKey    = [win valueForKey:@"isKeyWindow"]; } @catch (__unused NSException *e) {}
        @try { winAlpha  = [win valueForKey:@"alpha"]; } @catch (__unused NSException *e) {}
        @try { winBounds = [win valueForKey:@"bounds"]; } @catch (__unused NSException *e) {}
        id superview = nil;
        @try { superview = [view valueForKey:@"superview"]; } @catch (__unused NSException *e) {}
        a2_log_f("[A2-GLBRIDGE] 图层可见性核对：view=%s inWindow=%d frame=%s hidden=%s alpha=%s ｜ "
                 "layer=%s frame=%s hidden=%s opacity=%s z=%s",
                 view ? [NSStringFromClass([view class]) UTF8String] : "(nil)", (win != nil),
                 vframe ? [[vframe description] UTF8String] : "(nil)",
                 vhidden ? [[vhidden description] UTF8String] : "(nil)",
                 valpha ? [[valpha description] UTF8String] : "(nil)",
                 NSStringFromClass([layer class]).UTF8String,
                 lframe ? [[lframe description] UTF8String] : "(nil)",
                 lhidden ? [[lhidden description] UTF8String] : "(nil)",
                 lopacity ? [[lopacity description] UTF8String] : "(nil)",
                 [[[layer valueForKey:@"zPosition"] description] UTF8String]);
        a2_log_f("[A2-GLBRIDGE] ★窗口状态★ window=%s hidden=%s level=%s isKey=%s alpha=%s bounds=%s ｜ superview=%s",
                 win ? [NSStringFromClass([win class]) UTF8String] : "(nil)",
                 winHidden ? [[winHidden description] UTF8String] : "(nil)",
                 winLevel ? [[winLevel description] UTF8String] : "(nil)",
                 winKey ? [[winKey description] UTF8String] : "(nil)",
                 winAlpha ? [[winAlpha description] UTF8String] : "(nil)",
                 winBounds ? [[winBounds description] UTF8String] : "(nil)",
                 superview ? [NSStringFromClass([superview class]) UTF8String] : "(nil)");
        [layer setValue:@NO forKey:@"hidden"];
        [layer setValue:@1 forKey:@"opacity"];
        [layer setValue:@1000 forKey:@"zPosition"];
        if (win != nil && [win respondsToSelector:NSSelectorFromString(@"bringSubviewToFront:")]) {
            [win performSelector:NSSelectorFromString(@"bringSubviewToFront:") withObject:view];
        }
        a2_log_f(@"[A2-GLBRIDGE] 已强制图层可见（hidden=NO opacity=1 z=1000，view 提到最前）");
    } @catch (__unused NSException *e) {
        a2_log_f(@"[A2-GLBRIDGE] 图层可见性核对失败：%@", e.reason);
    }
}

static void *a2_gl_bridge_metal_layer_for(void *renderable) {
    if (renderable == NULL) return NULL;
    id host = (__bridge id)renderable;
    if (host == nil) return renderable;
    Class metalLayerCls = NSClassFromString(@"CAMetalLayer");
    if (metalLayerCls == Nil) return renderable;                 // 无 Metal ⇒ 原样返回
    if ([host isKindOfClass:metalLayerCls]) return renderable;    // 已是 ⇒ 直接用

    // 已有 CAMetalLayer 子层就复用，避免每次 attach 叠层
    id sublayers = [host valueForKey:@"sublayers"];
    if ([sublayers isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)sublayers) {
            if ([sub isKindOfClass:metalLayerCls]) return (__bridge void *)sub;
        }
    }

    id layer = [metalLayerCls new];
    if (layer == nil) return renderable;

    NSValue *boundsVal = [host valueForKey:@"bounds"];
    NSNumber *scaleVal = [host valueForKey:@"contentsScale"];
    if ([boundsVal isKindOfClass:[NSValue class]]) {
        [layer setValue:boundsVal forKey:@"frame"];
    }
    double scale = (scaleVal != nil) ? scaleVal.doubleValue : 1.0;
    if (scale <= 0.0) scale = 1.0;
    [layer setValue:@(scale) forKey:@"contentsScale"];

    SEL addSel = sel_registerName("addSublayer:");
    if ([host respondsToSelector:addSel]) {
        [host performSelector:addSel withObject:layer];
    } else {
        return renderable;
    }
    // ★宿主层是否真在窗口里（2026-10-31 真机）★
    //   CALayer 的 delegate 就是拥有它的 view；若那个 view 的 window 为 nil，
    //   说明这层根本不在任何窗口上 ⇒ 画得再对也不会被合成（现象：hidden=0 opacity=1 却全黑）。
    //   此时把 Metal 层改挂到 keyWindow 的根层，保证它进入合成树。
    id lyDelegate = [host valueForKey:@"delegate"];
    id lyWindow = nil;
    @try { lyWindow = [lyDelegate valueForKey:@"window"]; } @catch (__unused NSException *e) { lyWindow = nil; }
    NSLog(@"[A2-GLBRIDGE] 宿主归属：layer 的 delegate=%@ window=%@",
          lyDelegate ? NSStringFromClass([lyDelegate class]) : @"(nil)",
          lyWindow ? NSStringFromClass([lyWindow class]) : @"(nil)");
    if (lyWindow == nil && lyDelegate != nil) {
        Class appCls = NSClassFromString(@"UIApplication");
        id app = nil;
        if (appCls != Nil) {
            SEL sharedSel = sel_registerName("sharedApplication");
            if ([appCls respondsToSelector:sharedSel]) app = [appCls performSelector:sharedSel];
        }
        id keyWin = nil;
        @try { keyWin = [app valueForKey:@"keyWindow"]; } @catch (__unused NSException *e) { keyWin = nil; }
        id winLayer = nil;
        @try { winLayer = [keyWin valueForKey:@"layer"]; } @catch (__unused NSException *e) { winLayer = nil; }
        if (winLayer != nil) {
            SEL removeSel = sel_registerName("removeFromSuperlayer");
            if ([layer respondsToSelector:removeSel]) [layer performSelector:removeSel];
            NSValue *winBounds = nil;
            @try { winBounds = [keyWin valueForKey:@"bounds"]; } @catch (__unused NSException *e) { winBounds = nil; }
            if (winBounds != nil) [layer setValue:winBounds forKey:@"frame"];
            if ([winLayer respondsToSelector:addSel]) {
                [winLayer performSelector:addSel withObject:layer];
                NSLog(@"[A2-GLBRIDGE] ★宿主层不在窗口内 ⇒ 改挂 keyWindow 根层★ window=%@ layer=%@ frame=%@",
                      keyWin ? NSStringFromClass([keyWin class]) : @"(nil)",
                      winLayer ? NSStringFromClass([winLayer class]) : @"(nil)",
                      winBounds ? [[winBounds description] UTF8String] : "(nil)");
            }
        }
    }

    // ★可见性核对（2026-10-31 真机）★ 内容在 Metal 层上逐帧更新但屏幕全黑，
    //   所以这里把「这一层能不能被看见」的几个量一次打全：frame/hidden/opacity/父层/宿主窗口。
    NSValue *frameVal = [layer valueForKey:@"frame"];
    NSValue *hostFrameVal = [host valueForKey:@"frame"];
    NSNumber *hiddenVal = [layer valueForKey:@"hidden"];
    NSNumber *opacityVal = [layer valueForKey:@"opacity"];
    id superlayer = [layer valueForKey:@"superlayer"];
    id hostWindow = [host valueForKey:@"window"];
    NSNumber *viewHidden = [host valueForKey:@"hidden"];
    NSNumber *viewAlpha = [host valueForKey:@"alpha"];
    NSLog(@"[A2-GLBRIDGE] Metal 层可见性：frame=%s hidden=%d opacity=%d 父层=%@ ｜ 宿主 frame=%s hidden=%d alpha=%.2f window=%@",
          frameVal ? [[frameVal description] UTF8String] : "(nil)",
          hiddenVal ? hiddenVal.intValue : -1,
          opacityVal ? opacityVal.intValue : -1,
          superlayer ? NSStringFromClass([superlayer class]) : @"(nil)",
          hostFrameVal ? [[hostFrameVal description] UTF8String] : "(nil)",
          viewHidden ? viewHidden.intValue : -1,
          viewAlpha ? viewAlpha.doubleValue : -1.0,
          hostWindow ? NSStringFromClass([hostWindow class]) : @"(nil)");
    NSLog(@"[A2-GLBRIDGE] 为真 EGL 现挂 CAMetalLayer 子层（宿主=%@）", NSStringFromClass([host class]));
    return (__bridge void *)layer;
}

static A2EGLNativeWindowType a2_gl_bridge_window_arg(A2FakeEglWindowSize *box, void *renderable) {
    if (box != NULL) return (A2EGLNativeWindowType)box;
    return (A2EGLNativeWindowType)renderable;
}

/// 宿主 EGL 后端的 GL 层 dylib 名（★MG 当 GL 层，见 [A2-RENDERER] 的选型说明★）。
static const char *const A2GlBridgeHostEglLayerDylib = "libmobileglues.dylib";

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

// ============================================================================
//  ★MG 引导：`mg_init_gles`（老 Air 同款）★
// ============================================================================
// 老 Air `Natives/ctxbridges/gl_bridge.m`：`ame_mg_init_gles` 在 :1215 声明、:1381 dlsym、
//   :1534/1559 在 **gl_make_current 里、真实上下文生效之后** 调用；:1203-1206 的注释点明原因：
//   `mg_init_gles()` 内部做 caps 检测 ⇒ 必须「有当前上下文」才有正确结果。
// 本层补上同一步（方案 A 下 MG 只是门面，但它那套状态仍要初始化，否则 LWJGL 的
//   `GL.createCapabilities` 拿不到 caps ⇒ 卡死）。★缺符号 / 调用异常一律只记日志、不阻断启动★。

/// ★取 MG 的 `mg_init_gles`（唯一产地）★ 调用点：`a2_gl_bridge_attach` 的 ④（后端本体加载之后，一次）。
/// 幂等：已取到或句柄为空 ⇒ 直接返回（不重复 dlsym）。
static void a2_gl_bridge_load_mg_init_symbol(void) {
    if (gMgInitGles != NULL || gRendererHandle == NULL) return;
    gMgInitGles = (A2PFN_mg_init_gles)dlsym(gRendererHandle, "mg_init_gles");
    a2_log_f(@"[A2-GLBRIDGE] MG 引导符号 mg_init_gles=%p（%s）", (void *)gMgInitGles,
             (gMgInitGles != NULL) ? "已取得 ⇒ 上下文生效后调用"
                                   : "★缺符号★ ⇒ 不能引导（不阻断启动）");
}

/// ★在真实上下文生效之后调一次 `mg_init_gles`★
/// 调用点（两处，都是「上下文刚成为 current」的那一点）：
///   ① `a2_gl_bridge_attach` 的 ⑥（`eglMakeCurrent` 成功、`EGL 就绪` 之后）；
///   ② `a2_gl_bridge_make_current`（首次 `glfwMakeContextCurrent`，含其中那次表面重绑成功之后）。
/// @param why 调用点说明（进日志，真机据此区分是哪一处先到的）。
/// ★幂等★：`gMgInitGlesDone` 先置位再调用 ⇒ 之后每次 makeCurrent 都是空操作，绝不重入。
/// ★不阻断★：非 MG 后端 / 缺符号 / 已调用过 ⇒ 直接返回；`mg_init_gles` 无返回值，
///   失败只能靠后续日志（`Backend library:` 之后是否有输出）判读。
static void a2_gl_bridge_mg_init_gles_if_needed(const char *why) {
    if (!a2_gl_bridge_is_mobileglues()) return;   // 只有 MG 有这一步（其它后端的初始化见 ⑥a）
    if (gMgInitGlesDone) return;
    if (gMgInitGles == NULL) {
        gMgInitGlesDone = 1;   // 缺符号 ⇒ 只报一次（否则每次 makeCurrent 都刷屏）
        a2_log_f(@"[A2-GLBRIDGE] MG 缺 mg_init_gles 符号 ⇒ 不能引导（%s）",
                 (why != NULL) ? why : "未注明调用点");
        return;
    }

    // ★调用前后对照归属★：`glTexImage2D` 在 flat namespace 的归属若被 MG 引导改变，额外打一行（下面）。
    void *mgGlTexImage2D = (gRendererHandle != NULL) ? dlsym(gRendererHandle, "glTexImage2D") : NULL;
    void *addrBefore = NULL;
    A2GlBridgeSymbolOwner ownerBefore = a2_gl_bridge_symbol_owner("glTexImage2D", &addrBefore);

    gMgInitGlesDone = 1;       // ★先置位★：即便 init 内部抛异常也不重入（幂等由本标志承担）
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    gMgInitGles();
    clock_gettime(CLOCK_MONOTONIC, &t1);
    const double ms = (double)(t1.tv_sec - t0.tv_sec) * 1000.0 +
                      (double)(t1.tv_nsec - t0.tv_nsec) / 1e6;

    a2_log_criterion(@"[A2-GLBRIDGE] MG mg_init_gles 已调用（真实上下文已在场）— %s",
                     (why != NULL) ? why : "未注明调用点");
    a2_log_f(@"[A2-GLBRIDGE] mg_init_gles 耗时 %.2f ms", ms);

    void *addrAfter = NULL;
    A2GlBridgeSymbolOwner ownerAfter = a2_gl_bridge_symbol_owner("glTexImage2D", &addrAfter);
    if (ownerAfter != ownerBefore) {
        a2_log_f(@"[A2-GLBRIDGE] MG 引导后 glTexImage2D 归属变化：%s ⇒ %s（before=%p after=%p）",
                 a2_gl_bridge_owner_label(ownerBefore), a2_gl_bridge_owner_label(ownerAfter),
                 addrBefore, addrAfter);
        (void)a2_gl_bridge_log_owner("glTexImage2D", mgGlTexImage2D);   // 复用归属核对行（flat=… 归属=…（MG=…））
    }
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

/// ★把宿主视图所在的窗口抬到可见层级★（不改任何渲染状态）。
/// 真机证据（5c16780）：改绑成功、CAMetalLayer 上有内容且逐帧变化，但屏幕全黑；
/// 同时日志显示「重绑到 GLFW 宿主视图 view=A2GlfwView level=-1」——
/// 窗口层级为 -1 意味着它在所有普通窗口【下面】⇒ 画了也看不见。
/// 这里把 windowLevel 抬到 UIWindowLevelStatusBar+1（1001），并在抬前后各记一行。
static void a2_gl_bridge_raise_host_window(void *view) {
    if (view == NULL) return;
    SEL winSel = NSSelectorFromString(@"window");
    SEL levelSel = NSSelectorFromString(@"windowLevel");
    SEL setLevelSel = NSSelectorFromString(@"setWindowLevel:");
    id v = (__bridge id)view;
    if (![v respondsToSelector:winSel]) return;
    id win = [v performSelector:winSel];
    if (win == nil || ![win respondsToSelector:levelSel] || ![win respondsToSelector:setLevelSel]) return;
    double before = ((double (*)(id, SEL))objc_msgSend)(win, levelSel);
    if (before >= 1000.0) return;                       // 已经在状态栏之上 ⇒ 不动
    ((void (*)(id, SEL, double))objc_msgSend)(win, setLevelSel, 1001.0);
    double after = ((double (*)(id, SEL))objc_msgSend)(win, levelSel);
    a2_log_f(@"[A2-GLBRIDGE] ★宿主窗口抬层★ windowLevel %.0f ⇒ %.0f（原层级在普通窗口之下 ⇒ 画面不可见）",
             before, after);
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
    // ★宿主 EGL 后端：同样要包成 A2FakeEglWindowSize（上屏）★ —— 与 attach ⑥1 共用同一个实参产地。
    A2FakeEglWindowSize hostWinBox = { 0, 0, NULL };
    A2FakeEglWindowSize *hostWinBoxPtr = NULL;
    if (gHostEgl) {
        hostWinBox.width  = (A2EGLint)gWidthPixels;
        hostWinBox.height = (A2EGLint)gHeightPixels;
        hostWinBox.layer  = want;
        hostWinBoxPtr = &hostWinBox;
    }
    void *eglWant = gHostEgl ? want : a2_gl_bridge_metal_layer_for(want);
    A2EGLSurface newSurf = A2_EGL_NO_SURFACE;
    if (a2_gl_bridge_is_krypton()) {
        // KW 家族在 attach 里就是「NULL 属性」（对齐老 Air 建面顺序）⇒ 这里保持一致。
        newSurf = gEglCreateWindowSurface(gDpy, gCfg, a2_gl_bridge_window_arg(hostWinBoxPtr, eglWant), NULL);
    } else {
        const A2EGLint surfAttribs[] = {
            A2_EGL_WIDTH,  (A2EGLint)gWidthPixels,
            A2_EGL_HEIGHT, (A2EGLint)gHeightPixels,
            A2_EGL_NONE
        };
        if (gWidthPixels > 0 && gHeightPixels > 0) {
            newSurf = gEglCreateWindowSurface(gDpy, gCfg,
                                              a2_gl_bridge_window_arg(hostWinBoxPtr, eglWant), surfAttribs);
        }
        if (newSurf == A2_EGL_NO_SURFACE) {               // 实现不认 EGL_WIDTH/HEIGHT ⇒ 退到无属性
            newSurf = gEglCreateWindowSurface(gDpy, gCfg,
                                              a2_gl_bridge_window_arg(hostWinBoxPtr, want), NULL);
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
    // ★2026-10-31 判据★ 改绑成功：把新旧表面与宿主都打出来。
    //   真机（5070717）：像素采样 R239 G50 B61 说明游戏在画，但屏幕黑 ⇒
    //   必须确认这一行给出的 newSurf 是否已经从「启动器图层」换到了「CAMetalLayer」。
    a2_gl_bridge_raise_host_window(want);   // ★层级核对★ level<0 时抬到可见层（否则画了也黑）
    a2_gl_bridge_force_layer_visible(want, eglWant);   // ★可见性核对 + 强制可见★
    a2_log_f(@"[A2-GLBRIDGE] ★改绑成功★ 旧 surface=%p ⇒ 新 surface=%p（宿主=%p class=%s）",
             (void *)oldSurf, (void *)newSurf, (void *)eglWant,
             (eglWant != NULL) ? NSStringFromClass([(__bridge id)eglWant class]).UTF8String : "(null)");
    {
        // ★改绑成功必须留痕★：黑屏排查时要能确认「surface 换没换、换成谁」。
        const char *cls = "?";
        if (eglWant != NULL) {
            @try { cls = NSStringFromClass([(__bridge id)eglWant class]).UTF8String; }
            @catch (__unused NSException *e) { cls = "(not-objc)"; }
        }
        a2_log_f(@"[A2-GLBRIDGE] 改绑成功：新 surface=%p（旧=%p）renderable=%p class=%s drawable=%dx%d 像素",
                 (void *)newSurf, (void *)oldSurf, eglWant, cls, gWidthPixels, gHeightPixels);
    }
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
/// ★游戏是否已开始自己提交帧★（a2_gl_bridge_swap_buffers 被调用过）。
/// 一旦为真，预览用的「清屏+swap」循环必须让路，否则会把游戏画好的帧擦成纯黑。
static int gGamePresented = 0;

static void a2_gl_bridge_frame_work(void) {
    if (!gAttached) return;
    if (gGamePresented) return;   // 游戏在画 ⇒ 本层不再清屏/呈现

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
    // ★MG 引导★：上下文刚在**本线程**成为 current（上面那一步若做过首次重绑，此时绑的就是游戏视图）
    //   ⇒ 与老 Air 同一时点调一次 `mg_init_gles`（内部 caps 检测必须有当前上下文）。
    //   幂等：`gMgInitGlesDone` 置位后这里就是空操作；★失败只记日志，不影响返回值★。
    if (ok) a2_gl_bridge_mg_init_gles_if_needed("首次 make_current（glfwMakeContextCurrent）成功");
    return ok ? 0 : -2;
}

/// ★供 glfwSwapBuffers 调用★：只做「把当前表面 swap 上屏」，不碰 viewport/scissor、
/// 不清屏、不改上下文绑定 —— 内容由游戏自己画，我们只负责提交。
void a2_gl_bridge_swap_buffers(void) {
    if (!gAttached) return;
    if (gEglSwapBuffers != NULL && gDpy != NULL && gSurf != NULL) {
        // ★2026-10-31 黑屏判定★ 提交前读中心 1 个像素（每 60 次打一行）：
        //   非 0/0/0 ⇒ 画面确实在画，问题在「呈现到图层」；
        //   恒 0/0/0 ⇒ 根本没画，问题在「渲染/上下文」。
        //   只用 GLES2 就有的 glReadPixels，不需要 FBO/扩展。
        // ★上下文归属判据（每 60 次一行）★：MC 是否真的在【我们的】上下文/表面上画。
        //   真机 ede2f52：surface=0x1（假）且像素恒 0 ⇒ 有可能 MC 用的是另一个 context。
        static unsigned long a2_ctxProbeN = 0;
        if ((++a2_ctxProbeN % 60) == 1) {
            typedef void *(*A2PFN_eglGetCurrentContext)(void);
            typedef void *(*A2PFN_eglGetCurrentSurface)(int);
            A2PFN_eglGetCurrentContext curCtxFn =
                (A2PFN_eglGetCurrentContext)dlsym(RTLD_DEFAULT, "eglGetCurrentContext");
            A2PFN_eglGetCurrentSurface curSurfFn =
                (A2PFN_eglGetCurrentSurface)dlsym(RTLD_DEFAULT, "eglGetCurrentSurface");
            void *curCtx = curCtxFn ? curCtxFn() : NULL;
            void *curSurf = curSurfFn ? curSurfFn(0x305A /*EGL_READ*/) : NULL;
            a2_log_f(@"[A2-GLBRIDGE] 上下文归属 #%lu：当前 ctx=%p surf=%p ｜ 本层 gCtx=%p gSurf=%p %s",
                     a2_ctxProbeN, curCtx, curSurf, (void *)gCtx, (void *)gSurf,
                     (curCtx == (void *)gCtx) ? "（同一上下文 ⇒ 画在本层表面）"
                                              : "（★不同上下文 ⇒ MC 画在别处★）");
        }
        static unsigned long a2_pxProbeN = 0;
        if ((++a2_pxProbeN % 60) == 1) {
            typedef void (*A2PFN_glReadPixels)(int, int, int, int, unsigned, unsigned, void *);
            // ★从 GL 层句柄取★：flat namespace 可能解析到系统 GLES（MG 报过 SYMBOL THEFT），
            //   那样读的就不是 MC 实际绘制用的那条链路 ⇒ 恒 0 是假象。
            void *glLayerHandle = gRendererHandle;
            A2PFN_glReadPixels rp = glLayerHandle
                ? (A2PFN_glReadPixels)dlsym(glLayerHandle, "glReadPixels") : NULL;
            const char *rpSrc = "GL层句柄";
            if (rp == NULL) {
                rp = (A2PFN_glReadPixels)dlsym(RTLD_DEFAULT, "glReadPixels");
                rpSrc = "RTLD_DEFAULT";
            }
            if (rp != NULL && gWidthPixels > 2 && gHeightPixels > 2) {
                unsigned char px[4] = { 0, 0, 0, 0 };
                rp(gWidthPixels / 2, gHeightPixels / 2, 1, 1, 0x1908 /*GL_RGBA*/, 0x1401 /*GL_UNSIGNED_BYTE*/, px);
                a2_log_f(@"[A2-GLBRIDGE] 采样中心像素 #%lu = R%u G%u B%u A%u（全 0 ⇒ 没画；非 0 ⇒ 画了没上屏）",
                         a2_pxProbeN, px[0], px[1], px[2], px[3]);
                a2_log_f(@"[A2-GLBRIDGE] 像素采样来源=%s handle=%p", rpSrc, glLayerHandle);
            }
        }
        if (!gGamePresented) {
            gGamePresented = 1;   // 第一次由游戏提交 ⇒ 停掉预览清屏循环
            a2_log_f(@"[A2-GLBRIDGE] 游戏已开始提交帧 ⇒ 预览清屏循环让路（首次 glfwSwapBuffers）");
        }
        gEglSwapBuffers(gDpy, gSurf);
    }
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
        "libeagl.dylib",             // 宿主 EGL（系统 GLES 3.0 / EAGL；1.17+ 临时默认）
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
    a2_log_f(@"[A2-GLBRIDGE] 后端判定：selected=%s ⇒ EGL/GL 系，本桥负责建面", rendererName);

    // ---- ①b ★宿主 EGL 后端（libeagl.dylib）★：EGL 层是本二进制的假 EGL，GL 层是 MobileGlues ----
    //   · EGL 句柄 = `dlopen(NULL)`（主镜像；`egl*` 已在主二进制里，flat namespace 第一位）
    //     ⇒ 建面用的 EGL 就是「假 EGL → EAGLContext/CAEAGLLayer」，不是 ANGLE；
    //   · GL 层 = MobileGlues（下方 `glLayerName`）⇒ `gBackendName` 记的是 **GL 层**，
    //     MG 的 RTLD_GLOBAL / 归属核对等判据全都照旧命中（不另写一套 MG 判据）。
    const int hostEglBackend = a2_gl_bridge_backend_is_host_egl(rendererName);
    const char *glLayerName = hostEglBackend ? A2GlBridgeHostEglLayerDylib : rendererName;
    if (hostEglBackend) {
        gHostEgl = 1;
        snprintf(gBackendName, sizeof(gBackendName), "%s", glLayerName);
        a2_log_f(@"[A2-GLBRIDGE] ★宿主 EGL 后端★ chosen=%s ⇒ EGL=本二进制（假 EGL → CAEAGLLayer 上屏，"
                 @"不 dlopen ANGLE 的 libEGL）；GL 层=%s",
                 rendererName, glLayerName);
    }

    // ★「后端是不是 MG」的唯一判据★（`a2_gl_bridge_is_mobileglues()` 判 `gBackendName`）。
    //   在这里取的原因：①b 可能把 gBackendName 改写成 GL 层名（宿主 EGL 后端的 GL 层也是 MG），
    //   判据必须读**定稿后**的名字；③0（问 MG 要 EGL）与 ④（依赖旗标）共用这一份，不各写一遍。
    const BOOL a2BackendIsMG = (a2_gl_bridge_is_mobileglues() != 0);

    // ---- 重入：先彻底清掉上一次（不留半成品）----
    // ★保命前置判据（真机 iOS 16.7：键盘/文本效果窗触发相位改绑后再跑 attach ⇒ SIGSEGV）★：
    //   旧表面还在（gAttached）或入口表非空 ⇒ 先核入口表完整性。缺一个就**中止且不 teardown**
    //   —— 旧表面继续出帧，绝不把 GL 表面释放空、也绝不带着空指针往下走。
    if (gAttached || gEglGetDisplay != NULL) {
        const char *lostEntry = a2_gl_bridge_egl_entry_missing();
        if (lostEntry != NULL) {
            a2_log_f(@"[A2-GLBRIDGE] ★attach 中止★ 缺 egl 入口：%s（入口表不完整 ⇒ 不 teardown，"
                     @"旧表面保持不动、继续用）", lostEntry);
            return A2GlBridgeErrEgl;
        }
    }
    if (gAttached) {
        a2_log_f(@"[A2-GLBRIDGE] 已附着 ⇒ 先释放上一次的 EGL/GL 资源再重建");
        a2_gl_bridge_teardown();
    }
    // ★teardown 会把 gHostEgl 清零★（它本身也要靠这个标志决定「主镜像句柄不能 dlclose」）
    //   ⇒ 清完之后按本次判定重新置位，后续建房/改绑/帧动作才认得出宿主 EGL 后端。
    if (hostEglBackend) {
        gHostEgl = 1;
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
    NSString *eglPath      = hostEglBackend
        ? nil   // 宿主 EGL 后端没有包内 EGL：`egl*` 就在主二进制里（见 ①b）
        : [frameworksPath stringByAppendingPathComponent:
           [NSString stringWithUTF8String:A2GlBridgeEglLibraryRelPath]];
    // ★GLES 兼容底的两种形态（★MG 后端禁用系统 GLES★）★：
    //   · 宿主 EGL 后端（libeagl.dylib）= **系统 OpenGLES**（假 EGL 的 EAGL 上下文建在它上面，
    //     `glClear`/`glViewport` 等帧动作必须打同一份实现）；
    //   · 其余（含 MG）= ANGLE 的 libGLESv2（随包在 Frameworks/libGLESv2.framework/）。
    //   ★为什么 MG 绝不加载系统 GLES★ 真机 lastlog-105：系统 GLES 在 dyld 共享缓存里，一旦被
    //   MG 认成 backend library，flat namespace 的 `glTexImage2D` 就落到它，而它**没有 EGL**
    //   ⇒ MG 报 `EGL entry point eglGetDisplay is not available in the backend library` 并失败。
    //   ★唯一判据是 hostEglBackend★（= EAGL 后端），不在这里另写「后端名是不是 MG」的判断。
    //   ★2026-10-31 最终口径（用户拍板选 A：全 ANGLE）★
    //   曾经试过「MG 的 GL 宿主=系统 OpenGLES」，真机证明是混搭：EGL 上下文由 ANGLE 创建，
    //   而 GL 调用送到系统 GLES ⇒ 两套实现状态不通，MG 宿主函数表为空 ⇒ `glGetError+0x14 pc=0x0`。
    //   自洽组合只有两种：
    //     A 全 ANGLE：EGL=ANGLE libEGL，GL=ANGLE libGLESv2，MG 当门面   ← 当前采用
    //     B 假 EGL：EGL=我们的 a2_eagl_egl，GL=系统 OpenGLES，MG 当门面（保留为可选后端）
    //   ⇒ 只有宿主 EGL 后端（EAGL 那条）才用系统 OpenGLES。
    const BOOL glesFromSystemGles = (hostEglBackend != 0);
    NSString *glesPath     = glesFromSystemGles
        ? @"/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
        : [frameworksPath stringByAppendingPathComponent:
           [NSString stringWithUTF8String:A2GlBridgeGlesLibraryRelPath]];
    NSString *rendererPath = [frameworksPath stringByAppendingPathComponent:
                              [NSString stringWithUTF8String:glLayerName]];
    a2_log_f(@"[A2-GLBRIDGE] GLES 兼容底=%s（%s）",
             glesFromSystemGles ? "系统 OpenGLES" : "ANGLE libGLESv2",
             glesFromSystemGles ? "EAGL 后端上屏链（假 EGL）" : "ANGLE 宿主（MG 与其它后端的 GL 层）");
    if (a2BackendIsMG && !hostEglBackend) {
        a2_log_criterion(@"[A2-GLBRIDGE] MG 后端：EGL/GL 双宿主均为 ANGLE（方案 A：全 ANGLE，MG 仅作门面）");
    }
    // ★判据行（真机 grep 这一行即可确认「假 EGL 层没有提前把系统 OpenGLES 带进进程」）★：
    //   MG 后端下系统的 OpenGLES.framework 一旦被任何一路 dlopen 进来，MG 就会把它当 backend
    //   library（而它没有 EGL）⇒ 报 `EGL entry point eglGetDisplay is not available…`。
    //   本层两条保证：① 本文件只在宿主 EGL 后端（libeagl.dylib）里加载系统 GLES；
    //                ② 假 EGL 层（a2_eagl_egl.m）在 engage 之前不 dlopen OpenGLES、不查 EAGLContext。
    // （原「MG 后端：未加载系统 OpenGLES」判据行已删除 —— 见上面的订正：MG 需要系统 GLES 当宿主）

    // ---- ③0 ★MG：ANGLE 先行、MG 后行★ ----
    //   ★顺序（lastlog-105 的修因，★不许再反转★）★：
    //     ① 先把 ANGLE 的 libEGL/libGLESv2 以 RTLD_GLOBAL 放进 flat namespace（a2_gl_bridge_load_angle_first）；
    //     ② 再加载 MG 本体（RTLD_GLOBAL）；③ 其它后端仍按 ④ 的常规顺序最后加载。
    //   为什么不能再「MG 先、ANGLE 后」（上一版 lastlog-104 的写法）：那样 flat namespace 里排第一的
    //   `gl*` 会落到**系统 OpenGLES**（共享缓存里、早于我们的 dlopen 就在全局表），MG 把它当
    //   backend library ⇒ 找不到 `eglGetDisplay` ⇒ 初始化失败 ⇒ 本桥拿到空指针 ⇒ SIGSEGV。
    //   ★MG 的 egl* 仍是门面★（判据在 `a2_gl_bridge_use_own_egl()` 内部，与 gHostEgl 绑定，不在这里另判）；
    //   ★与宿主 EGL 后端（libeagl.dylib）互斥★：那条链的 EGL 是主二进制的假 EGL（①b），
    //   系统 GLES 才是它的 GL 层 ⇒ 不预加载 ANGLE，也不改顺序。
    BOOL anglePreloaded = NO;
    if (a2BackendIsMG && !hostEglBackend) {
        anglePreloaded = (a2_gl_bridge_load_angle_first(eglPath, glesPath) != 0);
        if (!anglePreloaded) {
            a2_log_f(@"[A2-GLBRIDGE] ★阻断★：MG 后端要求 ANGLE 先入 flat namespace，但 ANGLE 兼容底未就绪");
            a2_gl_bridge_teardown();
            return A2GlBridgeErrLoadFailed;
        }
        if (!a2_gl_bridge_open_renderer(rendererPath.UTF8String)) {
            a2_gl_bridge_teardown();
            return A2GlBridgeErrLoadFailed;
        }
        a2_gl_bridge_use_own_egl();   // 门面=MG / 回退 ANGLE（日志点明缺哪个入口）；宿主恒 ANGLE
    }
    // ★门面来源★：④a3 的归属核对可能把它改回 ANGLE（MG 门面不可用时）⇒ 这里不能是 const，
    //   否则下面的判据行会报「门面=MG」而实际建面用的是 ANGLE（两种事实必须一致）。
    BOOL eglFromMG = (a2_gl_bridge_egl_source() == A2GlBridgeEglSourceMG);

    // ★三层都要求存在★：门面（MG 或 ANGLE 自带）恒需要后端本体；ANGLE 的 libEGL/libGLESv2
    //   在 MG 门面下**仍是必需**（它们是宿主，缺了 MG 的门面无处落地）。
    NSMutableArray<NSString *> *needed = [NSMutableArray array];
    if (eglPath != nil) [needed addObject:eglPath];   // 宿主 EGL 后端没有包内 EGL（`egl*` 在主镜像里）
    [needed addObject:glesPath];
    [needed addObject:rendererPath];
    for (NSString *p in needed) {
        BOOL isDir = NO;
        // ★系统框架绝对路径不走「包内内置」校验★（2026-10-31 回归修复）
        //   真机 lastlog：GL 宿主改成系统 OpenGLES 后，这里把
        //   `/System/Library/Frameworks/OpenGLES.framework/OpenGLES` 当成「包里没有的库」直接阻断
        //   ⇒ 附着 rc=-1 ⇒ ★阻断启动★ ⇒ 建 VM rc=-12。
        //   绝对路径（/System 或 /usr/lib）由系统提供，不属于包内资源，只校验存在性。
        const BOOL isSystemPath = [p hasPrefix:@"/System/"] || [p hasPrefix:@"/usr/lib/"];
        if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir] || isDir) {
            a2_log_f(@"%s ★阻断★：%s 不可用（%s）⇒ 不静默回退到默认渲染器",
                     A2GlBridgeJudgementTag, p.UTF8String,
                     isSystemPath ? "系统框架缺失" : "包内缺该后端所需的库（未内置）");
            return A2GlBridgeErrMissingLib;
        }
        if (isSystemPath) {
            a2_log_f(@"[A2-GLBRIDGE] 系统库校验通过：%s（不参与包内内置检查）", p.UTF8String);
        }
    }

    // ---- ④ dlopen（★两层栈：门面 + 宿主★；EGL/GLES 兼容底的旗标按后端定：见下；后端本体恒 RTLD_GLOBAL）----
    // ★KW 时用 RTLD_LOCAL★（真机 lastlog-84）：ANGLE 的 libGLESv2 若以 GLOBAL 加载，
    //   它导出的 GLES1 入口（glLoadMatrixf 等）会被 MC/LWJGL 的 dlsym(RTLD_DEFAULT) 抢先命中，
    //   从而绕过 KW 自带 FPE，直接崩在 ANGLE 的 GLES1State（未初始化）。⇒ 只让 KW 自己全局可见。
    // ★MG 时恒 RTLD_GLOBAL★：MG 那套 `egl*` 只是**门面**，它要落到 **宿主 EGL**（backend library）
    //   才真正工作；宿主 = ANGLE 的 libEGL/libGLESv2 ⇒ 两者都必须进 flat namespace，
    //   MG 才解析得到 `eglGetDisplay`/`eglGetProcAddress`。
    //   ★ANGLE 已由 ③0 先行加载★（`a2_gl_bridge_load_angle_first`）：这里复用句柄、不重复 dlopen
    //   （重复只多一份引用计数，teardown 还要多配平一次）。
    //   ★SYMBOL THEFT 不复发的条件★：ANGLE 必须**早于** MG 进全局表 ⇒ flat 里的 `gl*` 命中 ANGLE，
    //   而不是系统 GLES。反转回「MG 先」即复发 lastlog-105（本单的根因），③0 的顺序就是这条契约。
    // ★KW 沿用原来的模糊判定★（`strstr`）：`libnggl4es.dylib`（老的那支）与
    //   `libnggl4es_kw.dylib` 都按 KW 处理 —— 这是 lastlog-84 起的行为，不在本单里改口径。
    const BOOL a2BackendIsKW = (strstr(rendererName, "krypton") != NULL) || (strstr(rendererName, "nggl4es") != NULL);
    const BOOL a2DepFlagsLocal = a2BackendIsKW;   // ★只剩 KW 用 LOCAL★：MG 必须 GLOBAL（宿主 EGL 在 ANGLE 里）
    const int a2GlDepFlags = RTLD_LAZY | (a2DepFlagsLocal ? RTLD_LOCAL : RTLD_GLOBAL);
    a2_log_f(@"[A2-GLBRIDGE] 依赖加载旗标：%s（后端=%s）",
             a2DepFlagsLocal ? "RTLD_LOCAL" : "RTLD_GLOBAL", gBackendName);
    if (a2DepFlagsLocal) {
        a2_log_f(@"[A2-GLBRIDGE] 旗标理由：KW 要自己的 GLES1 入口生效 ⇒ 不让兼容底的 gl* 进 flat namespace（防符号被抢）");
    }

    if (anglePreloaded) {
        // ③0 已把 ANGLE 两份放进 flat namespace（同一对句柄、同一个产地）⇒ ④ 只确认、不再加载。
        a2_log_f(@"[A2-GLBRIDGE] ANGLE 宿主句柄复用 ③0 的加载（④ 不重复 dlopen）：libEGL=%p；libGLESv2=%p",
                 gEglHandle, gGlesHandle);
    } else {
        // ★EGL 那一份★：宿主 EGL 后端 = 主镜像（`dlopen(NULL)`，不能 dlclose）；
        //   其余（含 MG 门面）= ANGLE 的 libEGL。★MG 门面下这个句柄是「宿主」，不是门面★ ——
        //   门面句柄由 `a2_gl_bridge_egl_entry_handle()` 给（= MG 本体），两者不混用。
        gEglHandle      = hostEglBackend ? dlopen(NULL, RTLD_LAZY)
                                         : dlopen(eglPath.UTF8String, a2GlDepFlags);
        if (gEglHandle == NULL) {
            const char *err = dlerror();
            a2_log_f(@"[A2-GLBRIDGE] ★阻断★：EGL 兼容底 dlopen 失败 %s（%s）",
                     hostEglBackend ? "(main image)" : eglPath.UTF8String, err ? err : "(dlerror 无输出)");
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
    }
    // 后端本体（GL 层 = MG / compat 底 / KW …）：RTLD_GLOBAL 让 MC 后续能直接解析到它的 GL 符号。
    // ★MG 已在 ③0 加载过★（顺序必须是 ANGLE 之后），这里由 a2_gl_bridge_open_renderer 幂等返回成功。
    if (!a2_gl_bridge_open_renderer(rendererPath.UTF8String)) {
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    // ---- ④b ★MG 引导符号 `mg_init_gles`★（MG 加载之后一次；真正调用在上下文生效之后）----
    //   两处 dlopen 都走完了才取：③0 先加载 MG（非宿主 EGL 后端），④ 再幂等补一次（宿主 EGL 后端）。
    //   ★只取符号，不在这里调★ —— 它内部做 caps 检测，必须等 `eglMakeCurrent` 成功（见 ⑥ / make_current）。
    if (a2BackendIsMG) {
        a2_gl_bridge_load_mg_init_symbol();
    }
    // ★两层判据行 / 兼容底判据行 都放在 ④a3·④a4 之后★：归属核对可能把门面从 MG 退回 ANGLE，
    //   这两行必须报**定稿后**的事实（否则会印「门面=MG」而实际建面用的是 ANGLE）。
    if (a2BackendIsMG && !hostEglBackend) {
        // ---- ④a2 ★dyld 动态 interpose：把 gl* 抢回 MG★（MG 后端专有）----
        //   真机 lastlog-11：flat 的 `glTexImage2D` 落在 **dyld 共享缓存**里的系统 OpenGLES 上，
        //   而共享缓存永远排在 dylib 之前 ⇒「ANGLE 先行」（③0）与「dlclose 系统 GLES」
        //   （① 的 reassert）都改不动它（两次实测无效）。这里换成 dyld 的 interpose 改绑定：
        //   `gl*` 改指 MG 自己的导出 ⇒ MG 不再是「符号被偷」的那一方。
        //   ★装不上 / 装了没翻转都不阻断★：④a3 仍是唯一否决点，④a4 照旧「退回 ANGLE 建面」。
        a2_gl_bridge_interpose_gl_to_mg();

        // ---- ④a3 ★归属核对（dladdr）★（MG 后端专有）----
        //   取代旧的「后端导出指针 == flat 指针」比法：那个比法只能回答「同不同源」，
        //   而且在 ANGLE 先加载后必然报「被抢走」（false alarm）—— 它答不了「归哪个镜像」。
        //   两行固定格式（真机 grep `归属核对` 即可判读），不通过则重试一次（见函数内注释）。
        int angleOwnershipOK = a2_gl_bridge_verify_angle_ownership(eglPath, glesPath);

        // ---- ④a4 ★MG 门面不可用 ⇒ 退回 ANGLE 建面★（判据：④a3 的归属结论）----
        //   真机 iOS 16.7：`glTexImage2D flat=… 归属=系统GLES（MG=…）` ⇒ MG 自报
        //   `EGL entry point eglGetDisplay is not available in the backend library`，
        //   而本桥若继续在 MG 门面上建面 ⇒ 空指针 ⇒ SIGSEGV（`a2_gl_bridge_attach`）。
        //   归属不对时 MG 的 `egl*` 必然失败 ⇒ ★不再走 MG 门面★，EGL 入口改从 ANGLE 解析
        //   （ANGLE 本就在 ③0 以 RTLD_GLOBAL 加载、且是宿主）—— 至少能出预览帧、不崩。
        //   ★只换门面来源★：后端名 / 加载顺序 / 依赖旗标一律不动（不假装换了渲染器）。
        if (!angleOwnershipOK) {
            gEglSource = A2GlBridgeEglSourceAngle;
            eglFromMG = NO;
            a2_log_criterion(@"[A2-GLBRIDGE] ★退回 ANGLE 建面★ MG 门面归属不对 ⇒ EGL 入口改从 %s 解析"
                             @"（MG 本体仍已 RTLD_GLOBAL 加载；后端名不变=%s）",
                             eglPath.UTF8String, gBackendName);
        }
        // ★两层判据行★（MG 后端专有）：门面句柄与 ANGLE 宿主句柄都已落地、归属结论已定稿，
        //   一行答完「谁当门面、谁当宿主」。
        a2_gl_bridge_log_egl_layers();
    }
    a2_log_f(@"[A2-GLBRIDGE] 已加载兼容底：EGL 门面=%s handle=%p；EGL 宿主=%s handle=%p；"
             @"GLESv2=%s handle=%p；后端(GL 层)=%s handle=%p",
             eglFromMG ? "MG 自带 egl*" : (hostEglBackend ? "主镜像假 EGL" : "ANGLE"),
             a2_gl_bridge_egl_entry_handle(),
             hostEglBackend ? "本二进制（假 EGL 自带宿主）" : "ANGLE libEGL",
             gEglHandle,
             glesPath.UTF8String, gGlesHandle,
             glLayerName, gRendererHandle);

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
    // ★来源由 `a2_gl_bridge_egl_source()` 唯一决定★（MG 自带 ⇒ MG 句柄；否则 ⇒ ANGLE / 假 EGL 句柄）：
    //   句柄只从 `a2_gl_bridge_egl_entry_handle()` 取一份，下面所有 `egl*` 都从它解析，不各写判断。
    void *eglEntryHandle = a2_gl_bridge_egl_entry_handle();
    int missing = 0;
    gEglGetDisplay          = (A2PFN_eglGetDisplay)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglGetDisplay", &missing);
    gEglInitialize          = (A2PFN_eglInitialize)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglInitialize", &missing);
    gEglChooseConfig        = (A2PFN_eglChooseConfig)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglChooseConfig", &missing);
    gEglCreateContext       = (A2PFN_eglCreateContext)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglCreateContext", &missing);
    gEglCreateWindowSurface = (A2PFN_eglCreateWindowSurface)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglCreateWindowSurface", &missing);
    gEglMakeCurrent         = (A2PFN_eglMakeCurrent)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglMakeCurrent", &missing);
    gEglGetError            = (A2PFN_eglGetError)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglGetError", &missing);
    // ★eglSwapBuffers 也进必需集★：它就是「上屏/换页」本身，缺了这份表就不完整
    //   （`a2_gl_bridge_egl_entry_missing()` 的判据集与这里必须逐字一致）。
    gEglSwapBuffers         = (A2PFN_eglSwapBuffers)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglSwapBuffers", &missing);
    if (missing) {
        // ★attach 中止（保命）★：必需入口缺一 ⇒ 不打空指针、不再往下建面。
        //   点名用 `a2_gl_bridge_egl_entry_missing()`（唯一判据），与上面逐符号的阻断行互补：
        //   逐符号那行说「缺谁」，这行说「因此中止」，便于真机 grep 一条即定位。
        const char *lostEntry = a2_gl_bridge_egl_entry_missing();
        a2_log_f(@"[A2-GLBRIDGE] ★attach 中止★ 缺 egl 入口：%s（函数指针表不全 ⇒ 不继续解引用）",
                 (lostEntry != NULL) ? lostEntry : "未知");
        a2_gl_bridge_teardown();
        return A2GlBridgeErrLoadFailed;
    }
    // 可选符号（缺了只影响能力，不影响建面主路径）：各自失败即静默留空，不打"阻断"。
    // `eglGetConfigAttrib` 只用来把「选定配置的位深」打进判据行（⑥ 之后），缺了不影响建面 ⇒ 同样宽容。
    gEglGetConfigAttrib   = (A2PFN_eglGetConfigAttrib)a2_gl_bridge_egl_symbol(eglEntryHandle, "eglGetConfigAttrib", NULL);
    gEglBindAPI           = (A2PFN_eglBindAPI)dlsym(eglEntryHandle, "eglBindAPI");
    // ★eglSwapBuffers 不在这里★：它已进必需集（见上），重复解析只会把同一份结论写第二遍。
    gEglGetProcAddress    = (A2PFN_eglGetProcAddress)dlsym(eglEntryHandle, "eglGetProcAddress");
    gEglDestroySurface    = (A2PFN_eglDestroySurface)dlsym(eglEntryHandle, "eglDestroySurface");
    gEglDestroyContext    = (A2PFN_eglDestroyContext)dlsym(eglEntryHandle, "eglDestroyContext");
    gEglTerminate         = (A2PFN_eglTerminate)dlsym(eglEntryHandle, "eglTerminate");
    gEglQuerySurface      = (A2PFN_eglQuerySurface)dlsym(eglEntryHandle, "eglQuerySurface");

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
        // ★判据：选定配置的 Alpha/Depth 位深★ —— 证明建面用的确实是「请求的那份配置」，
        //   也是「EGL 表到底从哪个镜像取的」这条结论的旁证（MG 自带 EGL 时同样出这一行）。
        if (gEglGetConfigAttrib != NULL) {
            A2EGLint alphaBits = -1, depthBits = -1;
            gEglGetConfigAttrib(gDpy, gCfg, A2_EGL_ALPHA_SIZE, &alphaBits);
            gEglGetConfigAttrib(gDpy, gCfg, A2_EGL_DEPTH_SIZE, &depthBits);
            a2_log_criterion(@"[A2-GLBRIDGE] 选定 EGL config：alpha=%d depth=%d（请求 8/24）",
                             (int)alphaBits, (int)depthBits);
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
        // ★宿主 EGL 后端只认 ES3★：假 EGL 的 `eglCreateContext` 明确拒绝 version≠3
        //   （不做 ES2 降级，见 a2_eagl_egl.m）；它的 EAGLContext 也只按 ES3 建。
        const A2EGLint wantVersion = isKrypton ? (kwMode == 1 ? 1 : (kwMode == 2 ? 2 : 3))
                                               : (hostEglBackend ? 3 : 2);
        A2EGLint gotVersion = wantVersion;   // ★实际拿到的版本★（回退时为 fbVersion，日志按它记，不假装）
        const A2EGLint ctxAttribs[] = { A2_EGL_CONTEXT_CLIENT_VERSION, wantVersion, A2_EGL_NONE };
        gCtx = gEglCreateContext(gDpy, gCfg, A2_EGL_NO_CONTEXT, ctxAttribs);
        if (isKrypton && gCtx == A2_EGL_NO_CONTEXT && wantVersion != 2) {
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
        // ★宿主 EGL 后端★：native window 必须是 `A2FakeEglWindowSize{宽, 高, 图层}` ——
        //   假 EGL 据此把 CAEAGLLayer 当 drawable（上屏）；普通后端仍就传图层指针。
        //   ★box 是栈变量★，eglCreateWindowSurface 内部会同步读走（不存指针）。
        A2FakeEglWindowSize hostWinBox = { 0, 0, NULL };
        A2FakeEglWindowSize *hostWinBoxPtr = NULL;
        if (hostEglBackend) {
            hostWinBox.width  = (A2EGLint)drawableW;
            hostWinBox.height = (A2EGLint)drawableH;
            hostWinBox.layer  = renderable;
            hostWinBoxPtr = &hostWinBox;
        }
        // 先带尺寸建；若实现不接受 EGL_WIDTH/HEIGHT（非核心 EGL 属性）再退到无属性。
        const A2EGLint surfAttribs[] = {
            A2_EGL_WIDTH,  (A2EGLint)drawableW,
            A2_EGL_HEIGHT, (A2EGLint)drawableH,
            A2_EGL_NONE
        };
        // 真 EGL（ANGLE）只认 CAMetalLayer；假 EGL 走自己的 A2FakeEglWindowSize 契约，不改。
        void *eglRenderable = hostEglBackend ? renderable : a2_gl_bridge_metal_layer_for(renderable);
        gSurf = gEglCreateWindowSurface(gDpy, gCfg,
                                        a2_gl_bridge_window_arg(hostWinBoxPtr, eglRenderable), surfAttribs);
        if (gSurf == A2_EGL_NO_SURFACE) {
            A2EGLint e1 = gEglGetError ? gEglGetError() : 0;
            a2_log_f(@"[A2-GLBRIDGE] EGL 建面：带尺寸(%dx%d 像素)失败 eglError=0x%x ⇒ 退到无属性重试",
                     drawableW, drawableH, (unsigned)e1);
            gSurf = gEglCreateWindowSurface(gDpy, gCfg,
                                            a2_gl_bridge_window_arg(hostWinBoxPtr, eglRenderable), NULL);
        }
        if (gSurf == A2_EGL_NO_SURFACE) {
            a2_log_f(@"%s ★阻断★：EGL 建面失败：eglCreateWindowSurface 返回 NO_SURFACE（eglError=0x%x；句柄=%p 像素格式=%d）",
                     A2GlBridgeJudgementTag, (unsigned)(gEglGetError ? gEglGetError() : 0),
                     renderable, host->surface.pixelFormat);
            a2_gl_bridge_teardown();
            return A2GlBridgeErrEgl;
        }
        // ★2026-10-31 黑屏诊断（6616cae 真机：swap 已提交但屏幕全黑）★
        //   记录「交给 eglCreateWindowSurface 的到底是什么」：
        //   hostEglBackend=1 ⇒ A2FakeEglWindowSize{宽,高,图层}（假 EGL 契约）；
        //   hostEglBackend=0 ⇒ 图层/视图指针本身（真 EGL，如 ANGLE 方案 A）。
        {
            const char *cls = "(null)";
            if (renderable != NULL) {
                @try {
                    id obj = (__bridge id)renderable;
                    cls = NSStringFromClass([obj class]).UTF8String;
                } @catch (__unused NSException *e) {
                    cls = "(not-an-objc-object)";
                }
            }
            a2_log_f(@"[A2-GLBRIDGE] EGL 建面成功：surface=%p hostEglBackend=%d renderable=%p class=%s drawable=%dx%d 像素",
                     (void *)gSurf, hostEglBackend ? 1 : 0, eglRenderable, cls, drawableW, drawableH);
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

    // ---- ⑥c ★MG 引导★：`eglMakeCurrent` 成功 ⇒ 真实上下文已在场 ⇒ 调一次 `mg_init_gles` ----
    //   老 Air 同款（`gl_bridge.m:1534`：在 gl_make_current 里、makeCurrent 之后）；幂等、不阻断。
    //   ★为什么必须在这里★：`mg_init_gles` 内部做 caps 检测，没有当前上下文时拿到的 caps 是空的
    //   ⇒ 真机 lastlog-108 的表现就是 LWJGL `GL.createCapabilities` 卡死（日志停在 `Backend library:`）。
    a2_gl_bridge_mg_init_gles_if_needed("attach ⑥ eglMakeCurrent 成功");

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

    // ---- ⑦ 取 GL 函数指针（glClear 必需；★先门面、后宿主★，见 a2_gl_bridge_gl_symbol）----
    void *pClear      = a2_gl_bridge_gl_symbol("glClear");
    void *pClearColor = a2_gl_bridge_gl_symbol("glClearColor");
    void *pGetError   = a2_gl_bridge_gl_symbol("glGetError");

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
    void *pViewport  = a2_gl_bridge_gl_symbol("glViewport");
    void *pScissor   = a2_gl_bridge_gl_symbol("glScissor");
    void *pEnable    = a2_gl_bridge_gl_symbol("glEnable");
    void *pDisable   = a2_gl_bridge_gl_symbol("glDisable");
    void *pGetInt    = a2_gl_bridge_gl_symbol("glGetIntegerv");
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

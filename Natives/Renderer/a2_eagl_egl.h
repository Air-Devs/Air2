// ============================================================================
//  Natives/Renderer/a2_eagl_egl.h
//  Air2 —— ★假 EGL 层★：一套最小 EGL 1.4 函数面，底层落到 EAGLContext + renderbuffer
// ----------------------------------------------------------------------------
//  分层：Natives/Renderer（docs/ARCHITECTURE.md §Natives：Renderer/ = 「EGL/GL 桥、
//        surface 生命周期」）。方案出处：docs/EAGL-ADAPTER-PLAN.md §2 / §P1。
//
//  ★为什么需要它★
//    1.17+ 的渲染器（MobileGlues 等）只认 EGL，不认 EAGL；而 iOS 上根本没有 EGL 实现。
//    本层就是用「EGL 的语法」说「EAGL 的话」：
//      · display  → 常量句柄（本层单例），`eglInitialize` 只校验版本并置位；
//      · config   → 只有 1 个，能力固定：RGBA8 / D24S8 / ES3（不模拟多样 config）；
//      · context  → `EAGLContext(kEAGLRenderingAPIOpenGLES3)` + `setCurrentContext:`；
//      · surface  → ★内部 renderbuffer + FBO★（不需要屏幕，离屏就能跑）；
//      · 函数入口 → `eglGetProcAddress`：先查本模块导出表，再 dlsym(RTLD_DEFAULT)；
//      · 错误     → 规范语义（`eglGetError` 读后清零；不支持就报明确错误码，不静默降级）。
//
//  ★调用点★
//    · `a2_eagl_egl_selftest()` —— 设置页「假 EGL 自检」一行
//      （Air2/UI/Screens/Settings/A2DiagnosticsSettings.m）点击即调；这是 P1 的判据入口
//      （离屏编译着色器 + 画一帧 + glReadPixels 取中心像素）。
//    · `a2_eagl_egl_engage()` —— 由自检先调（自检即接管）；P2 的宿主选择在确认要把渲染器
//      的 EGL 调用路由到本层时调。★接管之前本层对外的 egl* 一律「转给进程里真正的 EGL」★。
//
//  ★未接管时为什么要让路（本层唯一碰 flat namespace 的地方）★
//    本模块把 `eglXxx` 这些**EGL 规范名**定义进了主二进制。主二进制在 dyld 的 flat lookup
//    里排在所有 dylib 之前 ⇒ 任何 dylib 用 `dlsym(RTLD_DEFAULT, "eglXxx")` 探测都会先命中
//    本层。P1 还没接管渲染器时（宿主仍是 ANGLE），这种命中必须**无感**：
//      每个入口先看「是否已接管」；未接管 ⇒ `dlsym(RTLD_NEXT, …)` 把调用还给真正的 EGL；
//      真正的 EGL 不存在 ⇒ 返回该调用的「不可用」结果（EGL_NO_DISPLAY / EGL_FALSE …），
//      与「进程里没有 EGL」完全一致。★否则本层就会静悄悄改掉现有 ANGLE 路径的行为★。
//
//  ★明确不做（与计划 §2.2 一致）★
//    · 不做多重采样 / 交换间隔扩展的假实现：SURFACE 请求 SAMPLES>0 直接「没有匹配 config」；
//    · 不模拟多个 config / 多个 window surface 的差异：只有 1 个 config，能力固定；
//    · 不做 ES2 降级：RENDERABLE_TYPE 不含 ES 位 ⇒ 显式 0 个 config（不静默降级）；
//    · 不做 CAEAGLLayer 呈现：P1 只要离屏 ⇒ `eglSwapBuffers` = `glFlush` + 帧计数。
//
//  ★类型与常量的来历★
//    iOS SDK 没有 EGL 头（`<EGL/egl.h>` 不存在），所以类型/常量在这里按 **EGL 1.4 规范**
//    原样声明，数值与规范一致（不发明自己的编号）。若某天进程里真的出现了 EGL 头
//    （`__egl_h_` / `EGL_VERSION_1_4`），下面的声明整体让路，避免重复 typedef。
// ============================================================================
#ifndef A2_EAGL_EGL_H
#define A2_EAGL_EGL_H

#include <stdint.h>

#if !defined(__egl_h_) && !defined(EGL_VERSION_1_4) && !defined(A2_FAKEEGL_TYPES_DEFINED)
#define A2_FAKEEGL_TYPES_DEFINED 1

// ---------------------------------------------------------------------------
// 基础类型（EGL 1.4 §2.1；指针型句柄在本层都是「不透明句柄」）
// ---------------------------------------------------------------------------
typedef unsigned int   EGLBoolean;
typedef unsigned int   EGLenum;
typedef int32_t        EGLint;
typedef void *         EGLDisplay;
typedef void *         EGLConfig;
typedef void *         EGLSurface;
typedef void *         EGLContext;
typedef void *         EGLClientBuffer;
typedef void *         EGLNativeDisplayType;
typedef void *         EGLNativePixmapType;
typedef void *         EGLNativeWindowType;
typedef void (*         __eglMustCastToProperFunctionPointerType)(void);

// ---------------------------------------------------------------------------
// 布尔 / 空句柄
// ---------------------------------------------------------------------------
#define EGL_FALSE                       0
#define EGL_TRUE                        1
#define EGL_NO_DISPLAY                  ((EGLDisplay)0)
#define EGL_NO_CONTEXT                  ((EGLContext)0)
#define EGL_NO_SURFACE                  ((EGLSurface)0)
#define EGL_DEFAULT_DISPLAY             ((EGLNativeDisplayType)0)
#define EGL_DONT_CARE                   ((EGLint)-1)

// ---------------------------------------------------------------------------
// 错误码（EGL 1.4 §2.2.2）—— `eglGetError` 返回，读后清零
// ---------------------------------------------------------------------------
#define EGL_SUCCESS                     0x3000
#define EGL_NOT_INITIALIZED             0x3001
#define EGL_BAD_ACCESS                  0x3002
#define EGL_BAD_ALLOC                   0x3003
#define EGL_BAD_ATTRIBUTE               0x3004
#define EGL_BAD_CONFIG                  0x3005
#define EGL_BAD_CONTEXT                 0x3006
#define EGL_BAD_CURRENT_SURFACE         0x3007
#define EGL_BAD_DISPLAY                 0x3008
#define EGL_BAD_MATCH                   0x3009
#define EGL_BAD_NATIVE_PIXMAP           0x300A
#define EGL_BAD_NATIVE_WINDOW           0x300B
#define EGL_BAD_PARAMETER               0x300C
#define EGL_BAD_SURFACE                 0x300D
#define EGL_CONTEXT_LOST                0x300E

// ---------------------------------------------------------------------------
// 配置属性（EGL 1.4 §3.4）
// ---------------------------------------------------------------------------
#define EGL_BUFFER_SIZE                 0x3020
#define EGL_ALPHA_SIZE                  0x3021
#define EGL_BLUE_SIZE                   0x3022
#define EGL_GREEN_SIZE                  0x3023
#define EGL_RED_SIZE                    0x3024
#define EGL_DEPTH_SIZE                  0x3025
#define EGL_STENCIL_SIZE                0x3026
#define EGL_CONFIG_CAVEAT               0x3027
#define EGL_CONFIG_ID                   0x3028
#define EGL_LEVEL                       0x3029
#define EGL_MAX_PBUFFER_HEIGHT          0x302A
#define EGL_MAX_PBUFFER_PIXELS          0x302B
#define EGL_MAX_PBUFFER_WIDTH           0x302C
#define EGL_NATIVE_RENDERABLE           0x302D
#define EGL_NATIVE_VISUAL_ID            0x302E
#define EGL_NATIVE_VISUAL_TYPE          0x302F
#define EGL_PRESERVED_RESOURCES         0x3030
#define EGL_SAMPLES                     0x3031
#define EGL_SAMPLE_BUFFERS              0x3032
#define EGL_SURFACE_TYPE                0x3033
#define EGL_TRANSPARENT_TYPE            0x3034
#define EGL_TRANSPARENT_BLUE_VALUE      0x3035
#define EGL_TRANSPARENT_GREEN_VALUE     0x3036
#define EGL_TRANSPARENT_RED_VALUE       0x3037
#define EGL_NONE                        0x3038
#define EGL_BIND_TO_TEXTURE_RGB         0x3039
#define EGL_BIND_TO_TEXTURE_RGBA        0x303A
#define EGL_MIN_SWAP_INTERVAL           0x303B
#define EGL_MAX_SWAP_INTERVAL           0x303C
#define EGL_LUMINANCE_SIZE              0x303D
#define EGL_ALPHA_MASK_SIZE             0x303E
#define EGL_COLOR_BUFFER_TYPE           0x303F
#define EGL_RENDERABLE_TYPE             0x3040
#define EGL_MATCH_NATIVE_PIXMAP         0x3041
#define EGL_CONFORMANT                  0x3042

// surface_type / renderable_type 的位
#define EGL_PBUFFER_BIT                 0x0001
#define EGL_PIXMAP_BIT                  0x0002
#define EGL_WINDOW_BIT                  0x0004
#define EGL_OPENGL_ES_BIT               0x0001
#define EGL_OPENGL_ES2_BIT              0x0004
#define EGL_OPENGL_ES3_BIT              0x0040
#define EGL_OPENGL_ES3_BIT_KHR          EGL_OPENGL_ES3_BIT

// 没有多重采样的那个 config 一定给出的取值
#define EGL_MULTISAMPLE_RESOLVE_DEFAULT 0x309A
#define EGL_RGB_BUFFER                  0x308E
#define EGL_LUMINANCE_BUFFER            0x308F

// ---------------------------------------------------------------------------
// 上下文属性 / 查询目标
// ---------------------------------------------------------------------------
#define EGL_CONTEXT_CLIENT_VERSION      0x3098
#define EGL_CONTEXT_MAJOR_VERSION       0x3098
#define EGL_CONTEXT_MINOR_VERSION       0x30FB
#define EGL_CONTEXT_OPENGL_DEBUG        0x31B0
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD

#define EGL_VENDOR                      0x3053
#define EGL_VERSION                     0x3054
#define EGL_EXTENSIONS                  0x3055
#define EGL_HEIGHT                      0x3056
#define EGL_WIDTH                       0x3057
#define EGL_LARGEST_PBUFFER             0x3058
#define EGL_DRAW                        0x3059
#define EGL_READ                        0x305A
#define EGL_CORE_NATIVE_ENGINE          0x305B
#define EGL_TEXTURE_FORMAT              0x3080
#define EGL_TEXTURE_TARGET              0x3081
#define EGL_MIPMAP_TEXTURE              0x3082
#define EGL_MIPMAP_LEVEL                0x3083
#define EGL_BACK_BUFFER                 0x3084
#define EGL_SINGLE_BUFFER               0x3085
#define EGL_RENDER_BUFFER               0x3086
#define EGL_COLORSPACE                  0x3087
#define EGL_ALPHA_FORMAT                0x3088
#define EGL_NO_TEXTURE                  0x305C
#define EGL_TEXTURE                     0x305F
#define EGL_SWAP_BEHAVIOR               0x3093
#define EGL_MULTISAMPLE_RESOLVE         0x3099
#define EGL_BUFFER_PRESERVED            0x3094
#define EGL_BUFFER_DESTROYED            0x3095
#define EGL_CLIENT_APIS                 0x308D

// ---------------------------------------------------------------------------
// 客户端 API（eglBindAPI / eglQueryAPI）
// ---------------------------------------------------------------------------
#define EGL_OPENGL_ES_API               0x30A0
#define EGL_OPENVG_API                  0x30A1
#define EGL_OPENGL_API                  0x30A2

#endif /* 类型与常量守卫 */

#ifdef __cplusplus
extern "C" {
#endif

// ===========================================================================
//  本层自定义：原生窗口句柄的尺寸契约
// ---------------------------------------------------------------------------
//  EGL 的 window surface 尺寸来自**真实原生窗口**；本层没有窗口（离屏即可），
//  所以约定的 native window 就是一个「宽高像素」结构体指针：
//      A2FakeEglWindowSize size = { 1280, 720 };
//      eglCreateWindowSurface(dpy, cfg, &size, NULL);
//  传 NULL ⇒ EGL_BAD_NATIVE_WINDOW（本层不猜尺寸、不给默认值）。
//  宽高必须 > 0 且 ≤ EGL_MAX_PBUFFER_DIM（16384，系统 GLES3 的 renderbuffer 上限）。
// ===========================================================================
typedef struct {
    EGLint width;
    EGLint height;
} A2FakeEglWindowSize;

#define A2_FAKEEGL_MAX_SURFACE_DIM      16384

// ===========================================================================
//  接管开关
// ---------------------------------------------------------------------------

/// 让本层**接管**进程里的 EGL 名字（此后 eglXxx 走本层实现，不再让路给真 EGL）。
/// 幂等。调用点：`a2_eagl_egl_selftest()` 开头（自检即接管）、P2 的宿主选择。
void a2_eagl_egl_engage(void);

/// 是否已接管（供宿主/日志判断；未接管时本层对 egl* 一律让路）。
EGLBoolean a2_eagl_egl_is_engaged(void);

// ===========================================================================
//  EGL 1.4 子集（名字与规范一致：dlopen/dlsym、渲染器可直接用）
// ===========================================================================

EGLDisplay  eglGetDisplay(EGLNativeDisplayType display_id);
EGLBoolean  eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor);
EGLBoolean  eglTerminate(EGLDisplay dpy);
const char *eglQueryString(EGLDisplay dpy, EGLint name);

EGLBoolean  eglGetConfigs(EGLDisplay dpy, EGLConfig *configs, EGLint config_size, EGLint *num_config);
EGLBoolean  eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list, EGLConfig *configs,
                            EGLint config_size, EGLint *num_config);
EGLBoolean  eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value);

EGLSurface  eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config,
                                   EGLNativeWindowType win, const EGLint *attrib_list);
EGLSurface  eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint *attrib_list);
EGLBoolean  eglDestroySurface(EGLDisplay dpy, EGLSurface surface);
EGLBoolean  eglQuerySurface(EGLDisplay dpy, EGLSurface surface, EGLint attribute, EGLint *value);

EGLContext  eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context,
                             const EGLint *attrib_list);
EGLBoolean  eglDestroyContext(EGLDisplay dpy, EGLContext ctx);
EGLBoolean  eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx);

EGLContext  eglGetCurrentContext(void);
EGLSurface  eglGetCurrentSurface(EGLint readdraw);

EGLBoolean  eglSwapBuffers(EGLDisplay dpy, EGLSurface surface);
EGLBoolean  eglSwapInterval(EGLDisplay dpy, EGLint interval);

EGLint      eglGetError(void);
__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *procname);

EGLBoolean  eglBindAPI(EGLenum api);
EGLenum     eglQueryAPI(void);
EGLBoolean  eglReleaseThread(void);

// ===========================================================================
//  自检（P1 判据入口，离屏）
// ---------------------------------------------------------------------------
//  全流程：display → initialize → chooseConfig → createContext → (window|pbuffer)
//  surface → makeCurrent → 编译 ES3 三角形着色器 → 画一帧 → `glReadPixels` 取中心像素。
//  日志前缀 `[A2-EAGL]`；通过打 `[A2-EAGL] selftest PASS center=0x…`，
//  失败打**具体步骤**（哪一步、哪个 EGL 调用、错误码）。
//
//  @return 0 = 通过；负数 = 失败的步骤（-1 GLES 不可用 / -2 display / -3 initialize /
//          -4 chooseConfig / -5 createContext / -6 createWindowSurface / -7 pbuffer /
//          -8 makeCurrent / -9 着色器 / -10 draw / -11 readpixels 取值不符 /
//          -12 配置面自证（eglGetConfigs/eglGetConfigAttrib）/ -13 状态面自证
//          （current/API/swapInterval/eglGetProcAddress））。
//          ★失败绝不改全局行为：接管已发生，但"未接管"以外的语义不变★。
int a2_eagl_egl_selftest(void);

#ifdef __cplusplus
}
#endif

#endif /* A2_EAGL_EGL_H */

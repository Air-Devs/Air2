// ============================================================================
//  Natives/Renderer/a2_eagl_egl.m
//  Air2 —— ★假 EGL 层实现★：EGL 1.4 子集 → EAGLContext(ES3) + renderbuffer/FBO
// ----------------------------------------------------------------------------
//  对外契约（类型/常量/函数原型/接管开关/自检）见 a2_eagl_egl.h；本文件只实现。
//
//  ★这一层到底在做什么（一句话）★
//    「用 EGL 的语法说 EAGL 的话」：display/config 是常量单例，context 是
//    `EAGLContext(kEAGLRenderingAPIOpenGLES3)`，surface 是**本层自己建的 renderbuffer +
//    FBO**（离屏，不需要屏幕/图层），所有错误按 EGL 规范报，不静默降级。
//
//  ★为什么 GL 入口走 dlsym 而不是链接 OpenGLES.framework★
//    链接该系统框架会把 `gl*` 塞进**进程的 flat namespace**，任何渲染器（含 ANGLE 路径下的
//    MobileGlues）用 `dlsym(RTLD_DEFAULT, "glXxx")` 就会先命中系统 GLES，而不是它自己的解析器
//    —— 那等于悄悄改掉现有 ANGLE 路径的行为（本任务明令禁止）。所以：
//      · 本文件 **不 include 任何 OpenGLES 头**（连 <OpenGLES/EAGL.h> 都不 include，
//        因为它会经 implicit module maps 触发 `-framework OpenGLES` 自动链接）；
//      · `OpenGLES.framework/OpenGLES` 用 `dlopen(…, RTLD_LOCAL)` 取镜像句柄，
//        GL 入口一律 `dlsym(镜像句柄, …)`（★符号不外溢★）；
//      · ObjC 的 `EAGLContext` 用 `NSClassFromString` 取类 + 协议化的消息发送
//        （类注册与 dyld 符号可见性是两件事：RTLD_LOCAL 只挡符号，不挡 ObjC 类）。
//    注意：本文件里**没有** `EAGLContext` 这个标识符的硬引用（没有 `[EAGLContext …]`），
//    因此不会生成 `_OBJC_CLASS_$_EAGLContext` 未定义符号 ⇒ 不需要链接该框架。
//
//  ★surface 的 attach 是「懒惰」的（EGL 语义要求 surface 创建不依赖 current context）★
//    `eglCreateWindowSurface/eglCreatePbufferSurface` 只记尺寸；renderbuffer/FBO 在
//    `eglMakeCurrent` 时才在**传进来的 context** 里建（GL 对象属于 context，不属于进程）。
//    同一个 surface 被换到另一个 context 使用（EGL 允许、本层不推荐）⇒ 会重新建 FBO 并打一行警示。
//
//  ★判据（真机 grep）★
//    `[A2-FAKEEGL] eglInitialize …` / `eglChooseConfig renderable=ES3_BIT ok` /
//    `eglCreateContext version=3 ok` / `swap frame=<n> ms=<t>`
//    `[A2-EAGL] selftest PASS center=0x…`（失败则该行换成 `step=<名> rc=<码>`）
//
//  ★石山自检（每个新增符号的调用点）★
//    · `a2_eagl_egl_engage`      ← 本文件 `a2_eagl_egl_selftest()`；`a2_renderer_load_named()`（选到宿主 EGL 后端时）
//    · `a2_eagl_egl_is_engaged`  ← 同上（自检开头的幂等判断日志）+ `a2_gl_bridge_attach` 的 MG 判据行
//    · `a2_fe_engage_allowed`    ← `a2_fe_gles_open`（dlopen 闸门）/ `a2_fe_eagl_class`（类查询闸门）
//    · `a2_fe_eagl_class`        ← 上面六个 `egl*`/自检里原本直接 `NSClassFromString(@"EAGLContext")` 的地方
//    · `a2_eagl_egl_selftest`    ← Air2/UI/Screens/Settings/A2DiagnosticsSettings.m 的
//                                  「假 EGL 自检」行（onTap）
//    · 23 个 `egl*`              ← 自检全流程（每个都至少被调用一次）+ 渲染器/P2 直接使用
//    · 所有 `static` 辅助函数     ← 见各自定义处注释里写的调用者
// ============================================================================

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>     // objc_msgSend（取/设宿主图层的 bounds / contentsScale；不 import QuartzCore）
#import <string.h>
#import <stdlib.h>
#import <time.h>

#import "a2_eagl_egl.h"
#import "a2_log.h"          // Natives/Support —— [A2-EAGL] / [A2-FAKEEGL] 日志出口

// ===========================================================================
//  ObjC 侧对 `EAGLContext` 的最小接口（★不 import OpenGLES 头，故用协议描述★）
// ---------------------------------------------------------------------------
//  为什么用协议而不是 `@interface EAGLContext`：后者会在链接期要求
//  `_OBJC_CLASS_$_EAGLContext`（= 必须链接 OpenGLES.framework，见文件头的取舍）。
//  协议在运行期不做任何类型检查，消息发送仍落到真类上。
// ===========================================================================
@protocol A2EAGLContextFace <NSObject>
- (instancetype)initWithAPI:(NSUInteger)api;
- (instancetype)initWithAPI:(NSUInteger)api sharegroup:(id)sharegroup;
- (id)sharegroup;
/// ★上屏的两个入口（P2）★：颜色 renderbuffer 由 EAGL 按 drawable（CAEAGLLayer）建，
/// 交换 = `-presentRenderbuffer:`。★离屏面不调它们★，所以「离屏路径的语义」一字未变。
- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<NSObject>)drawable;
- (BOOL)presentRenderbuffer:(NSUInteger)target;
@end

/// `EAGLContext` 的**类方法**（`+setCurrentContext:` / `+currentContext`）。
/// ObjC 运行期不区分「发给类」还是「发给实例」，这里按实例方法声明，
/// 便于对 `Class`（本身就是 id 值）直接发消息；语义仍是类方法。
@protocol A2EAGLContextClassFace <NSObject>
- (BOOL)setCurrentContext:(id)context;
- (id)currentContext;
@end

/// `EAGLRenderingAPI` 里 ES3 的枚举值（EAGL.h：ES1=1 / ES2=2 / ES3=3）。
#define A2_EAGL_API_OPENGL_ES3  3

// ===========================================================================
//  最小 GL 类型/常量（本文件不 include GL 头，故按 Khronos 规范的数值声明）
// ===========================================================================
typedef unsigned int  A2GLenum;
typedef unsigned int  A2GLuint;
typedef int           A2GLint;
typedef int           A2GLsizei;
typedef unsigned char A2GLboolean;
typedef unsigned char A2GLubyte;
typedef float         A2GLfloat;
typedef char          A2GLchar;
typedef long          A2GLsizeiptr;

#define A2GL_NO_ERROR                  0
#define A2GL_FRAMEBUFFER               0x8D40
#define A2GL_RENDERBUFFER              0x8D41
#define A2GL_COLOR_ATTACHMENT0         0x8CE0
#define A2GL_DEPTH_ATTACHMENT          0x8D00
#define A2GL_STENCIL_ATTACHMENT        0x8D20
#define A2GL_FRAMEBUFFER_COMPLETE      0x8CD5
#define A2GL_RGBA8                     0x8058
#define A2GL_DEPTH24_STENCIL8          0x88F0
#define A2GL_COLOR_BUFFER_BIT          0x00004000
#define A2GL_DEPTH_BUFFER_BIT          0x00000100
#define A2GL_VERTEX_SHADER             0x8B31
#define A2GL_FRAGMENT_SHADER           0x8B30
#define A2GL_COMPILE_STATUS            0x8B81
#define A2GL_LINK_STATUS               0x8B82
#define A2GL_INFO_LOG_LENGTH           0x8B84
#define A2GL_ARRAY_BUFFER              0x8892
#define A2GL_STATIC_DRAW               0x88E4
#define A2GL_FLOAT                     0x1406
#define A2GL_TRIANGLES                 0x0004
#define A2GL_RGBA                      0x1908
#define A2GL_UNSIGNED_BYTE             0x1401
#define A2GL_VERSION                   0x1F02
#define A2GL_RENDERER                  0x1F01
// ★上屏（P2）用★：颜色 renderbuffer 由 `-renderbufferStorage:fromDrawable:` 建好之后，
// 它的真实尺寸只能从这两个 GL 查询里读（图层点数×scale 不一定等于实现回报）。
#define A2GL_RENDERBUFFER_WIDTH        0x8D42
#define A2GL_RENDERBUFFER_HEIGHT       0x8D43

// ===========================================================================
//  进程级状态
// ===========================================================================
static BOOL        gEngaged;                     ///< 是否已接管（见头文件「未接管」一节）
static BOOL        gIdleNoticeLogged;            ///< 「让路给真 EGL」只打一行，避免刷屏
static void       *gGlesImage;                   ///< dlopen(OpenGLES.framework/OpenGLES, RTLD_LOCAL)
static BOOL        gGlesOpenTried;               ///< dlopen 只尝试一次（失败也不反复试）
static EGLenum     gBoundAPI = EGL_OPENGL_ES_API;///< eglBindAPI 记住的客户端 API
static NSUInteger  gSwapCount;                   ///< eglSwapBuffers 总帧数（判据行用）
static int         gProcMissLogged;              ///< eglGetProcAddress 未命中日志条数上限

// ---------------------------------------------------------------------------
//  ★懒加载闸门（真机 iOS 16.7 的修因）★
// ---------------------------------------------------------------------------
//  只允许在 `a2_eagl_egl_engage()` 之后才碰 OpenGLES 镜像与 `EAGLContext` 类：
//    · `dlopen("…/OpenGLES.framework/OpenGLES")` 会把**系统 GLES 镜像**带进进程。MG（MobileGlues）
//      随后把「flat namespace 里抢到 `gl*` 的那个镜像」当成它的 backend library，而系统 GLES
//      没有 EGL ⇒ MG 自报 `EGL entry point eglGetDisplay is not available in the backend library`
//      并初始化失败（真机 lastlog：`glTexImage2D flat=… 归属=系统GLES（MG=…）`）；
//    · 未 engage 时本层对外的 `egl*` 一律**让路**给真 EGL（见头文件「未接管」一节）⇒ 本层一个
//      GL 入口都用不上，提前把镜像拉进来只有代价、没有任何收益。
//  调用点：`a2_fe_gles_open`（dlopen 闸门）与 `a2_fe_eagl_class`（类查询闸门）。
// ---------------------------------------------------------------------------
static BOOL a2_fe_engage_allowed(void) {
    return gEngaged;
}

/// 取 `EAGLContext` 类（★未 engage ⇒ Nil★，绝不因一次类查询把 OpenGLES 带进进程）。
/// 调用点：`a2_fe_gles_ready` / `eglTerminate` / `eglCreateContext` / `eglDestroyContext` /
///         `eglMakeCurrent` / `eglReleaseThread` / `a2_eagl_egl_selftest`。
static Class a2_fe_eagl_class(void) {
    if (!a2_fe_engage_allowed()) return Nil;
    return NSClassFromString(@"EAGLContext");   // ★全文件唯一一处★（其余入口一律走本函数）
}

static __thread EGLint tlsError = EGL_SUCCESS;   ///< EGL 错误是**每线程**的（规范 §2.2）
static __thread void  *tlsCurrentContext;        ///< 本线程 current context（raw：ARC 不允许
static __thread void  *tlsCurrentDraw;           ///<   在 __thread 里存 strong 引用；对象由
static __thread void  *tlsCurrentRead;           ///<   下面的注册表持有，这里只借指针）

// ===========================================================================
//  句柄对象
// ---------------------------------------------------------------------------
//  EGL 句柄对外是一串不透明指针；对内就是下面这几个对象。对象都由注册表持有
//  （ARC 强引用），句柄只是「借来的指针」⇒ 销毁即从注册表移除并清线程状态。
// ===========================================================================
@interface A2FakeEglDisplay : NSObject
@property (nonatomic, assign) BOOL initialized;
@end

@interface A2FakeEglConfig : NSObject
/// 取某个配置属性的值；不认识该属性 ⇒ 返回 EGL_FALSE（调用方报 EGL_BAD_ATTRIBUTE）。
- (BOOL)valueForAttribute:(EGLint)attribute out:(EGLint *)outValue;
@end

@interface A2FakeEglContext : NSObject
@property (nonatomic, strong) id eaglContext;     ///< 真实的 EAGLContext（协议化，见上）
@end

@interface A2FakeEglSurface : NSObject
@property (nonatomic, assign) EGLint width;
@property (nonatomic, assign) EGLint height;
@property (nonatomic, assign) BOOL pbuffer;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) void *ownerContext; ///< FBO 属于哪个 context（raw 指针比较）
@property (nonatomic, assign) A2GLuint framebuffer;
@property (nonatomic, assign) A2GLuint colorRenderbuffer;
@property (nonatomic, assign) A2GLuint depthStencilRenderbuffer;
@property (nonatomic, assign) EGLint swapInterval;
@property (nonatomic, assign) NSUInteger swapFrames;
@property (nonatomic, assign) double lastSwapMs;
/// ★上屏（P2）★：CAEAGLLayer（离屏面 = nil）。有它 ⇒ 颜色 renderbuffer 由 EAGL 按它建，
/// swap = presentRenderbuffer:；没有 ⇒ 离屏 FBO，swap 只 flush（P1 原行为）。
@property (nonatomic, strong) id drawableLayer;
/// 这块 CAEAGLLayer 是本层挂上去的（⇒ 销毁时摘掉；宿主自己的图层不摘）。
@property (nonatomic, assign) BOOL ownsDrawableLayer;
@end

/// 上屏面？（`layer` 给了且拿到了 drawable）—— 唯一的判据是 `drawableLayer != nil`。
static BOOL a2_fe_surface_is_onscreen(A2FakeEglSurface *s) {
    return s != nil && s.drawableLayer != nil;
}

static A2FakeEglDisplay *gDisplay;                ///< display 单例（eglGetDisplay 的返回值）
static A2FakeEglConfig  *gConfig;                 ///< 唯一 config（能力固定，见 -valueForAttribute:out:）
static NSMutableArray<A2FakeEglContext *> *gContexts;
static NSMutableArray<A2FakeEglSurface *> *gSurfaces;

// ---------------------------------------------------------------------------
// 注册表懒初始化 / 查找
// ---------------------------------------------------------------------------
static void a2_fe_ensure_state(void) {
    if (gDisplay == nil) gDisplay = [[A2FakeEglDisplay alloc] init];
    if (gConfig  == nil) gConfig  = [[A2FakeEglConfig alloc] init];
    if (gContexts == nil) gContexts = [NSMutableArray array];
    if (gSurfaces == nil) gSurfaces = [NSMutableArray array];
}

/// 按**指针身份**在注册表里找对象（★不对句柄发消息★：外来句柄可能是垃圾指针）。
static id a2_fe_lookup(NSArray *registry, void *handle) {
    if (handle == NULL) return nil;
    for (id obj in registry) {
        if ((__bridge void *)obj == handle) return obj;
    }
    return nil;
}

static void a2_fe_set_error(EGLint err) {
    // 规范：错误码「一旦置位就保持，直到 eglGetError 读走」⇒ 不覆盖已有错误。
    if (tlsError == EGL_SUCCESS) tlsError = err;
}

static BOOL a2_fe_display_ok(EGLDisplay dpy) {
    a2_fe_ensure_state();
    return dpy != EGL_NO_DISPLAY && (__bridge void *)gDisplay == (void *)dpy;
}

static A2FakeEglContext *a2_fe_context_of(EGLContext ctx) {
    return ctx == EGL_NO_CONTEXT ? nil : a2_fe_lookup(gContexts, (void *)ctx);
}

static A2FakeEglSurface *a2_fe_surface_of(EGLSurface surf) {
    return surf == EGL_NO_SURFACE ? nil : a2_fe_lookup(gSurfaces, (void *)surf);
}

// ===========================================================================
//  宿主图层的最小面（★不 import QuartzCore/UIKit★ —— 同 a2_gl_bridge.m 的取舍）
// ---------------------------------------------------------------------------
//  上屏只需要图层的五件事：bounds（点） / contentsScale（像素每点） / 设 frame /
//  挂子层 / 摘子层。CAEAGLLayer 本身是 CALayer 的子类 ⇒ 用 NSClassFromString 拿类 +
//  objc_msgSend 发消息，一个框架头都不引（否则本文件会把 QuartzCore 变成链接期依赖，
//  与文件头「不 import OpenGLES 头」同一条理由）。
//  ★CGRect 用同布局结构体传入传出★：arm64 上 CGFloat = double，四字段顺序固定
//  （与 a2_gl_bridge.m 的 A2GlBridgeRect 同一手法）。
// ===========================================================================
typedef struct { double x, y, width, height; } A2FeRect;

/// 取 bounds（取不到 / 宿主不是图层 ⇒ 全 0，不猜）。
static A2FeRect a2_fe_layer_bounds(id layer) {
    A2FeRect r = { 0.0, 0.0, 0.0, 0.0 };
    if (layer == nil) return r;
    SEL sel = NSSelectorFromString(@"bounds");
    if (![layer respondsToSelector:sel]) return r;
    return ((A2FeRect (*)(id, SEL))objc_msgSend)(layer, sel);
}

/// 取 contentsScale（取不到 ⇒ 0：调用方据此判「宿主没给像素口径」）。
static double a2_fe_layer_contents_scale(id layer) {
    if (layer == nil) return 0.0;
    SEL sel = NSSelectorFromString(@"contentsScale");
    if (![layer respondsToSelector:sel]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(layer, sel);
}

static void a2_fe_layer_set_frame(id layer, A2FeRect frame) {
    if (layer == nil) return;
    SEL sel = NSSelectorFromString(@"setFrame:");
    if (![layer respondsToSelector:sel]) return;
    ((void (*)(id, SEL, A2FeRect))objc_msgSend)(layer, sel, frame);
}

static void a2_fe_layer_set_contents_scale(id layer, double scale) {
    if (layer == nil || scale <= 0.0) return;
    SEL sel = NSSelectorFromString(@"setContentsScale:");
    if (![layer respondsToSelector:sel]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(layer, sel, scale);
}

static void a2_fe_layer_set_opaque(id layer, BOOL opaque) {
    if (layer == nil) return;
    SEL sel = NSSelectorFromString(@"setOpaque:");
    if (![layer respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, sel, opaque);
}

/// 把 sub 挂到 host 上（host 不是图层 / 不接受子层 ⇒ 静默不挂：调用方会发现「画不出」）。
static void a2_fe_layer_attach_sublayer(id host, id sub) {
    if (host == nil || sub == nil) return;
    SEL sel = NSSelectorFromString(@"addSublayer:");
    if (![host respondsToSelector:sel]) {
        a2_log_f(@"[A2-FAKEEGL] ★上屏不可用★：宿主对象不接受子层（不是 CALayer 形态）");
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(host, sel, sub);
}

static void a2_fe_layer_detach(id layer) {
    if (layer == nil) return;
    SEL sel = NSSelectorFromString(@"removeFromSuperlayer");
    if (![layer respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(layer, sel);
}

/// 上屏面的 drawable（★唯一产地★）：
///   · 宿主自己就是 CAEAGLLayer ⇒ 直接用它（生命周期归宿主，本层不摘）；
///   · 宿主是 CALayer/UIView ⇒ 新挂一块 CAEAGLLayer 上去（frame/contentsScale 抄宿主，
///     bounds 还没布局时按调用方给的像素尺寸反推），`*outOwned = YES` 由本层持有并销毁。
/// 返回 nil ⇒ 上屏做不到（没有 CAEAGLLayer 类 / 宿主不是图层）—— 调用方报 EGL_BAD_NATIVE_WINDOW。
static id a2_fe_drawable_layer_new(void *hostOrView, EGLint wantW, EGLint wantH, BOOL *outOwned) {
    if (outOwned != NULL) *outOwned = NO;
    if (hostOrView == NULL) return nil;
    id host = (__bridge id)hostOrView;

    // 宿主给的是视图 ⇒ 取其图层（与 a2_gl_bridge.m 的 a2_gl_bridge_renderable_handle 同口径）。
    SEL layerSel = NSSelectorFromString(@"layer");
    if ([host respondsToSelector:layerSel]) {
        id l = ((id (*)(id, SEL))objc_msgSend)(host, layerSel);
        if (l != nil) host = l;
    }

    Class layerClass = NSClassFromString(@"CAEAGLLayer");
    if (layerClass == Nil) {
        a2_log_f(@"[A2-FAKEEGL] ★上屏不可用★：进程里没有 CAEAGLLayer 类（OpenGLES.framework 未加载）");
        return nil;
    }
    double hostScale = a2_fe_layer_contents_scale(host);   // 0 = 宿主没给

    if ([host isKindOfClass:layerClass]) {
        // 宿主自己就是 CAEAGLLayer：只补 contentsScale（没给就 1.0 = 点当像素），不改它的 frame。
        if (hostScale <= 0.0) a2_fe_layer_set_contents_scale(host, 1.0);
        return host;
    }

    id drawable = ((id (*)(id, SEL))objc_msgSend)((id)layerClass, NSSelectorFromString(@"layer"));
    if (drawable == nil) {
        a2_log_f(@"[A2-FAKEEGL] ★上屏不可用★：CAEAGLLayer +layer 返回 nil");
        return nil;
    }
    double scale = (hostScale > 0.0) ? hostScale : 1.0;
    A2FeRect bounds = a2_fe_layer_bounds(host);
    if (bounds.width <= 0.0 || bounds.height <= 0.0) {
        // 宿主还没布局（bounds 全 0）：用调用方给的像素尺寸反推点尺寸（不猜 0 尺寸）。
        if (wantW > 0 && wantH > 0) {
            bounds.x = 0.0;
            bounds.y = 0.0;
            bounds.width  = (double)wantW / scale;
            bounds.height = (double)wantH / scale;
        }
    }
    a2_fe_layer_set_frame(drawable, bounds);
    a2_fe_layer_set_contents_scale(drawable, scale);
    a2_fe_layer_set_opaque(drawable, YES);
    a2_fe_layer_attach_sublayer(host, drawable);

    a2_log_f(@"[A2-FAKEEGL] 上屏 drawable 就绪：CAEAGLLayer 挂在宿主 %s 上，"
             @"frame=%.1fx%.1f 点 × scale=%.2f ⇒ %.0fx%.0f 像素",
             NSStringFromClass([host class]).UTF8String,
             bounds.width, bounds.height, scale,
             bounds.width * scale, bounds.height * scale);
    if (outOwned != NULL) *outOwned = YES;
    return drawable;
}

// ===========================================================================
//  GL 入口（全部经 OpenGLES 镜像句柄，★不进进程 flat namespace★）
// ===========================================================================
static BOOL a2_fe_gles_open(void) {
    // ★闸门★：未 engage ⇒ 绝不 dlopen 系统 OpenGLES（见 a2_fe_engage_allowed 的注释）。
    //   不置 gGlesOpenTried：engage 之后首次取 GL 入口时才真的加载。
    if (!a2_fe_engage_allowed()) return NO;
    if (gGlesOpenTried) return gGlesImage != NULL;
    gGlesOpenTried = YES;

    // RTLD_LOCAL：只让「本文件的 dlsym(句柄)」看见 gl*，不让整个进程看见。
    gGlesImage = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
                        RTLD_NOW | RTLD_LOCAL);
    if (gGlesImage == NULL) {
        a2_log_f(@"[A2-EAGL] OpenGLES 镜像 dlopen 失败：%s（退出 dlsym(RTLD_DEFAULT) 兜底）",
                 dlerror() ?: "unknown");
        return NO;
    }
    a2_log_f(@"[A2-EAGL] OpenGLES 镜像按需加载完成（engage 后首次取 GL 入口；未 engage 时本层从不加载它）");
    return YES;
}

/// 取 GL 入口：先镜像句柄（常态），再 RTLD_DEFAULT（框架已被别人加载时）。
static void *a2_fe_gl_symbol(const char *name) {
    a2_fe_gles_open();
    void *sym = (gGlesImage != NULL) ? dlsym(gGlesImage, name) : NULL;
    if (sym == NULL) sym = dlsym(RTLD_DEFAULT, name);
    return sym;
}

/// GL 入口调用简写：`A2_GL(void (*)(A2GLsizei, A2GLuint *), "glGenFramebuffers")(1, &fbo);`
#define A2_GL(type, name) ((type)a2_fe_gl_symbol(name))

/// GLES 是否可用（自检第一步的判据：镜像 + EAGLContext 类都得在）。
/// 抽 6 个「后面一定会用」的入口验证镜像真是 GLES —— 缺一个就把结论如实打出来，不硬撞。
static BOOL a2_fe_gles_ready(void) {
    if (a2_fe_eagl_class() == nil) {
        a2_log_f(@"[A2-EAGL] 缺 EAGLContext 类（OpenGLES.framework 未加载）");
        return NO;
    }
    static const char *const kProbe[] = {
        "glGetString", "glGenFramebuffers", "glCreateShader",
        "glDrawArrays", "glReadPixels", "glFlush",
    };
    for (size_t i = 0; i < sizeof(kProbe) / sizeof(kProbe[0]); i++) {
        if (a2_fe_gl_symbol(kProbe[i]) == NULL) {
            a2_log_f(@"[A2-EAGL] GL 入口缺失：%s", kProbe[i]);
            return NO;
        }
    }
    return YES;
}

// ===========================================================================
//  「未接管时让路」：本层唯一碰 flat namespace 的防护（详见头文件）
// ===========================================================================

/// 本模块自己导出的 EGL 名字表（eglGetProcAddress 的第一顺位，也是「让路」的自指识别表）。
typedef struct {
    const char *name;
    void       *fn;
} A2FakeEglEntry;

static const A2FakeEglEntry kFakeEglEntries[] = {
    { "eglGetDisplay",           (void *)eglGetDisplay },
    { "eglInitialize",           (void *)eglInitialize },
    { "eglTerminate",            (void *)eglTerminate },
    { "eglQueryString",          (void *)eglQueryString },
    { "eglGetConfigs",           (void *)eglGetConfigs },
    { "eglChooseConfig",         (void *)eglChooseConfig },
    { "eglGetConfigAttrib",      (void *)eglGetConfigAttrib },
    { "eglCreateWindowSurface",  (void *)eglCreateWindowSurface },
    { "eglCreatePbufferSurface", (void *)eglCreatePbufferSurface },
    { "eglDestroySurface",       (void *)eglDestroySurface },
    { "eglQuerySurface",         (void *)eglQuerySurface },
    { "eglCreateContext",        (void *)eglCreateContext },
    { "eglDestroyContext",       (void *)eglDestroyContext },
    { "eglMakeCurrent",          (void *)eglMakeCurrent },
    { "eglGetCurrentContext",    (void *)eglGetCurrentContext },
    { "eglGetCurrentSurface",    (void *)eglGetCurrentSurface },
    { "eglSwapBuffers",          (void *)eglSwapBuffers },
    { "eglSwapInterval",         (void *)eglSwapInterval },
    { "eglGetError",             (void *)eglGetError },
    { "eglGetProcAddress",       (void *)eglGetProcAddress },
    { "eglBindAPI",              (void *)eglBindAPI },
    { "eglQueryAPI",             (void *)eglQueryAPI },
    { "eglReleaseThread",        (void *)eglReleaseThread },
    { NULL, NULL },
};

static void *a2_fe_own_symbol(const char *name) {
    if (name == NULL) return NULL;
    for (int i = 0; kFakeEglEntries[i].name != NULL; i++) {
        if (strcmp(kFakeEglEntries[i].name, name) == 0) return kFakeEglEntries[i].fn;
    }
    return NULL;
}

/// 未接管时，把一次外部调用还给进程里**真正的** EGL。
/// 返回 NULL = 进程里根本没有别的 EGL ⇒ 调用方返回「该调用的不可用结果」。
/// ★自指防护★：若 RTLD_NEXT 解析回本模块自己（某些 dyld 情形），一律当作「没有」，
/// 否则会无限递归（栈爆）。
static void *a2_fe_unowned(const char *name) {
    void *real = dlsym(RTLD_NEXT, name);
    if (real != NULL && real == a2_fe_own_symbol(name)) real = NULL;
    if (real != NULL && !gIdleNoticeLogged) {
        gIdleNoticeLogged = YES;
        a2_log_f(@"[A2-FAKEEGL] 未接管：外部调用 %s 已让路给进程内真实 EGL", name);
    }
    return real;
}

/// 每个 `egl*` 入口的第一行：未接管 ⇒ 让路/返回「不可用」，接管 ⇒ 继续走本层。
#define A2_FE_IDLE_OR(fname, fnamestr, args, fallback)                            \
    do {                                                                          \
        if (!gEngaged) {                                                          \
            void *a2feReal_ = a2_fe_unowned(fnamestr);                            \
            return a2feReal_ ? ((__typeof__(&fname))a2feReal_) args : (fallback); \
        }                                                                         \
    } while (0)

// ===========================================================================
//  配置属性的唯一实现处（eglChooseConfig 的匹配 / eglGetConfigAttrib / attach /
//  eglQuerySurface 都读这里 ⇒ 只有一处「config 到底有哪些能力」）
// ===========================================================================
@implementation A2FakeEglConfig

- (BOOL)valueForAttribute:(EGLint)attribute out:(EGLint *)outValue {
    EGLint v;
    switch (attribute) {
        case EGL_BUFFER_SIZE:            v = 32; break;
        case EGL_ALPHA_SIZE:             v = 8;  break;
        case EGL_BLUE_SIZE:              v = 8;  break;
        case EGL_GREEN_SIZE:             v = 8;  break;
        case EGL_RED_SIZE:               v = 8;  break;
        case EGL_DEPTH_SIZE:             v = 24; break;
        case EGL_STENCIL_SIZE:           v = 8;  break;
        case EGL_CONFIG_CAVEAT:          v = EGL_NONE; break;
        case EGL_CONFIG_ID:              v = 1;  break;
        case EGL_LEVEL:                  v = 0;  break;
        case EGL_MAX_PBUFFER_HEIGHT:     v = A2_FAKEEGL_MAX_SURFACE_DIM; break;
        case EGL_MAX_PBUFFER_WIDTH:      v = A2_FAKEEGL_MAX_SURFACE_DIM; break;
        case EGL_MAX_PBUFFER_PIXELS:     v = A2_FAKEEGL_MAX_SURFACE_DIM * A2_FAKEEGL_MAX_SURFACE_DIM; break;
        case EGL_NATIVE_RENDERABLE:      v = EGL_TRUE; break;
        case EGL_NATIVE_VISUAL_ID:       v = 0;  break;
        case EGL_NATIVE_VISUAL_TYPE:     v = EGL_NONE; break;
        case EGL_PRESERVED_RESOURCES:    v = EGL_FALSE; break;
        case EGL_SAMPLES:                v = 0;  break;
        case EGL_SAMPLE_BUFFERS:         v = 0;  break;
        case EGL_SURFACE_TYPE:           v = EGL_WINDOW_BIT | EGL_PBUFFER_BIT; break;
        // RENDERABLE_TYPE 报 ES3；ES3 上下文天然能跑 ES2 着色器，故 **匹配**时额外认 ES/ES2 位
        // （见 a2_fe_config_matches），这里只如实报「本 config 的官方能力」。
        case EGL_RENDERABLE_TYPE:        v = EGL_OPENGL_ES3_BIT; break;
        case EGL_CONFORMANT:             v = EGL_OPENGL_ES3_BIT; break;
        case EGL_TRANSPARENT_TYPE:       v = EGL_NONE; break;
        case EGL_TRANSPARENT_RED_VALUE:  v = EGL_DONT_CARE; break;
        case EGL_TRANSPARENT_GREEN_VALUE: v = EGL_DONT_CARE; break;
        case EGL_TRANSPARENT_BLUE_VALUE: v = EGL_DONT_CARE; break;
        case EGL_BIND_TO_TEXTURE_RGB:    v = EGL_FALSE; break;
        case EGL_BIND_TO_TEXTURE_RGBA:   v = EGL_FALSE; break;
        case EGL_MIN_SWAP_INTERVAL:      v = 0;  break;
        case EGL_MAX_SWAP_INTERVAL:      v = 1;  break;
        case EGL_LUMINANCE_SIZE:         v = 0;  break;
        case EGL_ALPHA_MASK_SIZE:        v = 0;  break;
        case EGL_COLOR_BUFFER_TYPE:      v = EGL_RGB_BUFFER; break;
        default:
            return NO;
    }
    if (outValue != NULL) *outValue = v;
    return YES;
}

@end

@implementation A2FakeEglDisplay
@end

@implementation A2FakeEglContext
@end

@implementation A2FakeEglSurface
@end

// ===========================================================================
//  surface 的懒惰 attach（在 makeCurrent 时把 FBO/renderbuffer 建在当前 context 里）
// ===========================================================================
/// 删掉 surface 在**当前 current context** 里的 GL 对象（调用方必须保证 context 还是 current，
/// 否则 GL 删除调用落在别的上下文里 / 无上下文，只会静默失败或误删）。
/// 只碰 GL 对象，不动图层（上屏面的 drawable 归 surface 生命周期管，见 a2_fe_surface_detach）。
static void a2_fe_surface_release_gl(A2FakeEglSurface *s) {
    if (!s.attached) return;
    if (s.framebuffer != 0) {
        A2GLuint fbo = s.framebuffer;
        A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteFramebuffers")(1, &fbo);
        s.framebuffer = 0;
    }
    if (s.colorRenderbuffer != 0) {
        A2GLuint rb = s.colorRenderbuffer;
        A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteRenderbuffers")(1, &rb);
        s.colorRenderbuffer = 0;
    }
    if (s.depthStencilRenderbuffer != 0) {
        A2GLuint rb = s.depthStencilRenderbuffer;
        A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteRenderbuffers")(1, &rb);
        s.depthStencilRenderbuffer = 0;
    }
    s.attached = NO;
    s.ownerContext = NULL;
}

/// 只摘本层自己挂的 CAEAGLLayer（★不碰 GL 对象★）。用于「这张面已经不是 current」的销毁路径：
/// GL 对象随属主 context 一起消失，但图层必须当场摘掉，否则屏幕上会留一块死像素。
static void a2_fe_surface_release_owned_layer(A2FakeEglSurface *s) {
    if (s.ownsDrawableLayer) {
        a2_fe_layer_detach(s.drawableLayer);   // 宿主自己的图层不摘（所有权不在本层）
        a2_log_f(@"[A2-FAKEEGL] 上屏 drawable 已从宿主图层摘除");
    }
    s.drawableLayer = nil;
    s.ownsDrawableLayer = NO;
}

/// 彻底销毁一张面：先释放 GL 对象（须在当前 context 里调），再摘掉本层自己挂的 CAEAGLLayer。
static void a2_fe_surface_detach(A2FakeEglSurface *s) {
    a2_fe_surface_release_gl(s);
    a2_fe_surface_release_owned_layer(s);
}

/// ★上屏面的颜色附着★：由 `EAGLContext -renderbufferStorage:fromDrawable:` 按 CAEAGLLayer 建
/// （★这是唯一能把画面送上屏幕的建法★ —— 自己 `glRenderbufferStorage` 建的 renderbuffer
/// 没有可呈现的 backing）。建完立刻把**实现回报的** drawable 尺寸读回来写进 surface：
/// 图层的点数×scale 只是期望值，真实像素以 `GL_RENDERBUFFER_WIDTH/HEIGHT` 为准（不猜）。
/// 调用点：`a2_fe_surface_attach`（首次 attach 与尺寸变化后的重建都走它）。
static BOOL a2_fe_surface_color_from_drawable(A2FakeEglSurface *s, A2FakeEglContext *ctx,
                                              A2GLuint *outRenderbuffer) {
    if (outRenderbuffer == NULL) return NO;
    id eagl = ctx.eaglContext;
    if (eagl == nil) {
        a2_log_f(@"[A2-FAKEEGL] ★上屏失败★：context 没有 EAGLContext");
        return NO;
    }
    A2GLuint rb = 0;
    A2_GL(void (*)(A2GLsizei, A2GLuint *), "glGenRenderbuffers")(1, &rb);
    A2_GL(void (*)(A2GLenum, A2GLuint), "glBindRenderbuffer")(A2GL_RENDERBUFFER, rb);

    BOOL ok = [(id<A2EAGLContextFace>)eagl renderbufferStorage:A2GL_RENDERBUFFER
                                                   fromDrawable:(id<NSObject>)s.drawableLayer];
    if (!ok) {
        a2_log_f(@"[A2-FAKEEGL] ★上屏失败★：-renderbufferStorage:fromDrawable: 返回 NO"
                 @"（drawable=%p，期望 %dx%d）", (__bridge void *)s.drawableLayer, s.width, s.height);
        if (rb != 0) A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteRenderbuffers")(1, &rb);
        return NO;
    }

    A2GLint dw = 0, dh = 0;
    A2_GL(void (*)(A2GLenum, A2GLenum, A2GLint *), "glGetRenderbufferParameteriv")(
        A2GL_RENDERBUFFER, A2GL_RENDERBUFFER_WIDTH, &dw);
    A2_GL(void (*)(A2GLenum, A2GLenum, A2GLint *), "glGetRenderbufferParameteriv")(
        A2GL_RENDERBUFFER, A2GL_RENDERBUFFER_HEIGHT, &dh);
    if (dw > 0 && dh > 0) {
        s.width = dw;
        s.height = dh;
    } else {
        // 实现没回报尺寸（不该发生）：沿用期望值，并在日志里如实说明「这是期望不是实测」。
        a2_log_f(@"[A2-FAKEEGL] ⚠️ 上屏 drawable 尺寸查询为 0 ⇒ 沿用期望值 %dx%d（未实测）",
                 s.width, s.height);
    }
    *outRenderbuffer = rb;
    return YES;
}

/// 在 ctx 里把 surface 建好并绑成当前 framebuffer。调用方必须已把 ctx 设为 current。
/// ★两条路径只有「颜色附着由谁给」这一处分叉★：离屏 = `glRenderbufferStorage`（本层自建），
///   上屏 = `-renderbufferStorage:fromDrawable:`（EAGL 按 CAEAGLLayer 建，可 present）。
static BOOL a2_fe_surface_attach(A2FakeEglSurface *s, A2FakeEglContext *ctx) {
    const BOOL onscreen = a2_fe_surface_is_onscreen(s);
    if (s.attached && s.ownerContext == (__bridge void *)ctx) {
        // 已在本 context 里建过 ⇒ 只重新绑定（EGL 允许反复 makeCurrent）。
        A2_GL(void (*)(A2GLenum, A2GLuint), "glBindFramebuffer")(A2GL_FRAMEBUFFER, s.framebuffer);
        A2_GL(void (*)(A2GLint, A2GLint, A2GLsizei, A2GLsizei), "glViewport")(0, 0, s.width, s.height);
        return YES;
    }
    if (s.attached) {
        // 换 context 复用同一个 surface：GL 对象属于**旧** context，在新 context 里删不掉；
        // 直接丢弃句柄、由旧 context 释放，然后在新 context 里重建（打一行警示）。
        a2_log_f(@"[A2-FAKEEGL] surface 跨 context 复用 ⇒ 在旧 context 释放、新 context 重建（%dx%d）",
                 s.width, s.height);
        s.framebuffer = 0;
        s.colorRenderbuffer = 0;
        s.depthStencilRenderbuffer = 0;
        s.attached = NO;
        s.ownerContext = NULL;
    }

    A2GLuint fbo = 0, color = 0, depth = 0;
    A2_GL(void (*)(A2GLsizei, A2GLuint *), "glGenFramebuffers")(1, &fbo);
    A2_GL(void (*)(A2GLenum, A2GLuint), "glBindFramebuffer")(A2GL_FRAMEBUFFER, fbo);

    if (onscreen) {
        if (!a2_fe_surface_color_from_drawable(s, ctx, &color)) {
            if (fbo) A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteFramebuffers")(1, &fbo);
            return NO;
        }
    } else {
        A2_GL(void (*)(A2GLsizei, A2GLuint *), "glGenRenderbuffers")(1, &color);
        A2_GL(void (*)(A2GLenum, A2GLuint), "glBindRenderbuffer")(A2GL_RENDERBUFFER, color);
        A2_GL(void (*)(A2GLenum, A2GLenum, A2GLsizei, A2GLsizei), "glRenderbufferStorage")(
            A2GL_RENDERBUFFER, A2GL_RGBA8, s.width, s.height);
    }
    A2_GL(void (*)(A2GLenum, A2GLenum, A2GLenum, A2GLuint), "glFramebufferRenderbuffer")(
        A2GL_FRAMEBUFFER, A2GL_COLOR_ATTACHMENT0, A2GL_RENDERBUFFER, color);

    // 深度/模板：config 报的是 D24S8，一次打包成 GL_DEPTH24_STENCIL8 同时挂两个 attachment。
    // ★尺寸用 s.width/height★：上屏面此时已被 `-renderbufferStorage:fromDrawable:` 改成
    //   实现回报的真实像素（两者不一致会让深度面比颜色面小 → FBO 不完整）。
    A2GLint depthBits = 0, stencilBits = 0;
    [gConfig valueForAttribute:EGL_DEPTH_SIZE out:&depthBits];
    [gConfig valueForAttribute:EGL_STENCIL_SIZE out:&stencilBits];
    if (depthBits > 0 || stencilBits > 0) {
        A2_GL(void (*)(A2GLsizei, A2GLuint *), "glGenRenderbuffers")(1, &depth);
        A2_GL(void (*)(A2GLenum, A2GLuint), "glBindRenderbuffer")(A2GL_RENDERBUFFER, depth);
        A2_GL(void (*)(A2GLenum, A2GLenum, A2GLsizei, A2GLsizei), "glRenderbufferStorage")(
            A2GL_RENDERBUFFER, A2GL_DEPTH24_STENCIL8, s.width, s.height);
        A2_GL(void (*)(A2GLenum, A2GLenum, A2GLenum, A2GLuint), "glFramebufferRenderbuffer")(
            A2GL_FRAMEBUFFER, A2GL_DEPTH_ATTACHMENT, A2GL_RENDERBUFFER, depth);
        A2_GL(void (*)(A2GLenum, A2GLenum, A2GLenum, A2GLuint), "glFramebufferRenderbuffer")(
            A2GL_FRAMEBUFFER, A2GL_STENCIL_ATTACHMENT, A2GL_RENDERBUFFER, depth);
    }

    A2GLenum status = A2_GL(A2GLenum (*)(A2GLenum), "glCheckFramebufferStatus")(A2GL_FRAMEBUFFER);
    if (status != A2GL_FRAMEBUFFER_COMPLETE) {
        a2_log_f(@"[A2-FAKEEGL] FBO 不完整 status=0x%04x（%dx%d%s）", status, s.width, s.height,
                 onscreen ? "，上屏" : "，离屏");
        if (fbo)   { A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteFramebuffers")(1, &fbo); }
        if (color) { A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteRenderbuffers")(1, &color); }
        if (depth) { A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteRenderbuffers")(1, &depth); }
        return NO;
    }

    s.framebuffer = fbo;
    s.colorRenderbuffer = color;
    s.depthStencilRenderbuffer = depth;
    s.attached = YES;
    s.ownerContext = (__bridge void *)ctx;
    A2_GL(void (*)(A2GLenum, A2GLuint), "glBindFramebuffer")(A2GL_FRAMEBUFFER, fbo);
    A2_GL(void (*)(A2GLint, A2GLint, A2GLsizei, A2GLsizei), "glViewport")(0, 0, s.width, s.height);
    if (onscreen) {
        a2_log_f(@"[A2-FAKEEGL] 上屏面已附着：drawable=%p %dx%d 像素（FBO=%u 颜色 RB=%u 深度 RB=%u）",
                 (__bridge void *)s.drawableLayer, s.width, s.height,
                 fbo, color, depth);
    }
    return YES;
}

/// 上屏面的尺寸跟随：图层的 bounds×contentsScale 变了（旋转 / 分屏 / 窗口缩放）⇒
/// 颜色 renderbuffer 重新按 drawable 建（EAGL 的机制就是**再调一次**
/// `-renderbufferStorage:fromDrawable:`），深度面与 FBO 跟着重建。
/// ★每帧只读两个图层属性★：尺寸没变 ⇒ 一个 GL 调用都不发（不在热路径上加开销）。
/// 调用点：`eglSwapBuffers`（上屏面，present 之前）。
static void a2_fe_surface_sync_drawable(A2FakeEglSurface *s, A2FakeEglContext *ctx) {
    if (!a2_fe_surface_is_onscreen(s) || ctx == nil) return;
    A2FeRect b = a2_fe_layer_bounds(s.drawableLayer);
    double scale = a2_fe_layer_contents_scale(s.drawableLayer);
    if (b.width <= 0.0 || b.height <= 0.0 || scale <= 0.0) return;   // 图层没布局 / 没给口径 ⇒ 不动
    EGLint w = (EGLint)(b.width * scale + 0.5);
    EGLint h = (EGLint)(b.height * scale + 0.5);
    if (w == s.width && h == s.height) return;

    a2_log_f(@"[A2-FAKEEGL] 上屏面尺寸变化 %dx%d -> %dx%d（按 drawable 重建）",
             s.width, s.height, w, h);
    s.width = w;
    s.height = h;
    a2_fe_surface_release_gl(s);                 // 旧 GL 对象属于本 context（swap 时必为 current）
    if (!a2_fe_surface_attach(s, ctx)) {
        a2_log_f(@"[A2-FAKEEGL] ★上屏面重建失败★（%dx%d）—— 本帧不再 present", w, h);
    }
}

// ===========================================================================
//  EGL 实现
// ===========================================================================

void a2_eagl_egl_engage(void) {
    a2_fe_ensure_state();
    if (gEngaged) return;
    gEngaged = YES;
    // ★engage 之后才允许加载 OpenGLES★（见 a2_fe_engage_allowed 的注释）：这里不主动 dlopen，
    //   真正的加载发生在 engage 后第一次取 GL 入口/类的时候（按需、且只一次）。
    a2_log_criterion(@"[A2-EAGL] engage：本层接管 egl*（此前一律让路给进程内真实 EGL）；"
                     @"此后才按需加载 OpenGLES（engage 之前本层不加载系统 OpenGLES）");
}

EGLBoolean a2_eagl_egl_is_engaged(void) {
    return gEngaged ? EGL_TRUE : EGL_FALSE;
}

EGLDisplay eglGetDisplay(EGLNativeDisplayType display_id) {
    A2_FE_IDLE_OR(eglGetDisplay, "eglGetDisplay", (display_id), EGL_NO_DISPLAY);
    a2_fe_ensure_state();
    // 本层不区分原生 display：EGL_DEFAULT_DISPLAY / EGL_NO_DISPLAY / 任意句柄都回同一个单例。
    (void)display_id;
    return (EGLDisplay)(__bridge void *)gDisplay;
}

EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor) {
    A2_FE_IDLE_OR(eglInitialize, "eglInitialize", (dpy, major, minor), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (!a2_fe_gles_ready()) {          // 上下文建不出来的环境，初始化就如实失败
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }
    if (!gDisplay.initialized) {
        gDisplay.initialized = YES;
        a2_log_f(@"[A2-FAKEEGL] eglInitialize 1.5 A2-EAGL（host=EAGL api=ES3 vendor=Air2）");
    }
    if (major != NULL) *major = 1;
    if (minor != NULL) *minor = 5;
    return EGL_TRUE;
}

EGLBoolean eglTerminate(EGLDisplay dpy) {
    A2_FE_IDLE_OR(eglTerminate, "eglTerminate", (dpy), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    // 规范：eglTerminate 销毁该 display 上**所有** context 与 surface。
    // 顺序要紧：先趁 context 还是 current 把 GL 对象删掉，再解绑、再销毁 context。
    for (A2FakeEglSurface *s in [gSurfaces copy]) {
        if ((tlsCurrentDraw == (__bridge void *)s || tlsCurrentRead == (__bridge void *)s) &&
            tlsCurrentContext != NULL) {
            a2_fe_surface_detach(s);
        } else {
            a2_fe_surface_release_owned_layer(s);   // 上屏面：图层必须摘，GL 对象随 context 消失
        }
        [gSurfaces removeObject:s];
    }
    for (A2FakeEglContext *c in [gContexts copy]) {
        if (tlsCurrentContext == (__bridge void *)c) {
            id cls = a2_fe_eagl_class();
            [(id<A2EAGLContextClassFace>)cls setCurrentContext:nil];
            tlsCurrentContext = NULL;
            tlsCurrentDraw = tlsCurrentRead = NULL;
        }
        [gContexts removeObject:c];
    }
    gDisplay.initialized = NO;
    a2_log_f(@"[A2-FAKEEGL] eglTerminate：context/surface 已全部释放");
    return EGL_TRUE;
}

const char *eglQueryString(EGLDisplay dpy, EGLint name) {
    A2_FE_IDLE_OR(eglQueryString, "eglQueryString", (dpy, name), NULL);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return NULL;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return NULL;
    }
    switch (name) {
        case EGL_VERSION:     return "1.5 A2-EAGL";
        case EGL_VENDOR:      return "Air2";
        case EGL_CLIENT_APIS: return "OpenGL_ES";
        case EGL_EXTENSIONS:  return "";
        default:
            a2_fe_set_error(EGL_BAD_PARAMETER);
            return NULL;
    }
}

EGLBoolean eglGetConfigs(EGLDisplay dpy, EGLConfig *configs, EGLint config_size, EGLint *num_config) {
    A2_FE_IDLE_OR(eglGetConfigs, "eglGetConfigs", (dpy, configs, config_size, num_config), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (num_config == NULL) {
        a2_fe_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }
    *num_config = 1;
    if (configs != NULL) {
        if (config_size < 1) {
            a2_fe_set_error(EGL_BAD_PARAMETER);
            return EGL_FALSE;
        }
        configs[0] = (EGLConfig)(__bridge void *)gConfig;
    }
    return EGL_TRUE;
}

/// config 匹配：只认「能真做出来」的组合。不认识的属性 ⇒ EGL_BAD_ATTRIBUTE（*err 置位、*badAttr
/// 带回是哪一个）；认识但满足不了 ⇒ 匹配失败（返回 NO，调用方回 0 个 config，★不静默降级★）。
static BOOL a2_fe_config_matches(const EGLint *attribs, EGLint *err, EGLint *badAttr) {
    if (attribs == NULL) return YES;

    // 本 config 的「可用位」：surface = WINDOW|PBUFFER；renderable 额外认 ES/ES2 位（ES3 上下文
    // 能跑 ES2 着色器，EGL 1.5 亦把 ES3 视作 ES2 的超集）。
    const EGLint availableSurface    = EGL_WINDOW_BIT | EGL_PBUFFER_BIT;
    const EGLint availableRenderable = EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT | EGL_OPENGL_ES3_BIT;

    for (int i = 0; attribs[i] != EGL_NONE; i += 2) {
        const EGLint k = attribs[i];
        const EGLint v = attribs[i + 1];
        switch (k) {
            case EGL_SURFACE_TYPE:
                if (v != EGL_DONT_CARE && (v & ~availableSurface) != 0) return NO;
                break;
            case EGL_RENDERABLE_TYPE: {
                // 必须显式请求 ES 位；请求了 OpenGL/OpenVG 位 ⇒ 本层做不到。
                if (v == EGL_DONT_CARE) break;
                if ((v & ~availableRenderable) != 0) return NO;
                if ((v & availableRenderable) == 0) return NO;
                break;
            }
            case EGL_CONFORMANT:
                if (v != EGL_DONT_CARE && (v & ~availableRenderable) != 0) return NO;
                break;
            case EGL_RED_SIZE:     if (v != EGL_DONT_CARE && v > 8)  return NO; break;
            case EGL_GREEN_SIZE:   if (v != EGL_DONT_CARE && v > 8)  return NO; break;
            case EGL_BLUE_SIZE:    if (v != EGL_DONT_CARE && v > 8)  return NO; break;
            case EGL_ALPHA_SIZE:   if (v != EGL_DONT_CARE && v > 8)  return NO; break;
            case EGL_DEPTH_SIZE:   if (v != EGL_DONT_CARE && v > 24) return NO; break;
            case EGL_STENCIL_SIZE: if (v != EGL_DONT_CARE && v > 8)  return NO; break;
            case EGL_BUFFER_SIZE:  if (v != EGL_DONT_CARE && v > 32) return NO; break;
            case EGL_SAMPLES:      if (v != EGL_DONT_CARE && v > 0)  return NO; break;  // ★不做 MSAA★
            case EGL_SAMPLE_BUFFERS: if (v != EGL_DONT_CARE && v > 0) return NO; break;
            case EGL_COLOR_BUFFER_TYPE:
                if (v != EGL_DONT_CARE && v != EGL_RGB_BUFFER) return NO;
                break;
            case EGL_LEVEL:        if (v != EGL_DONT_CARE && v != 0) return NO; break;
            case EGL_TRANSPARENT_TYPE:
                if (v != EGL_DONT_CARE && v != EGL_NONE) return NO;
                break;
            case EGL_BIND_TO_TEXTURE_RGB:
            case EGL_BIND_TO_TEXTURE_RGBA:
                if (v != EGL_DONT_CARE && v != EGL_FALSE) return NO;
                break;
            case EGL_LUMINANCE_SIZE:
            case EGL_ALPHA_MASK_SIZE:
                if (v != EGL_DONT_CARE && v != 0) return NO;
                break;
            case EGL_MATCH_NATIVE_PIXMAP:
                return NO;                       // 本层没有原生 pixmap
            case EGL_MAX_PBUFFER_WIDTH:
            case EGL_MAX_PBUFFER_HEIGHT:
                break;                            // 上限由 surface 创建时校验
            case EGL_MAX_PBUFFER_PIXELS:
                if (v != EGL_DONT_CARE && v > A2_FAKEEGL_MAX_SURFACE_DIM * A2_FAKEEGL_MAX_SURFACE_DIM) return NO;
                break;
            // 只影响匹配强度、不影响可用性的属性：如实忽略（不假装满足、也不因此失败）。
            case EGL_NATIVE_RENDERABLE:
            case EGL_NATIVE_VISUAL_TYPE:
            case EGL_NATIVE_VISUAL_ID:
            case EGL_MIN_SWAP_INTERVAL:
            case EGL_MAX_SWAP_INTERVAL:
                break;
            default:
                if (err != NULL) *err = EGL_BAD_ATTRIBUTE;
                if (badAttr != NULL) *badAttr = k;
                return NO;
        }
    }
    return YES;
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list, EGLConfig *configs,
                           EGLint config_size, EGLint *num_config) {
    A2_FE_IDLE_OR(eglChooseConfig, "eglChooseConfig",
                  (dpy, attrib_list, configs, config_size, num_config), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (num_config == NULL) {
        a2_fe_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }

    EGLint err = EGL_SUCCESS;
    EGLint badAttr = 0;
    BOOL matched = a2_fe_config_matches(attrib_list, &err, &badAttr);
    if (err != EGL_SUCCESS) {
        *num_config = 0;
        a2_fe_set_error(err);
        a2_log_f(@"[A2-FAKEEGL] eglChooseConfig ★失败★：不支持的属性 0x%04x", badAttr);
        return EGL_FALSE;
    }
    if (configs != NULL && config_size < 1) {
        *num_config = 0;
        a2_fe_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    if (!matched) {
        // 规范：属性合法但没有匹配的 config ⇒ EGL_TRUE + num_config=0（不是错误）。
        *num_config = 0;
        a2_log_f(@"[A2-FAKEEGL] eglChooseConfig：无可匹配 config（请求超出 RGBA8/D24S8/ES3 能力）");
        return EGL_TRUE;
    }
    *num_config = 1;
    if (configs != NULL) configs[0] = (EGLConfig)(__bridge void *)gConfig;
    a2_log_f(@"[A2-FAKEEGL] eglChooseConfig renderable=ES3_BIT ok（config_id=1 RGBA8 D24S8）");
    return EGL_TRUE;
}

EGLBoolean eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value) {
    A2_FE_IDLE_OR(eglGetConfigAttrib, "eglGetConfigAttrib", (dpy, config, attribute, value), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }
    if ((void *)config != (__bridge void *)gConfig || value == NULL) {
        a2_fe_set_error(EGL_BAD_CONFIG);
        return EGL_FALSE;
    }
    if (![gConfig valueForAttribute:attribute out:value]) {
        a2_fe_set_error(EGL_BAD_ATTRIBUTE);
        return EGL_FALSE;
    }
    return EGL_TRUE;
}

/// surface 创建的唯一实现处（window / pbuffer 只是尺寸来源不同；window 再按 `layer`
/// 分「离屏」与「上屏」两态 —— 上屏的 drawable 在这里就挂好，真正建 renderbuffer 在 attach）。
static EGLSurface a2_fe_surface_new(EGLint width, EGLint height, BOOL pbuffer, void *layer) {
    // ★上屏面允许宽高为 0★（尺寸来自宿主图层；attach 时以实现回报的可测值为准）；
    //   离屏面必须给正尺寸（本层不从窗口系统取尺寸，猜一个是不诚实）。
    const BOOL onscreen = (layer != NULL) && !pbuffer;
    if (width < 0 || height < 0 || width > A2_FAKEEGL_MAX_SURFACE_DIM ||
        height > A2_FAKEEGL_MAX_SURFACE_DIM) {
        a2_fe_set_error(EGL_BAD_PARAMETER);
        a2_log_f(@"[A2-FAKEEGL] surface 尺寸非法 %dx%d（上限 %d）",
                 width, height, A2_FAKEEGL_MAX_SURFACE_DIM);
        return EGL_NO_SURFACE;
    }
    if (!onscreen && (width <= 0 || height <= 0)) {
        a2_fe_set_error(EGL_BAD_PARAMETER);
        a2_log_f(@"[A2-FAKEEGL] 离屏 surface 必须给正尺寸（得到 %dx%d）", width, height);
        return EGL_NO_SURFACE;
    }

    A2FakeEglSurface *s = [[A2FakeEglSurface alloc] init];
    s.width = width;
    s.height = height;
    s.pbuffer = pbuffer;
    s.swapInterval = 0;
    if (onscreen) {
        BOOL owned = NO;
        id drawable = a2_fe_drawable_layer_new(layer, width, height, &owned);
        if (drawable == nil) {
            // 拿不到可呈现的 drawable ⇒ 如实报 EGL_BAD_NATIVE_WINDOW（不悄悄退回离屏）。
            a2_fe_set_error(EGL_BAD_NATIVE_WINDOW);
            a2_log_f(@"[A2-FAKEEGL] eglCreateWindowSurface ★失败★：宿主图层给不出 CAEAGLLayer（layer=%p）", layer);
            return EGL_NO_SURFACE;
        }
        s.drawableLayer = drawable;
        s.ownsDrawableLayer = owned;
    }
    [gSurfaces addObject:s];
    a2_log_f(@"[A2-FAKEEGL] surface 创建 %s %dx%d（%s；attach 在 makeCurrent 时）",
             pbuffer ? "pbuffer" : "window", width, height,
             onscreen ? "上屏 CAEAGLLayer + presentRenderbuffer"
                      : "离屏 renderbuffer+FBO，swap 只 flush");
    return (EGLSurface)(__bridge void *)s;
}

EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config,
                                  EGLNativeWindowType win, const EGLint *attrib_list) {
    A2_FE_IDLE_OR(eglCreateWindowSurface, "eglCreateWindowSurface",
                  (dpy, config, win, attrib_list), EGL_NO_SURFACE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_NO_SURFACE;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_NO_SURFACE;
    }
    if ((void *)config != (__bridge void *)gConfig) {
        a2_fe_set_error(EGL_BAD_CONFIG);
        return EGL_NO_SURFACE;
    }
    if (win == NULL) {
        // 本层不从窗口系统取尺寸（见头文件的 A2FakeEglWindowSize 契约），猜一个尺寸是不诚实。
        a2_fe_set_error(EGL_BAD_NATIVE_WINDOW);
        a2_log_f(@"[A2-FAKEEGL] eglCreateWindowSurface：native window 为空（需要 A2FakeEglWindowSize*）");
        return EGL_NO_SURFACE;
    }

    const A2FakeEglWindowSize *size = (const A2FakeEglWindowSize *)win;
    EGLint width = size->width;
    EGLint height = size->height;
    void *layer = size->layer;
    if (attrib_list != NULL) {
        for (int i = 0; attrib_list[i] != EGL_NONE; i += 2) {
            switch (attrib_list[i]) {
                case EGL_WIDTH:            width  = attrib_list[i + 1]; break;
                case EGL_HEIGHT:           height = attrib_list[i + 1]; break;
                case EGL_RENDER_BUFFER:    break;   // 只有 BACK_BUFFER，接受即忽略
                case EGL_LARGEST_PBUFFER:  break;   // window surface 无意义，接受即忽略
                default:
                    a2_fe_set_error(EGL_BAD_ATTRIBUTE);
                    return EGL_NO_SURFACE;
            }
        }
    }
    return a2_fe_surface_new(width, height, NO, layer);
}

EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint *attrib_list) {
    A2_FE_IDLE_OR(eglCreatePbufferSurface, "eglCreatePbufferSurface",
                  (dpy, config, attrib_list), EGL_NO_SURFACE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_NO_SURFACE;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_NO_SURFACE;
    }
    if ((void *)config != (__bridge void *)gConfig) {
        a2_fe_set_error(EGL_BAD_CONFIG);
        return EGL_NO_SURFACE;
    }

    // 规范要求 pbuffer 必须给出 WIDTH/HEIGHT；没给 ⇒ EGL_BAD_ATTRIBUTE（不猜默认值）。
    EGLint width = 0, height = 0;
    if (attrib_list != NULL) {
        for (int i = 0; attrib_list[i] != EGL_NONE; i += 2) {
            switch (attrib_list[i]) {
                case EGL_WIDTH:            width  = attrib_list[i + 1]; break;
                case EGL_HEIGHT:           height = attrib_list[i + 1]; break;
                case EGL_LARGEST_PBUFFER:  break;
                case EGL_TEXTURE_FORMAT:
                    if (attrib_list[i + 1] != EGL_NO_TEXTURE) {
                        a2_fe_set_error(EGL_BAD_ATTRIBUTE);   // 本层不支持纹理 pbuffer
                        return EGL_NO_SURFACE;
                    }
                    break;
                case EGL_TEXTURE_TARGET:
                    if (attrib_list[i + 1] != EGL_NO_TEXTURE) {
                        a2_fe_set_error(EGL_BAD_ATTRIBUTE);
                        return EGL_NO_SURFACE;
                    }
                    break;
                default:
                    a2_fe_set_error(EGL_BAD_ATTRIBUTE);
                    return EGL_NO_SURFACE;
            }
        }
    }
    if (width == 0 || height == 0) {
        a2_fe_set_error(EGL_BAD_ATTRIBUTE);
        return EGL_NO_SURFACE;
    }
    return a2_fe_surface_new(width, height, YES, NULL);
}

EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surface) {
    A2_FE_IDLE_OR(eglDestroySurface, "eglDestroySurface", (dpy, surface), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    A2FakeEglSurface *s = a2_fe_surface_of(surface);
    if (s == nil) {
        a2_fe_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }
    // GL 对象只在「它正被 current」时能删（删除调用要落在属主 context 上）；
    // 其余情形随 context 销毁一并释放（EAGL 的 renderbuffer 属于 context）。
    // ★图层例外★：不管是不是 current，本层自己挂的 CAEAGLLayer 都要当场摘掉。
    if (tlsCurrentDraw == (__bridge void *)s || tlsCurrentRead == (__bridge void *)s) {
        a2_fe_surface_detach(s);
        tlsCurrentDraw = tlsCurrentRead = NULL;
        if (tlsCurrentContext != NULL) {
            // 只解绑 surface，context 仍是 current（EGL 允许 context 无 surface 时 current）。
            A2_GL(void (*)(A2GLenum, A2GLuint), "glBindFramebuffer")(A2GL_FRAMEBUFFER, 0);
        }
    } else {
        a2_fe_surface_release_owned_layer(s);
    }
    [gSurfaces removeObject:s];
    a2_log_f(@"[A2-FAKEEGL] surface 销毁 %dx%d", s.width, s.height);
    return EGL_TRUE;
}

EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface surface, EGLint attribute, EGLint *value) {
    A2_FE_IDLE_OR(eglQuerySurface, "eglQuerySurface", (dpy, surface, attribute, value), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    A2FakeEglSurface *s = a2_fe_surface_of(surface);
    if (s == nil || value == NULL) {
        a2_fe_set_error(s == nil ? EGL_BAD_SURFACE : EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    switch (attribute) {
        case EGL_WIDTH:  *value = s.width;  return EGL_TRUE;
        case EGL_HEIGHT: *value = s.height; return EGL_TRUE;
        case EGL_CONFIG_ID: *value = 1; return EGL_TRUE;
        case EGL_SWAP_BEHAVIOR: *value = EGL_BUFFER_DESTROYED; return EGL_TRUE;
        case EGL_RENDER_BUFFER: *value = EGL_BACK_BUFFER; return EGL_TRUE;
        case EGL_MULTISAMPLE_RESOLVE: *value = EGL_MULTISAMPLE_RESOLVE_DEFAULT; return EGL_TRUE;
        case EGL_TEXTURE_FORMAT:
        case EGL_TEXTURE_TARGET: *value = EGL_NO_TEXTURE; return EGL_TRUE;
        case EGL_MIPMAP_TEXTURE: *value = EGL_FALSE; return EGL_TRUE;
        case EGL_MIPMAP_LEVEL:   *value = 0; return EGL_TRUE;
        default:
            a2_fe_set_error(EGL_BAD_ATTRIBUTE);
            return EGL_FALSE;
    }
}

EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context,
                            const EGLint *attrib_list) {
    A2_FE_IDLE_OR(eglCreateContext, "eglCreateContext",
                  (dpy, config, share_context, attrib_list), EGL_NO_CONTEXT);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_NO_CONTEXT;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_NO_CONTEXT;
    }
    if ((void *)config != (__bridge void *)gConfig) {
        a2_fe_set_error(EGL_BAD_CONFIG);
        return EGL_NO_CONTEXT;
    }

    // 版本：只接受 3（不做 ES2 降级）。缺省按 1 处理（EGL 规范：未给 CONTEXT_CLIENT_VERSION 视为 ES1，
    // 而 ES1 本层不支持 ⇒ EGL_BAD_CONFIG）。
    EGLint version = 1;
    if (attrib_list != NULL) {
        for (int i = 0; attrib_list[i] != EGL_NONE; i += 2) {
            switch (attrib_list[i]) {
                case EGL_CONTEXT_CLIENT_VERSION: version = attrib_list[i + 1]; break;
                case EGL_CONTEXT_MINOR_VERSION:  break;   // 本层恒 3.0，忽略
                case EGL_CONTEXT_OPENGL_DEBUG:   break;   // 无 KHR_debug，接受即忽略
                default:
                    a2_fe_set_error(EGL_BAD_ATTRIBUTE);
                    return EGL_NO_CONTEXT;
            }
        }
    }
    if (version != 3) {
        a2_fe_set_error(EGL_BAD_CONFIG);
        a2_log_f(@"[A2-FAKEEGL] eglCreateContext ★失败★：只支持 ES3（请求 version=%d）", version);
        return EGL_NO_CONTEXT;
    }

    // 共享：EGL 的 share_context 语义 = 共享资源组；EAGL 对应 sharegroup。
    A2FakeEglContext *share = a2_fe_context_of(share_context);
    if (share_context != EGL_NO_CONTEXT && share == nil) {
        a2_fe_set_error(EGL_BAD_CONTEXT);
        return EGL_NO_CONTEXT;
    }

    Class cls = a2_fe_eagl_class();
    if (cls == nil) {
        a2_fe_set_error(EGL_BAD_ALLOC);
        a2_log_f(@"[A2-FAKEEGL] eglCreateContext ★失败★：EAGLContext 类不存在");
        return EGL_NO_CONTEXT;
    }
    id eagl = nil;
    if (share != nil && share.eaglContext != nil) {
        eagl = [(id<A2EAGLContextFace>)[cls alloc] initWithAPI:A2_EAGL_API_OPENGL_ES3
                                                    sharegroup:[(id<A2EAGLContextFace>)share.eaglContext sharegroup]];
    } else {
        eagl = [(id<A2EAGLContextFace>)[cls alloc] initWithAPI:A2_EAGL_API_OPENGL_ES3];
    }
    if (eagl == nil) {
        a2_fe_set_error(EGL_BAD_ALLOC);
        a2_log_f(@"[A2-FAKEEGL] eglCreateContext ★失败★：EAGLContext(ES3) 创建返回 nil");
        return EGL_NO_CONTEXT;
    }

    A2FakeEglContext *ctx = [[A2FakeEglContext alloc] init];
    ctx.eaglContext = eagl;
    [gContexts addObject:ctx];
    a2_log_f(@"[A2-FAKEEGL] eglCreateContext version=3 ok（api=kEAGLRenderingAPIOpenGLES3）");
    return (EGLContext)(__bridge void *)ctx;
}

EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    A2_FE_IDLE_OR(eglDestroyContext, "eglDestroyContext", (dpy, ctx), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    A2FakeEglContext *c = a2_fe_context_of(ctx);
    if (c == nil) {
        a2_fe_set_error(EGL_BAD_CONTEXT);
        return EGL_FALSE;
    }
    if (tlsCurrentContext == (__bridge void *)c) {
        id cls = a2_fe_eagl_class();
        [(id<A2EAGLContextClassFace>)cls setCurrentContext:nil];
        tlsCurrentContext = NULL;
        tlsCurrentDraw = tlsCurrentRead = NULL;
    }
    [gContexts removeObject:c];
    a2_log_f(@"[A2-FAKEEGL] context 销毁");
    return EGL_TRUE;
}

EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    A2_FE_IDLE_OR(eglMakeCurrent, "eglMakeCurrent", (dpy, draw, read, ctx), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (!gDisplay.initialized) {
        a2_fe_set_error(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }

    id cls = a2_fe_eagl_class();

    // ① 解绑（ctx == EGL_NO_CONTEXT）：draw/read 也必须为空。
    if (ctx == EGL_NO_CONTEXT) {
        if (draw != EGL_NO_SURFACE || read != EGL_NO_SURFACE) {
            a2_fe_set_error(EGL_BAD_MATCH);
            return EGL_FALSE;
        }
        [(id<A2EAGLContextClassFace>)cls setCurrentContext:nil];
        tlsCurrentContext = tlsCurrentDraw = tlsCurrentRead = NULL;
        return EGL_TRUE;
    }

    A2FakeEglContext *c = a2_fe_context_of(ctx);
    if (c == nil) {
        a2_fe_set_error(EGL_BAD_CONTEXT);
        return EGL_FALSE;
    }
    A2FakeEglSurface *drawS = a2_fe_surface_of(draw);
    A2FakeEglSurface *readS = (read == draw) ? drawS : a2_fe_surface_of(read);
    if (drawS == nil) {
        a2_fe_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }
    if (read != draw) {
        if (readS == nil) {                     // 读面不是本层的 surface：如实报错，不悄悄用 draw 顶替
            a2_fe_set_error(EGL_BAD_SURFACE);
            return EGL_FALSE;
        }
        // 本层只有一张离屏面（= 同一个 FBO）：读写面不同无法如实做到，明确拒绝而不是假装。
        a2_fe_set_error(EGL_BAD_MATCH);
        a2_log_f(@"[A2-FAKEEGL] eglMakeCurrent ★拒绝★：不支持 draw≠read 的双面绑定");
        return EGL_FALSE;
    }

    if (![(id<A2EAGLContextClassFace>)cls setCurrentContext:c.eaglContext]) {
        a2_fe_set_error(EGL_BAD_CONTEXT);
        a2_log_f(@"[A2-FAKEEGL] eglMakeCurrent ★失败★：setCurrentContext 返回 NO");
        return EGL_FALSE;
    }
    if (!a2_fe_surface_attach(drawS, c)) {
        a2_fe_set_error(EGL_BAD_ALLOC);
        return EGL_FALSE;
    }
    tlsCurrentContext = (__bridge void *)c;
    tlsCurrentDraw = (__bridge void *)drawS;
    tlsCurrentRead = (__bridge void *)drawS;
    return EGL_TRUE;
}

EGLContext eglGetCurrentContext(void) {
    A2_FE_IDLE_OR(eglGetCurrentContext, "eglGetCurrentContext", (), EGL_NO_CONTEXT);
    return (EGLContext)tlsCurrentContext;
}

EGLSurface eglGetCurrentSurface(EGLint readdraw) {
    A2_FE_IDLE_OR(eglGetCurrentSurface, "eglGetCurrentSurface", (readdraw), EGL_NO_SURFACE);
    switch (readdraw) {
        case EGL_DRAW: return (EGLSurface)tlsCurrentDraw;
        case EGL_READ: return (EGLSurface)tlsCurrentRead;
        default:
            a2_fe_set_error(EGL_BAD_PARAMETER);
            return EGL_NO_SURFACE;
    }
}

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    A2_FE_IDLE_OR(eglSwapBuffers, "eglSwapBuffers", (dpy, surface), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    A2FakeEglSurface *s = a2_fe_surface_of(surface);
    if (s == nil) {
        a2_fe_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }
    if (tlsCurrentDraw != (__bridge void *)s || tlsCurrentContext == NULL) {
        a2_fe_set_error(EGL_BAD_CURRENT_SURFACE);
        return EGL_FALSE;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    // ★两条路径的唯一分叉★
    //   · 离屏面：没有 CALayer 可呈现 ⇒ flush 是「这一帧确实提交给驱动」的可判据动作；
    //   · 上屏面：先把尺寸跟随（旋转/缩放后 drawable 变了就重建），再
    //     `-presentRenderbuffer:`（★这就是「上屏」本身★）。present 失败如实报错，不假装成功。
    BOOL presented = NO;
    if (a2_fe_surface_is_onscreen(s)) {
        A2FakeEglContext *ctx = a2_fe_context_of((EGLContext)tlsCurrentContext);
        a2_fe_surface_sync_drawable(s, ctx);       // 尺寸变了 ⇒ 重建（不变则零开销）
        if (!s.attached) {                          // 重建失败 ⇒ 本帧没有可呈现的面
            clock_gettime(CLOCK_MONOTONIC, &t1);
            s.lastSwapMs = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
            a2_fe_set_error(EGL_BAD_SURFACE);
            a2_log_f(@"[A2-FAKEEGL] ★上屏失败★：surface 未附着（重建失败），本帧不 present");
            return EGL_FALSE;
        }
        A2_GL(void (*)(A2GLenum, A2GLuint), "glBindRenderbuffer")(A2GL_RENDERBUFFER,
                                                                s.colorRenderbuffer);
        presented = [(id<A2EAGLContextFace>)ctx.eaglContext presentRenderbuffer:A2GL_RENDERBUFFER];
        if (!presented) {
            clock_gettime(CLOCK_MONOTONIC, &t1);
            s.lastSwapMs = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
            a2_fe_set_error(EGL_BAD_SURFACE);
            a2_log_f(@"[A2-FAKEEGL] ★上屏失败★：-presentRenderbuffer: 返回 NO（drawable=%p %dx%d）",
                     (__bridge void *)s.drawableLayer, s.width, s.height);
            return EGL_FALSE;
        }
    } else {
        A2_GL(void (*)(void), "glFlush")();
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    s.swapFrames++;
    gSwapCount++;
    s.lastSwapMs = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    // 每帧都打会淹掉日志：前 3 帧 + 之后每 300 帧一行（与 [FRAME] 的采样节奏一致）。
    if (s.swapFrames <= 3 || s.swapFrames % 300 == 0) {
        a2_log_f(@"[A2-FAKEEGL] swap frame=%lu ms=%.3f（%s %dx%d interval=%d total=%lu %s）",
                 (unsigned long)s.swapFrames, s.lastSwapMs,
                 s.pbuffer ? "pbuffer" : (a2_fe_surface_is_onscreen(s) ? "上屏" : "window"),
                 s.width, s.height, (int)s.swapInterval, (unsigned long)gSwapCount,
                 presented ? "present=ok" : "flush");
    }
    return EGL_TRUE;
}

EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval) {
    A2_FE_IDLE_OR(eglSwapInterval, "eglSwapInterval", (dpy, interval), EGL_FALSE);
    if (!a2_fe_display_ok(dpy)) {
        a2_fe_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    A2FakeEglSurface *s = a2_fe_surface_of((EGLSurface)tlsCurrentDraw);
    if (s == nil || tlsCurrentContext == NULL) {
        a2_fe_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }
    // 本层 config 的区间是 [0,1]（见 MIN/MAX_SWAP_INTERVAL），超出按规范夹到边界。
    s.swapInterval = interval < 0 ? 0 : (interval > 1 ? 1 : interval);
    return EGL_TRUE;
}

EGLint eglGetError(void) {
    A2_FE_IDLE_OR(eglGetError, "eglGetError", (), EGL_SUCCESS);
    EGLint err = tlsError;
    tlsError = EGL_SUCCESS;      // ★规范语义：读后清零★
    return err;
}

__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *procname) {
    A2_FE_IDLE_OR(eglGetProcAddress, "eglGetProcAddress", (procname), NULL);
    if (procname == NULL) return NULL;

    // ① 本模块导出表（EGL 名字）
    void *sym = a2_fe_own_symbol(procname);
    // ② 系统 GLES（进程 flat namespace；本层若用 RTLD_LOCAL 镜像，这里有可能是 NULL）
    if (sym == NULL) sym = dlsym(RTLD_DEFAULT, procname);
    // ③ 本次自己 dlopen 的 OpenGLES 镜像（RTLD_LOCAL ⇒ 只能按句柄解析）
    if (sym == NULL) sym = a2_fe_gl_symbol(procname);

    if (sym == NULL) {
        if (gProcMissLogged < 20) {
            gProcMissLogged++;
            a2_log_f(@"[A2-FAKEEGL] eglGetProcAddress 未命中：%s", procname);
        }
        return NULL;
    }
    return (__eglMustCastToProperFunctionPointerType)sym;
}

EGLBoolean eglBindAPI(EGLenum api) {
    A2_FE_IDLE_OR(eglBindAPI, "eglBindAPI", (api), EGL_FALSE);
    if (api != EGL_OPENGL_ES_API) {          // 只有 ES（OpenGL/OpenVG 在 iOS 上不存在）
        a2_fe_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    gBoundAPI = api;
    return EGL_TRUE;
}

EGLenum eglQueryAPI(void) {
    A2_FE_IDLE_OR(eglQueryAPI, "eglQueryAPI", (), EGL_OPENGL_ES_API);
    return gBoundAPI;
}

EGLBoolean eglReleaseThread(void) {
    A2_FE_IDLE_OR(eglReleaseThread, "eglReleaseThread", (), EGL_FALSE);
    // 规范：释放本线程的 EGL 资源（本层即「把 current 解掉」），不改进程级 display/config。
    if (tlsCurrentContext != NULL) {
        id cls = a2_fe_eagl_class();
        [(id<A2EAGLContextClassFace>)cls setCurrentContext:nil];
    }
    tlsCurrentContext = tlsCurrentDraw = tlsCurrentRead = NULL;
    return EGL_TRUE;
}

// ===========================================================================
//  自检（离屏三角形）—— P1 判据入口
// ===========================================================================
static const char *const kSelfTestTag = "[A2-EAGL]";

/// 编译一个着色器；失败时把 GL 的 info log 打出来（★不吞错★）。
static A2GLuint a2_fe_compile_shader(A2GLenum type, const char *src, const char *label) {
    A2GLuint sh = A2_GL(A2GLuint (*)(A2GLenum), "glCreateShader")(type);
    if (sh == 0) {
        a2_log_f(@"%s %s：glCreateShader 返回 0", kSelfTestTag, label);
        return 0;
    }
    A2_GL(void (*)(A2GLuint, A2GLsizei, const A2GLchar *const *, const A2GLint *), "glShaderSource")(
        sh, 1, &src, NULL);
    A2_GL(void (*)(A2GLuint), "glCompileShader")(sh);

    A2GLint ok = 0;
    A2_GL(void (*)(A2GLuint, A2GLenum, A2GLint *), "glGetShaderiv")(sh, A2GL_COMPILE_STATUS, &ok);
    if (!ok) {
        A2GLint len = 0;
        A2_GL(void (*)(A2GLuint, A2GLenum, A2GLint *), "glGetShaderiv")(sh, A2GL_INFO_LOG_LENGTH, &len);
        char *log = (char *)calloc(1, (size_t)(len > 1 ? len : 1));
        if (log != NULL) {
            A2_GL(void (*)(A2GLuint, A2GLsizei, A2GLsizei *, A2GLchar *), "glGetShaderInfoLog")(
                sh, len, NULL, log);
            a2_log_f(@"%s %s 编译失败：%s", kSelfTestTag, label, log);
            free(log);
        }
        A2_GL(void (*)(A2GLuint), "glDeleteShader")(sh);
        return 0;
    }
    return sh;
}

int a2_eagl_egl_selftest(void) {
    a2_eagl_egl_engage();
    a2_log_criterion(@"[A2-EAGL] selftest begin（engaged=%d 离屏 ES3 三角形）",
                     (int)a2_eagl_egl_is_engaged());

    // ---- 0 GLES 镜像 + EAGLContext 类 ----
    if (!a2_fe_gles_ready()) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=gles rc=-1");
        return -1;
    }

    // 保存调用线程原来的 EAGL 上下文（自检结束要还回去，不能留下副作用）。
    Class ctxClass = a2_fe_eagl_class();
    id prevCurrent = [(id<A2EAGLContextClassFace>)ctxClass currentContext];

    int rc = 0;
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLSurface surf = EGL_NO_SURFACE;
    EGLSurface pbuffer = EGL_NO_SURFACE;
    EGLContext ctx = EGL_NO_CONTEXT;
    A2GLuint vs = 0, fs = 0, prog = 0, vbo = 0;

    // ---- 1 display ----
    dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (dpy == EGL_NO_DISPLAY) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=display rc=-2");
        rc = -2;
        goto done;
    }

    // ---- 2 initialize ----
    EGLint major = 0, minor = 0;
    if (!eglInitialize(dpy, &major, &minor)) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=initialize rc=-3 err=0x%04x",
                         (unsigned)eglGetError());
        rc = -3;
        goto done;
    }
    a2_log_f(@"%s version=%d.%d query=%s", kSelfTestTag, major, minor,
             eglQueryString(dpy, EGL_VERSION) ?: "(null)");

    // ---- 3 chooseConfig ----
    const EGLint cfgAttrs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      24,
        EGL_STENCIL_SIZE,    8,
        EGL_NONE,
    };
    EGLConfig cfg = NULL;
    EGLint numCfg = 0;
    if (!eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &numCfg) || numCfg < 1) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=chooseConfig rc=-4 err=0x%04x num=%d",
                         (unsigned)eglGetError(), (int)numCfg);
        rc = -4;
        goto done;
    }

    // ---- 3b 配置面自证（eglGetConfigs / eglGetConfigAttrib 在 P1 没有别的调用点）----
    {
        EGLConfig all[2] = { NULL, NULL };
        EGLint n = 0;
        EGLint depthBits = 0;
        if (!eglGetConfigs(dpy, all, 2, &n) || n != 1 || all[0] != cfg ||
            !eglGetConfigAttrib(dpy, cfg, EGL_DEPTH_SIZE, &depthBits) || depthBits != 24) {
            a2_log_criterion(@"[A2-EAGL] selftest FAIL step=configApi rc=-12 err=0x%04x n=%d depth=%d",
                             (unsigned)eglGetError(), (int)n, (int)depthBits);
            rc = -12;
            goto done;
        }
    }

    // ---- 4 createContext（ES3）----
    const EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (ctx == EGL_NO_CONTEXT) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=createContext rc=-5 err=0x%04x",
                         (unsigned)eglGetError());
        rc = -5;
        goto done;
    }

    // ---- 5 window surface（离屏 64x64：中心像素判定足够，且快）----
    A2FakeEglWindowSize size = { 64, 64 };
    surf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)&size, NULL);
    if (surf == EGL_NO_SURFACE) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=createWindowSurface rc=-6 err=0x%04x",
                         (unsigned)eglGetError());
        rc = -6;
        goto done;
    }

    // ---- 6 pbuffer surface（尺寸查询 + 销毁路径也走一遍）----
    const EGLint pbAttrs[] = { EGL_WIDTH, 32, EGL_HEIGHT, 32, EGL_NONE };
    pbuffer = eglCreatePbufferSurface(dpy, cfg, pbAttrs);
    EGLint pw = 0, ph = 0;
    if (pbuffer == EGL_NO_SURFACE ||
        !eglQuerySurface(dpy, pbuffer, EGL_WIDTH, &pw) ||
        !eglQuerySurface(dpy, pbuffer, EGL_HEIGHT, &ph) || pw != 32 || ph != 32) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=pbuffer rc=-7 err=0x%04x got=%dx%d",
                         (unsigned)eglGetError(), (int)pw, (int)ph);
        rc = -7;
        goto done;
    }
    a2_log_f(@"%s pbuffer 32x32 ok（query 尺寸一致）", kSelfTestTag);

    // ---- 7 makeCurrent ----
    if (!eglMakeCurrent(dpy, surf, surf, ctx)) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=makeCurrent rc=-8 err=0x%04x",
                         (unsigned)eglGetError());
        rc = -8;
        goto done;
    }
    {
        // 用 GL 自己的 reports 确认「上下文真的可用」（不是本层自称）。
        const char *ver = A2_GL(const char *(*)(A2GLenum), "glGetString")(A2GL_VERSION);
        const char *ren = A2_GL(const char *(*)(A2GLenum), "glGetString")(A2GL_RENDERER);
        a2_log_f(@"%s GL_VERSION=%s GL_RENDERER=%s", kSelfTestTag, ver ?: "(null)", ren ?: "(null)");
    }

    // ---- 7b current / API / interval / getProcAddress 自证 ----
    // 这四个入口在 P1 没有别的调用点，自检里各走一次，语义也顺带验了。
    {
        void *drawArrays = (void *)eglGetProcAddress("glDrawArrays");
        if (eglGetCurrentContext() != ctx ||
            eglGetCurrentSurface(EGL_DRAW) != surf ||
            eglGetCurrentSurface(EGL_READ) != surf ||
            !eglBindAPI(EGL_OPENGL_ES_API) ||
            eglQueryAPI() != EGL_OPENGL_ES_API ||
            !eglSwapInterval(dpy, 0) ||
            drawArrays == NULL) {
            a2_log_criterion(@"[A2-EAGL] selftest FAIL step=stateApi rc=-13 err=0x%04x drawArrays=%p",
                             (unsigned)eglGetError(), drawArrays);
            rc = -13;
            goto done;
        }
        a2_log_f(@"%s current/API/swapInterval ok，eglGetProcAddress(glDrawArrays)=%p",
                 kSelfTestTag, drawArrays);
    }

    // ---- 8 着色器（ES3 300 es）----
    static const char *kVS =
        "#version 300 es\n"
        "layout(location = 0) in vec2 aPos;\n"
        "void main() { gl_Position = vec4(aPos, 0.0, 1.0); }\n";
    static const char *kFS =
        "#version 300 es\n"
        "precision mediump float;\n"
        "out vec4 fragColor;\n"
        "void main() { fragColor = vec4(0.2, 0.9, 0.4, 1.0); }\n";

    vs = a2_fe_compile_shader(A2GL_VERTEX_SHADER, kVS, "vertex");
    fs = a2_fe_compile_shader(A2GL_FRAGMENT_SHADER, kFS, "fragment");
    if (vs == 0 || fs == 0) {
        a2_log_criterion(@"[A2-EAGL] selftest FAIL step=shader rc=-9（见上一行 compile 日志）");
        rc = -9;
        goto done;
    }
    prog = A2_GL(A2GLuint (*)(void), "glCreateProgram")();
    A2_GL(void (*)(A2GLuint, A2GLuint), "glAttachShader")(prog, vs);
    A2_GL(void (*)(A2GLuint, A2GLuint), "glAttachShader")(prog, fs);
    A2_GL(void (*)(A2GLuint), "glLinkProgram")(prog);
    {
        A2GLint ok = 0;
        A2_GL(void (*)(A2GLuint, A2GLenum, A2GLint *), "glGetProgramiv")(prog, A2GL_LINK_STATUS, &ok);
        if (!ok) {
            A2GLint len = 0;
            A2_GL(void (*)(A2GLuint, A2GLenum, A2GLint *), "glGetProgramiv")(prog, A2GL_INFO_LOG_LENGTH, &len);
            char *log = (char *)calloc(1, (size_t)(len > 1 ? len : 1));
            if (log != NULL) {
                A2_GL(void (*)(A2GLuint, A2GLsizei, A2GLsizei *, A2GLchar *), "glGetProgramInfoLog")(
                    prog, len, NULL, log);
                a2_log_f(@"%s program link 失败：%s", kSelfTestTag, log);
                free(log);
            }
            a2_log_criterion(@"[A2-EAGL] selftest FAIL step=link rc=-9");
            rc = -9;
            goto done;
        }
    }
    A2_GL(void (*)(A2GLuint), "glUseProgram")(prog);

    // ---- 9 画一帧 ----
    {
        // 三角形覆盖中心点（顶点 (-0.6,-0.6) (0.6,-0.6) (0,0.6)：几何中心就是 (0,0)）。
        static const A2GLfloat kVerts[] = {
            -0.6f, -0.6f,
             0.6f, -0.6f,
             0.0f,  0.6f,
        };
        A2_GL(void (*)(A2GLint, A2GLint, A2GLsizei, A2GLsizei), "glViewport")(0, 0, 64, 64);
        A2_GL(void (*)(A2GLfloat, A2GLfloat, A2GLfloat, A2GLfloat), "glClearColor")(0.0f, 0.0f, 0.0f, 1.0f);
        A2_GL(void (*)(A2GLenum), "glClear")(A2GL_COLOR_BUFFER_BIT | A2GL_DEPTH_BUFFER_BIT);

        A2_GL(void (*)(A2GLsizei, A2GLuint *), "glGenBuffers")(1, &vbo);
        A2_GL(void (*)(A2GLenum, A2GLuint), "glBindBuffer")(A2GL_ARRAY_BUFFER, vbo);
        A2_GL(void (*)(A2GLenum, A2GLsizeiptr, const void *, A2GLenum), "glBufferData")(
            A2GL_ARRAY_BUFFER, (A2GLsizeiptr)sizeof(kVerts), kVerts, A2GL_STATIC_DRAW);
        A2_GL(void (*)(A2GLuint), "glEnableVertexAttribArray")(0);
        A2_GL(void (*)(A2GLuint, A2GLint, A2GLenum, A2GLboolean, A2GLsizei, const void *),
              "glVertexAttribPointer")(0, 2, A2GL_FLOAT, 0, 0, NULL);
        A2_GL(void (*)(A2GLenum, A2GLint, A2GLsizei), "glDrawArrays")(A2GL_TRIANGLES, 0, 3);

        A2GLenum glErr = A2_GL(A2GLenum (*)(void), "glGetError")();
        if (glErr != A2GL_NO_ERROR) {
            a2_log_criterion(@"[A2-EAGL] selftest FAIL step=draw rc=-10 glError=0x%04x", glErr);
            rc = -10;
            goto done;
        }
        if (!eglSwapBuffers(dpy, surf)) {
            a2_log_criterion(@"[A2-EAGL] selftest FAIL step=swapBuffers rc=-10 err=0x%04x",
                             (unsigned)eglGetError());
            rc = -10;
            goto done;
        }
    }

    // ---- 10 读中心像素 ----
    {
        A2GLubyte px[4] = { 0, 0, 0, 0 };
        A2_GL(void (*)(A2GLint, A2GLint, A2GLsizei, A2GLsizei, A2GLenum, A2GLenum, void *),
              "glReadPixels")(32, 32, 1, 1, A2GL_RGBA, A2GL_UNSIGNED_BYTE, px);

        const int expectR = 51, expectG = 229, expectB = 102;   // (0.2, 0.9, 0.4) → 8bit
        const int tolerance = 8;
        BOOL colorOk = abs((int)px[0] - expectR) <= tolerance &&
                       abs((int)px[1] - expectG) <= tolerance &&
                       abs((int)px[2] - expectB) <= tolerance &&
                       px[3] == 255;
        unsigned center = (unsigned)px[0] | ((unsigned)px[1] << 8) |
                          ((unsigned)px[2] << 16) | ((unsigned)px[3] << 24);
        if (!colorOk) {
            a2_log_criterion(@"[A2-EAGL] selftest FAIL step=readpixels rc=-11 center=0x%08x "
                             "(expect ~0x%08x)", center,
                             (unsigned)expectR | ((unsigned)expectG << 8) |
                             ((unsigned)expectB << 16) | (255u << 24));
            rc = -11;
            goto done;
        }
        a2_log_criterion(@"[A2-EAGL] selftest PASS center=0x%08x（面 64x64，三角形 1 帧，swap 计数 %lu）",
                         center, (unsigned long)gSwapCount);
        rc = 0;
    }

done:
    // ---- 收尾：删 GL 对象 → 解绑 → 销毁 surface/context → terminate → 还回原上下文 ----
    if (prog) A2_GL(void (*)(A2GLuint), "glDeleteProgram")(prog);
    if (vs)   A2_GL(void (*)(A2GLuint), "glDeleteShader")(vs);
    if (fs)   A2_GL(void (*)(A2GLuint), "glDeleteShader")(fs);
    if (vbo)  A2_GL(void (*)(A2GLsizei, const A2GLuint *), "glDeleteBuffers")(1, &vbo);
    if (surf != EGL_NO_SURFACE)    eglDestroySurface(dpy, surf);
    if (pbuffer != EGL_NO_SURFACE) eglDestroySurface(dpy, pbuffer);
    if (ctx != EGL_NO_CONTEXT)     eglDestroyContext(dpy, ctx);
    if (dpy != EGL_NO_DISPLAY)     eglTerminate(dpy);
    eglReleaseThread();
    if (prevCurrent != nil && ctxClass != Nil) {
        [(id<A2EAGLContextClassFace>)ctxClass setCurrentContext:prevCurrent];
    }
    if (rc != 0) {
        a2_log_criterion(@"[A2-EAGL] selftest end rc=%d（失败步骤见上一行 FAIL）", rc);
    }
    return rc;
}

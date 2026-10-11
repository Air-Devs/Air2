/*
 * Air2 —— 复用线 Java 覆盖层（JavaApp/src/lwjgl/**）的 native 对端
 * ============================================================================
 * 文件：Natives/Input/a2_glfw_overlay_bridge.m
 * 归属线：复用线（JavaApp/src/lwjgl/** → air2-lwjgl-patch.jar，classpath 最前，
 *         由 Air2/Bridge/A2LaunchRunner.m 的 frontItems 排在最前；见 docs/ARCHITECTURE.md [LWJGL-PATCH]）。
 *         与本仓另一条自研线（JavaApp/src/ownglfw/** + Natives/OwnGlfw/a2_own_glfw_bridge.m）
 *         ★互不混同★：那条线是自己的 GLFW 类与自己的 11 个 `..._GLFW_n*` 符号；
 *         本条线服务的是「覆盖官方同名类」的那 10 个复用类，符号名由它们逐字决定。
 *
 * ★本文件只做一件事★：把复用线 Java 覆盖层的 native 契约，接到 Air2 已有的
 *   Natives/Input 中立窗口/事件层（a2_glfw_window.h / a2_glfw_input.h）。
 *   本文件不做窗口逻辑、不做输入翻译、不碰任何图形后端（后端专有名一字不提；
 *   机器判据见 scripts/verify_ownglfw_native.py 的「渲染器解耦」项）。
 *
 * ---------------------------------------------------------------------------
 * ① 谁调它（唯一依据 = 复用线 Java 覆盖层的实际调用；逐符号给行号）
 * ---------------------------------------------------------------------------
 * A. JNI（符号名由 Java 类/方法名逐字决定，不可改）—— 13 个，全部在
 *    JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java 内声明；
 *    「谁调它」= 该 Java 方法（公有 GLFW API），而公有 API 由 MC 调用：
 *
 *    | 本文件符号                                       | Java 声明行 | Java 调用行（同文件） |
 *    |--------------------------------------------------|-------------|------------------------|
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetCharCallback        | 576 | 651（glfwSetCharCallback）        |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetCharModsCallback    | 577 | 659（glfwSetCharModsCallback）    |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetCursorEnterCallback | 578 | 667（glfwSetCursorEnterCallback） |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetCursorPosCallback   | 579 | 675（glfwSetCursorPosCallback）   |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetFramebufferSizeCallback | 580 | 699（glfwSetFramebufferSizeCallback） |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetKeyCallback         | 581 | 715（glfwSetKeyCallback）         |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetMouseButtonCallback | 582 | 731（glfwSetMouseButtonCallback） |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetScrollCallback      | 583 | 739（glfwSetScrollCallback）      |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetWindowSizeCallback  | 584 | 802（glfwSetWindowSizeCallback）  |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow       | 586 | 1087（glfwDestroyWindow）、1115（glfwShowWindow） |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos           | 1233 | 1229（glfwGetCursorPos, DoubleBuffer 版） |
 *    | Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA          | 1234 | 1453（glfwGetCursorPos, double[] 版）     |
 *    | Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos            | 1236 | MC 直接调（公有 native）                  |
 *
 * B. JNI（CallbackBridge）—— 2 个，声明在
 *    JavaApp/src/lwjgl/org/lwjgl/glfw/CallbackBridge.java：
 *    | Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard   | 49 | GLFW.java:1260（COPY）/1268（PASTE） |
 *    | Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing | 50 | GLFW.java:1200/1202（glfwSetInputMode, GLFW_CURSOR） |
 *
 * C. C 入口（不是 JNI 符号，由 Java 侧 dlsym 取函数地址）—— 10 个：
 *    Java 侧 GLFW.java:604-624 建 `MacOSXLibraryDL(..., RTLD_DEFAULT)` 句柄后
 *    逐个 `apiGetFunctionAddress(GLFW, "pojav…")`；★解析失败会让 `Functions` 类
 *    初始化抛异常 ⇒ 10 个一个都不能缺★。调用点（同文件）：
 *      pojavInit            ← 613 声明 / 811-813 调用（glfwInit）
 *      pojavCreateContext   ← 615 / 1029（nglfwCreateContext ← 1033 glfwCreateWindow）
 *      pojavGetCurrentContext ← 616 / 867（glfwGetCurrentContext）
 *      pojavMakeCurrent     ← 618 / 994（glfwMakeContextCurrent；另 1055 建窗后自动 current）
 *      pojavTerminate       ← 619 / 820（glfwTerminate）
 *      pojavSetWindowHint   ← 620 / 1119（glfwWindowHint）
 *      pojavSwapBuffers     ← 621 / 999（glfwSwapBuffers）
 *      pojavSwapInterval    ← 622 / 1004（glfwSwapInterval）
 *      pojavPumpEvents      ← 623 / 1150-1152（glfwPollEvents）
 *      pojavRewindEvents    ← 624 / 1154（glfwPollEvents）
 *
 * ---------------------------------------------------------------------------
 * ② 与渲染器解耦（本文件硬约束，同 Natives/Input 的既有定位）
 * ---------------------------------------------------------------------------
 *   · 只经 `a2_glfw_window.h` 的中立面工作：窗口生命周期 + 事件总线 + A2GlfwSurface。
 *     本文件不认识任何图形 API（源码里不出现任何后端专有名，机器判据同前端）。
 *   · 需要图形上下文的地方（MakeContextCurrent / SwapBuffers / SwapInterval）★刻意不做图形工作★：
 *     它们是「渲染器的交接点」，本层只保留 ABI 入口 + 记录调用（否则 Java 侧 native 解析不到
 *     ⇒ UnsatisfiedLinkError）。真正的上下文创建/呈现属渲染器（用户拍板：渲染器选型以后再说）。
 *   · 事件 → Java 的方向：本层只把 A2GlfwEvent 翻译成「官方 glfw3.h 的 C 回调 ABI」并调用
 *     Java 侧交给本层的回调地址（LWJGL 的 libffi 闭包，见 ④）。
 *
 * ---------------------------------------------------------------------------
 * ③ 每符号为何必需（判据 = 「会不会在进主界面的路上被调到」）
 * ---------------------------------------------------------------------------
 *   · 9 个 `nglfwSet*Callback`：MC 的 InputConstants/MouseHandler 在初始化时注册全部回调
 *     （Java 侧 651…802 行），任一缺失 ⇒ 首次调用即 UnsatisfiedLinkError。
 *   · `nglfwSetShowingWindow`：glfwShowWindow（MC 建窗后必调）与 glfwDestroyWindow 都走它。
 *   · `nglfwGetCursorPos(A)` / `glfwSetCursorPos`：MC 的 MouseHandler 每帧读写光标。
 *   · `nativeClipboard`：MC 的复制/粘贴（glfwSet/GetClipboardString）。
 *   · `nativeSetGrabbing`：glfwSetInputMode(GLFW_CURSOR, DISABLED)（MC 进世界/抓取鼠标时调）。
 *   · 10 个 `pojav*`：glfwInit/CreateWindow/PollEvents/Terminate 等每个都直通它们（见 ①C）。
 *   ※ 未落项与理由见 §未落（如 `CallbackBridge.nativeSetModifiers` 全仓无调用方 ⇒ 只列清单不落）。
 *
 * ---------------------------------------------------------------------------
 * ④ 事件通道的机制（★一条链，写清不猜★）
 * ---------------------------------------------------------------------------
 *   UIKit 触摸/按键 → Natives/Input（a2_glfw_input.m / a2_glfw_window.m）翻译成 A2GlfwEvent
 *   → pojavPumpEvents（本文件）在 **Java 调用线程** 上 a2_glfw_event_pump()
 *   → 本文件的 sink（同线程）→ 直接调用 Java 侧注册进来的回调地址（官方 C ABI）。
 *   Java 侧那个地址来自 `GLFWKeyCallback.createSafe(nglfwSetKeyCallback(window, memAddressSafe(cbfun)))`，
 *   即 LWJGL 的 libffi 闭包（被覆盖的 org.lwjgl.system.Callback 用 ffi_closure_alloc +
 *   ffi_prep_closure_loc 造出可调用的 C 函数指针；其 native 端 getCallbackHandler 由随包
 *   `liblwjgl.dylib` 提供，已实测该库导出 `..._system_Callback_getCallbackHandler`）。
 *   ⇒ 本文件按官方 glfw3.h 的函数原型调用即可，闭包的 C ABI 与官方原型一致。
 *   ★线程安全★：sink 只在 pump 线程被调用；状态用 gLock 保护；持 gLock 时绝不调 sink/回调。
 *
 * ---------------------------------------------------------------------------
 * ⑤ 环境/纪律
 * ---------------------------------------------------------------------------
 *   · JNI 符号宿主 = 主可执行文件 Air2.app/Air2（由 A2Entry → A2NativeLibrary.load 显式 System.load，
 *     JavaApp/src/launcher/.../A2NativeLibrary.java:29），与 Java 侧注释（GLFW.java:535-537）一致。
 *   · 净室声明：本文件由 Air2 自研；未参考、未复制 Pojav / Boardwalk / Amethyst / LWJGL 的
 *     native 源码。ABI 依据 = 官方 glfw3.h 的公开函数原型（公开事实数据）+ 本仓 Java 覆盖层的
 *     调用面（行号见 ①）。
 *   · 许可：归 Air2 项目本人（本文件无 GPL 血缘；它服务的那 10 个 Java 类自带各自的上游许可声明）。
 * ============================================================================
 */
#include <jni.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#import <UIKit/UIKit.h>
#import "a2_glfw_window.h"
#import "a2_log.h"

// ============================================================================
//  适配层状态（全部由 gLock 保护；持锁时绝不进入 sink / Java 回调）
// ============================================================================
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

// 9 个 GLFW 回调槽（GLFW 语义：回调地址由 Java 侧给；本适配层只保管 + 派发）
enum {
    A2_CB_CHAR = 0,
    A2_CB_CHAR_MODS,
    A2_CB_CURSOR_ENTER,
    A2_CB_CURSOR_POS,
    A2_CB_FRAMEBUFFER_SIZE,
    A2_CB_KEY,
    A2_CB_MOUSE_BUTTON,
    A2_CB_SCROLL,
    A2_CB_WINDOW_SIZE,
    A2_CB_COUNT
};
static void *gSlots[A2_CB_COUNT];

static long   gNextHandle     = 1;   // pojavCreateContext 的句柄发号（0 保留给「无窗口」）
static long   gCurrentContext = 0;   // pojavGetCurrentContext / pojavMakeCurrent
static long   gShowingWindow  = 0;   // nglfwSetShowingWindow
static double gCursorX        = 0.0; // nglfwGetCursorPos(A) 的最近值（来自光标事件）
static double gCursorY        = 0.0;
static int    gGrabbing       = 0;   // CallbackBridge.nativeSetGrabbing
static long   gPumpCount      = 0;   // pojavPumpEvents 调用次数（判据日志用）
static long   gDispatched     = 0;   // 已派发进 Java 的事件条数（判据日志用）
static long   gSwapCount      = 0;   // pojavSwapBuffers 调用次数（判据日志用）
static int    gHintLogged     = 0;   // pojavSetWindowHint 日志上限（防刷屏）
static int    gScaleLogged    = 0;   // 无回调槽的事件类型只记一次

// ---------------------------------------------------------------------------
//  槽读写助手
// ---------------------------------------------------------------------------
static void *a2_cb_swap(int idx, void *cb) {
    pthread_mutex_lock(&gLock);
    void *old = gSlots[idx];
    gSlots[idx] = cb;
    pthread_mutex_unlock(&gLock);
    return old;
}

static void *a2_cb_get(int idx) {
    pthread_mutex_lock(&gLock);
    void *cb = gSlots[idx];
    pthread_mutex_unlock(&gLock);
    return cb;
}

// ---------------------------------------------------------------------------
//  事件 sink：把一条中立事件翻译成官方 glfw3.h 的回调 ABI 并调用 Java 侧地址
//  调用点：a2_glfw_window.m 的事件泵（经 a2_glfw_event_set_sink 注册，见 pojavInit）。
// ---------------------------------------------------------------------------
static void a2_overlay_dispatch(const A2GlfwEvent *ev, void *user) {
    (void) user;
    if (ev == NULL) {
        return;
    }
    void *win = (void *) (intptr_t) ev->window;

    switch (ev->type) {
        case A2_GLFW_EVENT_KEY: {
            void *cb = a2_cb_get(A2_CB_KEY);
            if (cb != NULL) {
                ((void (*)(void *, int, int, int, int)) cb)(win, ev->i0, ev->i1, ev->i2, ev->i3);
            }
            break;
        }
        case A2_GLFW_EVENT_MOUSE_BUTTON: {
            void *cb = a2_cb_get(A2_CB_MOUSE_BUTTON);
            if (cb != NULL) {
                ((void (*)(void *, int, int, int)) cb)(win, ev->i0, ev->i1, ev->i2);
            }
            break;
        }
        case A2_GLFW_EVENT_CURSOR_POS: {
            pthread_mutex_lock(&gLock);
            gCursorX = ev->d0;
            gCursorY = ev->d1;
            void *cb = gSlots[A2_CB_CURSOR_POS];
            pthread_mutex_unlock(&gLock);
            if (cb != NULL) {
                ((void (*)(void *, double, double)) cb)(win, ev->d0, ev->d1);
            }
            break;
        }
        case A2_GLFW_EVENT_CURSOR_ENTER: {
            void *cb = a2_cb_get(A2_CB_CURSOR_ENTER);
            if (cb != NULL) {
                ((void (*)(void *, int)) cb)(win, ev->i0);
            }
            break;
        }
        case A2_GLFW_EVENT_FRAMEBUFFER_SIZE: {
            void *cb = a2_cb_get(A2_CB_FRAMEBUFFER_SIZE);
            if (cb != NULL) {
                ((void (*)(void *, int, int)) cb)(win, ev->i0, ev->i1);
            }
            break;
        }
        case A2_GLFW_EVENT_WINDOW_SIZE: {
            void *cb = a2_cb_get(A2_CB_WINDOW_SIZE);
            if (cb != NULL) {
                ((void (*)(void *, int, int)) cb)(win, ev->i0, ev->i1);
            }
            break;
        }
        case A2_GLFW_EVENT_WINDOW_FOCUS:
        case A2_GLFW_EVENT_CONTENT_SCALE: {
            // 复用线覆盖层没有为这两类注册 native 回调（GLFW.java 的 native 面里没有
            // nglfwSetWindowFocusCallback / ContentScale）。→ 本层只记一次，不猜。
            pthread_mutex_lock(&gLock);
            int first = (gScaleLogged == 0);
            gScaleLogged = 1;
            pthread_mutex_unlock(&gLock);
            if (first) {
                a2_log_f(@"[A2-GLFW-PEER] 收到无回调槽的事件 type=%d window=%ld"
                         "（复用线未注册该类的 native 回调，按原样丢弃，不猜）",
                         ev->type, (long) ev->window);
            }
            break;
        }
        default: {
            break;
        }
    }

    pthread_mutex_lock(&gLock);
    gDispatched++;
    long n = gDispatched;
    pthread_mutex_unlock(&gLock);
    if (n == 1) {
        a2_log_f(@"[A2-GLFW-PEER] 首条事件已派发进 Java：type=%d window=%ld"
                 "（触摸/按键 → 中立事件层 → 官方 C 回调 ABI 的通道通则）",
                 ev->type, (long) ev->window);
    }
}

// ---------------------------------------------------------------------------
//  A 组：13 个 JNI 符号（表见文件头 ①A；表里每行都给 Java 声明行/调用行）
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetCharCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_CHAR, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 字符回调槽更新 window=%ld ptr=%p（上一槽=%p；"
             "软键盘字符的生产者属阶段 B，本槽先注册不派发）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetCharModsCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_CHAR_MODS, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 字符+mods 回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetCursorEnterCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_CURSOR_ENTER, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 光标进出回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetCursorPosCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_CURSOR_POS, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 光标位置回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetFramebufferSizeCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_FRAMEBUFFER_SIZE, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 帧缓冲尺寸回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetKeyCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_KEY, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 键盘回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetMouseButtonCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_MOUSE_BUTTON, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 鼠标按键回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetScrollCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_SCROLL, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 滚轮回调槽更新 window=%ld ptr=%p（上一槽=%p；"
             "滚轮的生产者 = 触控板/鼠标，Phase B）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetWindowSizeCallback
  (JNIEnv *env, jclass cls, jlong window, jlong ptr) {
    (void) env; (void) cls;
    void *old = a2_cb_swap(A2_CB_WINDOW_SIZE, (void *) (intptr_t) ptr);
    a2_log_f(@"[A2-GLFW-PEER] 窗口尺寸回调槽更新 window=%ld ptr=%p（上一槽=%p）",
             (long) window, (void *) (intptr_t) ptr, old);
    return (jlong) (intptr_t) old;
}

// glfwShowWindow（GLFW.java:1115）/ glfwDestroyWindow（GLFW.java:1087）
// ★只记录 + 记日志★：窗口的「可见」由中立层的 a2_glfw_window_create 在主队列 makeKeyAndVisible
// 完成（本层没有第二个可见性开关，避免造与中立层重复的状态）。
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow
  (JNIEnv *env, jclass cls, jlong window) {
    (void) env; (void) cls;
    pthread_mutex_lock(&gLock);
    gShowingWindow = (long) window;
    pthread_mutex_unlock(&gLock);
    a2_log_f(@"[A2-GLFW-PEER] nglfwSetShowingWindow window=%ld（窗口可见性由中立层建窗流程持有）",
             (long) window);
}

// 光标位置 → DoubleBuffer 版（GLFW.java:1229）。写入位置取 buffer 的当前 position（不是 base）。
static double *a2_direct_double_at(JNIEnv *env, jobject buf) {
    if (env == NULL || buf == NULL) {
        return NULL;
    }
    double *base = (double *) (*env)->GetDirectBufferAddress(env, buf);
    if (base == NULL) {
        return NULL;
    }
    jclass cls = (*env)->GetObjectClass(env, buf);
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return base;
    }
    jmethodID mpos = (*env)->GetMethodID(env, cls, "position", "()I");
    if (mpos == NULL) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, cls);
        return base;
    }
    jint pos = (*env)->CallIntMethod(env, buf, mpos);
    (*env)->DeleteLocalRef(env, cls);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return base;
    }
    return base + (pos > 0 ? (long) pos : 0L);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos
  (JNIEnv *env, jclass cls, jlong window, jobject xpos, jobject ypos) {
    (void) cls;
    (void) window;
    double x, y;
    pthread_mutex_lock(&gLock);
    x = gCursorX;
    y = gCursorY;
    pthread_mutex_unlock(&gLock);

    double *px = a2_direct_double_at(env, xpos);
    double *py = a2_direct_double_at(env, ypos);
    if (px != NULL) {
        px[0] = x;
    }
    if (py != NULL) {
        py[0] = y;
    }
}

// 光标位置 → double[] 版（GLFW.java:1453）
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA
  (JNIEnv *env, jclass cls, jlong window, jdoubleArray xpos, jdoubleArray ypos) {
    (void) cls;
    (void) window;
    if (env == NULL) {
        return;
    }
    double x, y;
    pthread_mutex_lock(&gLock);
    x = gCursorX;
    y = gCursorY;
    pthread_mutex_unlock(&gLock);

    if (xpos != NULL) {
        jdouble tmp[1];
        tmp[0] = x;
        (*env)->SetDoubleArrayRegion(env, xpos, 0, 1, tmp);
    }
    if (ypos != NULL) {
        jdouble tmp[1];
        tmp[0] = y;
        (*env)->SetDoubleArrayRegion(env, ypos, 0, 1, tmp);
    }
}

// MC 主动设置光标位置（GLFW.java:1236 的公有 native）。存起来供上面的读接口回读。
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos
  (JNIEnv *env, jclass cls, jlong window, jdouble xpos, jdouble ypos) {
    (void) env; (void) cls; (void) window;
    pthread_mutex_lock(&gLock);
    gCursorX = (double) xpos;
    gCursorY = (double) ypos;
    pthread_mutex_unlock(&gLock);
}

// ---------------------------------------------------------------------------
//  B 组：CallbackBridge 的 2 个 JNI 符号（声明行见文件头 ①B）
// ---------------------------------------------------------------------------
JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard
  (JNIEnv *env, jclass cls, jint action, jbyteArray copy) {
    (void) cls;
    if (env == NULL) {
        return NULL;
    }
    if (action == 2000) {                       // CallbackBridge.CLIPBOARD_COPY
        if (copy == NULL) {
            return NULL;
        }
        jsize len = (*env)->GetArrayLength(env, copy);
        jbyte *bytes = (*env)->GetByteArrayElements(env, copy, NULL);
        if (bytes == NULL) {
            (*env)->ExceptionClear(env);
            return NULL;
        }
        // Java 侧（GLFW.java:1257-1260）交来的是 memUTF8Safe 的 UTF-8 字节，
        // 可能带一个结尾 NUL ⇒ 去掉尾部 0，避免把 NUL 也贴进剪贴板。
        jsize n = len;
        while (n > 0 && bytes[n - 1] == 0) {
            n--;
        }
        NSString *text = [[NSString alloc] initWithBytes:bytes
                                                  length:(NSUInteger) n
                                                encoding:NSUTF8StringEncoding];
        (*env)->ReleaseByteArrayElements(env, copy, bytes, JNI_ABORT);
        if (text == nil) {
            a2_log_f(@"[A2-GLFW-PEER] 剪贴板写入跳过：字节不是合法 UTF-8（len=%d）", (int) len);
            return NULL;
        }
        [UIPasteboard generalPasteboard].string = text;
        a2_log_f(@"[A2-GLFW-PEER] 剪贴板已写入 %d 字节", (int) n);
        return NULL;
    }
    if (action == 2001) {                       // CallbackBridge.CLIPBOARD_PASTE
        NSString *text = [UIPasteboard generalPasteboard].string;
        if (text == nil) {
            return NULL;
        }
        return (*env)->NewStringUTF(env, text.UTF8String);
    }
    a2_log_f(@"[A2-GLFW-PEER] 剪贴板动作未知 action=%d（2000=COPY / 2001=PASTE）", (int) action);
    return NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing
  (JNIEnv *env, jclass cls, jboolean grab) {
    (void) env; (void) cls;
    pthread_mutex_lock(&gLock);
    int changed = (gGrabbing != (grab == JNI_TRUE ? 1 : 0));
    gGrabbing = (grab == JNI_TRUE) ? 1 : 0;
    int now = gGrabbing;
    pthread_mutex_unlock(&gLock);
    if (changed) {
        // 触发点：GLFW.java:1194-1203 glfwSetInputMode(GLFW_CURSOR, DISABLED/…) ⇒ MC 抓取鼠标。
        // 消费者（按抓取态切换触摸指针行为）随输入阶段 B 落位；此处只记录 + 可观察。
        a2_log_f(@"[A2-GLFW-PEER] 抓取态变更 grabbing=%d（供输入层读取；本层无第二份状态）", now);
    }
}

// ---------------------------------------------------------------------------
//  C 组：10 个 C 入口（非 JNI 符号；Java 侧 dlsym 取地址，见文件头 ①C）
//  签名逐字对齐 Java 调用点：pojavInit(jint)→jint、pojavCreateContext(jlong)→jlong、
//  pojavMakeCurrent/SwapBuffers/PumpEvents(jlong)→void、pojavSetWindowHint(jint,jint)/SwapInterval(jint)→void、
//  pojavGetCurrentContext()→jlong、pojavTerminate/RewindEvents()→void。
// ---------------------------------------------------------------------------
jint pojavInit(jint isCalledFromLWJGLX) {
    a2_glfw_event_set_sink(a2_overlay_dispatch, NULL);
    int ok = a2_glfw_window_platform_init();
    a2_log_f(@"[A2-GLFW-PEER] pojavInit(参数=%d) ⇒ %d：窗口/事件层就绪"
             "（复用线 Java 覆盖层的 native 对端；图形上下文归渲染器，本层不持有）",
             (int) isCalledFromLWJGLX, ok);
    return ok ? 1 : 0;
}

void pojavTerminate(void) {
    a2_glfw_event_set_sink(NULL, NULL);
    a2_glfw_window_platform_terminate();

    pthread_mutex_lock(&gLock);
    for (int i = 0; i < A2_CB_COUNT; i++) {
        gSlots[i] = NULL;
    }
    gCurrentContext = 0;
    gShowingWindow = 0;
    pthread_mutex_unlock(&gLock);

    a2_log_f(@"[A2-GLFW-PEER] pojavTerminate：窗口/事件层已结束（回调槽已清空）");
}

jlong pojavGetCurrentContext(void) {
    pthread_mutex_lock(&gLock);
    long ctx = gCurrentContext;
    pthread_mutex_unlock(&gLock);
    return (jlong) ctx;
}

// glfwCreateWindow → nglfwCreateContext → 这里（GLFW.java:1029-1033）。
// ★本层只造「中立窗口」并返回句柄★：尺寸/标题由中立层的建窗流程与 UIKit 决定（真实尺寸经
// 「窗口就绪」事件回到 Java），图形上下文不在这里创建（渲染器职责）。
jlong pojavCreateContext(jlong share) {
    pthread_mutex_lock(&gLock);
    long handle = gNextHandle++;
    pthread_mutex_unlock(&gLock);

    if (!a2_glfw_window_create(handle, 0, 0, "Minecraft")) {
        // 建窗被拒（平台未初始化/句柄重复/超上限）：如实返回 0，Java 侧按「无窗口」处理。
        a2_log_f(@"[A2-GLFW-PEER] pojavCreateContext 失败：中立层建窗被拒 handle=%ld", handle);
        return 0;
    }

    pthread_mutex_lock(&gLock);
    gCurrentContext = handle;
    pthread_mutex_unlock(&gLock);

    a2_log_f(@"[A2-GLFW-PEER] pojavCreateContext share=%ld ⇒ handle=%ld"
             "（已受理；真实尺寸以「窗口就绪」事件为准）", (long) share, handle);
    return (jlong) handle;
}

// ★渲染器交接点（本层刻意不做图形工作）★：绑定当前上下文属渲染器。
void pojavMakeCurrent(jlong window) {
    pthread_mutex_lock(&gLock);
    gCurrentContext = (long) window;
    pthread_mutex_unlock(&gLock);
    a2_log_f(@"[A2-GLFW-PEER] pojavMakeCurrent window=%ld（本层只记当前上下文；"
             "上下文绑定/呈现属渲染器）", (long) window);
}

// ★渲染器交接点★：呈现属渲染器；每帧都会调 ⇒ 只在首次打一行判据，不刷屏。
void pojavSwapBuffers(jlong window) {
    pthread_mutex_lock(&gLock);
    gSwapCount++;
    long n = gSwapCount;
    pthread_mutex_unlock(&gLock);
    if (n == 1) {
        a2_log_f(@"[A2-GLFW-PEER] pojavSwapBuffers 首次调用 window=%ld"
                 "（本层只保留 ABI 入口；呈现属渲染器）", (long) window);
    }
}

void pojavSwapInterval(jint interval) {
    a2_log_f(@"[A2-GLFW-PEER] pojavSwapInterval interval=%d（帧率/垂直同步属渲染器）", (int) interval);
}

// GLFW 窗口提示。本层不需要它们来建中立窗口 ⇒ 只记日志（不存一份没人读的表），
// 上限 32 行防刷屏；渲染器接线时若需要，再按「谁调它」补落地。
void pojavSetWindowHint(jint hint, jint value) {
    pthread_mutex_lock(&gLock);
    int idx = gHintLogged;
    if (idx < 32) {
        gHintLogged = idx + 1;
    }
    pthread_mutex_unlock(&gLock);
    if (idx < 32) {
        a2_log_f(@"[A2-GLFW-PEER] pojavSetWindowHint hint=0x%x value=%d", (unsigned int) hint, (int) value);
    } else if (idx == 32) {
        gHintLogged = 33;
        a2_log_f(@"[A2-GLFW-PEER] pojavSetWindowHint 日志已达上限 32 条，后续省略");
    }
}

// glfwPollEvents（GLFW.java:1150-1152）→ 中立层事件队列在此刻、本线程排空。
void pojavPumpEvents(jlong window) {
    pthread_mutex_lock(&gLock);
    gPumpCount++;
    long n = gPumpCount;
    pthread_mutex_unlock(&gLock);

    a2_glfw_event_pump();

    if (n == 1) {
        a2_log_f(@"[A2-GLFW-PEER] pojavPumpEvents 首次调用 window=%ld"
                 "（事件在 Java 线程上排空 ⇒ 回调同线程）", (long) window);
    }
}

// 本层事件语义 = pump 即全部消费（无「回退重放」需求）⇒ 空实现，保留符号满足 ABI。
void pojavRewindEvents(void) {
    static int logged = 0;
    if (logged == 0) {
        logged = 1;
        a2_log_f(@"[A2-GLFW-PEER] pojavRewindEvents：本层队列无回退语义 ⇒ 空实现（保留 ABI 入口）");
    }
}

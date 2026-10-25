/*
 * Air2 —— 自研 GLFW native 桥（阶段 A：窗口/事件/输入层的 JNI 入口）
 * ============================================================================
 * 文件：Natives/OwnGlfw/a2_own_glfw_bridge.m
 * 归属：Air2 自研线（[A2-OWNGLFW-1] 的 native 对端，本单 [A2-OWNGLFW-NATIVE-1]）。
 *
 * ★本文件只做一件事：把 Java 侧 org.lwjgl.glfw.GLFW 的 11 个私有 native
 *   原样转发给 Natives/Input 的自研窗口/事件/输入层，并把事件 upcall 回 Java。★
 *   本文件不含任何窗口/输入逻辑本身（那些在 Natives/Input 下的 .m 里），也不认识
 *   任何渲染后端（后端专有名一字不提；机器判据见 scripts/verify_ownglfw_native.py）。
 *
 * 与 Java 的一一对应（调用点 = JavaApp/src/ownglfw/org/lwjgl/glfw/GLFW.java 的声明）：
 *   nInit                -> 注册事件 sink + a2_glfw_window_platform_init
 *   nTerminate           -> a2_glfw_window_platform_terminate
 *   nCreateWindow        -> a2_glfw_window_create
 *   nDestroyWindow       -> a2_glfw_window_destroy
 *   nMakeContextCurrent  -> ★刻意空实现★（GL 上下文是渲染器的；本层不碰）
 *   nSwapBuffers         -> ★刻意空实现★（呈现是渲染器的）
 *   nSwapInterval        -> ★刻意空实现★（vsync/帧率是渲染器的）
 *   nPollEvents          -> a2_glfw_event_pump
 *   nWaitEvents          -> a2_glfw_event_wait
 *   nWaitEventsTimeout   -> a2_glfw_event_wait_timeout
 *   nPostEmptyEvent      -> a2_glfw_event_post_empty
 *
 * ★native → Java 的「回调桥」（接口契约的 Java 落地点）★
 *   事件在 pump 线程上逐个 upcall 到：
 *     org.lwjgl.glfw.GLFW.a2OwnGlfwDispatch(long window, int type,
 *                                           int i0, int i1, int i2, int i3,
 *                                           double d0, double d1)   // static void
 *   签名描述符 = (JIIIIIDD)V。
 *   ★该方法已落地★（自研 Java 线阶段 2：JavaApp/src/ownglfw/org/lwjgl/glfw/GLFW.java）。
 *   它在同一方法里把事件转成 LWJGL 回调（glfwSet*Callback 登记的那批）并同步 Java 状态；
 *   Java 侧一旦缺失/签名不符，本桥**一次性**报告并静默空转（绝不抛异常/不死锁）。
 *   两侧对齐由 JavaApp/scripts/ownglfw_verify.py 的「事件通道对齐」判据守住。
 *
 * 净室声明：未参考、未复制 Pojav / Boardwalk / Amethyst / LWJGL 的 native 源码。
 * 许可：归 Air2 项目本人；无 GPL 血缘。
 * ============================================================================
 */
#include <jni.h>
#include <string.h>
#include "a2_glfw_window.h"
#include "a2_glfw_trace.h"
#include "a2_log.h"

#define A2_OWN_GLFW_JAVA_CLASS     "org/lwjgl/glfw/GLFW"
#define A2_OWN_GLFW_JAVA_METHOD    "a2OwnGlfwDispatch"
#define A2_OWN_GLFW_JAVA_SIG       "(JIIIIIDD)V"

// ---------------------------------------------------------------------------
// Java 侧引用（pump 线程解析一次，之后复用）
// ---------------------------------------------------------------------------
static jobject   gGlfwClassRef   = NULL;   // org.lwjgl.glfw.GLFW 的全局引用
static jmethodID gDispatchMethod = NULL;
static int       gDispatchLookup = 0;      // 0=未查 1=已就绪 2=已判定不存在（不再重查）

// pump 期间的本线程 JNIEnv（仅 pump/wait 系列设置；事件派发同步 ⇒ 安全）
static JNIEnv   *gPumpEnv        = NULL;

// ---------------------------------------------------------------------------
// 事件 sink：把一条 GLFW 语义事件 upcall 进 Java
// ---------------------------------------------------------------------------
static void a2_own_glfw_java_sink(const A2GlfwEvent *event, void *user) {
    (void) user;
    JNIEnv *env = gPumpEnv;
    if (env == NULL || event == NULL) {
        return;
    }

    if (gDispatchLookup == 0) {
        jclass cls = (*env)->FindClass(env, A2_OWN_GLFW_JAVA_CLASS);
        if (cls == NULL) {
            (*env)->ExceptionClear(env);
            gDispatchLookup = 2;
            a2_log_f(@"[A2-GLFW] native→Java 事件落地点缺失：未找到 %s."
                     "a2OwnGlfwDispatch（阶段 2 由自研 Java 线落；在此之前事件通道空转）",
                     A2_OWN_GLFW_JAVA_CLASS);
        } else {
            jmethodID mid = (*env)->GetStaticMethodID(env, cls,
                                                      A2_OWN_GLFW_JAVA_METHOD,
                                                      A2_OWN_GLFW_JAVA_SIG);
            if (mid == NULL) {
                (*env)->ExceptionClear(env);
                gDispatchLookup = 2;
                a2_log_f(@"[A2-GLFW] native→Java 事件落地点签名不匹配：期望 static void %s("
                         "long,int,int,int,int,int,double,double) 描述符 %s",
                         A2_OWN_GLFW_JAVA_METHOD, A2_OWN_GLFW_JAVA_SIG);
            } else {
                gGlfwClassRef   = (*env)->NewGlobalRef(env, cls);
                gDispatchMethod = mid;
                gDispatchLookup = 1;
                a2_log_f(@"[A2-GLFW] native→Java 事件落地点已绑定：%s.%s %s ✓",
                         A2_OWN_GLFW_JAVA_CLASS, A2_OWN_GLFW_JAVA_METHOD,
                         A2_OWN_GLFW_JAVA_SIG);
            }
            (*env)->DeleteLocalRef(env, cls);
        }
    }

    if (gDispatchLookup != 1 || gGlfwClassRef == NULL) {
        return;
    }

    (*env)->CallStaticVoidMethod(env, gGlfwClassRef, gDispatchMethod,
                                 (jlong)   event->window,
                                 (jint)    event->type,
                                 (jint)    event->i0,
                                 (jint)    event->i1,
                                 (jint)    event->i2,
                                 (jint)    event->i3,
                                 (jdouble) event->d0,
                                 (jdouble) event->d1);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
}

// ---------------------------------------------------------------------------
// 11 个 JNI 符号（与 GLFW.java 的 private static native 一一对应）
// ---------------------------------------------------------------------------
JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nInit
  (JNIEnv* env, jclass cls) {
    (void) cls;
    (void) env;
    a2_glfw_event_set_sink(a2_own_glfw_java_sink, NULL);
    if (!a2_glfw_window_platform_init()) {
        return JNI_FALSE;
    }
    a2_log_f(@"[A2-GLFW] nInit：窗口/事件层就绪（pump 线程 upcall Java；渲染后端与本层无关）");
    return JNI_TRUE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nTerminate
  (JNIEnv* env, jclass cls) {
    (void) cls;
    a2_glfw_window_platform_terminate();
    if (gGlfwClassRef != NULL && env != NULL) {
        (*env)->DeleteGlobalRef(env, gGlfwClassRef);
    }
    gGlfwClassRef   = NULL;
    gDispatchMethod = NULL;
    gDispatchLookup = 0;
    a2_log_f(@"[A2-GLFW] nTerminate：窗口/事件层已结束");
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nCreateWindow
  (JNIEnv* env, jclass cls, jlong window, jint width, jint height, jstring title) {
    (void) cls;
    // ★[A2-GLFW-TRACE]★ 黑屏卡死定位：只有 enter 没 exit = 卡在建窗里（主队列那段 UIKit 工作）。
    long long trT0 = a2_glfw_tr_us();
    unsigned long long trTid = a2_glfw_tr_tid();
    a2_log_f(@"[A2-GLFW-TRACE] enter glfwCreateWindow tid=%llu window=%lld w=%d h=%d",
             trTid, (long long) window, (int) width, (int) height);
    char titleUtf[256];
    titleUtf[0] = '\0';
    if (env != NULL && title != NULL) {
        const char *utf = (*env)->GetStringUTFChars(env, title, NULL);
        if (utf != NULL) {
            strncpy(titleUtf, utf, sizeof(titleUtf) - 1);
            titleUtf[sizeof(titleUtf) - 1] = '\0';
            (*env)->ReleaseStringUTFChars(env, title, utf);
        }
    }
    int ok = a2_glfw_window_create((long) window, (int) width, (int) height, titleUtf);
    if (!ok) {
        a2_log_f(@"[A2-GLFW] nCreateWindow 失败 window=%ld %dx%d",
                 (long) window, (int) width, (int) height);
        a2_log_f(@"[A2-GLFW-TRACE] exit glfwCreateWindow tid=%llu rc=0 ms=%lld",
                 trTid, a2_glfw_tr_ms(trT0));
        return JNI_FALSE;
    }
    a2_log_f(@"[A2-GLFW] nCreateWindow 受理 window=%ld %dx%d title=\"%s\""
             "（UIKit 建窗异步到主队列；就绪后另有「窗口就绪」日志）",
             (long) window, (int) width, (int) height, titleUtf);
    a2_log_f(@"[A2-GLFW-TRACE] exit glfwCreateWindow tid=%llu rc=1 ms=%lld",
             trTid, a2_glfw_tr_ms(trT0));
    return JNI_TRUE;
}

// ★2026-10-18★ metallum（Metal 后端）需要真实的 UIView 去挂 CAMetalLayer：
//   MetalBackend 调 GLFWNativeCocoa.glfwGetCocoaWindow/View，拿不到就 throw
//   "glfwGetCocoaWindow returned null"，表现为黑屏 + 截图时 SIGSEGV。
//   这两条把「本层建出来的宿主 UIView/UIWindow」如实回报（调用方只借用指针，不改所有权）。
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFWNativeCocoa_glfwGetCocoaWindow0
    (JNIEnv *env, jclass cls, jlong window) {
    (void) env; (void) cls;
    A2GlfwSurface surf;
    if (a2_glfw_window_surface((long) window, &surf) != 1) return 0;
    return (jlong) (intptr_t) surf.nativeWindow;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFWNativeCocoa_glfwGetCocoaView0
    (JNIEnv *env, jclass cls, jlong window) {
    (void) env; (void) cls;
    A2GlfwSurface surf;
    if (a2_glfw_window_surface((long) window, &surf) != 1) return 0;
    return (jlong) (intptr_t) surf.nativeView;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_glfw_GLFWNativeCocoa_glfwGetCocoaMonitor0
    (JNIEnv *env, jclass cls, jlong monitor) {
    (void) env; (void) cls; (void) monitor;
    return 0;   // iOS 无 NSScreen；返回 0 = 无显示器句柄（调用方已按 0 处理）
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nDestroyWindow
  (JNIEnv* env, jclass cls, jlong window) {
    (void) env;
    (void) cls;
    a2_glfw_window_destroy((long) window);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nMakeContextCurrent
  (JNIEnv* env, jclass cls, jlong window) {
    (void) env;
    (void) cls;
    (void) window;
    // ★[A2-GLFW-TRACE]★ 卡在这里 = 渲染器 eglMakeCurrent 没返回（后端初始化卡死）。
    long long trT0 = a2_glfw_tr_us();
    unsigned long long trTid = a2_glfw_tr_tid();
    a2_log_f(@"[A2-GLFW-TRACE] enter glfwMakeContextCurrent tid=%llu window=%lld",
             trTid, (long long) window);
    // ★2026-10-18★ 不再空实现：MC 在渲染线程上调用它后立刻要 GL.createCapabilities，
    //   必须在这一线程把 EGL 上下文设为 current（真机否则报
    //   "There is no OpenGL context current in the current thread"）。
    extern int a2_gl_bridge_make_current(void);
    int rc = a2_gl_bridge_make_current();
    a2_log_f(@"[A2-GLFW] nMakeContextCurrent window=%lld rc=%d", (long long) window, rc);
    a2_log_f(@"[A2-GLFW-TRACE] exit glfwMakeContextCurrent tid=%llu rc=%d ms=%lld",
             trTid, rc, a2_glfw_tr_ms(trT0));
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nSwapBuffers
  (JNIEnv* env, jclass cls, jlong window) {
    (void) env;
    (void) cls;
    // ★刻意空实现★：呈现是渲染器的事（本层与渲染后端解耦）。
    // ★[A2-GLFW-TRACE]★ 每帧都调 ⇒ 只打前 20 次（超过 100ms 的慢调用另计，不受限）。
    static unsigned long trSwapN = 0;
    unsigned long n = ++trSwapN;
    long long trT0 = a2_glfw_tr_us();
    unsigned long long trTid = a2_glfw_tr_tid();
    if (n <= 20) {
        a2_log_f(@"[A2-GLFW-TRACE] enter glfwSwapBuffers tid=%llu window=%lld n=%lu",
                 trTid, (long long) window, n);
    }
    long long ms = a2_glfw_tr_ms(trT0);
    if (n <= 20 || ms >= 100) {
        a2_log_f(@"[A2-GLFW-TRACE] exit glfwSwapBuffers tid=%llu rc=0 ms=%lld n=%lu%s",
                 trTid, ms, n, (n > 20) ? "（慢调用，超 20 次仍打）" : "");
    }
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nSwapInterval
  (JNIEnv* env, jclass cls, jint interval) {
    (void) env;
    (void) cls;
    (void) interval;
    // ★刻意空实现★：垂直同步/帧率由渲染器决定。
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nPollEvents
  (JNIEnv* env, jclass cls) {
    (void) cls;
    // ★[A2-GLFW-TRACE]★ 每帧都调 ⇒ 只打前 20 次；★卡在这里 = 事件 pump 里的 Java upcall 没返回★。
    static unsigned long trPollN = 0;
    unsigned long n = ++trPollN;
    long long trT0 = a2_glfw_tr_us();
    unsigned long long trTid = a2_glfw_tr_tid();
    if (n <= 20) {
        a2_log_f(@"[A2-GLFW-TRACE] enter glfwPollEvents tid=%llu n=%lu", trTid, n);
    }
    gPumpEnv = env;
    a2_glfw_event_pump();
    gPumpEnv = NULL;
    long long ms = a2_glfw_tr_ms(trT0);
    if (n <= 20 || ms >= 100) {
        a2_log_f(@"[A2-GLFW-TRACE] exit glfwPollEvents tid=%llu rc=0 ms=%lld n=%lu%s",
                 trTid, ms, n, (n > 20) ? "（慢调用，超 20 次仍打）" : "");
    }
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nWaitEvents
  (JNIEnv* env, jclass cls) {
    (void) cls;
    gPumpEnv = env;
    a2_glfw_event_wait();
    gPumpEnv = NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nWaitEventsTimeout
  (JNIEnv* env, jclass cls, jdouble timeout) {
    (void) cls;
    gPumpEnv = env;
    a2_glfw_event_wait_timeout((double) timeout);
    gPumpEnv = NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nPostEmptyEvent
  (JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
    a2_glfw_event_post_empty();
}

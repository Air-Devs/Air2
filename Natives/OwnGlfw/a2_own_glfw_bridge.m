/*
 * Air2 —— 自研 GLFW native 桥（阶段 1 · 最小集）
 * ============================================================================
 * 文件：Natives/OwnGlfw/a2_own_glfw_bridge.m
 * 归属：Air2 自研线（[A2-OWNGLFW-1]）。净室实现——未参考 Pojav/Boardwalk/Amethyst
 *       的 native 源码；本文件与 Java 侧 org/lwjgl/glfw/GLFW.java 的私有 native
 *       一一对应（11 个符号）。
 * 许可：归 Air2 项目本人；无 GPL 血缘。
 *
 * 范围（阶段 1，只做「能编译 + 能启动最小窗口/上下文」）：
 *   nInit / nTerminate / nCreateWindow / nDestroyWindow / nMakeContextCurrent /
 *   nSwapBuffers / nSwapInterval / nPollEvents / nWaitEvents / nWaitEventsTimeout /
 *   nPostEmptyEvent
 *   这是「窗口/上下文/事件循环」的最小骨架。事件泵、IME、HID→键码表、EGL/Metal
 *   上下文创建等属阶段 2+，本文件不做（★不提前实现没人调的接口★）。
 *
 * 说明：本文件刻意只用 C 语言构造（不含 ObjC/Foundation 调用），因此既能作为
 *       iOS 目标的 .m 编译，也能用纯 C 编译器语法检查（便于无 Mac 时自证）。
 *       阶段 2 再在 nCreateWindow/nMakeContextCurrent 内接 UIKit/EGL/MetalANGLE。
 * ============================================================================
 */
#include <jni.h>
#include <string.h>

#define A2_MAX_WINDOWS 16

typedef struct A2OwnWindow {
    jlong    handle;
    jint     width;
    jint     height;
    jboolean created;
} A2OwnWindow;

static jboolean     gInitialized    = JNI_FALSE;
static jlong        gCurrentContext = 0;
static int          gSwapInterval   = 1;
static A2OwnWindow  gWindows[A2_MAX_WINDOWS];
static int          gWindowCount    = 0;

static A2OwnWindow* a2_findWindow(jlong handle) {
    int i;
    for (i = 0; i < gWindowCount; ++i) {
        if (gWindows[i].created == JNI_TRUE && gWindows[i].handle == handle) {
            return &gWindows[i];
        }
    }
    return 0;
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nInit
  (JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
    if (gInitialized == JNI_TRUE) {
        return JNI_TRUE;
    }
    gInitialized = JNI_TRUE;
    gWindowCount = 0;
    gCurrentContext = 0;
    return JNI_TRUE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nTerminate
  (JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
    gInitialized = JNI_FALSE;
    gWindowCount = 0;
    gCurrentContext = 0;
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nCreateWindow
  (JNIEnv* env, jclass cls, jlong window, jint width, jint height, jstring title) {
    A2OwnWindow* w;
    (void) cls;
    (void) title; /* 阶段 1 不消费标题文本；阶段 2 交给 UIKit。 */
    if (env != 0 && title != 0) {
        const char* utf = (*env)->GetStringUTFChars(env, title, 0);
        if (utf != 0) {
            (*env)->ReleaseStringUTFChars(env, title, utf);
        }
    }
    if (gInitialized != JNI_TRUE || gWindowCount >= A2_MAX_WINDOWS) {
        return JNI_FALSE;
    }
    w = &gWindows[gWindowCount];
    w->handle = window;
    w->width = width;
    w->height = height;
    w->created = JNI_TRUE;
    gWindowCount++;
    return JNI_TRUE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nDestroyWindow
  (JNIEnv* env, jclass cls, jlong window) {
    A2OwnWindow* w;
    (void) env;
    (void) cls;
    w = a2_findWindow(window);
    if (w != 0) {
        w->created = JNI_FALSE;
    }
    if (gCurrentContext == window) {
        gCurrentContext = 0;
    }
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nMakeContextCurrent
  (JNIEnv* env, jclass cls, jlong window) {
    (void) env;
    (void) cls;
    gCurrentContext = window;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nSwapBuffers
  (JNIEnv* env, jclass cls, jlong window) {
    (void) env;
    (void) cls;
    (void) window;
    /* 阶段 2：在此做 EGL/Metal 呈现。 */
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nSwapInterval
  (JNIEnv* env, jclass cls, jint interval) {
    (void) env;
    (void) cls;
    gSwapInterval = interval;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nPollEvents
  (JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
    /* 阶段 2：在此泵输入/触摸事件并回调 Java 侧。 */
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nWaitEvents
  (JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nWaitEventsTimeout
  (JNIEnv* env, jclass cls, jdouble timeout) {
    (void) env;
    (void) cls;
    (void) timeout;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nPostEmptyEvent
  (JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
}

// ============================================================================
//  Natives/Input/a2_sdl_input.m  —— 26.3 输入镜像桥（我们自己的实现）
// ----------------------------------------------------------------------------
//  MC 26.3 的窗口/输入栈从 GLFW 换成 SDL3。我们的控件发的是 GLFW 事件
//  （a2_glfw_input_post_*）⇒ 26.3 收不到 ⇒ 画面正常但点屏幕没反应。
//
//  做法：用 JNI_GetCreatedJavaVMs 拿已建好的 VM → 找 agent 提供的
//  com.metallum.agent.SdlInputBridge → 调 dispatch(IIIII)V 把同一份输入
//  镜像进 MC 的 SDL 事件队列。
//
//  对 26.2 及更早：没有该类 ⇒ 查类失败后永久关闭，完全静默（零影响）。
// ============================================================================

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>
#include <jni.h>

#include "a2_sdl_input.h"

// 与 agent 侧 SdlInputBridge 常量一致
static const int kA2SdlCursorPos   = 1003;
static const int kA2SdlMouseButton = 1006;
static const int kA2SdlKey         = 1005;

static JavaVM   *gVM = NULL;
static jclass    gBridgeClass = NULL;
static jmethodID gDispatchMid = NULL;
static int       gState = 0;   // 0=未尝试 1=可用 -1=不可用

static int a2_sdl_prepare(void) {
    if (gState != 0) return gState == 1;

    typedef jint (*a2_get_vms_fn)(JavaVM **, jsize, jsize *);
    a2_get_vms_fn getVMs = (a2_get_vms_fn)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    if (getVMs == NULL) { gState = -1; return 0; }

    jsize n = 0;
    if (getVMs(&gVM, 1, &n) != JNI_OK || gVM == NULL || n < 1) { gState = -1; return 0; }

    JNIEnv *env = NULL;
    if ((*gVM)->AttachCurrentThread(gVM, (void **)&env, NULL) != JNI_OK || env == NULL) {
        gState = -1;
        return 0;
    }

    jclass cls = (*env)->FindClass(env, "com/metallum/agent/SdlInputBridge");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        gState = -1;
        NSLog(@"[A2-SDLIN] no SdlInputBridge (non-26.3) -> mirror disabled");
        return 0;
    }
    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "dispatch", "(IIIII)V");
    if (mid == NULL) {
        (*env)->ExceptionClear(env);
        gState = -1;
        return 0;
    }

    gBridgeClass = (jclass)(*env)->NewGlobalRef(env, cls);
    gDispatchMid = mid;
    gState = 1;
    NSLog(@"[A2-SDLIN] SdlInputBridge ready -> 触控镜像到 SDL 生效");
    return 1;
}

static void a2_sdl_call(int type, int i1, int i2, int i3, int i4) {
    if (!a2_sdl_prepare()) return;

    JNIEnv *env = NULL;
    if ((*gVM)->GetEnv(gVM, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*gVM)->AttachCurrentThread(gVM, (void **)&env, NULL) != JNI_OK) return;
    }
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gDispatchMid,
                                 (jint)type, (jint)i1, (jint)i2, (jint)i3, (jint)i4);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

void a2_sdl_input_cursor(double x, double y) {
    a2_sdl_call(kA2SdlCursorPos, (int)lround(x), (int)lround(y), 0, 0);
}

void a2_sdl_input_button(int button, int down) {
    int sdlButton = (button == 0) ? 1 : (button == 1 ? 3 : button + 1);
    a2_sdl_call(kA2SdlMouseButton, sdlButton, down ? 1 : 0, 0, 0);
}

static int a2_sdl_keycode_from_glfw(int key) {
    if (key >= 'A' && key <= 'Z') return key + 32;
    if (key >= '0' && key <= '9') return key;
    if (key == 32)  return 32;
    if (key == 256) return 27;
    if (key == 257) return 13;
    if (key == 258) return 9;
    if (key == 259) return 8;
    if (key >= 290 && key <= 301) {
        static const int fk[12] = {1073741882, 1073741883, 1073741884, 1073741885,
                                   1073741886, 1073741887, 1073741888, 1073741889,
                                   1073741890, 1073741891, 1073741892, 1073741893};
        return fk[key - 290];
    }
    if (key == 340) return 1073742049;
    if (key == 341) return 1073742048;
    if (key == 342) return 1073742050;
    return key;
}

void a2_sdl_input_key(int glfwKey, int down) {
    a2_sdl_call(kA2SdlKey, 0, a2_sdl_keycode_from_glfw(glfwKey), down ? 1 : 0, 0);
}

int a2_sdl_input_active(void) {
    return a2_sdl_prepare();
}

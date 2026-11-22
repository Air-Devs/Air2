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
static const int kA2SdlTextInput   = 1000;   // agent: pushText((char) i1)

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
    // GLFW: 0=左 1=右 2=中；SDL: 1=左 2=中 3=右（不是简单 +1）
    int sdlButton;
    switch (button) {
        case 0:  sdlButton = 1; break;
        case 1:  sdlButton = 3; break;
        case 2:  sdlButton = 2; break;
        default: sdlButton = button + 1; break;
    }
    a2_sdl_call(kA2SdlMouseButton, sdlButton, down ? 1 : 0, 0, 0);
}

static int a2_sdl_keycode_from_glfw(int key) {
    // GLFW 的可打印键与 ASCII 一致；SDL3 对字母键同样用小写 ASCII。
    if (key >= 'A' && key <= 'Z') return key + 32;
    if (key >= 32 && key <= 96)  return key;

    switch (key) {
        case 256: return 27;               // ESCAPE
        case 257: return 13;               // RETURN
        case 258: return 9;                // TAB
        case 259: return 8;                // BACKSPACE
        case 260: return 1073741897;       // INSERT
        case 261: return 127;              // DELETE（SDL3 用 0x7F 而非 scancode）
        case 262: return 1073741903;       // RIGHT
        case 263: return 1073741904;       // LEFT
        case 264: return 1073741905;       // DOWN
        case 265: return 1073741906;       // UP
        case 266: return 1073741899;       // PAGE_UP
        case 267: return 1073741902;       // PAGE_DOWN
        case 268: return 1073741898;       // HOME
        case 269: return 1073741901;       // END
        case 280: return 1073741881;       // CAPS_LOCK
        case 281: return 1073741895;       // SCROLL_LOCK
        case 282: return 1073741907;       // NUM_LOCK
        case 283: return 1073741894;       // PRINT_SCREEN
        case 284: return 1073741896;       // PAUSE
        case 340: return 1073742049;       // LEFT_SHIFT
        case 341: return 1073742048;       // LEFT_CONTROL
        case 342: return 1073742050;       // LEFT_ALT
        case 343: return 1073742051;       // LEFT_SUPER
        case 344: return 1073742053;       // RIGHT_SHIFT
        case 345: return 1073742052;       // RIGHT_CONTROL
        case 346: return 1073742054;       // RIGHT_ALT
        case 347: return 1073742055;       // RIGHT_SUPER
        case 348: return 1073741925;       // APPLICATION / MENU
        default: break;
    }

    if (key >= 290 && key <= 301) {        // F1..F12
        static const int fk[12] = {1073741882, 1073741883, 1073741884, 1073741885,
                                   1073741886, 1073741887, 1073741888, 1073741889,
                                   1073741890, 1073741891, 1073741892, 1073741893};
        return fk[key - 290];
    }

    if (key >= 320 && key <= 336) {        // GLFW KP_0..KP_EQUAL
        // SDL3 scancode：KP_0 = 98（不是 88）；顺序与 GLFW 320..336 不同，必须逐项列。
        static const int kp[17] = {
            1073741922,  // KP_0
            1073741913,  // KP_1
            1073741914,  // KP_2
            1073741915,  // KP_3
            1073741916,  // KP_4
            1073741917,  // KP_5
            1073741918,  // KP_6
            1073741919,  // KP_7
            1073741920,  // KP_8
            1073741921,  // KP_9
            1073741923,  // KP_DECIMAL
            1073741908,  // KP_DIVIDE
            1073741909,  // KP_MULTIPLY
            1073741910,  // KP_SUBTRACT
            1073741911,  // KP_ADD
            1073741912,  // KP_ENTER
            1073741927,  // KP_EQUAL
        };
        return kp[key - 320];
    }
    return key;
}

/// 26.3 的文本输入：agent 侧 pushText(char) 只写低 8 位，超过 ASCII 会变乱码，
/// 因此只镜像 1..127；非 ASCII 在 agent 升级前不发送（避免把 CJK 打成问号）。
void a2_sdl_input_text(int codepoint) {
    if (codepoint <= 0 || codepoint > 127) return;
    a2_sdl_call(kA2SdlTextInput, codepoint, 0, 0, 0);
}

void a2_sdl_input_key(int glfwKey, int down) {
    a2_sdl_call(kA2SdlKey, 0, a2_sdl_keycode_from_glfw(glfwKey), down ? 1 : 0, 0);
}

int a2_sdl_input_active(void) {
    return a2_sdl_prepare();
}

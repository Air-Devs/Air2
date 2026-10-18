//
//  environ_globals.m —— 遗留头的「唯一定义」落点
//
//  背景：environ.h / utils.h 是 Pojav 血统的头，里面**直接定义**了全局变量
//  （`atomic_size_t eventCounter;`、`BOOL debugLogEnabled, isJailbroken;` …）。
//  Clang 11 起默认 -fno-common ⇒ 每个 import 它的翻译单元都生成一份强符号，
//  链接期报几十个 duplicate symbol（_eventCounter / _cursorX / _debugLogEnabled …）。
//  修法：头文件里改成 extern（声明），定义集中在这里，保证全工程只有一份。
//

#import <Foundation/Foundation.h>
#import <jni.h>
#include <stdatomic.h>
#import "environ.h"
#import "utils.h"

// ---- environ.h ----
jclass class_CTCClipboard = 0;
jmethodID method_SystemClipboardDataReceived = 0;
atomic_size_t eventCounter = 0;
double cursorX = 0, cursorY = 0, cLastX = 0, cLastY = 0;
jmethodID method_internalWindowSizeChanged = 0;
jclass bridgeClazz = 0;
jclass vmGlfwClass = 0;
JNIEnv* runtimeJNIEnvPtr = 0;
long showingWindow = 0;
bool isInputReady = 0, isCursorEntered = 0, isUseStackQueueCall = 0;
int windowWidth = 0, windowHeight = 0;
int physicalWidth = 0, physicalHeight = 0;
float resolutionScale = 0;
BOOL virtualMouseEnabled = 0, isControlModifiable = 0;
uint64_t hwRedirectOrig[6], hwRedirectTarget[6] = {0};

// ---- utils.h ----
BOOL debugLogEnabled = 0, isJailbroken = 0;

// ---- GLFW 回调函数指针（environ.h 的 ADD_CALLBACK_WWIN 宏展开）----
GLFW_invoke_Char_func* GLFW_invoke_Char = 0;
GLFW_invoke_CharMods_func* GLFW_invoke_CharMods = 0;
GLFW_invoke_CursorEnter_func* GLFW_invoke_CursorEnter = 0;
GLFW_invoke_CursorPos_func* GLFW_invoke_CursorPos = 0;
GLFW_invoke_FramebufferSize_func* GLFW_invoke_FramebufferSize = 0;
GLFW_invoke_Key_func* GLFW_invoke_Key = 0;
GLFW_invoke_MouseButton_func* GLFW_invoke_MouseButton = 0;
GLFW_invoke_Scroll_func* GLFW_invoke_Scroll = 0;
GLFW_invoke_WindowPos_func* GLFW_invoke_WindowPos = 0;
GLFW_invoke_WindowSize_func* GLFW_invoke_WindowSize = 0;

// ---- 这几个之前被误判为"别处已定义"而删掉，实际只有引用、没有定义 ----
GLFWInputEvent events[8000] = {0};
int guiScale = 0;
jboolean isGrabbing = 0;
jbyte* keyDownBuffer = 0;
JavaVM* runtimeJavaVMPtr = 0;


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
GLFWInputEvent events[8000] = {0};
double cursorX = 0, cursorY = 0, cLastX = 0, cLastY = 0;
jmethodID method_internalWindowSizeChanged = 0;
jclass bridgeClazz = 0;
jclass vmGlfwClass = 0;
jboolean isGrabbing = 0;
jbyte* keyDownBuffer = 0;
JavaVM* runtimeJavaVMPtr = 0;
JNIEnv* runtimeJNIEnvPtr = 0;
long showingWindow = 0;
bool isInputReady = 0, isCursorEntered = 0, isUseStackQueueCall = 0;
int windowWidth = 0, windowHeight = 0;
int physicalWidth = 0, physicalHeight = 0;
int guiScale = 0;
float resolutionScale = 0;
BOOL virtualMouseEnabled = 0, isControlModifiable = 0;
uint64_t hwRedirectOrig[6], hwRedirectTarget[6] = {0};

// ---- utils.h ----
BOOL debugLogEnabled = 0, isJailbroken = 0;

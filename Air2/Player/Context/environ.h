//
//  environ.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
// Created by maks on 24.09.2022.
//

#ifndef POJAVLAUNCHER_ENVIRON_H
#define POJAVLAUNCHER_ENVIRON_H

#include <stdatomic.h>
#include "jni.h"

typedef struct {
    short type;
    union {
        int i1;
        float f1;
    };
    union {
        int i2;
        float f2;
    };
    short i3;
    short i4;
} GLFWInputEvent;

typedef void GLFW_invoke_Char_func(void* window, unsigned int codepoint);
typedef void GLFW_invoke_CharMods_func(void* window, unsigned int codepoint, int mods);
typedef void GLFW_invoke_CursorEnter_func(void* window, int entered);
typedef void GLFW_invoke_CursorPos_func(void* window, double xpos, double ypos);
typedef void GLFW_invoke_FramebufferSize_func(void* window, int width, int height);
typedef void GLFW_invoke_Key_func(void* window, int key, int scancode, int action, int mods);
typedef void GLFW_invoke_MouseButton_func(void* window, int button, int action, int mods);
typedef void GLFW_invoke_Scroll_func(void* window, double xoffset, double yoffset);
typedef void GLFW_invoke_WindowPos_func(void* window, int x, int y);
typedef void GLFW_invoke_WindowSize_func(void* window, int width, int height);

extern jclass class_CTCClipboard;
extern jmethodID method_SystemClipboardDataReceived;

//struct pojav_environ_s {
    //render_window_t* mainWindowBundle;
    //BOOL force_vsync;
    extern atomic_size_t eventCounter;
    extern GLFWInputEvent events[8000];
    extern double cursorX, cursorY, cLastX, cLastY;
    //jmethodID method_accessAndroidClipboard;
    //jmethodID method_onGrabStateChanged;
    //jmethodID method_glfwSetWindowAttrib;
    extern jmethodID method_internalWindowSizeChanged;
    extern jclass bridgeClazz;
    extern jclass vmGlfwClass;
    extern jboolean isGrabbing;
    extern jbyte* keyDownBuffer;
    extern JavaVM* runtimeJavaVMPtr;
    extern JNIEnv* runtimeJNIEnvPtr;
    //JavaVM* dalvikJavaVMPtr;
    //JNIEnv* dalvikJNIEnvPtr_ANDROID;
    extern long showingWindow;
    extern bool isInputReady, isCursorEntered, isUseStackQueueCall;
    //int savedWidth, savedHeight;
    extern int windowWidth, windowHeight;
    extern int physicalWidth, physicalHeight;
#define ADD_CALLBACK_WWIN(NAME) \
    extern GLFW_invoke_##NAME##_func* GLFW_invoke_##NAME;
    ADD_CALLBACK_WWIN(Char);
    ADD_CALLBACK_WWIN(CharMods);
    ADD_CALLBACK_WWIN(CursorEnter);
    ADD_CALLBACK_WWIN(CursorPos);
    ADD_CALLBACK_WWIN(FramebufferSize);
    ADD_CALLBACK_WWIN(Key);
    ADD_CALLBACK_WWIN(MouseButton);
    ADD_CALLBACK_WWIN(Scroll);
    ADD_CALLBACK_WWIN(WindowPos);
    ADD_CALLBACK_WWIN(WindowSize);

#undef ADD_CALLBACK_WWIN
//};

extern int guiScale;
extern float resolutionScale;
extern BOOL virtualMouseEnabled, isControlModifiable;

// 硬件断点重定向数组（同步自上游，用于非 TXM 的 iOS 26+ 设备 dlopen 重定向）
// 由 redirectFunctionHWBreakpoint 填充，由 catch_mach_exception_raise_state 读取
extern uint64_t hwRedirectOrig[6], hwRedirectTarget[6];

#endif //POJAVLAUNCHER_ENVIRON_H

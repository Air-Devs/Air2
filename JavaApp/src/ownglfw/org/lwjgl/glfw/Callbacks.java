/*
 * Air2 —— org.lwjgl.glfw.Callbacks（自研净室实现）
 * ============================================================================
 * 用途：MC 的 Window.close() 调 Callbacks.glfwFreeCallbacks(window) 释放全部回调。
 * 净室：独立编写，未参考 Pojav / Boardwalk / LWJGL 源码；仅依官方 javadoc 公共
 *       签名（public static void glfwFreeCallbacks(long)）。
 * 行为：对齐官方语义——依次把每个窗口回调置空并释放上一个回调对象（Callback#free），
 *       最后释放全局错误回调。
 * ============================================================================
 */
package org.lwjgl.glfw;

import org.lwjgl.system.Callback;

public final class Callbacks {

    private Callbacks() {
    }

    public static void glfwFreeCallbacks(long window) {
        free(GLFW.glfwSetWindowPosCallback(window, null));
        free(GLFW.glfwSetWindowSizeCallback(window, null));
        free(GLFW.glfwSetWindowCloseCallback(window, null));
        free(GLFW.glfwSetWindowRefreshCallback(window, null));
        free(GLFW.glfwSetWindowFocusCallback(window, null));
        free(GLFW.glfwSetWindowIconifyCallback(window, null));
        free(GLFW.glfwSetWindowMaximizeCallback(window, null));
        free(GLFW.glfwSetFramebufferSizeCallback(window, null));
        free(GLFW.glfwSetWindowContentScaleCallback(window, null));
        free(GLFW.glfwSetKeyCallback(window, null));
        free(GLFW.glfwSetCharCallback(window, null));
        free(GLFW.glfwSetCharModsCallback(window, null));
        free(GLFW.glfwSetMouseButtonCallback(window, null));
        free(GLFW.glfwSetCursorPosCallback(window, null));
        free(GLFW.glfwSetCursorEnterCallback(window, null));
        free(GLFW.glfwSetScrollCallback(window, null));
        free(GLFW.glfwSetDropCallback(window, null));
        free(GLFW.glfwSetPreeditCallback(window, null));
        free(GLFW.glfwSetIMEStatusCallback(window, null));
        free(GLFW.glfwSetPreeditCandidateCallback(window, null));

        free(GLFW.glfwSetErrorCallback(null));
    }

    private static void free(Callback callback) {
        if (callback != null) {
            callback.free();
        }
    }
}

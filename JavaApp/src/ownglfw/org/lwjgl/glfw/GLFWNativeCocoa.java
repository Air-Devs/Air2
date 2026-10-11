/*
 * Air2 —— org.lwjgl.glfw.GLFWNativeCocoa（自研净室实现 · iOS 替身）
 * ============================================================================
 * 为什么要有：MC 的 Blaze3D（macOS 分支）会调 glfwGetCocoaWindow/glfwGetCocoaView
 *   去拿 NSWindow/NSView。iOS 上没有 Cocoa 窗口对象，官方实现（在 jar 内）会走
 *   GLFW.getLibrary()/native 探测而失败 ⇒ 本类返回 0（NULL），让 MC 跳过 NSWindow 分支
 *   （与老树注释「return NULL instead to skip calling to NSWindow stuff」同义，
 *     但本实现为独立编写）。
 * 净室：未参考 Pojav/Boardwalk/LWJGL 源码；签名依官方 javadoc。
 * 官方签名（lwjgl-glfw.jar 实测）：
 *   public static int  glfwGetCocoaMonitor(long monitor)
 *   public static long glfwGetCocoaWindow(long window)
 *   public static long glfwGetCocoaView(long window)
 * ============================================================================
 */
package org.lwjgl.glfw;

public final class GLFWNativeCocoa {

    private GLFWNativeCocoa() {
    }

    public static int glfwGetCocoaMonitor(long monitor) {
        return 0;
    }

    public static long glfwGetCocoaWindow(long window) {
        return 0L;
    }

    public static long glfwGetCocoaView(long window) {
        return 0L;
    }
}

/*
 * Air2 —— org.lwjgl.glfw.GLFWNativeCocoa（自研净室实现 · iOS 替身）
 * ============================================================================
 * 为什么要有：MC 的 Blaze3D 与 metallum 的 Metal 后端会调
 *   glfwGetCocoaWindow/glfwGetCocoaView 去拿 NSWindow/NSView。
 *
 * ★2026-10-18 真机证据★ 早期实现直接 return 0（NULL）：
 *   · metallum 的 MetalBackend 拿不到视图 ⇒ 没有可挂 CAMetalLayer 的宿主
 *   ⇒ 表现：游戏起来了但★黑屏★，系统截图取快照时 SIGSEGV（ScreenshotServices）。
 *   现在改为 JNI 回报「a2_glfw_window 建出来的宿主 UIView / UIWindow」，
 *   只在拿不到表面时返回 0。
 *
 * 净室：未参考 Pojav/Boardwalk/LWJGL 源码；签名依官方 javadoc：
 *   public static int  glfwGetCocoaMonitor(long monitor)
 *   public static long glfwGetCocoaWindow(long window)
 *   public static long glfwGetCocoaView(long window)
 * ============================================================================
 */
package org.lwjgl.glfw;

public final class GLFWNativeCocoa {

    private GLFWNativeCocoa() {
    }

    /** iOS 无 NSScreen：恒 0（调用方按「无显示器句柄」处理）。 */
    public static int glfwGetCocoaMonitor(long monitor) {
        return glfwGetCocoaMonitor0(monitor);
    }

    /** 宿主 UIWindow 的指针（NSWindow 语义替身）；拿不到表面时为 0。 */
    public static long glfwGetCocoaWindow(long window) {
        return glfwGetCocoaWindow0(window);
    }

    /** 宿主 UIView 的指针（NSView 语义替身），Metal 层挂在它上面。 */
    public static long glfwGetCocoaView(long window) {
        return glfwGetCocoaView0(window);
    }

    private static native int  glfwGetCocoaMonitor0(long monitor);
    private static native long glfwGetCocoaWindow0(long window);
    private static native long glfwGetCocoaView0(long window);
}

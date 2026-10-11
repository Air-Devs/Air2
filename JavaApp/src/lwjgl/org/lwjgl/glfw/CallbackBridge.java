package org.lwjgl.glfw;

/**
 * Air2 —— LWJGL 补丁类第一片：GLFW 输入桥的 Java 壳。
 *
 * <p>归属（见 docs/ARCHITECTURE.md [LWJGL-PATCH] 与 D:\CTF\_AIR2_LAUNCH_PATH.md §①）：
 * {@code org.lwjgl.*} 补丁类落在 <b>Java 侧、独立 jar</b>（{@code air2-lwjgl-patch.jar}），
 * 排在 {@code libs/lwjgl-&lt;ver&gt;/*} <b>之前</b>（同名类覆盖）。Java 壳只声明契约；
 * 它的 {@code native} 方法实现（符号宿主）在 <b>主可执行文件</b>里（Natives 层）——
 * 这与分层规范不冲突：桥的两端分别由 VM（Java 类）与 Natives（符号）提供，经 JNI 相接。
 *
 * <p>为什么先做这一个：它是<b>非官方类</b>（官方 LWJGL 里没有 {@code CallbackBridge}），
 * 因此放在 classpath 最前也<b>不可能遮蔽</b>官方同名类 ⇒ 零回归风险，可以作为
 * 「jar 机制 + classpath 归属 + 随包」这条通路的第一个可验证产物。
 * 其余补丁类（会覆盖官方同名类）逐条列在 jar 内的
 * {@code META-INF/air2-lwjgl-patch.list}，等真正接线输入桥时再逐个落位 ——
 * 一次性塞入半成品覆盖类会把 LWJGL 的类初始化打坏，比不塞更糟。
 *
 * <p>本文件为净室实现：只按「native 侧要提供哪些符号」反推出的最小契约，
 * 不含任何 Pojav/Boardwalk 代码。
 */
public final class CallbackBridge {

    // ---- 剪贴板动作（native 侧约定值）----
    public static final int CLIPBOARD_COPY = 2000;
    public static final int CLIPBOARD_PASTE = 2001;

    // ---- 输入事件类型（native 侧约定值）----
    public static final int EVENT_TYPE_CHAR = 1000;
    public static final int EVENT_TYPE_CHAR_MODS = 1001;
    public static final int EVENT_TYPE_CURSOR_ENTER = 1002;
    public static final int EVENT_TYPE_CURSOR_POS = 1003;
    public static final int EVENT_TYPE_FRAMEBUFFER_SIZE = 1004;
    public static final int EVENT_TYPE_KEY = 1005;
    public static final int EVENT_TYPE_MOUSE_BUTTON = 1006;
    public static final int EVENT_TYPE_SCROLL = 1007;
    public static final int EVENT_TYPE_WINDOW_SIZE = 1008;

    /** 抓取状态事件（触控层用）。 */
    public static final int EVENT_GRAB_STATE = 0;

    /** 输入调试日志开关（默认关；`-Dglfwstub.debugInput=true` 打开）。 */
    public static final boolean INPUT_DEBUG_ENABLED;

    static {
        INPUT_DEBUG_ENABLED = Boolean.parseBoolean(System.getProperty("glfwstub.debugInput", "false"));
    }

    private CallbackBridge() {
    }

    /**
     * 剪贴板读写。action = {@link #CLIPBOARD_COPY} / {@link #CLIPBOARD_PASTE}；
     * {@code copy} 仅拷贝时携带内容。
     *
     * <p>符号宿主：主可执行文件（Natives/Input 的 CallbackBridge 实现）。
     */
    public static native String nativeClipboard(int action, byte[] copy);

    /** 设置指针抓取状态（触控层据此显示/隐藏准星与摇杆）。 */
    public static native void nativeSetGrabbing(boolean grab);

    /**
     * 显式同步 MC 1.21.9+ 的 modifier 缓存。
     *
     * <p>背景：MC 1.21.9+ 不再只依赖 key 回调里的 mods 参数，而是通过
     * {@code InputConstants.isKeyDown(...)} 查询 modifier 状态；该状态在 MC 内部另有一份缓存，
     * 只喂 key 回调不更新它 ⇒ 需要由 native 侧经 JNI 回调进来显式 setModifiers。
     */
    public static native void nativeSetModifiers(int mods);
}

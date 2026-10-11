package org.lwjgl.glfw;

import java.util.HashMap;
import java.util.Map;

/**
 * Air2 —— LWJGL 补丁类第一片：GLFW 窗口属性数据持有者。
 *
 * <p>同 {@link CallbackBridge}：这是<b>非官方类</b>（官方 LWJGL 里没有同名类），
 * 放在 classpath 最前不可能遮蔽官方实现 ⇒ 零回归风险。补丁版 {@code GLFW} 会用它记录
 * 窗口尺寸/位置/输入模式；本类只做数据，不含任何原生调用。
 *
 * <p>归属与剩余清单见 jar 内 {@code META-INF/air2-lwjgl-patch.list}。
 * 本文件为净室实现（不 import 任何启动器/游戏包）。
 */
public final class GLFWWindowProperties {

    public int width;
    public int height;
    public float x;
    public float y;
    public CharSequence title;
    public boolean shouldClose;
    public boolean isInitialSizeCalled;
    public boolean isCursorEntered;
    public long monitor;

    public final Map<Integer, Integer> inputModes = new HashMap<Integer, Integer>();
    public final Map<Integer, Integer> windowAttribs = new HashMap<Integer, Integer>();

    @Override
    public String toString() {
        return "GLFWWindowProperties{width=" + width + ", height=" + height
                + ", x=" + x + ", y=" + y + "}";
    }
}

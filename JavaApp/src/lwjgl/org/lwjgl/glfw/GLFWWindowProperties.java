/*
 * ★复用自【老树】D:\CTF\_510src\runtime_native（Amethyst-iOS / Pojav 系，GPL-3.0）★
 *   源路径: JavaApp/src/lwjgl/org/lwjgl/glfw/GLFWWindowProperties.java
 *   许可: GPL-3.0-or-later（与本仓 LICENSE 一致）；上游版权声明原样保留在本文件正文。
 *   落位: Air2 JavaApp/src/lwjgl/ → air2-lwjgl-patch.jar（classpath 最前；见 docs/ARCHITECTURE.md [LWJGL-PATCH]）
 *   Air2 适配: 见本文件内 ★A2-LWJGL-*★ 标记；无标记即与上游逐字节相同。
 */
package org.lwjgl.glfw;

import java.util.*;
// ★A2-LWJGL-3★ 删上游的 `import net.kdt.pojavlaunch.Tools;`：老树启动器类，本文件实下未使用（死 import）。

public class GLFWWindowProperties {
    public int width, height;
    public float x, y;
    public CharSequence title;
    public boolean shouldClose, isInitialSizeCalled, isCursorEntered;
    public long monitor;
    public Map<Integer, Integer> inputModes = new HashMap<>();
    public Map<Integer, Integer> windowAttribs = new HashMap<>();
    
    @Override
    public String toString() {
        return "width=" + width + ", " +
          "height=" + height + ", " +
          "x=" + x + ", " +
          "y=" + y + ", ";
    }
}

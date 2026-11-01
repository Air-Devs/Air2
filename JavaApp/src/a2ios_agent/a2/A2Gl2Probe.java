package a2;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.URL;
import java.security.CodeSource;

/**
 * ★[A2-GL2-PROBE] 只读取证探针 —— 固定管线入口到底绑定在哪★
 *
 * <p>注入方式（唯一）：{@link A2IosCompatAgent} 的规则 F —— 在 {@code org/lwjgl/opengl/GL11}
 * 的 {@code <clinit>} 末尾插一条 {@code INVOKESTATIC a2/A2Gl2Probe.run()V}。
 * ★没有第二个 agent★：本类随 {@code -javaagent:patchios_agent.jar} 一起进 JVM。
 *
 * <p>它回答两个问题：
 * <ol>
 *   <li>Java 侧：GL11 是从哪个 jar 加载的；这 7 个入口是不是 {@code native}（= 有没有 Java 侧函数指针）；</li>
 *   <li>原生侧：这 7 条 JNI 实现落在哪张镜像（dladdr），同一个 GL 名字在进程 flat namespace 里
 *       又会命中哪张镜像（这是「直取 ANGLE 入口」那条路的判据）。</li>
 * </ol>
 * 原生侧那一半由 {@code Natives/Renderer/a2_gl2_jni_probe.m} 的
 * {@code Java_a2_A2Gl2Probe_report} 提供。
 *
 * <p>★不改行为★：这里只打印；不注册、不改绑定、不动任何状态。
 * 默认关闭：只有 {@code A2_GL2_PROBE=1} 或 {@code A2_GL2_SHIM=1}（或 {@code -Da2.gl2.probe=1}）
 * 才输出明细，否则只留一行「探针关闭」。
 */
public final class A2Gl2Probe {

    /** 本轮接管的 7 个入口（与 Natives/Renderer/a2_gl2_jni_probe.m 的登记表同序）。 */
    private static final String[] GL_NAMES = {
            "glBegin", "glEnd", "glVertex3f", "glColor4f",
            "glMatrixMode", "glLoadIdentity", "glDrawArrays",
    };

    private static boolean alreadyRun;

    private A2Gl2Probe() {
    }

    /** 由注入进 {@code GL11.<clinit>} 的调用进入（方法必须是 public：跨包调用）。 */
    public static void run() {
        if (alreadyRun) {
            return;
        }
        alreadyRun = true;
        try {
            if (!wanted()) {
                System.out.println("[A2-GL2-PROBE] 探针关闭（A2_GL2_SHIM / A2_GL2_PROBE 均未设 ⇒ 不输出明细）");
                return;
            }
            System.out.println("[A2-GL2-PROBE] ===== 固定管线入口绑定取证开始 =====");
            ClassLoader loader = A2Gl2Probe.class.getClassLoader();
            Class<?> gl11 = Class.forName("org.lwjgl.opengl.GL11", false, loader);
            System.out.println("[A2-GL2-PROBE] GL11 来源 = " + originOf(gl11));
            Class<?> gl11c = null;
            try {
                gl11c = Class.forName("org.lwjgl.opengl.GL11C", false, loader);
                System.out.println("[A2-GL2-PROBE] GL11C 来源 = " + originOf(gl11c));
            } catch (Throwable t) {
                System.out.println("[A2-GL2-PROBE] 无 GL11C（glDrawArrays 的 native 声明无处可找）: " + t);
            }
            dumpMethods(gl11, gl11c, "org.lwjgl.opengl.GL11");
            String nativeReport = report();
            if (nativeReport != null) {
                System.out.print(nativeReport);
            } else {
                System.out.println("[A2-GL2-PROBE] 原生侧报告为空（主可执行文件未 load？）");
            }
            System.out.println("[A2-GL2-PROBE] ===== 取证结束 =====");
        } catch (Throwable t) {
            // 探针永远不许影响启动
            System.out.println("[A2-GL2-PROBE] 探针异常（已忽略）: " + t);
        }
    }

    private static boolean wanted() {
        if ("1".equals(System.getProperty("a2.gl2.probe"))) {
            return true;
        }
        return truthy(System.getenv("A2_GL2_PROBE")) || truthy(System.getenv("A2_GL2_SHIM"));
    }

    private static boolean truthy(String v) {
        return v != null && v.length() > 0 && !"0".equals(v);
    }

    private static String originOf(Class<?> c) {
        try {
            CodeSource cs = c.getProtectionDomain().getCodeSource();
            if (cs == null) {
                return "(无 CodeSource)";
            }
            URL loc = cs.getLocation();
            return (loc != null) ? loc.toString() : "(无 location)";
        } catch (Throwable t) {
            return "(读取失败: " + t + ")";
        }
    }

    /**
     * 打印每个入口的「谁声明、是不是 native」。
     * 判据：native=true ⇒ 调用不经过任何 Java 侧函数指针/解析器（本次取证的核心事实）。
     */
    private static void dumpMethods(Class<?> gl11, Class<?> gl11c, String gl11Name) {
        for (String name : GL_NAMES) {
            Method onGl11 = findByName(gl11, name);
            Method onGl11c = findByName(gl11c, name);
            Method hit = (onGl11 != null) ? onGl11 : onGl11c;
            if (hit == null) {
                System.out.println("[A2-GL2-PROBE] " + name + "：GL11/GL11C 都没有这个方法（LWJGL 版本不同？）");
                continue;
            }
            boolean isNative = Modifier.isNative(hit.getModifiers());
            String desc = descriptorOf(hit);
            String owner = hit.getDeclaringClass().getName();
            System.out.println("[A2-GL2-PROBE] " + name + " ← " + owner + "." + name + desc
                    + " native=" + isNative
                    + " 声明于=" + (gl11Name.equals(owner) ? "GL11" : "GL11C")
                    + "（同签名在 GL11=" + (onGl11 != null) + " / GL11C=" + (onGl11c != null) + "）");
        }
    }

    private static Method findByName(Class<?> c, String name) {
        if (c == null) {
            return null;
        }
        try {
            for (Method m : c.getDeclaredMethods()) {
                if (m.getName().equals(name)) {
                    return m;
                }
            }
        } catch (Throwable ignored) {
            // 反射被拒（少见）⇒ 当作没找到
        }
        return null;
    }

    /** 只给日志用：返回 JVM 描述符（如 (FFF)V）。 */
    private static String descriptorOf(Method m) {
        StringBuilder sb = new StringBuilder("(");
        for (Class<?> p : m.getParameterTypes()) {
            sb.append(typeCode(p));
        }
        return sb.append(')').append(typeCode(m.getReturnType())).toString();
    }

    private static char typeCode(Class<?> c) {
        if (c == void.class) return 'V';
        if (c == int.class) return 'I';
        if (c == float.class) return 'F';
        if (c == long.class) return 'J';
        if (c == double.class) return 'D';
        if (c == boolean.class) return 'Z';
        if (c == byte.class) return 'B';
        if (c == short.class) return 'S';
        if (c == char.class) return 'C';
        return c.isArray() ? '[' : 'L';
    }

    /**
     * 原生侧：逐条 dladdr 报告（实现见 {@code Natives/Renderer/a2_gl2_jni_probe.m}）。
     * 宿主约定：主可执行文件即 JNI 符号宿主（A2Entry → A2NativeLibrary.load）。
     */
    private static native String report();
}

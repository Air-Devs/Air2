package dev.airdevs.air2.launch;

import java.lang.reflect.Field;

/**
 * 只读诊断：打印 LWJGL 的 GL/GLES 提供者到底是谁。
 *
 * 背景（真机 hs_err）：MC 1.7.10 的 org.lwjgl.opengl.GL11.glLoadIdentity() 最终崩在
 * ANGLE 的 gl::ContextPrivateLoadIdentity，而 LWJGL 的 DebugLoader 又明确显示加载的是
 * libnggl4es_kw.dylib。两者矛盾 ⇒ 需要看清 LWJGL 内部把 glLoadIdentity 解析到了哪里。
 *
 * 纪律：全部反射 + try/catch，任何失败只打印原因，绝不影响启动。
 */
final class A2GlProviderProbe {

    private static final String TAG = "[A2-GL-PROVIDER] ";

    private A2GlProviderProbe() {}

    static void dump() {
        try {
            System.out.println(TAG + "Configuration.OPENGL_LIBRARY_NAME=" + staticField(
                    "org.lwjgl.system.Configuration", "OPENGL_LIBRARY_NAME"));
            System.out.println(TAG + "Configuration.OPENGLES_LIBRARY_NAME=" + staticField(
                    "org.lwjgl.system.Configuration", "OPENGLES_LIBRARY_NAME"));
        } catch (Throwable t) {
            System.out.println(TAG + "Configuration 读取失败: " + t);
        }

        dumpProvider("org.lwjgl.opengl.GL", "opengl");
        dumpProvider("org.lwjgl.opengles.GLES", "opengles");
    }

    private static Object staticField(String className, String field) {
        try {
            Class<?> c = Class.forName(className);
            Field f = c.getField(field);
            return String.valueOf(f.get(null));
        } catch (Throwable t) {
            return "(不可读: " + t.getClass().getSimpleName() + ")";
        }
    }

    private static void dumpProvider(String className, String label) {
        try {
            Class<?> c = Class.forName(className);
            Object p = c.getMethod("getFunctionProvider").invoke(null);
            System.out.println(TAG + label + " provider=" + p);

            // 拿它的内部字段：不同 LWJGL 版本字段名不同，全打一遍（限制长度）
            Class<?> pc = p.getClass();
            while (pc != null && pc != Object.class) {
                for (Field f : pc.getDeclaredFields()) {
                    try {
                        f.setAccessible(true);
                        Object v = f.get(p);
                        String s = String.valueOf(v);
                        if (s.length() > 200) s = s.substring(0, 200) + "…";
                        System.out.println(TAG + label + "  ." + f.getName() + " = " + s);
                    } catch (Throwable ignore) {
                        // 静态字段/不可读，跳过
                    }
                }
                pc = pc.getSuperclass();
            }
        } catch (Throwable t) {
            System.out.println(TAG + label + " provider 读取失败: " + t);
        }
    }
}

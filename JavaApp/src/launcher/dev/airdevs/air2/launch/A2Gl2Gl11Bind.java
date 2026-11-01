package dev.airdevs.air2.launch;

/**
 * ★[A2-GL2] 固定管线入口抢占的 Java 侧唯一落点★
 *
 * <p>为什么需要它：MC 1.12.2 的 {@code org.lwjgl.opengl.GL11.glBegin} 是
 * {@code public static native}（javap 实测），Java 侧既没有函数指针也不能改解析器 ——
 * 这条 native 的实现在 {@code liblwjgl_opengl.dylib}（{@code Java_org_lwjgl_opengl_GL11_glBegin}），
 * 而该 dylib 自身零外部导入、不链 libGLESv2、无 dlsym ⇒ 进程里没有可供 dyld 抢占的
 * {@code _glBegin} 符号。唯一确定的口子是 JNI 绑定本身：{@code RegisterNatives}。
 *
 * <p>本类只做一件事：把 {@code GL11} / {@code GL11C} 两个 Class 交给 native 侧
 * （{@code Natives/Renderer/a2_gl2_jni_bind.m}），由它逐条验签名后注册。
 * 是否真的注册由 native 侧判据决定（{@code A2_GL2_SHIM} / {@code A2_GL2_PROBE}），
 * 两者都没设时一个方法都不动 —— 默认行为与接入前逐字节一致。
 *
 * <p>★调用点★：{@link A2Entry#main(String[])} —— 追加完类路径之后、派发 MC 主类之前
 * （必须早于 MC 的第一次 GL 调用；GL11 在 MC 里是 {@code <clinit>} 才初始化，
 * 这里用 {@code initialize=false} 只加载不初始化，避免提前触发 LWJGL 的库加载）。
 */
final class A2Gl2Gl11Bind {

    private A2Gl2Gl11Bind() {
    }

    /**
     * 安装抢占（幂等；任何失败都只打日志，绝不阻断启动）。
     *
     * @param loader 系统类加载器（GL11 就在它上面）
     */
    static void bind(ClassLoader loader) {
        try {
            Class<?> gl11 = Class.forName("org.lwjgl.opengl.GL11", false, loader);
            Class<?> gl11c = null;
            try {
                gl11c = Class.forName("org.lwjgl.opengl.GL11C", false, loader);
            } catch (ClassNotFoundException e) {
                // glDrawArrays 的 native 声明在 GL11C 上；缺了就少接管一条，其余照旧。
                System.out.println("[A2-GL2] 缺 org.lwjgl.opengl.GL11C ⇒ 本次不接管 glDrawArrays: " + e);
            }
            int n = install(gl11, gl11c);
            System.out.println("[A2-GL2] Java 侧抢占完成：已注册 " + n + " 条固定管线入口");
        } catch (Throwable t) {
            System.out.println("[A2-GL2] 抢占安装异常（不阻断启动）: " + t);
        }
    }

    /**
     * native 侧（{@code Natives/Renderer/a2_gl2_jni_bind.m}）：
     * 逐条 {@code GetStaticMethodID} 验签名 + {@code RegisterNatives}。
     *
     * @return 成功注册的条数（0 = 未启用 / 全部失败）
     */
    private static native int install(Class<?> gl11, Class<?> gl11c);
}

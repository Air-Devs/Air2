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

    /**
     * ★FBO 入口（GL30/GL30C）★ 本层把 FBO 当默认帧缓冲：分配 id、恒报 COMPLETE、
     * Bind/Delete/Attach 记账后忽略。真机 lastlog-191：MC 1.12 建 FBO 时
     * `GL30C.nglGenFramebuffers` 踩空 SIGSEGV（pc=0），就是这里没接。
     */
    static void bindFbo(ClassLoader loader) {
        try {
            Class<?> gl30  = loadForOverride(loader, "org.lwjgl.opengl.GL30");
            Class<?> gl30c = loadForOverride(loader, "org.lwjgl.opengl.GL30C");
            bindFboNative(gl30, gl30c);
        } catch (Throwable t) {
            System.out.println("[A2-GL2-FBO] 绑定失败（不阻断）：" + t);
        }
    }

    private static native void bindFboNative(Class<?> gl30, Class<?> gl30c);

    /**
     * ★VBO（GL15）接管★ metallum 后端没有 GL 上下文，MC 用 VBO 会落到原生实现上
     * ⇒ 真机 lastlog-207 卡在 GL15C.glBindBuffer。这里把 GL15C 交给 native 侧用
     * 「CPU 影子缓冲」接管（bufferData 存副本、map 返回副本、指针偏移做翻译）。
     */
    static void bindVbo(ClassLoader loader) {
        try {
            Class<?> gl15c = loadForOverride(loader, "org.lwjgl.opengl.GL15C");
            bindVboNative(gl15c);
        } catch (Throwable t) {
            System.out.println("[A2-GL2-VBO] 绑定失败（不阻断）：" + t);
        }
    }

    private static native void bindVboNative(Class<?> gl15c);

    /** ★GL20（着色器）★ MC 1.12 调 glCreateShader 时落到 MG（无上下文）⇒ pc=0 崩溃。 */
    static void bindGl20(ClassLoader loader) {
        try {
            Class<?> gl20c = loadForOverride(loader, "org.lwjgl.opengl.GL20C");
            bindGl20Native(gl20c);
        } catch (Throwable t) {
            System.out.println("[A2-GL2-GL20] 绑定失败（不阻断）：" + t);
        }
    }

    private static native void bindGl20Native(Class<?> gl20c);

    /**
     * ★GL12C..GL32C 全量空实现★（兜底层）
     * MC 1.12 会碰 GL13/GL14/GL21/GL30/GL31 的边角入口；没接管 ⇒ LWJGL native 为 NULL
     * ⇒ JIT 间接调用 ⇒ SIGSEGV pc=0（lastlog-212/213）。
     * ★调用顺序★ 必须早于 bindFbo / bindVbo / bindGl20，让那些真实现覆盖这里。
     */
    static void bindExtras(ClassLoader loader) {
        String[] names = { "GL12C", "GL13C", "GL14C", "GL15C", "GL20C",
                           "GL21C", "GL30C", "GL31C", "GL32C" };
        Class<?>[] cls = new Class<?>[names.length];
        int n = 0;
        for (String nm : names) {
            try {
                cls[n++] = loadForOverride(loader, "org.lwjgl.opengl." + nm);
            } catch (Throwable t) {
                System.out.println("[A2-GL2-EXT] " + nm + " 取类失败（跳过）：" + t);
            }
        }
        Class<?>[] compact = new Class<?>[n];
        System.arraycopy(cls, 0, compact, 0, n);
        try {
            bindExtrasNative(compact, names);
        } catch (Throwable t) {
            System.out.println("[A2-GL2-EXT] 注册失败（不阻断）：" + t);
        }
    }

    private static native void bindExtrasNative(Class<?>[] classes, String[] names);

    private A2Gl2Gl11Bind() {
    }

    /**
     * 安装抢占（幂等；任何失败都只打日志，绝不阻断启动）。
     *
     * @param loader 系统类加载器（GL11 就在它上面）
     */
    /**
     * 取类：先尝试 **初始化**（让 LWJGL 的 <clinit> 先把 native 注册完，我们再覆盖），
     * 若初始化抛错（无 GL 上下文时 LWJGL 会 UnsupportedOperationException）⇒ 退回仅加载。
     * ★为什么需要它★ 真机 lastlog-199：GL11C 的 nglGetIntegerv 覆盖被它的 <clinit> 盖回去了。
     */
    private static Class<?> loadForOverride(ClassLoader loader, String name) throws ClassNotFoundException {
        try {
            return Class.forName(name, true, loader);
        } catch (Throwable t) {
            System.out.println("[A2-GL2] " + name + " 初始化失败（" + t + "）⇒ 退回仅加载");
            return Class.forName(name, false, loader);
        }
    }

    static void bind(ClassLoader loader) {
        try {
            // ★initialize=true★ 必须先让类初始化：LWJGL 的 native 是在各 GLxx 类的
            //   <clinit> 里 RegisterNatives 的；若只 load 不 initialize，等 MC 第一次用到
            //   GL11C 时它的 <clinit> 才跑，会把我们刚注册的覆盖又盖回去
            //   （真机现象：GL11 的入口生效、GL11C 的 nglGetIntegerv 覆盖失效）。
            Class<?> gl11 = loadForOverride(loader, "org.lwjgl.opengl.GL11");
            Class<?> gl11c = null;
            try {
                gl11c = loadForOverride(loader, "org.lwjgl.opengl.GL11C");   // 同上：先初始化再覆盖
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

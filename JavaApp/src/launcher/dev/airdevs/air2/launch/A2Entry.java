package dev.airdevs.air2.launch;

import java.io.File;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;

/**
 * Air2 启动核心 —— Java 侧入口（native 侧 {@code a2_run_main} 的派发目标）。
 *
 * <p>调用约定：native 侧构造 margv 形如
 * <pre>
 *   &lt;javaHome&gt;/bin/java &lt;-X/-D…&gt; -cp &lt;classpath&gt; \
 *       dev.airdevs.air2.launch.A2Entry --plan &lt;launch-plan.json&gt;
 * </pre>
 * R3（{@code a2_argbuilder}）把主类之后的 token 原样当程序参数保留，classpath 由 R4 注入；
 * {@code -Djava.system.class.loader=dev.airdevs.air2.launch.A2GameClassLoader} 是**推荐**的
 * 追加类路径方式（见 {@link A2GameClassLoader}），不带也能跑（走反射兜底）。
 *
 * <p>本类只做四件「非 Java 不可」的事，顺序不可换：
 * <ol>
 *   <li>System.load 主可执行文件（JNI 符号宿主）；</li>
 *   <li>落 JVM 系统属性（必须在 MC / LWJGL 任何类被加载之前）；</li>
 *   <li>把 MC 库追加到系统类路径（JNI_CreateJavaVM 之后唯一能改类路径的时机）；</li>
 *   <li>派发主类 main。</li>
 * </ol>
 *
 * <p>版本 JSON、账号、参数占位符替换、下载/UI 一律不在这里 —— 那些是 native 侧的事，
 * 本类只消费已经解析好的《启动计划》。见 {@link A2LaunchPlan}。
 */
public final class A2Entry {

    /** 启动计划参数名。 */
    public static final String PLAN_FLAG = "--plan";

    private A2Entry() {
    }

    public static void main(String[] argv) throws Exception {
        String planPath = planPath(argv);
        System.out.println("[A2-JAVA] A2Entry 启动；启动计划=" + planPath);

        A2LaunchPlan plan = A2LaunchPlan.load(new File(planPath));

        A2NativeLibrary.load(plan.nativeLibrary());
        // ★只读诊断★：打印 LWJGL 认定的 GL/GLES 提供者与库路径（不影响行为）
        System.out.println("[A2-JAVA] nativeLibrary 已加载 ⇒ 开始 GL provider 探测");
        A2GlProviderProbe.dump();
        System.out.println("[A2-JAVA] GL provider 探测结束");
        A2JvmProperties.apply(plan.properties());
        System.out.println("[A2-JAVA] JVM 属性已应用");

        ClassLoader loader = ClassLoader.getSystemClassLoader();
        URL[] extra = A2GameClasspath.toUrls(plan.classpath());
        // ★2026-11-08 真机（lastlog-279 watchdog）★ main 线程卡在
        //   java.util.jar.JarVerifier$VerifierStream.read ⇒ URLClassLoader.defineClass，
        //   即带签名的 jar（LWJGL 官方包）**逐类做签名校验** ⇒ 首帧被拖到 102 秒。
        //   MC 不依赖 jar 签名，启动前把 META-INF/*.SF|*.RSA|*.DSA|*.EC 去掉即可让 JVM 按未签名处理。
        a2StripJarSignatures(extra);
        appendToSystemClassLoader(loader, extra);

        // ★[A2-GL2] 固定管线入口抢占★（默认不生效：见 A2Gl2Gl11Bind 的判据说明）
        //   必须在这里：GL11 必须在 MC 第一次 GL 调用之前完成 RegisterNatives；
        //   又必须在类路径追加之后（GL11 在 libs/lwjgl-<ver>/lwjgl.jar 里）。
        A2Gl2Gl11Bind.bind(loader);
        // ★兜底层★：先把 GL12C..GL32C 全注册成空实现，再让下面几个真实现覆盖
        A2Gl2Gl11Bind.bindExtras(loader);
        A2Gl2Gl11Bind.bindFbo(loader);
        A2Gl2Gl11Bind.bindVbo(loader);
        A2Gl2Gl11Bind.bindGl20(loader);
        System.out.println("[A2-JAVA] GL2 抢占绑定返回（loader=" + loader.getClass().getName() + "）");

        System.out.println("[A2-JAVA] 追加类路径 " + extra.length + " 条；派发 " + plan.mainClass());
        System.out.println("[A2-JAVA] 即将派发主类（若无下一条日志 ⇒ 卡在主类静态初始化/GLFW/LWJGL 初始化）");
        startStallWatchdog();
        A2MainDispatcher.dispatch(plan.mainClass(), plan.arguments(), loader);
        System.out.println("[A2-JAVA] 主类正常返回");
    }

    /**
     * ★卡死诊断★ 15 秒后把全部 Java 线程的栈打出来（只在前 3 次触发时打印）。
     *
     * <p>为什么需要它：真机 1.12.2 出现过「主类派发后一条日志都没有、进程还活着」的情形，
     * 光看 lastlog 分不清是等锁、等 GL、还是死循环。栈是唯一能直接指认的方法。
     */
    private static void startStallWatchdog() {
        Thread wd = new Thread(new Runnable() {
            @Override
            public void run() {
                for (int round = 1; round <= 3; round++) {
                    try {
                        Thread.sleep(15000L);
                    } catch (InterruptedException e) {
                        return;
                    }
                    System.out.println("[A2-WD] 第 " + round + " 次线程栈（15s×" + round + "）：");
                    for (java.util.Map.Entry<Thread, StackTraceElement[]> e
                            : Thread.getAllStackTraces().entrySet()) {
                        Thread t = e.getKey();
                        System.out.println("[A2-WD] --- " + t.getName() + " [" + t.getState() + "]");
                        for (StackTraceElement f : e.getValue()) {
                            System.out.println("[A2-WD]     at " + f);
                        }
                    }
                }
            }
        }, "A2-StallWatchdog");
        wd.setDaemon(true);
        wd.start();
    }

    /**
     * 取 {@code --plan <path>}（顺序无关，取最后一个）。
     * 不给默认值：猜路径会把「漏传计划」伪装成「文件不存在」，真机上难判。
     */
    private static String planPath(String[] argv) throws A2LaunchFailure {
        String found = null;
        for (int i = 0; i + 1 < argv.length; i++) {
            if (PLAN_FLAG.equals(argv[i])) {
                found = argv[i + 1];
            }
        }
        if (found == null || found.isEmpty()) {
            throw new A2LaunchFailure("缺少启动计划参数：期望 \"--plan <launch-plan.json>\"");
        }
        return found;
    }

    /**
     * 把追加类路径挂到系统类加载器上。
     *
     * <p>为什么必须在 VM 内做：{@code JNI_CreateJavaVM} 创建时类路径就固定了，而 native 的
     * R3/R4 只覆盖 app 自带 {@code libs/} 与 {@code lwjgl-&lt;ver&gt;/}；MC 的
     * {@code {game}/libraries} 是 Maven 嵌套树，R4 的平铺扫描取不到，所以这一步只能在 Java 侧补。
     */
    private static void appendToSystemClassLoader(ClassLoader loader, URL[] urls) throws A2LaunchFailure {
        if (urls.length == 0) {
            return;
        }
        if (loader instanceof A2GameClassLoader) {
            ((A2GameClassLoader) loader).addUrls(urls);
            return;
        }
        // 兜底：Java 8 的系统加载器是 URLClassLoader 子类，addURL 为 protected ⇒ 只能反射。
        // 这条路径不是设计意图，只是没带 -Djava.system.class.loader 时不至于直接失败。
        // ★ Java 9+ 上反射会被模块系统挡下（java.base 不 opens java.net）⇒ 那时必须带 -D；
        //   消息里写清两条可行路，否则真机上只剩一句 InaccessibleObjectException。
        try {
            Method addUrl = URLClassLoader.class.getDeclaredMethod("addURL", URL.class);
            addUrl.setAccessible(true);
            for (URL u : urls) {
                addUrl.invoke(loader, u);
            }
        } catch (Exception e) {
            throw new A2LaunchFailure(
                    "无法向系统类加载器追加类路径。请让 margv 带 "
                            + "-Djava.system.class.loader=" + A2GameClassLoader.class.getName()
                            + "（Java 9+ 唯一可行路；Java 8 上也可用 --add-opens java.base/java.net=ALL-UNNAMED）",
                    e);
        }
    }

    /// 去掉 jar 里的签名文件（只删 META-INF/*.SF|*.RSA|*.DSA|*.EC，内容原样保留）。
    /// 调用点：main() 里 appendToSystemClassLoader 之前（见那里的注释）。
    private static void a2StripJarSignatures(URL[] urls) {
        int scanned = 0, stripped = 0;
        long t0 = System.currentTimeMillis();
        for (URL u : urls) {
            if (!"file".equals(u.getProtocol())) continue;
            File jar;
            try { jar = new File(u.toURI()); } catch (Throwable t) { continue; }
            String lower = jar.getName().toLowerCase(java.util.Locale.ROOT);
            if (!jar.isFile() || !lower.endsWith(".jar")) continue;
            scanned++;
            if (a2StripOneJar(jar)) stripped++;
        }
        if (scanned > 0) {
            System.out.println("[A2-JAVA] jar 签名剥离：扫描 " + scanned + "，改写 " + stripped
                + "，耗时 " + (System.currentTimeMillis() - t0) + " ms");
        }
    }

    private static boolean a2StripOneJar(File jar) {
        java.util.zip.ZipFile zf = null;
        try {
            zf = new java.util.zip.ZipFile(jar);
            boolean signed = false;
            for (java.util.Enumeration<? extends java.util.zip.ZipEntry> e = zf.entries(); e.hasMoreElements(); ) {
                String n = e.nextElement().getName().toUpperCase(java.util.Locale.ROOT);
                if (n.startsWith("META-INF/") && (n.endsWith(".SF") || n.endsWith(".RSA")
                        || n.endsWith(".DSA") || n.endsWith(".EC"))) { signed = true; break; }
            }
            if (!signed) return false;
            File tmp = new File(jar.getParentFile(), jar.getName() + ".a2tmp");
            java.util.zip.ZipOutputStream out = new java.util.zip.ZipOutputStream(
                new java.io.BufferedOutputStream(new java.io.FileOutputStream(tmp)));
            try {
                for (java.util.Enumeration<? extends java.util.zip.ZipEntry> e = zf.entries(); e.hasMoreElements(); ) {
                    java.util.zip.ZipEntry en = e.nextElement();
                    String n = en.getName().toUpperCase(java.util.Locale.ROOT);
                    if (n.startsWith("META-INF/") && (n.endsWith(".SF") || n.endsWith(".RSA")
                            || n.endsWith(".DSA") || n.endsWith(".EC"))) continue;
                    out.putNextEntry(new java.util.zip.ZipEntry(en.getName()));
                    if (!en.isDirectory()) {
                        java.io.InputStream in = zf.getInputStream(en);
                        byte[] buf = new byte[65536];
                        int r;
                        while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
                        in.close();
                    }
                    out.closeEntry();
                }
            } finally {
                out.close();
            }
            zf.close();
            zf = null;
            if (!jar.delete()) { tmp.delete(); return false; }
            return tmp.renameTo(jar);
        } catch (Throwable t) {
            return false;
        } finally {
            if (zf != null) { try { zf.close(); } catch (Throwable ignored) { } }
        }
    }
}

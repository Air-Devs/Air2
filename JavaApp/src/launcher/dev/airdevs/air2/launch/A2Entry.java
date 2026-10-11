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
        A2JvmProperties.apply(plan.properties());

        ClassLoader loader = ClassLoader.getSystemClassLoader();
        URL[] extra = A2GameClasspath.toUrls(plan.classpath());
        appendToSystemClassLoader(loader, extra);

        System.out.println("[A2-JAVA] 追加类路径 " + extra.length + " 条；派发 " + plan.mainClass());
        A2MainDispatcher.dispatch(plan.mainClass(), plan.arguments(), loader);
        System.out.println("[A2-JAVA] 主类正常返回");
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
}

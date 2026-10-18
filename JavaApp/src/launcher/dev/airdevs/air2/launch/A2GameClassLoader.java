package dev.airdevs.air2.launch;

import java.net.URL;
import java.net.URLClassLoader;

/**
 * 运行期可追加类路径的系统类加载器。
 *
 * <p><b>为什么必须有这一类</b>：{@code JNI_CreateJavaVM} 在创建时就把 classpath 钉死，
 * 之后再改 {@code java.class.path} 属性对类加载毫无影响。而 native 的 R4 只产出
 * 「app 自带 {@code libs/*.jar} + {@code lwjgl-&lt;ver&gt;/*}」这一份 classpath；
 * MC 的库在 {@code {game}/libraries/<group>/<artifact>/<ver>/…} 的 Maven 嵌套树里，
 * R4 的平铺扫描按设计取不到。所以「把 MC 库挂上 VM 类路径」只能在 VM 内、由 Java 侧完成。
 *
 * <p>接法（推荐）：margv 里带
 * {@code -Djava.system.class.loader=dev.airdevs.air2.launch.A2GameClassLoader}。
 * JVM 反射创建系统类加载器时要求构造函数签名恰为 {@code (ClassLoader)}，多一个参数就起不来。
 *
 * <p>不带这个 {@code -D} 时，{@link A2Entry} 会退到「反射调用 Java 8 的
 * {@code URLClassLoader.addURL}」兜底路径；两条路都指向同一件事，不是两种设计。
 */
public final class A2GameClassLoader extends URLClassLoader {

    public A2GameClassLoader(ClassLoader parent) {
        super(new URL[0], parent);
    }

    /** 追加类路径。重复追加同一 URL 是无害的（{@code URLClassLoader} 内部按 URL 去重）。 */
    public void addUrls(URL[] urls) {
        if (urls == null) {
            return;
        }
        for (URL url : urls) {
            if (url != null) {
                super.addURL(url);
            }
        }
    }

    /**
     * {@code -javaagent} 的落地约定：JVM 用系统类加载器把 agent jar 挂上类路径时，
     * 反射调用本方法（签名固定为 {@code (String)}）。
     *
     * <p><b>为什么必须实现</b>：真机日志（2026-10-18）——
     * <pre>
     * System class loader does not define the appendToClassPathForInstrumentation method
     * FATAL ERROR in native method: processing of -javaagent failed,
     *          appending to system class path failed   ⇒  VM 直接 abort
     * </pre>
     * 缺了它，任何 {@code -javaagent}（metallum_agent / patchjna_agent）都会在
     * {@code JNI_CreateJavaVM} 的 VMInit 阶段把进程打死。
     *
     * <p>调用点：{@code libinstrument.dylib} 的 {@code eventHandlerVMInit}（agent premain 之前）。
     */
    public void appendToClassPathForInstrumentation(String path) {
        if (path == null || path.isEmpty()) {
            return;
        }
        try {
            super.addURL(new java.io.File(path).toURI().toURL());
        } catch (java.net.MalformedURLException e) {
            throw new IllegalArgumentException("agent 路径无法转 URL: " + path, e);
        }
    }
}

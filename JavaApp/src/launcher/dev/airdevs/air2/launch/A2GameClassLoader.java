package dev.airdevs.air2.launch;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 运行期可追加类路径的系统类加载器。
 *
 * <p><b>为什么自己读字节定义类（2026-10-18 真机证据）</b>：MC 官方版本 jar 带 Mojang 签名
 * （{@code META-INF/MOJANGCS.SF|.RSA}），由 URLClassLoader 从该 jar 加载的类会带
 * {@code CodeSigner}；而 metallum agent 用反射 {@code defineClass} 把 {@code classes262/}
 * 里的类（同属 {@code com.mojang.blaze3d.*} 包）定义进同一包 —— 那些类<b>没有签名</b>。
 * 于是 {@code ClassLoader.checkCerts} 抛：
 * <pre>
 * SecurityException: class "…WindowEventHandler"'s signer information does not match …
 * </pre>
 * MC 主类根本起不来（表现为「没声音、没画面、进程还活着」）。
 *
 * <p>⇒ 本类自己从 jar 读 class 字节，用 {@code defineClass(name, b, 0, len)}
 * （<b>不传 ProtectionDomain</b>）定义：包内所有类都没有签名，检查恒等成立，
 * <b>不需要改动游戏 jar 一个字节</b>。资源查找仍走 {@code URLClassLoader}。
 *
 * <p>接法（推荐）：margv 里带
 * {@code -Djava.system.class.loader=dev.airdevs.air2.launch.A2GameClassLoader}。
 * JVM 反射创建系统类加载器时要求构造函数签名恰为 {@code (ClassLoader)}，多一个参数就起不来。
 *
 * <p>不带这个 {@code -D} 时，{@link A2Entry} 会退到「反射调用 Java 8 的
 * {@code URLClassLoader.addURL}」兜底路径；两条路都指向同一件事，不是两种设计。
 */
public final class A2GameClassLoader extends URLClassLoader {

    /** 已登记的 classpath jar（查找顺序 = 登记顺序）。 */
    private final List<File> jars = Collections.synchronizedList(new ArrayList<File>());
    /** 打开中的 ZipFile 缓存。 */
    private final Map<String, ZipFile> openJars = new LinkedHashMap<>();

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
                registerIfJar(url);
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
            URL url = new File(path).toURI().toURL();
            registerIfJar(url);
            super.addURL(url);
        } catch (java.net.MalformedURLException e) {
            throw new IllegalArgumentException("agent 路径无法转 URL: " + path, e);
        }
    }

    /**
     * 从登记的 jar 里自己读字节并定义类（无 ProtectionDomain ⇒ 无签名）。
     *
     * <p>调用时机：父加载器找不到时（{@code ClassLoader.loadClass → findClass}）。
     * 找不到的再交回 {@code URLClassLoader}（例如 app 自带 jar 里的类）。
     */
    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        // 只对「游戏自己的包」走无签名路径 —— 签名冲突只发生在这里（agent 往
        // com.mojang.blaze3d.* 定义类），把范围收窄可避免影响 LWJGL 等库
        // （它们会读 ProtectionDomain 的 CodeSource 去定位 native）。
        // ★只覆盖 agent 真正注入的那 13 个包★（全部在 com.mojang.blaze3d.*）：
        //   metallum_agent.jar 的 classes26*/ 条目就落在这里，签名冲突也只发生在这里。
        //   范围越窄，越不会影响 MC 其它类/库对 CodeSource 的依赖。
        boolean gameOwned = name.startsWith("com.mojang.blaze3d.");
        if (!gameOwned) {
            return super.findClass(name);
        }
        byte[] bytes = readFromJars(name.replace('.', '/') + ".class");
        if (bytes == null) {
            return super.findClass(name);
        }
        // ★关键：不传 ProtectionDomain★ —— 没有 CodeSource 就没有 CodeSigner，
        //   与 metallum agent 反射 defineClass 定义进同包的类签名状态一致，
        //   ClassLoader.checkCerts 不会再抛 SecurityException。
        return defineClass(name, bytes, 0, bytes.length);
    }

    // ---------------------------------------------------------------- 内部

    private void registerIfJar(URL url) {
        if (url == null || !"file".equalsIgnoreCase(url.getProtocol())) {
            return;
        }
        String p = url.getPath();
        if (p == null || !p.endsWith(".jar")) {
            return;
        }
        File f = new File(p);
        if (!f.isFile()) {
            return;
        }
        synchronized (jars) {
            if (!jars.contains(f)) {
                jars.add(f);
            }
        }
    }

    private byte[] readFromJars(String entryName) {
        List<File> snapshot;
        synchronized (jars) {
            snapshot = new ArrayList<>(jars);
        }
        for (File jar : snapshot) {
            try {
                ZipFile zf = openJar(jar);
                if (zf == null) {
                    continue;
                }
                ZipEntry entry = zf.getEntry(entryName);
                if (entry == null) {
                    continue;
                }
                try (InputStream is = zf.getInputStream(entry)) {
                    ByteArrayOutputStream out = new ByteArrayOutputStream(
                            entry.getSize() > 0 ? (int) entry.getSize() : 8192);
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = is.read(buf)) > 0) {
                        out.write(buf, 0, n);
                    }
                    return out.toByteArray();
                }
            } catch (Exception ignored) {
                // 单个 jar 读失败不该拖垮整个类加载
            }
        }
        return null;
    }

    private ZipFile openJar(File jar) {
        synchronized (openJars) {
            String key = jar.getAbsolutePath();
            ZipFile zf = openJars.get(key);
            if (zf != null) {
                return zf;
            }
            try {
                zf = new ZipFile(jar);
                openJars.put(key, zf);
                return zf;
            } catch (Exception e) {
                return null;
            }
        }
    }
}

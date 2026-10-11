package dev.airdevs.air2.launch;

import java.util.Map;

/**
 * JVM 系统属性落地。
 *
 * <p>值由《启动计划》给定（native 侧算好），本类只负责写下去 —— 选择哪个渲染器本地库、
 * 走不走 libffi、allocator 用哪个，都是启动期决策，不是编译期常量，所以不能只靠 margv 的
 * 静态 {@code -D}。
 *
 * <p><b>调用时机是硬约束</b>：LWJGL 的 {@code Library}、{@code Configuration} 在类初始化时读这些
 * 属性并缓存；必须在任何 MC / LWJGL 类被加载之前调用，否则设了也不生效。
 *
 * <p>典型条目（具体值由计划给，这里只列约定）：
 * <ul>
 *   <li>{@code org.lwjgl.vulkan.libname} —— Vulkan 本地库名（iOS 上传裸名，交给
 *       {@code Platform.mapLibraryName} 补 {@code lib}/{@code .dylib}）；</li>
 *   <li>{@code org.lwjgl.spvc.libname} —— spirv-cross 本地库名；</li>
 *   <li>{@code org.lwjgl.system.allocator} —— 只认 {@code system}/{@code jemalloc}/{@code rpmalloc}；</li>
 *   <li>{@code org.lwjgl.system.libffi.enabled} / {@code .initialize} —— iOS 上关掉 libffi 路径。</li>
 * </ul>
 */
final class A2JvmProperties {

    private A2JvmProperties() {
    }

    static void apply(Map<String, String> properties) {
        if (properties == null || properties.isEmpty()) {
            return;
        }
        for (Map.Entry<String, String> e : properties.entrySet()) {
            String key = e.getKey();
            String value = e.getValue();
            if (key == null || key.isEmpty() || value == null) {
                continue;
            }
            System.setProperty(key, value);
            System.out.println("[A2-JAVA] -D" + key + "=" + value);
        }
    }
}

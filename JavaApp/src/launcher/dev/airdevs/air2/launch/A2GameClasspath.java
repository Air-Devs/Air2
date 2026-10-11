package dev.airdevs.air2.launch;

import java.io.File;
import java.net.MalformedURLException;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

/**
 * 把《启动计划》里的类路径条目变成 URL。
 *
 * <p>只做两件事：判定条目在磁盘上是否存在、转成 {@link URL}。**不做通配展开** ——
 * {@code "<dir>/*"} 的展开在 native R4（{@code a2_paths_expand_classpath_wildcards}）是唯一实现，
 * Java 再写一遍就是第二份口径，两条链的 classpath 从此可能不一致。
 *
 * <p>条目不存在时打一行 WARN 并跳过，不中断：MC 的库列表里常有平台不匹配的条目，
 * 这在 native 侧已经按规则筛过一轮，Java 侧只做最后一道「文件真在不在」的确认。
 */
final class A2GameClasspath {

    private A2GameClasspath() {
    }

    static URL[] toUrls(List<String> entries) throws A2LaunchFailure {
        List<URL> out = new ArrayList<URL>();
        if (entries == null) {
            return new URL[0];
        }
        for (String entry : entries) {
            if (entry == null || entry.isEmpty()) {
                continue;
            }
            File file = new File(entry);
            if (!file.exists()) {
                System.out.println("[A2-JAVA] WARN 类路径条目不存在，跳过: " + entry);
                continue;
            }
            try {
                out.add(file.toURI().toURL());
            } catch (MalformedURLException e) {
                throw new A2LaunchFailure("类路径条目无法转成 URL: " + entry, e);
            }
        }
        return out.toArray(new URL[out.size()]);
    }
}

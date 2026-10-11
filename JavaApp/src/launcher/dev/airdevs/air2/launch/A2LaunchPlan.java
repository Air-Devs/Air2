package dev.airdevs.air2.launch;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 启动计划 —— native 侧（Core / Bridge）解析版本 JSON、账号与资源后，下达给 Java 侧的
 * <b>唯一</b>输入。Java 侧不懂它从哪来，只做机械动作。
 *
 * <p>计划 JSON（schema = 1）：
 * <pre>
 * {
 *   "schema": 1,
 *   "mainClass": "net.minecraft.client.main.Main",
 *   "arguments": ["--username", "Steve", "--version", "1.21.5", ...],
 *   "properties": {"org.lwjgl.vulkan.libname": "MoltenVK"},
 *   "nativeLibrary": "/…/Air2.app/Air2",
 *   "classpath": ["/…/libraries/a/b/1.0/b-1.0.jar", ...]
 * }
 * </pre>
 *
 * <p>两处刻意的「不做」，都是为了不把 native 的活搬回 Java：
 * <ul>
 *   <li>{@code arguments} 里 <b>不</b>留占位符（{@code ${auth_player_name}} 之类）——
 *       取值要读账号与版本 JSON，属业务，归 native；Java 只把数组原样交给主类。</li>
 *   <li>{@code classpath} 是<b>显式 jar 列表</b>，不含 {@code *} 通配 ——
 *       通配展开的唯一实现方是 native R4（{@code a2_paths_expand_classpath_wildcards}），
 *       Java 再实现一遍就是两套口径。</li>
 * </ul>
 */
final class A2LaunchPlan {

    /** 本类认识的计划格式版本。不匹配直接失败，不猜。 */
    static final int SCHEMA_VERSION = 1;

    private final String mainClass;
    private final List<String> arguments;
    private final Map<String, String> properties;
    private final List<String> classpath;
    private final String nativeLibrary;

    private A2LaunchPlan(String mainClass,
                         List<String> arguments,
                         Map<String, String> properties,
                         List<String> classpath,
                         String nativeLibrary) {
        this.mainClass = mainClass;
        this.arguments = Collections.unmodifiableList(arguments);
        this.properties = Collections.unmodifiableMap(properties);
        this.classpath = Collections.unmodifiableList(classpath);
        this.nativeLibrary = nativeLibrary;
    }

    String mainClass() {
        return mainClass;
    }

    String[] arguments() {
        return arguments.toArray(new String[arguments.size()]);
    }

    Map<String, String> properties() {
        return properties;
    }

    List<String> classpath() {
        return classpath;
    }

    String nativeLibrary() {
        return nativeLibrary;
    }

    @Override
    public String toString() {
        return "A2LaunchPlan{mainClass=" + mainClass
                + ", arguments=" + arguments.size()
                + ", properties=" + properties.size()
                + ", classpath=" + classpath.size()
                + ", nativeLibrary=" + (nativeLibrary == null ? "(未给)" : nativeLibrary) + "}";
    }

    static A2LaunchPlan load(File file) throws A2LaunchFailure {
        if (!file.isFile()) {
            throw new A2LaunchFailure("启动计划不存在: " + file.getAbsolutePath());
        }
        Object root;
        try {
            root = A2Json.parse(readUtf8(file));
        } catch (IOException e) {
            throw new A2LaunchFailure("读取启动计划失败: " + file.getAbsolutePath(), e);
        }
        if (!(root instanceof Map)) {
            throw new A2LaunchFailure("启动计划根节点必须是 JSON 对象");
        }
        Map<?, ?> m = (Map<?, ?>) root;

        long schema = asLong(m.get("schema"), -1L);
        if (schema != SCHEMA_VERSION) {
            throw new A2LaunchFailure("启动计划 schema 不匹配：期望 " + SCHEMA_VERSION + "，实际 " + schema);
        }

        String mainClass = asString(m.get("mainClass"));
        if (mainClass == null || mainClass.isEmpty()) {
            throw new A2LaunchFailure("启动计划缺 mainClass");
        }

        List<String> arguments = stringList(m.get("arguments"), "arguments");
        Map<String, String> properties = stringMap(m.get("properties"), "properties");
        List<String> classpath = stringList(m.get("classpath"), "classpath");
        String nativeLibrary = asString(m.get("nativeLibrary"));

        A2LaunchPlan plan = new A2LaunchPlan(mainClass, arguments, properties, classpath, nativeLibrary);
        System.out.println("[A2-JAVA] 启动计划就绪: " + plan);
        return plan;
    }

    // ---------------------------------------------------------------- 取值辅助

    private static String asString(Object v) {
        return (v instanceof String) ? (String) v : null;
    }

    private static long asLong(Object v, long fallback) {
        if (v instanceof Number) {
            return ((Number) v).longValue();
        }
        if (v instanceof String) {
            try {
                return Long.parseLong((String) v);
            } catch (NumberFormatException ignored) {
                return fallback;
            }
        }
        return fallback;
    }

    private static List<String> stringList(Object v, String field) throws A2LaunchFailure {
        List<String> out = new ArrayList<String>();
        if (v == null) {
            return out;
        }
        if (!(v instanceof List)) {
            throw new A2LaunchFailure("启动计划字段 " + field + " 必须是数组");
        }
        for (Object item : (List<?>) v) {
            if (!(item instanceof String)) {
                throw new A2LaunchFailure("启动计划字段 " + field + " 只能包含字符串");
            }
            out.add((String) item);
        }
        return out;
    }

    private static Map<String, String> stringMap(Object v, String field) throws A2LaunchFailure {
        Map<String, String> out = new LinkedHashMap<String, String>();
        if (v == null) {
            return out;
        }
        if (!(v instanceof Map)) {
            throw new A2LaunchFailure("启动计划字段 " + field + " 必须是对象");
        }
        for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
            if (!(e.getKey() instanceof String) || !(e.getValue() instanceof String)) {
                throw new A2LaunchFailure("启动计划字段 " + field + " 的键值都必须是字符串");
            }
            out.put((String) e.getKey(), (String) e.getValue());
        }
        return out;
    }

    private static String readUtf8(File file) throws IOException {
        InputStream in = new FileInputStream(file);
        try {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int n;
            while ((n = in.read(chunk)) != -1) {
                buf.write(chunk, 0, n);
            }
            return new String(buf.toByteArray(), Charset.forName("UTF-8"));
        } finally {
            in.close();
        }
    }
}

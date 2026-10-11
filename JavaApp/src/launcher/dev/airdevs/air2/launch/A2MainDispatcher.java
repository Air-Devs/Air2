package dev.airdevs.air2.launch;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * 主类派发 —— 与 native 的 {@code a2_run_main} 同语义（FindClass → GetStaticMethodID("main")
 * → CallStaticVoidMethod），只是换成 Java 侧反射调用。
 *
 * <p>为什么不直接把 MC 主类交给 {@code a2_run_main}：那样类路径必须在 {@code JNI_CreateJavaVM}
 * 之前就带全 MC 的库，而 R4 取不到 Maven 嵌套树；交给 Java 侧派发才有「先追加类路径、再找类」的机会。
 *
 * <p>异常一律解包：{@code InvocationTargetException} 会把 MC 的真实崩溃原因藏在 cause 里，
 * 不解包就只剩一句「InvocationTargetException」，真机排查等于没有信息。
 */
final class A2MainDispatcher {

    private A2MainDispatcher() {
    }

    static void dispatch(String mainClass, String[] args, ClassLoader loader) throws A2LaunchFailure {
        Class<?> cls;
        try {
            cls = Class.forName(mainClass, true, loader);
        } catch (ClassNotFoundException e) {
            throw new A2LaunchFailure("找不到主类（类路径里没有它）: " + mainClass, e);
        } catch (LinkageError e) {
            throw new A2LaunchFailure("主类链接失败: " + mainClass, e);
        }

        Method main;
        try {
            main = cls.getMethod("main", String[].class);
        } catch (NoSuchMethodException e) {
            throw new A2LaunchFailure("主类没有 main(String[]) : " + mainClass, e);
        }

        try {
            main.invoke(null, (Object) args);
        } catch (IllegalAccessException e) {
            throw new A2LaunchFailure("主类 main 不可访问: " + mainClass, e);
        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            throw new A2LaunchFailure("主类 " + mainClass + " 抛出异常: "
                    + (cause == null ? e : cause), cause);
        }
    }
}

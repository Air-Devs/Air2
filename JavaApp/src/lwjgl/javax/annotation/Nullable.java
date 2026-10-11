/*
 * Air2 —— 编译期注解补丁（★A2-LWJGL-1★）
 *
 * 为什么需要它（可追溯的调用点）：
 *   本 jar 内的 org.lwjgl.glfw.GLFW 等 class 源码沿用了上游 Amethyst(runtime_native)
 *   overlay，其方法签名大量使用 {@code javax.annotation.Nullable}（JSR-305，
 *   官方 LWJGL 曾随包发布，见 old tree JavaApp/Makefile 的 classpath 说明）。
 *   Air2 随包的 Libraries/Jars/lwjgl-341/*.jar 中【没有】javax.annotation（已用
 *   unzip -l 逐个核对，无 javax/annotation、无 jspecify）⇒ 若缺此声明，
 *   javac 会报 50 处 "cannot find symbol: class Nullable"、运行时类加载亦需该类型。
 *
 * 归属与许可：JSR-305 javax.annotation（公有领域性质的标准注解接口，
 *   https://jcp.org/en/jsr/detail?id=305）。此处为最小声明，非拷贝任何实现。
 *   与老树源码的对应关系：old tree JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java
 *   的 50 处 {@code @Nullable}（其中 4 处独立成行）。
 *
 * 保留策略用 CLASS（编译期/链接期可见即可），避免无谓的运行时注解解析。
 */
package javax.annotation;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Retention(RetentionPolicy.CLASS)
@Target({ElementType.METHOD, ElementType.PARAMETER, ElementType.FIELD, ElementType.LOCAL_VARIABLE, ElementType.TYPE_USE})
public @interface Nullable {
}

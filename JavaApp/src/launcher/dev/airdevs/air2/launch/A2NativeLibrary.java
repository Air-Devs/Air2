package dev.airdevs.air2.launch;

import java.io.File;

/**
 * 「主可执行文件即 JNI 符号宿主」这一约定的落地。
 *
 * <p>约定：App 主二进制（{@code Air2.app/Air2}）导出 native 层用 {@code @_cdecl} / {@code extern "C"}
 * 写的 JNI 实现（输入桥、surface、诊断…）。Java 侧要显式 {@code System.load} 它一次，
 * 否则 LWJGL 补丁类里的 {@code native} 方法在第一次调用时抛 {@code UnsatisfiedLinkError}。
 *
 * <p>只写约定，不写实现：符号全在 native 层（Natives/Input、Natives/Renderer）；
 * 本类不 {@code dlopen} 任何 dylib，也不做路径猜测 —— 路径由计划给，给错就报错。
 */
final class A2NativeLibrary {

    private A2NativeLibrary() {
    }

    static void load(String path) throws A2LaunchFailure {
        if (path == null || path.isEmpty()) {
            // 无约定即跳过：headless 跑法（如只跑安装器）不需要符号宿主。
            return;
        }
        File file = new File(path);
        if (!file.isFile()) {
            throw new A2LaunchFailure("nativeLibrary 不存在: " + file.getAbsolutePath());
        }
        System.load(file.getAbsolutePath());
        System.out.println("[A2-JAVA] nativeLibrary loaded: " + file.getAbsolutePath());
    }
}

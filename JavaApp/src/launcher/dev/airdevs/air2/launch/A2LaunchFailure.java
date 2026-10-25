package dev.airdevs.air2.launch;

/**
 * 启动期失败 —— 带一句可直接给人看的原因。
 *
 * <p>为什么单独一个类型：native 侧（{@code a2_run_main}）要按失败
 * 种类分流文案，用 Exception 分不出来。消息一律写「发生了什么 + 关键路径/名字」，
 * 不写「请重试」这类无信息量的话。
 */
public final class A2LaunchFailure extends Exception {

    private static final long serialVersionUID = 1L;

    public A2LaunchFailure(String message) {
        super(message);
    }

    public A2LaunchFailure(String message, Throwable cause) {
        super(message, cause);
    }
}

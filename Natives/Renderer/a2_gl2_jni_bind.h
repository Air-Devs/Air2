// ============================================================================
//  Natives/Renderer/a2_gl2_jni_bind.h
//  Air2 —— ★[A2-GL2] 接入面：把 LWJGL 的 GL11 固定管线 native 换成自研实现★
// ----------------------------------------------------------------------------
//  分层：Natives/Renderer（与 a2_gl2_shim.* 同一层；本文件是「入口抢夺」，.shim 是「实现」）。
//
//  ★为什么抢在 JNI 这一层（本轮取证结论，见 docs/GL2-BINDING-FORENSICS.md）★
//    MC 1.12.2 的 `org.lwjgl.opengl.GL11.glBegin` 是 `public static native`：
//      · Java 侧没有函数指针、没有 getFunctionAddress ⇒ 改系统属性/换 provider 都碰不到它；
//      · 实现在 `liblwjgl_opengl.dylib` 的 `Java_org_lwjgl_opengl_GL11_glBegin`，而那条实现是
//        一段中继（`env → [env] → [+0x18] → [+OFFSET] → br`），dylib 自身 **零外部导入**
//        （无 dlsym / 无 dlopen / 不链 libGLESv2）⇒ 进程里根本没有 `_glBegin` 这个未定义符号
//        可供 dyld interpose / flat-namespace 抢占。
//      ⇒ 唯一可行且确定的口子 = JNI 绑定本身：`RegisterNatives` 把这条 native 换成我们的函数。
//        它不依赖符号搜索顺序、不污染进程 flat namespace、不影响其它 GL 入口。
//
//  ★调用点（不允许有「没人调」的符号）★
//    · `Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_install`
//         ← `JavaApp/src/launcher/dev/airdevs/air2/launch/A2Gl2Gl11Bind.java:install()`
//         ← `A2Entry.main()`（追加完类路径、派发 MC 主类之前）
//    · `a2_gl2_jni_install()`  ← 上面那条 JNI 面（唯一调用点）
//
//  ★默认不生效★：`A2_GL2_SHIM` 与 `A2_GL2_PROBE` 都没设 ⇒ 一个方法都不注册，
//    行为与接入前逐字节一致（只在日志里留一行判据）。
// ============================================================================
#ifndef A2_GL2_JNI_BIND_H
#define A2_GL2_JNI_BIND_H

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 把 7 个固定管线入口从 LWJGL 的 JNI native 换成自研层。
/// @param env   当前 JNIEnv（非 NULL）
/// @param gl11  `org.lwjgl.opengl.GL11` 的 jclass（6 个入口注册在它上面）
/// @param gl11c `org.lwjgl.opengl.GL11C` 的 jclass（glDrawArrays 的 native 声明在它上面；
///              传 NULL ⇒ 跳过该条并打一行判据）
/// @return 成功注册的条数（0 = 未启用 / 全部失败）
/// 幂等：重复调用返回首次结果，不重复注册。
int a2_gl2_jni_install(JNIEnv *env, jclass gl11, jclass gl11c);

#ifdef __cplusplus
}
#endif

#endif /* A2_GL2_JNI_BIND_H */

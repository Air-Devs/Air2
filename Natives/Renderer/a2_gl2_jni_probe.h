// ============================================================================
//  Natives/Renderer/a2_gl2_jni_probe.h
//  Air2 —— ★只读取证：LWJGL 里那批「固定管线入口」的实现到底落在哪个镜像★
// ----------------------------------------------------------------------------
//  分层：Natives/Renderer（与 a2_gl2_shim.* / a2_gl_bridge.* 同一层）。
//
//  ★为什么需要它（本轮唯一问题的取证手段）★
//    MC 1.12.2 的 `org.lwjgl.opengl.GL11.glBegin` 是 **native 方法**（不是 Java 侧
//    函数指针，见 javap：`public static native void glBegin(int)`）。它的实现在
//    `liblwjgl_opengl.dylib` 的 `Java_org_lwjgl_opengl_GL11_glBegin` 里，而那条实现
//    本身是一段 5 条指令的中继（`env → [env] → [+0x18] → [+OFFSET] → br`），本层要做的是：
//    把「这条中继属于哪张镜像」「这个 GL 名字在进程 flat namespace 里又会命中哪张镜像」
//    两件事，用 dladdr 打成人能读的一行。
//    ⇒ 判据是镜像名，不是猜测。真机/模拟器都不需要断点。
//
//  ★调用点（不允许有「没人调」的符号）★
//    · `a2_gl2_probe_log()`            ← `Natives/Renderer/a2_gl2_jni_bind.m`
//                                         `a2_gl2_jni_install()`（安装抢占前先取证）
//    · `Java_a2_A2Gl2Probe_report`     ← `JavaApp/src/a2ios_agent/a2/A2Gl2Probe.java:report()`
//                                         ← 由 `A2IosCompatAgent` 在 `GL11.<clinit>` 末尾注入
//    · `a2_gl2_probe_sample()`         ← 上面两个（唯一采样口）
//
//  ★纪律★：本文件只读（dlsym + dladdr + 拼字符串），不改任何绑定、不写任何全局状态。
// ============================================================================
#ifndef A2_GL2_JNI_PROBE_H
#define A2_GL2_JNI_PROBE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 一条入口的「绑定事实」（全部由 dladdr/dlsym 当场得到，不缓存）
typedef struct {
    const char *glName;        ///< GL 入口名（如 "glBegin"）
    const char *jniSymbol;     ///< 该入口的 JNI 实现符号名（Java_org_lwjgl_opengl_GL11_glBegin）
    const char *declaringClass;///< Java 侧声明它的类（org/lwjgl/opengl/GL11 或 GL11C）
    void       *jniAddress;    ///< dlsym 到的地址；NULL = 该镜像还没进进程
    const char *jniImage;      ///< dladdr(jniAddress) 的镜像名（失败 = "(未知)"）
    const char *flatImage;     ///< dlsym(RTLD_DEFAULT, glName) 命中的镜像（失败 = "(无)"）
} A2GL2ProbeFact;

/// 采样本轮接管的入口（唯一产地）。返回写入条数（≤ cap）。
/// 顺序 = `kA2GL2ProbeEntries` 的登记顺序（固定 7 个，见 .m）。
int a2_gl2_probe_sample(A2GL2ProbeFact *out, int cap);

/// 把采样结果打成 `[A2-GL2-PROBE]` 判据行（每个入口一行 + 一行结论）。
/// 调用点：`a2_gl2_jni_install()`（安装前取证）。
void a2_gl2_probe_log(void);

#pragma mark - 登记表的只读访问（★唯一登记表在 .m，别处不另抄一份★）

/// 登记表条数（固定 7：见 .m 的 `kA2GL2ProbeEntries`）。
/// 调用点：`a2_gl2_jni_bind.m` 的 `a2_gl2_jni_install()`（按索引逐个注册/懒解析）。
int a2_gl2_probe_entry_count(void);

/// 第 index 条的 GL 入口名；越界返回 NULL。
/// 调用点：`a2_gl2_jni_bind.m` 的 7 个 JNI 转发（取 `a2_gl2_shim_lookup` 的名字）。
const char *a2_gl2_probe_gl_name(int index);

/// 第 index 条的 JNI 实现符号名；越界返回 NULL。
/// 调用点：`a2_gl2_jni_bind.m` 的 `a2gl2_orig()`（关闭本层时转发的原实现）。
const char *a2_gl2_probe_jni_symbol(int index);

/// 第 index 条在 Java 侧声明的类（内部名，GL11 / GL11C）；越界返回 NULL。
/// 调用点：`a2_gl2_jni_bind.m` 的 `a2_gl2_jni_install()`（决定注册到哪个 jclass）。
const char *a2_gl2_probe_declaring_class(int index);

#ifdef __cplusplus
}
#endif

#endif /* A2_GL2_JNI_PROBE_H */

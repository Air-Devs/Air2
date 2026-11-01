// ============================================================================
//  Natives/Renderer/a2_gl2_jni_bind.m
//  Air2 —— 把 LWJGL 的 GL11 固定管线 JNI native 换成自研固定管线层
//  对外契约见 a2_gl2_jni_bind.h（只有一个函数）。本文件只实现。
// ============================================================================
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <jni.h>

#import "a2_log.h"
#import "a2_gl2_shim.h"
#import "a2_gl2_jni_probe.h"
#import "a2_gl2_jni_bind.h"

// ============================================================================
//  ① 索引常量（★与 a2_gl2_jni_probe.m 的登记表同序★；install() 起步会逐条核对，
//     表被重排 ⇒ 直接拒绝安装，不让「装错入口」这种静默错误发生）
// ============================================================================
enum {
    kA2GL2IdxBegin        = 0,
    kA2GL2IdxEnd          = 1,
    kA2GL2IdxVertex3f     = 2,
    kA2GL2IdxColor4f      = 3,
    kA2GL2IdxMatrixMode   = 4,
    kA2GL2IdxLoadIdentity = 5,
    kA2GL2IdxDrawArrays   = 6,
    kA2GL2IdxCount        = 7,
};

/// 期望的名字（核对用；唯一调用点 `a2gl2_verify_table()`）。
static const char *const kA2GL2ExpectedNames[kA2GL2IdxCount] = {
    "glBegin", "glEnd", "glVertex3f", "glColor4f", "glMatrixMode", "glLoadIdentity", "glDrawArrays",
};

// ============================================================================
//  ② 原实现的 JNI 签名（与 jar 里 native 声明逐字对应，见 javap -s）
//     glBegin(I)V / glEnd()V / glVertex3f(FFF)V / glColor4f(FFFF)V
//     glMatrixMode(I)V / glLoadIdentity()V / glDrawArrays(III)V
// ============================================================================
typedef void (*A2GL2JniVI)(JNIEnv *, jclass, jint);
typedef void (*A2GL2JniVFFF)(JNIEnv *, jclass, jfloat, jfloat, jfloat);
typedef void (*A2GL2JniVFFFF)(JNIEnv *, jclass, jfloat, jfloat, jfloat, jfloat);
typedef void (*A2GL2JniVV)(JNIEnv *, jclass);
typedef void (*A2GL2JniVIII)(JNIEnv *, jclass, jint, jint, jint);

// ============================================================================
//  ③ 状态（全部只被 install/转发读写；无锁：安装只在启动线程一次，转发只读）
// ============================================================================
static void *gOrigFn[kA2GL2IdxCount];      ///< 原 JNI 实现（懒解析：首次转发时 dlsym）
static void *gShimFn[kA2GL2IdxCount];      ///< 本层实现（★每入口只查一次★）
static int   gShimChecked[kA2GL2IdxCount]; ///< 0=尚未查过本层（首命时才查）
static int   gHitLogged[kA2GL2IdxCount];   ///< 首命日志去重（每入口只打一行）
static int   gDropLogged[kA2GL2IdxCount];  ///< 「丢弃」日志去重（每入口只打一行）
static int   gInstalled = -1;              ///< -1=未装 0=未启用/失败 >0=注册条数
static void *gLWJGLHandle = NULL;          ///< liblwjgl_opengl.dylib 的 dlopen 句柄

// ============================================================================
//  ④ 打开 liblwjgl_opengl.dylib（唯一产地：原实现只在这张镜像里）
// ----------------------------------------------------------------------------
//  为什么显式 dlopen：一旦我们 RegisterNatives 成功，JVM 就不必再为这 7 个方法去
//  加载 LWJGL 的 native 库 ⇒ 「关闭本层时转发原实现」这条路会拿不到原符号。
//  dlopen 同路径是引用计数，LWJGL 自己后面再 load 一次也安全。
// ============================================================================
static int a2gl2_open_lwjgl_opengl(void) {
    if (gLWJGLHandle != NULL) return 1;
    NSString *path = [[[NSBundle mainBundle] bundlePath]
                      stringByAppendingPathComponent:@"Frameworks/liblwjgl_opengl.dylib"];
    gLWJGLHandle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (gLWJGLHandle == NULL) {
        a2_log_criterion(@"[A2-GL2] ★原实现库打不开★ %s err=%s ⇒ 关闭本层时无法转发（本层启用时不受影响）",
                         path.UTF8String, dlerror());
        return 0;
    }
    return 1;
}

/// 懒解析第 idx 条的原实现（唯一调用点：7 个 JNI 转发里「本层未接管」那条分支）。
static void *a2gl2_orig(int idx) {
    if (idx < 0 || idx >= kA2GL2IdxCount) return NULL;
    if (gOrigFn[idx] != NULL) return gOrigFn[idx];
    const char *sym = a2_gl2_probe_jni_symbol(idx);
    if (sym == NULL) return NULL;
    // ① 首选：自己 dlopen 的句柄（路径确定，不受进程 flat namespace 顺序影响）
    if (a2gl2_open_lwjgl_opengl()) {
        gOrigFn[idx] = dlsym(gLWJGLHandle, sym);
    }
    // ② 兜底：路径解析失败时按进程全局符号找一遍（LWJGL 若已由 JVM 自己 load 过就能找到）
    if (gOrigFn[idx] == NULL) {
        gOrigFn[idx] = dlsym(RTLD_DEFAULT, sym);
    }
    if (gOrigFn[idx] == NULL) {
        a2_log_criterion(@"[A2-GL2] ★原实现缺失★ %s ⇒ 该入口在本层关闭时会被丢弃（不会崩，但少了这次绘制）",
                         sym);
    }
    return gOrigFn[idx];
}

// ============================================================================
//  ⑤ 公共分支：先问本层，未接管再转发原实现
// ----------------------------------------------------------------------------
//  调用点：7 个 JNI 转发各一处（见 ⑥）。返回非 NULL = 本层实现，调用方直接调它。
// ============================================================================
static void *a2gl2_enter(int idx) {
    if (idx < 0 || idx >= kA2GL2IdxCount) return NULL;
    // ★每入口只查一次★：glVertex3f 这种入口每帧被调几十万次，
    //   每次都跑 a2_gl2_shim_lookup（60 条 strcmp）会把帧时间吃光。
    //   判据（A2_GL2_SHIM）在进程生命周期内不变 ⇒ 缓存安全。
    if (gShimChecked[idx]) return gShimFn[idx];
    gShimChecked[idx] = 1;
    const char *name = a2_gl2_probe_gl_name(idx);
    gShimFn[idx] = a2_gl2_shim_lookup(name);     // 未启用/未实现 ⇒ NULL（a2_gl2_shim.m 的唯一查询口）
    if (!gHitLogged[idx]) {
        gHitLogged[idx] = 1;
        a2_log_criterion(@"[A2-GL2-PROBE] 抢占命中 %s（JNI native 已被本层接管；本层实现=%s）",
                         (name != NULL) ? name : "(null)",
                         (gShimFn[idx] != NULL) ? "有" : "无 ⇒ 转发原实现");
    }
    return gShimFn[idx];
}

/// 原实现也拿不到时的兜底（唯一调用点：7 个转发里 `a2gl2_orig()` 返回 NULL 的分支）。
static void a2gl2_drop(int idx) {
    if (gDropLogged[idx]) return;
    gDropLogged[idx] = 1;
    const char *name = a2_gl2_probe_gl_name(idx);
    a2_log_criterion(@"[A2-GL2] ★丢弃★ %s：本层未实现且原实现不可用",
                     (name != NULL) ? name : "(null)");
}

// ============================================================================
//  ⑥ 7 个 JNI 转发（★唯一注册面★：签名与 ② 的类型别名逐一对应）
// ----------------------------------------------------------------------------
//  谁调它们：RegisterNatives 之后，MC 的 `org.lwjgl.opengl.GL11.<name>` 调用直接落到这里
//  （MC 侧的调用面：1.12.2 的 RenderItem/RenderGlobal 等经 GL11 静态方法，无第二个入口）。
// ============================================================================
static void JNICALL a2gl2_j_glBegin(JNIEnv *env, jclass cls, jint mode) {
    void *shim = a2gl2_enter(kA2GL2IdxBegin);
    if (shim != NULL) { ((void (*)(int))shim)((int)mode); return; }
    A2GL2JniVI orig = (A2GL2JniVI)a2gl2_orig(kA2GL2IdxBegin);
    if (orig != NULL) orig(env, cls, mode); else a2gl2_drop(kA2GL2IdxBegin);
}

static void JNICALL a2gl2_j_glEnd(JNIEnv *env, jclass cls) {
    void *shim = a2gl2_enter(kA2GL2IdxEnd);
    if (shim != NULL) { ((void (*)(void))shim)(); return; }
    A2GL2JniVV orig = (A2GL2JniVV)a2gl2_orig(kA2GL2IdxEnd);
    if (orig != NULL) orig(env, cls); else a2gl2_drop(kA2GL2IdxEnd);
}

static void JNICALL a2gl2_j_glVertex3f(JNIEnv *env, jclass cls, jfloat x, jfloat y, jfloat z) {
    void *shim = a2gl2_enter(kA2GL2IdxVertex3f);
    if (shim != NULL) { ((void (*)(float, float, float))shim)(x, y, z); return; }
    A2GL2JniVFFF orig = (A2GL2JniVFFF)a2gl2_orig(kA2GL2IdxVertex3f);
    if (orig != NULL) orig(env, cls, x, y, z); else a2gl2_drop(kA2GL2IdxVertex3f);
}

static void JNICALL a2gl2_j_glColor4f(JNIEnv *env, jclass cls, jfloat r, jfloat g, jfloat b, jfloat a) {
    void *shim = a2gl2_enter(kA2GL2IdxColor4f);
    if (shim != NULL) { ((void (*)(float, float, float, float))shim)(r, g, b, a); return; }
    A2GL2JniVFFFF orig = (A2GL2JniVFFFF)a2gl2_orig(kA2GL2IdxColor4f);
    if (orig != NULL) orig(env, cls, r, g, b, a); else a2gl2_drop(kA2GL2IdxColor4f);
}

static void JNICALL a2gl2_j_glMatrixMode(JNIEnv *env, jclass cls, jint mode) {
    void *shim = a2gl2_enter(kA2GL2IdxMatrixMode);
    if (shim != NULL) { ((void (*)(int))shim)((int)mode); return; }
    A2GL2JniVI orig = (A2GL2JniVI)a2gl2_orig(kA2GL2IdxMatrixMode);
    if (orig != NULL) orig(env, cls, mode); else a2gl2_drop(kA2GL2IdxMatrixMode);
}

static void JNICALL a2gl2_j_glLoadIdentity(JNIEnv *env, jclass cls) {
    void *shim = a2gl2_enter(kA2GL2IdxLoadIdentity);
    if (shim != NULL) { ((void (*)(void))shim)(); return; }
    A2GL2JniVV orig = (A2GL2JniVV)a2gl2_orig(kA2GL2IdxLoadIdentity);
    if (orig != NULL) orig(env, cls); else a2gl2_drop(kA2GL2IdxLoadIdentity);
}

static void JNICALL a2gl2_j_glDrawArrays(JNIEnv *env, jclass cls, jint mode, jint first, jint count) {
    void *shim = a2gl2_enter(kA2GL2IdxDrawArrays);
    if (shim != NULL) { ((void (*)(int, int, int))shim)((int)mode, (int)first, (int)count); return; }
    A2GL2JniVIII orig = (A2GL2JniVIII)a2gl2_orig(kA2GL2IdxDrawArrays);
    if (orig != NULL) orig(env, cls, mode, first, count); else a2gl2_drop(kA2GL2IdxDrawArrays);
}

// ============================================================================
//  ⑦ 注册表（★名字/签名与 jar 里逐字一致；写错会在注册前被签名核对拦下★）
// ============================================================================
static const JNINativeMethod kA2GL2MethodsGL11[] = {
    { (char *)"glBegin",        (char *)"(I)V",    (void *)a2gl2_j_glBegin        },
    { (char *)"glEnd",          (char *)"()V",     (void *)a2gl2_j_glEnd          },
    { (char *)"glVertex3f",     (char *)"(FFF)V",  (void *)a2gl2_j_glVertex3f     },
    { (char *)"glColor4f",      (char *)"(FFFF)V", (void *)a2gl2_j_glColor4f      },
    { (char *)"glMatrixMode",   (char *)"(I)V",    (void *)a2gl2_j_glMatrixMode   },
    { (char *)"glLoadIdentity", (char *)"()V",     (void *)a2gl2_j_glLoadIdentity },
};

/// glDrawArrays 的 native 声明在 GL11C 上（GL11.glDrawArrays 是普通 Java 方法，转调 GL11C）。
static const JNINativeMethod kA2GL2MethodsGL11C[] = {
    { (char *)"glDrawArrays",   (char *)"(III)V",  (void *)a2gl2_j_glDrawArrays   },
};

#define A2GL2_COUNT_OF(a) ((int)(sizeof(a) / sizeof((a)[0])))

// ============================================================================
//  ⑧ 表序核对（唯一调用点：a2_gl2_jni_install 开头）
// ----------------------------------------------------------------------------
//  索引常量与探针登记表分处两个文件 ⇒ 必须机器核对；表被重排就等于把 glEnd 装成 glBegin，
//  这种错只会表现为「画面全黑」，从日志里查不出来。
// ============================================================================
static int a2gl2_verify_table(void) {
    if (a2_gl2_probe_entry_count() != kA2GL2IdxCount) {
        a2_log_criterion(@"[A2-GL2] ★拒绝安装★ 入口表条数=%d，期望 %d",
                         a2_gl2_probe_entry_count(), kA2GL2IdxCount);
        return 0;
    }
    for (int i = 0; i < kA2GL2IdxCount; i++) {
        const char *name = a2_gl2_probe_gl_name(i);
        if (name == NULL || strcmp(name, kA2GL2ExpectedNames[i]) != 0) {
            a2_log_criterion(@"[A2-GL2] ★拒绝安装★ 第 %d 条名字=%s，期望 %s",
                             i, (name != NULL) ? name : "(null)", kA2GL2ExpectedNames[i]);
            return 0;
        }
    }
    return 1;
}

// ============================================================================
//  ⑨ 单个类的注册（唯一产地；两条调用：GL11 / GL11C）
// ----------------------------------------------------------------------------
//  先逐条 GetStaticMethodID 验签名：签名对不上时 RegisterNatives 只会回一个 -1，
//  不告诉你是哪一条 —— 真机上就只剩「一个入口都没接管」的黑盒。
// ============================================================================
static int a2gl2_register_class(JNIEnv *env, jclass cls, const char *what,
                                const JNINativeMethod *methods, int count) {
    if (cls == NULL) {
        a2_log_criterion(@"[A2-GL2] %s 的 jclass 为 NULL ⇒ 跳过", what);
        return 0;
    }
    JNINativeMethod verified[8];
    int n = 0;
    for (int i = 0; i < count && i < 8; i++) {
        jmethodID mid = (*env)->GetStaticMethodID(env, cls, methods[i].name, methods[i].signature);
        if (mid == NULL) {
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
            a2_log_criterion(@"[A2-GL2] ★签名不匹配★ %s.%s%s ⇒ 跳过该入口（LWJGL 版本可能变了）",
                             what, methods[i].name, methods[i].signature);
            continue;
        }
        verified[n++] = methods[i];
    }
    if (n == 0) return 0;
    jint rc = (*env)->RegisterNatives(env, cls, verified, n);
    if (rc != JNI_OK) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        a2_log_criterion(@"[A2-GL2] ★RegisterNatives 失败★ %s（rc=%d，已注册 0 条）", what, (int)rc);
        return 0;
    }
    return n;
}

// ============================================================================
//  ⑩ 安装（唯一入口；调用点见 .h）
// ============================================================================
int a2_gl2_jni_install(JNIEnv *env, jclass gl11, jclass gl11c) {
    if (gInstalled >= 0) return gInstalled;      // ★幂等★
    gInstalled = 0;
    if (env == NULL || gl11 == NULL) {
        a2_log_criterion(@"[A2-GL2] 安装失败：env/GL11 为 NULL");
        return 0;
    }

    // 判据口径与 a2_gl2_shim_enabled() 一致：默认关；A2_GL2_PROBE=1 只取证不改行为。
    const char *probeEnv = getenv("A2_GL2_PROBE");
    const int probeOn = (probeEnv != NULL && probeEnv[0] != '\0' && strcmp(probeEnv, "0") != 0);
    const int shimOn  = a2_gl2_shim_enabled();
    if (!shimOn && !probeOn) {
        a2_log_criterion(@"[A2-GL2] GL11 入口抢占=未启用（A2_GL2_SHIM 与 A2_GL2_PROBE 均未设）"
                         @"⇒ 一条都不注册，行为与接入前一致");
        return 0;
    }
    if (!a2gl2_verify_table()) return 0;

    // ★取证★：安装前先把「这批入口原来落在哪张镜像」打成判据行。
    a2_gl2_probe_log();

    int n = a2gl2_register_class(env, gl11, "org/lwjgl/opengl/GL11",
                                 kA2GL2MethodsGL11, A2GL2_COUNT_OF(kA2GL2MethodsGL11));
    n += a2gl2_register_class(env, gl11c, "org/lwjgl/opengl/GL11C",
                              kA2GL2MethodsGL11C, A2GL2_COUNT_OF(kA2GL2MethodsGL11C));
    gInstalled = n;
    a2_log_criterion(@"[A2-GL2] ★GL11 入口抢占=生效★ 已接管 %d/%d 个固定管线入口"
                     @"（A2_GL2_SHIM=%d A2_GL2_PROBE=%d）—— MC 的 glBegin/glEnd/glVertex3f/"
                     @"glColor4f/glMatrixMode/glLoadIdentity/glDrawArrays 现在先到本进程",
                     n, kA2GL2IdxCount, shimOn, probeOn);
    return n;
}

// ============================================================================
//  ⑪ JNI 面（唯一调用点：JavaApp/src/launcher/.../A2Gl2Gl11Bind.java:install()）
// ----------------------------------------------------------------------------
//  宿主约定：主可执行文件即 JNI 符号宿主（A2Entry → A2NativeLibrary.load）。
// ============================================================================
JNIEXPORT jint JNICALL Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_install
(JNIEnv *env, jclass self, jclass gl11, jclass gl11c) {
    (void)self;
    return (jint)a2_gl2_jni_install(env, gl11, gl11c);
}

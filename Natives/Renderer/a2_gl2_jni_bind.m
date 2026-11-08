// ============================================================================
//  Natives/Renderer/a2_gl2_jni_bind.m
//  Air2 —— 把 LWJGL 的 GL11 固定管线 JNI native 换成自研固定管线层
//  对外契约见 a2_gl2_jni_bind.h（只有一个函数）。本文件只实现。
// ----------------------------------------------------------------------------
//  ★本轮登记面 = 68 条真实现 + 268 条空实现 = 336 条（= GL11/GL11C 上 native 总数）★
//    javap 实测：GL11 274 个 static native，GL11C 62 个，合计 336 个（两类的 native 无交集）。
//    ① 68 条 → `kA2GL2Methods[]`，走 `a2_gl2_shim.m` 的**真实现**（本层真正模拟的固定管线入口）；
//    ② 其余 268 条 → `a2_gl2_stub_table.h` 的**空实现**（no-op，返回默认值）。
//
//  ★为什么必须把 336 条全部接管★（真机证据 lastlog-153，MC 1.12.2）：
//    只接管 68 条时，glLogicOp / glPointSize / glHint / glPolygonMode / glLineWidth / glAccum
//    这类桌面专用入口仍落回 `liblwjgl_opengl.dylib`，而它入口函数指针表在本层接管 GL 过程后是
//    NULL ⇒ `liblwjgl_opengl.dylib+0xbbbc` 一次间接调用踩空 ⇒ SIGSEGV + JVM os::abort。
//    修法是「全接管」而不是「猜哪些会被调」：有真实现的走真实现，没有的走 no-op。
//
//  ★优先级（本文件最硬的一条约束）★：真实现先装，装成什么名字、落在哪个类，全部记进 taken 集；
//    stub 后装、装前逐条查 taken ⇒ **已实现的 68 条在任何情况下都不会被 no-op 顶掉**。
//    日志会打「已实现 N 条 / 空实现 M 条 / 总计 T」以及「免装 X 条（真实现已覆盖）」。
//
//  ★签名来源（禁止凭记忆）★：每条 (类, 方法名, 描述符) 都由 `javap -s` 实测：
//    · 本文件 68 条 → `scripts/verify_gl2_registry.py`（两套 jar 逐条比对 + 三张表同序核对）
//    · stub 336 条 → `scripts/gen_gl2_stub_table.py`（生成 + 自检：表条数 == jar native 总数）
//
//  ★同一个 GL 名字的 native 不一定在同一个类上★（jar 实测两种落点）：
//    · GL11  ：glBegin/glEnd/glVertex*/glColor*/glNormal*/glTexCoord*/矩阵栈/glTexEnv* …
//    · GL11C ：glEnable/glDisable/glDrawArrays/glTexParameter*/glPolygonMode/glHint/
//              glLogicOp/glPointSize/nglDrawElements
//    ⇒ 表里的 `declClass` 只是「首选类」；首选类上没有就自动在另一类上再试一次
//      （两套 jar 若把某条放在别的类，也不会因此漏登记）。
//
//  ★指针入口登记的是 nglXxx★：jar 里 glVertex2fv / glVertexPointer / glDrawElements …
//    都是 Java 包装（javap 不带 native），真正的 native 是 `nglXxx(long ptr)`。
//    登记 nglXxx 才能覆盖「Buffer / 数组 / long 地址」全部重载（它们最后都汇到 nglXxx）。
//    该 jlong 就是客户端内存地址，直接当指针交给本层实现（见 ①）。
//
//  ★默认不生效★：`A2_GL2_SHIM` 与 `A2_GL2_PROBE` 都没设 ⇒ 一条都不注册。
// ============================================================================
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>   // getenv
#include <string.h>
#include <jni.h>

#import "a2_log.h"
#import "a2_gl2_shim.h"
#import "a2_gl2_jni_probe.h"
#import "a2_gl2_jni_bind.h"

// ============================================================================
//  ① ABI 形状（本层实现 / 原实现共用一套函数指针形状）
// ----------------------------------------------------------------------------
//  为什么两者能共用一套：JNI 的 jint/jfloat/jdouble 就是 int/float/double，jbyte 是 8 位整数；
//  唯一要说明的是指针参数 —— jar 里它是 `jlong ptr`（客户端内存地址），本层实现收的是
//  `const void *`。arm64 / x86_64 上「64 位整数」与「指针」都走通用寄存器、位模式不变
//  ⇒ 同一个形状既能调本层实现，也能转调原实现（只是形参写法不同）。
//  ★这是本文件唯一的 ABI 约定★：改动它必须重新核对全部 68 条。
// ============================================================================
typedef void (*A2GL2FnV)(void);
typedef void (*A2GL2FnI)(int);
typedef void (*A2GL2FnII)(int, int);
typedef void (*A2GL2FnIII)(int, int, int);
typedef void (*A2GL2FnF)(float);
typedef void (*A2GL2FnFF)(float, float);
typedef void (*A2GL2FnFFF)(float, float, float);
typedef void (*A2GL2FnFFFF)(float, float, float, float);
typedef void (*A2GL2FnDD)(double, double);
typedef void (*A2GL2FnDDD)(double, double, double);
typedef void (*A2GL2FnDDDDDD)(double, double, double, double, double, double);
typedef void (*A2GL2FnIF)(int, float);
typedef void (*A2GL2FnIIF)(int, int, float);
typedef void (*A2GL2FnU8x3)(unsigned char, unsigned char, unsigned char);
typedef void (*A2GL2FnU8x4)(unsigned char, unsigned char, unsigned char, unsigned char);
typedef void (*A2GL2FnP)(const void *);
typedef void (*A2GL2FnIP)(int, const void *);
typedef void (*A2GL2FnIIP)(int, int, const void *);
typedef void (*A2GL2FnIIIP)(int, int, int, const void *);

// 原实现的形状 = 同一个 ABI 形状 + 每个 JNI native 都有的 (JNIEnv *, jclass) 头两个参数。
// 为什么不能省：`RegisterNatives` 装的是 JNI 函数，转调它必须按 JNI 的调用约定传 env/cls。
typedef void (*A2GL2JniV)(JNIEnv *, jclass);
typedef void (*A2GL2JniI)(JNIEnv *, jclass, int);
typedef void (*A2GL2JniII)(JNIEnv *, jclass, int, int);
typedef void (*A2GL2JniIII)(JNIEnv *, jclass, int, int, int);
typedef void (*A2GL2JniF)(JNIEnv *, jclass, float);
typedef void (*A2GL2JniFF)(JNIEnv *, jclass, float, float);
typedef void (*A2GL2JniFFF)(JNIEnv *, jclass, float, float, float);
typedef void (*A2GL2JniFFFF)(JNIEnv *, jclass, float, float, float, float);
typedef void (*A2GL2JniDD)(JNIEnv *, jclass, double, double);
typedef void (*A2GL2JniDDD)(JNIEnv *, jclass, double, double, double);
typedef void (*A2GL2JniDDDDDD)(JNIEnv *, jclass, double, double, double, double, double, double);
typedef void (*A2GL2JniIF)(JNIEnv *, jclass, int, float);
typedef void (*A2GL2JniIIF)(JNIEnv *, jclass, int, int, float);
typedef void (*A2GL2JniU8x3)(JNIEnv *, jclass, unsigned char, unsigned char, unsigned char);
typedef void (*A2GL2JniU8x4)(JNIEnv *, jclass, unsigned char, unsigned char,
                             unsigned char, unsigned char);
typedef void (*A2GL2JniP)(JNIEnv *, jclass, const void *);
typedef void (*A2GL2JniIP)(JNIEnv *, jclass, int, const void *);
typedef void (*A2GL2JniIIP)(JNIEnv *, jclass, int, int, const void *);
typedef void (*A2GL2JniIIIP)(JNIEnv *, jclass, int, int, int, const void *);

// ============================================================================
//  ② 索引常量（★与 a2_gl2_jni_probe.m 的登记表同序★；install() 起步会逐条核对，
//     表被重排 ⇒ 直接拒绝安装，不让「装错入口」这种静默错误发生）
// ============================================================================
enum {
    // 立即模式（glBegin/glEnd/glVertex*/glColor*/glTexCoord*/glNormal*）
    kA2GL2IdxBegin = 0,
    kA2GL2IdxEnd = 1,
    kA2GL2IdxVertex2f = 2,
    kA2GL2IdxVertex3f = 3,
    kA2GL2IdxVertex2d = 4,
    kA2GL2IdxVertex3d = 5,
    kA2GL2IdxVertex2i = 6,
    kA2GL2IdxVertex3i = 7,
    kA2GL2IdxVertex2fv = 8,
    kA2GL2IdxVertex3fv = 9,
    kA2GL2IdxColor3f = 10,
    kA2GL2IdxColor4f = 11,
    kA2GL2IdxColor3ub = 12,
    kA2GL2IdxColor4ub = 13,
    kA2GL2IdxColor4fv = 14,
    kA2GL2IdxTexCoord2f = 15,
    kA2GL2IdxTexCoord2d = 16,
    kA2GL2IdxTexCoord2fv = 17,
    kA2GL2IdxNormal3f = 18,
    kA2GL2IdxNormal3fv = 19,

    // 矩阵栈
    kA2GL2IdxMatrixMode = 20,
    kA2GL2IdxLoadIdentity = 21,
    kA2GL2IdxLoadMatrixf = 22,
    kA2GL2IdxMultMatrixf = 23,
    kA2GL2IdxPushMatrix = 24,
    kA2GL2IdxPopMatrix = 25,
    kA2GL2IdxTranslatef = 26,
    kA2GL2IdxScalef = 27,
    kA2GL2IdxRotatef = 28,
    kA2GL2IdxOrtho = 29,
    kA2GL2IdxFrustum = 30,

    // 开关 / 状态（glEnable/glDisable 的 native 在 GL11C，见文件头）
    kA2GL2IdxEnable = 31,
    kA2GL2IdxDisable = 32,
    kA2GL2IdxEnableClientState = 33,
    kA2GL2IdxDisableClientState = 34,
    kA2GL2IdxPushAttrib = 35,
    kA2GL2IdxPopAttrib = 36,
    kA2GL2IdxPushClientAttrib = 37,
    kA2GL2IdxPopClientAttrib = 38,
    kA2GL2IdxShadeModel = 39,
    kA2GL2IdxAlphaFunc = 40,

    // 客户端数组 + 绘制
    kA2GL2IdxVertexPointer = 41,
    kA2GL2IdxColorPointer = 42,
    kA2GL2IdxTexCoordPointer = 43,
    kA2GL2IdxNormalPointer = 44,
    kA2GL2IdxDrawArrays = 45,
    kA2GL2IdxDrawElements = 46,

    // 纹理状态改写
    kA2GL2IdxTexEnvi = 47,
    kA2GL2IdxTexEnvf = 48,
    kA2GL2IdxTexParameteri = 49,
    kA2GL2IdxTexParameterf = 50,

    // 明确忽略（shim 里共用 gl2_ignored：固定管线专属、本层不模拟）
    kA2GL2IdxLightf = 51,
    kA2GL2IdxLighti = 52,
    kA2GL2IdxLightfv = 53,
    kA2GL2IdxLightiv = 54,
    kA2GL2IdxLightModelf = 55,
    kA2GL2IdxLightModelfv = 56,
    kA2GL2IdxMaterialf = 57,
    kA2GL2IdxMaterialfv = 58,
    kA2GL2IdxColorMaterial = 59,
    kA2GL2IdxFogf = 60,
    kA2GL2IdxFogi = 61,
    kA2GL2IdxFogfv = 62,
    kA2GL2IdxClipPlane = 63,
    kA2GL2IdxPolygonMode = 64,
    kA2GL2IdxHint = 65,
    kA2GL2IdxLogicOp = 66,
    kA2GL2IdxPointSize = 67,

    kA2GL2IdxCount = 68,
};

// ============================================================================
//  ③ 状态（全部只被 install/转发读写；无锁：安装只在启动线程一次，转发只读）
// ============================================================================
static void *gOrigFn[kA2GL2IdxCount];      ///< 原 JNI 实现（懒解析：首次转发时 dlsym）
static void *gShimFn[kA2GL2IdxCount];      ///< 本层实现（★每入口只查一次★）
static int   gShimChecked[kA2GL2IdxCount]; ///< 0=尚未查过本层（首命时才查）
static int   gHitLogged[kA2GL2IdxCount];   ///< 首命日志去重（每入口只打一行）
static int   gDropLogged[kA2GL2IdxCount];  ///< 「丢弃」日志去重（每入口只打一行）
static int   gInstalled = -1;              ///< -1=未装 0=未启用/一条都没成功 >0=接管条数（真实现+空实现）
static int   gRealCount = 0;               ///< 其中真实现条数（幂等返回 / Java 侧文案用它）
static void *gLWJGLHandle = NULL;          ///< liblwjgl_opengl.dylib 的 dlopen 句柄

// ============================================================================
//  ④ 打开 liblwjgl_opengl.dylib（唯一产地：原实现只在这张镜像里）
// ----------------------------------------------------------------------------
//  为什么显式 dlopen：一旦我们 RegisterNatives 成功，JVM 就不必再为这批方法去
//  加载 LWJGL 的 native 库 ⇒「关闭本层时转发原实现」这条路会拿不到原符号。
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

/// 懒解析第 idx 条的原实现（唯一调用点：68 个 JNI 转发里「本层未接管」那条分支）。
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
//  调用点：68 个 JNI 转发各一处（见 ⑥）。返回非 NULL = 本层实现，调用方直接调它。
// ============================================================================
static void *a2gl2_enter(int idx) {
    if (idx < 0 || idx >= kA2GL2IdxCount) return NULL;
    // ★每入口只查一次★：glVertex3f 这种入口每帧被调几十万次，
    //   每次都跑 a2_gl2_shim_lookup（70 条 strcmp）会把帧时间吃光。
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

/// 原实现也拿不到时的兜底（唯一调用点：68 个转发里 `a2gl2_orig()` 返回 NULL 的分支）。
static void a2gl2_drop(int idx) {
    if (idx < 0 || idx >= kA2GL2IdxCount) return;
    if (gDropLogged[idx]) return;
    gDropLogged[idx] = 1;
    const char *name = a2_gl2_probe_gl_name(idx);
    a2_log_criterion(@"[A2-GL2] ★丢弃★ %s：本层未实现且原实现不可用",
                     (name != NULL) ? name : "(null)");
}

// ============================================================================
//  ⑥ 68 个 JNI 转发（★唯一注册面★）
// ----------------------------------------------------------------------------
//  谁调它们：RegisterNatives 之后，MC 对 `org.lwjgl.opengl.GL11.glBegin(…)` /
//  `GL11C.glEnable(…)` 的每一次调用都直接落在这里（JNI 符号解析路径；
//  既不经过 eglGetProcAddress，也不经过 a2_gl_bridge_gles_getprocaddress）。
//  三段落：① 本层实现 ② 原实现 ③ 都不可用 ⇒ 丢弃这一次并只打一行日志
//  （绝不抛 Java 异常、绝不中断启动）。
//  签名由 ① 的形状给出、参数由 jar 侧描述符给出（见每条末尾的形状名）。
// ============================================================================
#define A2GL2_FWD(IDX, NAME, JPARAMS, SHAPE, ORIG_SHAPE, ...)                        \
    static void JNICALL a2gl2_j_##NAME JPARAMS {                                      \
        void *shim = a2gl2_enter(IDX);                                                \
        if (shim != NULL) { ((SHAPE)shim)(__VA_ARGS__); return; }                      \
        void *orig = a2gl2_orig(IDX);                                                 \
        if (orig != NULL) { ((ORIG_SHAPE)orig)(env, cls, __VA_ARGS__); return; }        \
        a2gl2_drop(IDX);                                                              \
    }

#define A2GL2_FWD0(IDX, NAME, JPARAMS, SHAPE, ORIG_SHAPE)                             \
    static void JNICALL a2gl2_j_##NAME JPARAMS {                                      \
        void *shim = a2gl2_enter(IDX);                                                \
        if (shim != NULL) { ((SHAPE)shim)(); return; }                                 \
        void *orig = a2gl2_orig(IDX);                                                 \
        if (orig != NULL) { ((ORIG_SHAPE)orig)(env, cls); return; }                     \
        a2gl2_drop(IDX);                                                              \
    }

// ---- 立即模式（glBegin/glEnd/glVertex*/glColor*/glTexCoord*/glNormal*）
A2GL2_FWD(kA2GL2IdxBegin, glBegin, (JNIEnv *env, jclass cls, jint mode), A2GL2FnI, A2GL2JniI, mode)
A2GL2_FWD0(kA2GL2IdxEnd, glEnd, (JNIEnv *env, jclass cls), A2GL2FnV, A2GL2JniV)
A2GL2_FWD(kA2GL2IdxVertex2f, glVertex2f, (JNIEnv *env, jclass cls, jfloat x, jfloat y), A2GL2FnFF, A2GL2JniFF, x, y)
A2GL2_FWD(kA2GL2IdxVertex3f, glVertex3f, (JNIEnv *env, jclass cls, jfloat x, jfloat y, jfloat z), A2GL2FnFFF, A2GL2JniFFF, x, y, z)
A2GL2_FWD(kA2GL2IdxVertex2d, glVertex2d, (JNIEnv *env, jclass cls, jdouble x, jdouble y), A2GL2FnDD, A2GL2JniDD, x, y)
A2GL2_FWD(kA2GL2IdxVertex3d, glVertex3d, (JNIEnv *env, jclass cls, jdouble x, jdouble y, jdouble z), A2GL2FnDDD, A2GL2JniDDD, x, y, z)
A2GL2_FWD(kA2GL2IdxVertex2i, glVertex2i, (JNIEnv *env, jclass cls, jint x, jint y), A2GL2FnII, A2GL2JniII, x, y)
A2GL2_FWD(kA2GL2IdxVertex3i, glVertex3i, (JNIEnv *env, jclass cls, jint x, jint y, jint z), A2GL2FnIII, A2GL2JniIII, x, y, z)
A2GL2_FWD(kA2GL2IdxVertex2fv, nglVertex2fv, (JNIEnv *env, jclass cls, jlong v), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)v)
A2GL2_FWD(kA2GL2IdxVertex3fv, nglVertex3fv, (JNIEnv *env, jclass cls, jlong v), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)v)
A2GL2_FWD(kA2GL2IdxColor3f, glColor3f, (JNIEnv *env, jclass cls, jfloat r, jfloat g, jfloat b), A2GL2FnFFF, A2GL2JniFFF, r, g, b)
A2GL2_FWD(kA2GL2IdxColor4f, glColor4f, (JNIEnv *env, jclass cls, jfloat r, jfloat g, jfloat b, jfloat a), A2GL2FnFFFF, A2GL2JniFFFF, r, g, b, a)
A2GL2_FWD(kA2GL2IdxColor3ub, glColor3ub, (JNIEnv *env, jclass cls, jbyte r, jbyte g, jbyte b), A2GL2FnU8x3, A2GL2JniU8x3, r, g, b)
A2GL2_FWD(kA2GL2IdxColor4ub, glColor4ub, (JNIEnv *env, jclass cls, jbyte r, jbyte g, jbyte b, jbyte a), A2GL2FnU8x4, A2GL2JniU8x4, r, g, b, a)
A2GL2_FWD(kA2GL2IdxColor4fv, nglColor4fv, (JNIEnv *env, jclass cls, jlong v), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)v)
A2GL2_FWD(kA2GL2IdxTexCoord2f, glTexCoord2f, (JNIEnv *env, jclass cls, jfloat s, jfloat t), A2GL2FnFF, A2GL2JniFF, s, t)
A2GL2_FWD(kA2GL2IdxTexCoord2d, glTexCoord2d, (JNIEnv *env, jclass cls, jdouble s, jdouble t), A2GL2FnDD, A2GL2JniDD, s, t)
A2GL2_FWD(kA2GL2IdxTexCoord2fv, nglTexCoord2fv, (JNIEnv *env, jclass cls, jlong v), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)v)
A2GL2_FWD(kA2GL2IdxNormal3f, glNormal3f, (JNIEnv *env, jclass cls, jfloat x, jfloat y, jfloat z), A2GL2FnFFF, A2GL2JniFFF, x, y, z)
A2GL2_FWD(kA2GL2IdxNormal3fv, nglNormal3fv, (JNIEnv *env, jclass cls, jlong v), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)v)

// ---- 矩阵栈
A2GL2_FWD(kA2GL2IdxMatrixMode, glMatrixMode, (JNIEnv *env, jclass cls, jint mode), A2GL2FnI, A2GL2JniI, mode)
A2GL2_FWD0(kA2GL2IdxLoadIdentity, glLoadIdentity, (JNIEnv *env, jclass cls), A2GL2FnV, A2GL2JniV)
A2GL2_FWD(kA2GL2IdxLoadMatrixf, nglLoadMatrixf, (JNIEnv *env, jclass cls, jlong m), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)m)
A2GL2_FWD(kA2GL2IdxMultMatrixf, nglMultMatrixf, (JNIEnv *env, jclass cls, jlong m), A2GL2FnP, A2GL2JniP, (const void *)(intptr_t)m)
A2GL2_FWD0(kA2GL2IdxPushMatrix, glPushMatrix, (JNIEnv *env, jclass cls), A2GL2FnV, A2GL2JniV)
A2GL2_FWD0(kA2GL2IdxPopMatrix, glPopMatrix, (JNIEnv *env, jclass cls), A2GL2FnV, A2GL2JniV)
A2GL2_FWD(kA2GL2IdxTranslatef, glTranslatef, (JNIEnv *env, jclass cls, jfloat x, jfloat y, jfloat z), A2GL2FnFFF, A2GL2JniFFF, x, y, z)
A2GL2_FWD(kA2GL2IdxScalef, glScalef, (JNIEnv *env, jclass cls, jfloat x, jfloat y, jfloat z), A2GL2FnFFF, A2GL2JniFFF, x, y, z)
A2GL2_FWD(kA2GL2IdxRotatef, glRotatef, (JNIEnv *env, jclass cls, jfloat angle, jfloat x, jfloat y, jfloat z), A2GL2FnFFFF, A2GL2JniFFFF, angle, x, y, z)
A2GL2_FWD(kA2GL2IdxOrtho, glOrtho, (JNIEnv *env, jclass cls, jdouble l, jdouble r, jdouble b, jdouble t, jdouble n, jdouble f), A2GL2FnDDDDDD, A2GL2JniDDDDDD, l, r, b, t, n, f)
A2GL2_FWD(kA2GL2IdxFrustum, glFrustum, (JNIEnv *env, jclass cls, jdouble l, jdouble r, jdouble b, jdouble t, jdouble n, jdouble f), A2GL2FnDDDDDD, A2GL2JniDDDDDD, l, r, b, t, n, f)

// ---- 开关 / 状态（glEnable/glDisable 的 native 在 GL11C，见文件头）
A2GL2_FWD(kA2GL2IdxEnable, glEnable, (JNIEnv *env, jclass cls, jint cap), A2GL2FnI, A2GL2JniI, cap)
A2GL2_FWD(kA2GL2IdxDisable, glDisable, (JNIEnv *env, jclass cls, jint cap), A2GL2FnI, A2GL2JniI, cap)
A2GL2_FWD(kA2GL2IdxEnableClientState, glEnableClientState, (JNIEnv *env, jclass cls, jint array), A2GL2FnI, A2GL2JniI, array)
A2GL2_FWD(kA2GL2IdxDisableClientState, glDisableClientState, (JNIEnv *env, jclass cls, jint array), A2GL2FnI, A2GL2JniI, array)
A2GL2_FWD(kA2GL2IdxPushAttrib, glPushAttrib, (JNIEnv *env, jclass cls, jint mask), A2GL2FnI, A2GL2JniI, mask)
A2GL2_FWD0(kA2GL2IdxPopAttrib, glPopAttrib, (JNIEnv *env, jclass cls), A2GL2FnV, A2GL2JniV)
A2GL2_FWD(kA2GL2IdxPushClientAttrib, glPushClientAttrib, (JNIEnv *env, jclass cls, jint mask), A2GL2FnI, A2GL2JniI, mask)
A2GL2_FWD0(kA2GL2IdxPopClientAttrib, glPopClientAttrib, (JNIEnv *env, jclass cls), A2GL2FnV, A2GL2JniV)
A2GL2_FWD(kA2GL2IdxShadeModel, glShadeModel, (JNIEnv *env, jclass cls, jint mode), A2GL2FnI, A2GL2JniI, mode)
A2GL2_FWD(kA2GL2IdxAlphaFunc, glAlphaFunc, (JNIEnv *env, jclass cls, jint func, jfloat ref), A2GL2FnIF, A2GL2JniIF, func, ref)

// ---- 客户端数组 + 绘制
A2GL2_FWD(kA2GL2IdxVertexPointer, nglVertexPointer, (JNIEnv *env, jclass cls, jint size, jint type, jint stride, jlong ptr), A2GL2FnIIIP, A2GL2JniIIIP, size, type, stride, (const void *)(intptr_t)ptr)
A2GL2_FWD(kA2GL2IdxColorPointer, nglColorPointer, (JNIEnv *env, jclass cls, jint size, jint type, jint stride, jlong ptr), A2GL2FnIIIP, A2GL2JniIIIP, size, type, stride, (const void *)(intptr_t)ptr)
A2GL2_FWD(kA2GL2IdxTexCoordPointer, nglTexCoordPointer, (JNIEnv *env, jclass cls, jint size, jint type, jint stride, jlong ptr), A2GL2FnIIIP, A2GL2JniIIIP, size, type, stride, (const void *)(intptr_t)ptr)
A2GL2_FWD(kA2GL2IdxNormalPointer, nglNormalPointer, (JNIEnv *env, jclass cls, jint type, jint stride, jlong ptr), A2GL2FnIIP, A2GL2JniIIP, type, stride, (const void *)(intptr_t)ptr)
A2GL2_FWD(kA2GL2IdxDrawArrays, glDrawArrays, (JNIEnv *env, jclass cls, jint mode, jint first, jint count), A2GL2FnIII, A2GL2JniIII, mode, first, count)
A2GL2_FWD(kA2GL2IdxDrawElements, nglDrawElements, (JNIEnv *env, jclass cls, jint mode, jint count, jint type, jlong indices), A2GL2FnIIIP, A2GL2JniIIIP, mode, count, type, (const void *)(intptr_t)indices)

// ---- 纹理状态改写
A2GL2_FWD(kA2GL2IdxTexEnvi, glTexEnvi, (JNIEnv *env, jclass cls, jint target, jint pname, jint param), A2GL2FnIII, A2GL2JniIII, target, pname, param)
A2GL2_FWD(kA2GL2IdxTexEnvf, glTexEnvf, (JNIEnv *env, jclass cls, jint target, jint pname, jfloat param), A2GL2FnIIF, A2GL2JniIIF, target, pname, param)
A2GL2_FWD(kA2GL2IdxTexParameteri, glTexParameteri, (JNIEnv *env, jclass cls, jint target, jint pname, jint param), A2GL2FnIII, A2GL2JniIII, target, pname, param)
A2GL2_FWD(kA2GL2IdxTexParameterf, glTexParameterf, (JNIEnv *env, jclass cls, jint target, jint pname, jfloat param), A2GL2FnIIF, A2GL2JniIIF, target, pname, param)

// ---- 明确忽略（shim 里共用 gl2_ignored：固定管线专属、本层不模拟）
A2GL2_FWD(kA2GL2IdxLightf, glLightf, (JNIEnv *env, jclass cls, jint light, jint pname, jfloat param), A2GL2FnIIF, A2GL2JniIIF, light, pname, param)
A2GL2_FWD(kA2GL2IdxLighti, glLighti, (JNIEnv *env, jclass cls, jint light, jint pname, jint param), A2GL2FnIII, A2GL2JniIII, light, pname, param)
A2GL2_FWD(kA2GL2IdxLightfv, nglLightfv, (JNIEnv *env, jclass cls, jint light, jint pname, jlong params), A2GL2FnIIP, A2GL2JniIIP, light, pname, (const void *)(intptr_t)params)
A2GL2_FWD(kA2GL2IdxLightiv, nglLightiv, (JNIEnv *env, jclass cls, jint light, jint pname, jlong params), A2GL2FnIIP, A2GL2JniIIP, light, pname, (const void *)(intptr_t)params)
A2GL2_FWD(kA2GL2IdxLightModelf, glLightModelf, (JNIEnv *env, jclass cls, jint pname, jfloat param), A2GL2FnIF, A2GL2JniIF, pname, param)
A2GL2_FWD(kA2GL2IdxLightModelfv, nglLightModelfv, (JNIEnv *env, jclass cls, jint pname, jlong params), A2GL2FnIP, A2GL2JniIP, pname, (const void *)(intptr_t)params)
A2GL2_FWD(kA2GL2IdxMaterialf, glMaterialf, (JNIEnv *env, jclass cls, jint face, jint pname, jfloat param), A2GL2FnIIF, A2GL2JniIIF, face, pname, param)
A2GL2_FWD(kA2GL2IdxMaterialfv, nglMaterialfv, (JNIEnv *env, jclass cls, jint face, jint pname, jlong params), A2GL2FnIIP, A2GL2JniIIP, face, pname, (const void *)(intptr_t)params)
A2GL2_FWD(kA2GL2IdxColorMaterial, glColorMaterial, (JNIEnv *env, jclass cls, jint face, jint mode), A2GL2FnII, A2GL2JniII, face, mode)
A2GL2_FWD(kA2GL2IdxFogf, glFogf, (JNIEnv *env, jclass cls, jint pname, jfloat param), A2GL2FnIF, A2GL2JniIF, pname, param)
A2GL2_FWD(kA2GL2IdxFogi, glFogi, (JNIEnv *env, jclass cls, jint pname, jint param), A2GL2FnII, A2GL2JniII, pname, param)
A2GL2_FWD(kA2GL2IdxFogfv, nglFogfv, (JNIEnv *env, jclass cls, jint pname, jlong params), A2GL2FnIP, A2GL2JniIP, pname, (const void *)(intptr_t)params)
A2GL2_FWD(kA2GL2IdxClipPlane, nglClipPlane, (JNIEnv *env, jclass cls, jint plane, jlong equation), A2GL2FnIP, A2GL2JniIP, plane, (const void *)(intptr_t)equation)
A2GL2_FWD(kA2GL2IdxPolygonMode, glPolygonMode, (JNIEnv *env, jclass cls, jint face, jint mode), A2GL2FnII, A2GL2JniII, face, mode)
A2GL2_FWD(kA2GL2IdxHint, glHint, (JNIEnv *env, jclass cls, jint target, jint mode), A2GL2FnII, A2GL2JniII, target, mode)
A2GL2_FWD(kA2GL2IdxLogicOp, glLogicOp, (JNIEnv *env, jclass cls, jint opcode), A2GL2FnI, A2GL2JniI, opcode)
A2GL2_FWD(kA2GL2IdxPointSize, glPointSize, (JNIEnv *env, jclass cls, jfloat size), A2GL2FnF, A2GL2JniF, size)

// 转发器全部生成完 ⇒ 立刻收回两个宏：表里只许引用生成出来的函数名，
// 后面再有人拿这两个宏「顺手加一条」就会在这里编译失败（而不是悄悄多一条没人核过的入口）。
#undef A2GL2_FWD
#undef A2GL2_FWD0

// ============================================================================
//  ⑦ 登记表（★名字 / 描述符 / 类与 jar 里逐字一致；写错会在注册前被签名核对拦下★）
// ----------------------------------------------------------------------------
//  idx     = 与 a2_gl2_jni_probe.m 同序（install 起步逐条核对）
//  glName  = 交给 a2_gl2_shim_lookup 的 GL 入口名（指针入口也是 gl 名，不是 ngl 名）
//  jniName = Java 侧 native 方法名（指针入口是 nglXxx）
//  declClass = 首选类（jar 实测）；首选类上没有 ⇒ 自动换另一类
// ============================================================================
enum { A2GL2_CLASS_GL11 = 0, A2GL2_CLASS_GL11C = 1, A2GL2_CLASS_GL15C = 2 };

typedef struct {
    int         idx;
    const char *glName;
    const char *jniName;
    const char *sig;
    int         declClass;
    void       *fn;
} A2GL2Method;

static const A2GL2Method kA2GL2Methods[] = {
    // ---- 立即模式（glBegin/glEnd/glVertex*/glColor*/glTexCoord*/glNormal*）
    { kA2GL2IdxBegin, "glBegin", "glBegin", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glBegin },
    { kA2GL2IdxEnd, "glEnd", "glEnd", "()V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glEnd },
    { kA2GL2IdxVertex2f, "glVertex2f", "glVertex2f", "(FF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glVertex2f },
    { kA2GL2IdxVertex3f, "glVertex3f", "glVertex3f", "(FFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glVertex3f },
    { kA2GL2IdxVertex2d, "glVertex2d", "glVertex2d", "(DD)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glVertex2d },
    { kA2GL2IdxVertex3d, "glVertex3d", "glVertex3d", "(DDD)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glVertex3d },
    { kA2GL2IdxVertex2i, "glVertex2i", "glVertex2i", "(II)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glVertex2i },
    { kA2GL2IdxVertex3i, "glVertex3i", "glVertex3i", "(III)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glVertex3i },
    { kA2GL2IdxVertex2fv, "glVertex2fv", "nglVertex2fv", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglVertex2fv },
    { kA2GL2IdxVertex3fv, "glVertex3fv", "nglVertex3fv", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglVertex3fv },
    { kA2GL2IdxColor3f, "glColor3f", "glColor3f", "(FFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glColor3f },
    { kA2GL2IdxColor4f, "glColor4f", "glColor4f", "(FFFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glColor4f },
    { kA2GL2IdxColor3ub, "glColor3ub", "glColor3ub", "(BBB)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glColor3ub },
    { kA2GL2IdxColor4ub, "glColor4ub", "glColor4ub", "(BBBB)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glColor4ub },
    { kA2GL2IdxColor4fv, "glColor4fv", "nglColor4fv", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglColor4fv },
    { kA2GL2IdxTexCoord2f, "glTexCoord2f", "glTexCoord2f", "(FF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glTexCoord2f },
    { kA2GL2IdxTexCoord2d, "glTexCoord2d", "glTexCoord2d", "(DD)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glTexCoord2d },
    { kA2GL2IdxTexCoord2fv, "glTexCoord2fv", "nglTexCoord2fv", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglTexCoord2fv },
    { kA2GL2IdxNormal3f, "glNormal3f", "glNormal3f", "(FFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glNormal3f },
    { kA2GL2IdxNormal3fv, "glNormal3fv", "nglNormal3fv", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglNormal3fv },

    // ---- 矩阵栈
    { kA2GL2IdxMatrixMode, "glMatrixMode", "glMatrixMode", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glMatrixMode },
    { kA2GL2IdxLoadIdentity, "glLoadIdentity", "glLoadIdentity", "()V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glLoadIdentity },
    { kA2GL2IdxLoadMatrixf, "glLoadMatrixf", "nglLoadMatrixf", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglLoadMatrixf },
    { kA2GL2IdxMultMatrixf, "glMultMatrixf", "nglMultMatrixf", "(J)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglMultMatrixf },
    { kA2GL2IdxPushMatrix, "glPushMatrix", "glPushMatrix", "()V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glPushMatrix },
    { kA2GL2IdxPopMatrix, "glPopMatrix", "glPopMatrix", "()V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glPopMatrix },
    { kA2GL2IdxTranslatef, "glTranslatef", "glTranslatef", "(FFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glTranslatef },
    { kA2GL2IdxScalef, "glScalef", "glScalef", "(FFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glScalef },
    { kA2GL2IdxRotatef, "glRotatef", "glRotatef", "(FFFF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glRotatef },
    { kA2GL2IdxOrtho, "glOrtho", "glOrtho", "(DDDDDD)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glOrtho },
    { kA2GL2IdxFrustum, "glFrustum", "glFrustum", "(DDDDDD)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glFrustum },

    // ---- 开关 / 状态（glEnable/glDisable 的 native 在 GL11C，见文件头）
    { kA2GL2IdxEnable, "glEnable", "glEnable", "(I)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glEnable },
    { kA2GL2IdxDisable, "glDisable", "glDisable", "(I)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glDisable },
    { kA2GL2IdxEnableClientState, "glEnableClientState", "glEnableClientState", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glEnableClientState },
    { kA2GL2IdxDisableClientState, "glDisableClientState", "glDisableClientState", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glDisableClientState },
    { kA2GL2IdxPushAttrib, "glPushAttrib", "glPushAttrib", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glPushAttrib },
    { kA2GL2IdxPopAttrib, "glPopAttrib", "glPopAttrib", "()V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glPopAttrib },
    { kA2GL2IdxPushClientAttrib, "glPushClientAttrib", "glPushClientAttrib", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glPushClientAttrib },
    { kA2GL2IdxPopClientAttrib, "glPopClientAttrib", "glPopClientAttrib", "()V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glPopClientAttrib },
    { kA2GL2IdxShadeModel, "glShadeModel", "glShadeModel", "(I)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glShadeModel },
    { kA2GL2IdxAlphaFunc, "glAlphaFunc", "glAlphaFunc", "(IF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glAlphaFunc },

    // ---- 客户端数组 + 绘制
    { kA2GL2IdxVertexPointer, "glVertexPointer", "nglVertexPointer", "(IIIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglVertexPointer },
    { kA2GL2IdxColorPointer, "glColorPointer", "nglColorPointer", "(IIIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglColorPointer },
    { kA2GL2IdxTexCoordPointer, "glTexCoordPointer", "nglTexCoordPointer", "(IIIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglTexCoordPointer },
    { kA2GL2IdxNormalPointer, "glNormalPointer", "nglNormalPointer", "(IIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglNormalPointer },
    { kA2GL2IdxDrawArrays, "glDrawArrays", "glDrawArrays", "(III)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glDrawArrays },
    { kA2GL2IdxDrawElements, "glDrawElements", "nglDrawElements", "(IIIJ)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_nglDrawElements },

    // ---- 纹理状态改写
    { kA2GL2IdxTexEnvi, "glTexEnvi", "glTexEnvi", "(III)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glTexEnvi },
    { kA2GL2IdxTexEnvf, "glTexEnvf", "glTexEnvf", "(IIF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glTexEnvf },
    { kA2GL2IdxTexParameteri, "glTexParameteri", "glTexParameteri", "(III)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glTexParameteri },
    { kA2GL2IdxTexParameterf, "glTexParameterf", "glTexParameterf", "(IIF)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glTexParameterf },

    // ---- 明确忽略（shim 里共用 gl2_ignored：固定管线专属、本层不模拟）
    { kA2GL2IdxLightf, "glLightf", "glLightf", "(IIF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glLightf },
    { kA2GL2IdxLighti, "glLighti", "glLighti", "(III)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glLighti },
    { kA2GL2IdxLightfv, "glLightfv", "nglLightfv", "(IIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglLightfv },
    { kA2GL2IdxLightiv, "glLightiv", "nglLightiv", "(IIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglLightiv },
    { kA2GL2IdxLightModelf, "glLightModelf", "glLightModelf", "(IF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glLightModelf },
    { kA2GL2IdxLightModelfv, "glLightModelfv", "nglLightModelfv", "(IJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglLightModelfv },
    { kA2GL2IdxMaterialf, "glMaterialf", "glMaterialf", "(IIF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glMaterialf },
    { kA2GL2IdxMaterialfv, "glMaterialfv", "nglMaterialfv", "(IIJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglMaterialfv },
    { kA2GL2IdxColorMaterial, "glColorMaterial", "glColorMaterial", "(II)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glColorMaterial },
    { kA2GL2IdxFogf, "glFogf", "glFogf", "(IF)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glFogf },
    { kA2GL2IdxFogi, "glFogi", "glFogi", "(II)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_glFogi },
    { kA2GL2IdxFogfv, "glFogfv", "nglFogfv", "(IJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglFogfv },
    { kA2GL2IdxClipPlane, "glClipPlane", "nglClipPlane", "(IJ)V", A2GL2_CLASS_GL11, (void *)a2gl2_j_nglClipPlane },
    { kA2GL2IdxPolygonMode, "glPolygonMode", "glPolygonMode", "(II)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glPolygonMode },
    { kA2GL2IdxHint, "glHint", "glHint", "(II)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glHint },
    { kA2GL2IdxLogicOp, "glLogicOp", "glLogicOp", "(I)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glLogicOp },
    { kA2GL2IdxPointSize, "glPointSize", "glPointSize", "(F)V", A2GL2_CLASS_GL11C, (void *)a2gl2_j_glPointSize },
};

/// 本层实现了、但 jar 里没有可登记的 native 声明（安装时逐条打印，不进登记表）。
typedef struct { const char *glName; const char *why; } A2GL2Skip;

static const A2GL2Skip kA2GL2Skips[] = {
    { "glOrthof", "GL11/GL11C 都没有这个 native 声明（桌面 GL 1.1 无 glOrthof，是 ES 专名）⇒ 没有可登记的方法" },
    { "glFrustumf", "GL11/GL11C 都没有这个 native 声明（同上；MC 走的是 glFrustum）⇒ 没有可登记的方法" },
};

#define A2GL2_COUNT_OF(a) ((int)(sizeof(a) / sizeof((a)[0])))

/// 类的内部名（日志/核对用）。
/// 调用点：`a2gl2_verify_table()`（核对探针表与登记表的首选类）、`a2_gl2_jni_install()`（登记落点日志）、
/// `a2gl2_install_stubs()`（空实现未装时的逐条日志）。
static const char *a2gl2_class_name(int kind) {
    return (kind == A2GL2_CLASS_GL11) ? "org/lwjgl/opengl/GL11" : "org/lwjgl/opengl/GL11C";
}

// ============================================================================
//  ⑧ 空实现（stub）面：生成式表 + 「已被真实现占住」集合
// ----------------------------------------------------------------------------
//  表本体是**生成**的（`scripts/gen_gl2_stub_table.py`，签名全部由 javap 从
//  `Libraries/Jars/lwjgl-2/lwjgl-opengl-3.2.3.jar` 实测）：里面是 N 个按描述符归类的
//  no-op 函数 + 一张 `kA2GL2Stubs[]`（类 / 方法名 / 描述符 / 函数指针），条数 = jar 里
//  GL11+GL11C 的 native 总数（由生成器自检保证）。
//  ★为什么不在这里手写★：336 条手写必然漏；漏一条就是一次 NULL 间接调用 = 一次 os::abort。
//  ★为什么 stub 必须是 no-op 而不是「调原来的」★：本层接管 GL 过程后 LWJGL 已经拿不到
//  可用的 GL 过程地址，转调原实现等于原地再踩一次空。no-op 的语义是「这条入口的效果不模拟，
//  但调用安全通过」—— 唯一安全的做法。
// ============================================================================
#include "a2_gl2_stub_table.h"

// 编译期钉住类编号同义：stub 表里写的是 0/1，必须与 A2GL2_CLASS_* 完全同义。
// 不同义 ⇒ 「把 GL11C 的入口装到 GL11 上」这种静默错误（只会表现为画面不对，日志里看不出来）。
// 用 typedef 而不是 _Static_assert：本项目不假设 C11，这个写法在任何 ObjC 语言标准下都成立。
typedef char a2gl2_stub_class_kind_must_match
    [(A2GL2_CLASS_GL11 == 0 && A2GL2_CLASS_GL11C == 1) ? 1 : -1];

/// 「已被真实现占住」的一条 (类, 方法名, 描述符)。
typedef struct { int kind; const char *name; const char *sig; } A2GL2Taken;

// 容量：真实现每条最多记 4 格（落地类/另一类 × 主名字/GL 名），68 条远小于此上限；
// 写满时静默不记（宁可不记也不越界）—— 上限取 stub 表条数 + 128，一眼能看出够用。
static A2GL2Taken gTaken[A2GL2_STUB_COUNT + 128];
static int gTakenCount = 0;

/// 记一条「已被真实现占住」的 (类, 名字, 描述符)。幂等：重复记录无副作用。
/// 调用点：`a2gl2_register_raw()` 的调用方（真实现登记成功处，每次 4 次，见 ⑪）。
static void a2gl2_taken_add(int kind, const char *name, const char *sig) {
    if (name == NULL || sig == NULL) return;
    for (int i = 0; i < gTakenCount; i++) {
        if (gTaken[i].kind == kind && strcmp(gTaken[i].name, name) == 0
            && strcmp(gTaken[i].sig, sig) == 0) {
            return;
        }
    }
    if (gTakenCount >= (int)(sizeof(gTaken) / sizeof(gTaken[0]))) return;
    gTaken[gTakenCount].kind = kind;
    gTaken[gTakenCount].name = name;
    gTaken[gTakenCount].sig = sig;
    gTakenCount++;
}

/// 这条 (类, 名字, 描述符) 是否已被真实现占住。
/// @return 1 = 占住了 ⇒ ★不许 stub 覆盖★  0 = 空着，可以装 no-op
/// 调用点：`a2gl2_install_stubs()` 的每一条（本文件唯一调用点）。
static int a2gl2_taken_has(int kind, const char *name, const char *sig) {
    if (name == NULL || sig == NULL) return 0;
    for (int i = 0; i < gTakenCount; i++) {
        if (gTaken[i].kind == kind && strcmp(gTaken[i].name, name) == 0
            && strcmp(gTaken[i].sig, sig) == 0) {
            return 1;
        }
    }
    return 0;
}

// ============================================================================
//  ⑨ 表序核对（唯一调用点：a2_gl2_jni_install 开头）
// ----------------------------------------------------------------------------
//  索引常量与探针登记表分处两个文件 ⇒ 必须机器核对；表被重排就等于把
//  glEnd 装成 glBegin，这种错只会表现为「画面全黑」，从日志里查不出来。
// ============================================================================
static int a2gl2_verify_table(void) {
    const int n = A2GL2_COUNT_OF(kA2GL2Methods);
    if (a2_gl2_probe_entry_count() != n) {
        a2_log_criterion(@"[A2-GL2] ★拒绝安装★ 本文件登记表=%d 条，探针登记表=%d 条（两者必须同序同长）",
                         n, a2_gl2_probe_entry_count());
        return 0;
    }
    for (int i = 0; i < n; i++) {
        const A2GL2Method *m = &kA2GL2Methods[i];
        if (m->idx != i) {
            a2_log_criterion(@"[A2-GL2] ★拒绝安装★ 第 %d 条 %s 的 idx=%d（登记表必须按 idx 升序排）",
                             i, m->glName, m->idx);
            return 0;
        }
        const char *name = a2_gl2_probe_gl_name(i);
        if (name == NULL || strcmp(name, m->glName) != 0) {
            a2_log_criterion(@"[A2-GL2] ★拒绝安装★ 第 %d 条名字=%s，探针登记表=%s",
                             i, m->glName, (name != NULL) ? name : "(null)");
            return 0;
        }
        const char *decl = a2_gl2_probe_declaring_class(i);
        const char *want = a2gl2_class_name(m->declClass);
        if (decl == NULL || strcmp(decl, want) != 0) {
            a2_log_criterion(@"[A2-GL2] ★拒绝安装★ 第 %d 条 %s 的首选类：登记表=%s，探针登记表=%s",
                             i, m->glName, want, (decl != NULL) ? decl : "(null)");
            return 0;
        }
    }
    return 1;
}

// ============================================================================
//  ⑩ 逐条注册（★唯一产地★）
// ----------------------------------------------------------------------------
//  为什么要「先验 native 再登记」：GL11 上大量 glXxx 是 Java 包装（javap 不带 native），
//  描述符对得上、`GetStaticMethodID` 也成功，但它不是 native ⇒ `RegisterNatives` 会失败。
//  为什么逐条登记（每次 1 条）而不是整批：整批里只要一条不是 native，ART 会回 JNI_ERR，
//  而它可能已经把前面几条登记成功 —— 表现是「一部分入口被接管」，最难查。
//  逐条登记把失败精确到 1 条，且任何一条失败都不影响其它条（绝不阻断启动）。
//
//  ★反射面缓存★：本文件现在要为 68+336 条各验一次 native，`FindClass`/
//  `GetMethodID` 每次都要走一遍类查找与符号解析 —— 真机启动期是实打实的开销。
//  `java.lang.reflect.Method` 的类和 `getModifiers` 的 id 在进程内恒定 ⇒ 取一次即可。
// ============================================================================
static unsigned  gA2GL2BoundTex = 0;   ///< 当前绑定的 GL 纹理名（glBindTexture 写入，TexImage 读取）
static jclass    gReflectMethodClass = NULL;   ///< java/lang/reflect/Method（全局引用，取一次）
static jmethodID gReflectGetModifiers = NULL;  ///< Method.getModifiers()I

/// 该 (类, 方法名, 描述符) 是不是一个 static native。
/// @return 1=native（可登记） 0=存在但是 Java 包装 -1=这个类上没有这个 static 方法
static int a2gl2_native_state(JNIEnv *env, jclass cls, const char *name, const char *sig) {
    jmethodID mid = (*env)->GetStaticMethodID(env, cls, name, sig);
    if (mid == NULL) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        return -1;      // GetStaticMethodID 只认 static 方法 ⇒ 找不到 = 不是 static 或描述符不符
    }
    if (gReflectMethodClass == NULL) {
        jclass local = (*env)->FindClass(env, "java/lang/reflect/Method");
        if (local != NULL) {
            gReflectMethodClass = (jclass)(*env)->NewGlobalRef(env, local);
            (*env)->DeleteLocalRef(env, local);
            if (gReflectMethodClass != NULL) {
                gReflectGetModifiers = (*env)->GetMethodID(env, gReflectMethodClass,
                                                          "getModifiers", "()I");
            }
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        }
    }
    int result = -1;
    jobject ref = (*env)->ToReflectedMethod(env, cls, mid, JNI_TRUE);
    if (ref != NULL && gReflectMethodClass != NULL && gReflectGetModifiers != NULL) {
        jint mods = (*env)->CallIntMethod(env, ref, gReflectGetModifiers);
        result = ((mods & 0x0100) != 0) ? 1 : 0;    // 0x0100 = java.lang.reflect.Modifier.NATIVE
    }
    if (ref != NULL) (*env)->DeleteLocalRef(env, ref);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    return result;
}

/// 把一条 (名字, 描述符, 函数指针) 装到 cls 上 —— 真实现与空实现共用的**唯一**登记口。
/// @param name 要登记的 Java 侧 native 方法名（主名字 m->jniName，或另一套命名 m->glName）
/// @param why  失败时写入原因（静态字符串，调用方直接打日志）
/// @return 1=已登记 0=跳过（失败原因写进 *why，绝不抛 Java 异常）
static int a2gl2_register_raw(JNIEnv *env, jclass cls, const char *name, const char *sig,
                              void *fn, const char **why) {
    const int st = a2gl2_native_state(env, cls, name, sig);
    if (st < 0) {
        *why = "这个类上没有该 static 方法（描述符不符，LWJGL 版本可能变了）";
        return 0;
    }
    if (st == 0) {
        *why = "这条在 jar 里是 Java 包装（非 native）⇒ RegisterNatives 收不下";
        return 0;
    }
    if (fn == NULL) {
        *why = "函数指针为 NULL（登记进去就是一个新的踩空点）";
        return 0;
    }
    JNINativeMethod nm;
    nm.name = (char *)name;
    nm.signature = (char *)sig;
    nm.fnPtr = fn;
    const jint rc = (*env)->RegisterNatives(env, cls, &nm, 1);
    if (rc != JNI_OK) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        *why = "RegisterNatives 返回非 JNI_OK（该 native 已被别处占用或类状态异常）";
        return 0;
    }
    return 1;
}

/// 把一条**真实现**登记表条目装到 cls 上（调用点：`a2_gl2_jni_install` 的 ②）。
static int a2gl2_register_one(JNIEnv *env, jclass cls, const A2GL2Method *m,
                              const char *name, const char **why) {
    return a2gl2_register_raw(env, cls, name, m->sig, m->fn, why);
}

// ============================================================================
//  ⑪ 空实现（stub）安装 —— 只填「真实现没占住」的坑
// ----------------------------------------------------------------------------
//  为什么单独一段、且必须排在真实现之后：stub 的合法作用域只有「本层没实现」的入口。
//  真实现先落、落成什么名字/落在哪个类都记进 taken 集，stub 逐条查 taken 跳过
//  ⇒ 已实现的 68 条在任何情况下都不会被 no-op 顶掉（本文件最硬的一条约束）。
//  为什么在「本层未启用」时一条都不装：no-op 是**行为改变**（本来会调 LWJGL 的实现，
//  现在什么都不做）。`A2_GL2_PROBE=1` 只取证的承诺不能因为 stub 而破。
//  为什么失败只跳过这一条：单条失败（类上没这个 static 方法 / 已被占用）不影响别人；
//  整批注册会「一条坏、全批回滚」，反而留下最难查的部分接管状态。
//
//  ★空实现的语义边界（必须读）★：no-op 只保证「调用不踩空」，**不保证这条入口有效果**。
//  本层的真实现只覆盖固定管线（§kA2GL2Entries 的 70 个名字 ⇒ 68 条可登记），
//  所以 `nglGenTextures` / `nglBindTexture` / `nglTexImage2D` / `nglGetIntegerv` /
//  `nglReadPixels` 这类**资源与取数**入口一旦被 stub 接管，就会变成「安全但无效」：
//  纹理不会真的生成、`glGetIntegerv` 不会写回缓冲。这是本轮**已知且已被接受**的取舍
//  （换来的是「不再 SIGSEGV」）；需要某个入口真的生效 ⇒ 去 `a2_gl2_shim.m` 补真实现，
//  真实现优先级永远高于 stub。要复现接入前的行为做对照 ⇒ `A2_GL2_STUB=0`。
// ============================================================================
typedef struct {
    int total;    ///< 表里一共多少条（= jar native 总数）
    int ok;       ///< 真的装上了 no-op 的条数
    int covered;  ///< 被真实现占住、故意免装的条数
    int failed;   ///< 想装但失败的条数（已逐条打日志）
} A2GL2StubStats;

// ----------------------------------------------------------------------------
//  ★值敏感入口的最小例外（不是第二张实现表）★
// ----------------------------------------------------------------------------
//  绝大多数 no-op 返回 0 / JNI_FALSE 是安全的（0 在 GL 语义里就是「没有 / 没启用 /
//  没有错误」）。但有极少数入口，Java 侧会把返回值当成**指针**继续用 —— 返回 0
//  不是「空操作」，而是**制造一个新的空指针**。这类入口给一个「安全常量」，仍然
//  不碰 GL、仍然不是真实现，只是不让默认值把调用方带崩。
//
//  唯一一条（依据：javap -c 实测调用链，不是推测）：
//    GL11C.nglGetString(I)J
//      ← GL11C.glGetString(I)Ljava/lang/String; 里第 5-6 条字节码：
//        lload_1 → invokestatic MemoryUtil.memUTF8Safe(J)Ljava/lang/String;
//      ⇒ 返回 0 时 memUTF8Safe 给 null，MC 拿版本串/扩展串的地方会 NPE。
//      ⇒ 这里返回一段静态 ASCII，语义仍然是「这条入口没有真实现」。
//
//  ★加条目的门槛★：只有「默认返回 0 会让 Java 侧解引用空指针」才加。
//  想让某个入口**真的生效**，去 `a2_gl2_shim.m` 补真实现（那条路优先级更高）。
// ----------------------------------------------------------------------------
static char kA2GL2StubString[] = "Air2-GL2";

/// nglGetString 的安全常量实现（唯一调用点：`a2gl2_stub_fn()` 的覆盖分支 ⇒ 注册给 GL11C）。
static jlong a2gl2_stub_nglGetString(JNIEnv *env, jclass cls, jint name) {
    (void)env;
    (void)cls;
    (void)name;
    return (jlong)(intptr_t)kA2GL2StubString;
}

// ★纹理接缝（M2）★ 由后端 a2_gl2_backend_metallum.m 提供实现
extern void a2gl2_metallum_texture_gen(int n, int *out);
extern void a2gl2_metallum_texture_bind(unsigned name);
extern void a2gl2_metallum_texture_delete(unsigned name);
extern void a2gl2_metallum_texture_image(unsigned name, int level, int w, int h,
                                         int format, int type, const void *pixels,
                                         int xoff, int yoff);

static void JNICALL a2gl2_stub_nglGenTextures(JNIEnv *env, jclass cls, jint n, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0) return;
    a2gl2_metallum_texture_gen((int)n, (int *)(intptr_t)ptr);
    static int logged = 0;
    if (logged++ < 3) a2_log_f(@"[A2-GL2] 纹理名已分配：n=%d", (int)n);
}

static void JNICALL a2gl2_stub_nglDeleteTextures(JNIEnv *env, jclass cls, jint n, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0) return;
    const int *ids = (const int *)(intptr_t)ptr;
    for (jint i = 0; i < n; i++) a2gl2_metallum_texture_delete((unsigned)ids[i]);
}

static void JNICALL a2gl2_stub_glBindTexture(JNIEnv *env, jclass cls, jint target, jint texture) {
    (void)env; (void)cls; (void)target;
    gA2GL2BoundTex = (unsigned)texture;
    a2gl2_metallum_texture_bind((unsigned)texture);
}

/// 最近一次 GL_PROXY_TEXTURE_2D(0x84F8=34040? 实际 32868) 的尺寸。
/// ★为什么需要★ MC 1.12.2 的 Minecraft.getGLMaximumTextureSize() 用「代理纹理探测」：
///   glTexImage2D(32868, 0, RGBA8, i, i, ...) 然后 glGetTexLevelParameteri(32868,0,GL_TEXTURE_WIDTH)
///   读回宽度判断这个尺寸能不能用（字节码实测：bib.B()，sipush 16384 起步，失败就 i>>=1）。
///   我们原来这条取数入口是空实现（返回 0）⇒ 一路减到 0 ⇒ Stitcher(0,0) ⇒ Unable to fit。
// ============================================================================
//  ★VBO（GL15）接管★ 2026-11-06 真机 lastlog-207
//  metallum 后端没有 GL 上下文；MC 1.12 的区块/字体一旦用 VBO，
//  就会落到 LWJGL 原生 → dlsym 到 MobileGlues（没有我们的上下文）⇒ 卡在 glBindBuffer。
//  这里用「CPU 影子缓冲」接管：bufferData 存副本、map 返回副本地址、
//  顶点指针的「偏移量」翻译成 副本地址+偏移。绘制仍走 GL2 的客户端数组路径。
// ============================================================================
#define A2GL2_VBO_MAX 256
#define A2GL2_GL_ARRAY_BUFFER 0x8892
#define A2GL2_GL_BUFFER_SIZE  0x8764

typedef struct { unsigned id; void *data; size_t size; } A2GL2Vbo;
static A2GL2Vbo gVbo[A2GL2_VBO_MAX];
static int      gVboCount = 0;
static unsigned gVboBound = 0;          ///< 当前 GL_ARRAY_BUFFER 绑定
static int      gVboNextId = 1;

static A2GL2Vbo *a2gl2_vbo_find(unsigned id) {
    for (int i = 0; i < gVboCount; i++) if (gVbo[i].id == id) return &gVbo[i];
    return NULL;
}
static A2GL2Vbo *a2gl2_vbo_ensure(unsigned id) {
    A2GL2Vbo *b = a2gl2_vbo_find(id);
    if (b != NULL) return b;
    if (gVboCount >= A2GL2_VBO_MAX) return NULL;
    b = &gVbo[gVboCount++];
    b->id = id; b->data = NULL; b->size = 0;
    return b;
}

/// 把「VBO 偏移」翻译成真实地址（★唯一翻译点★；调用点：客户端数组指针 4 处）。
const void *a2gl2_vbo_translate(const void *p) {
    if (gVboBound == 0) return p;
    A2GL2Vbo *b = a2gl2_vbo_find(gVboBound);
    if (b == NULL || b->data == NULL) return p;
    const uintptr_t off = (uintptr_t)p;
    if (off < b->size) return (const uint8_t *)b->data + off;
    return p;
}

static void JNICALL a2gl2_stub_glBindBuffer(JNIEnv *env, jclass cls, jint target, jint id) {
    (void)env; (void)cls;
    if (target == A2GL2_GL_ARRAY_BUFFER) gVboBound = (unsigned)id;
}

static void JNICALL a2gl2_stub_nglGenBuffers(JNIEnv *env, jclass cls, jint n, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0) return;
    int *out = (int *)(intptr_t)ptr;
    for (jint i = 0; i < n; i++) {
        unsigned id = (unsigned)(gVboNextId++);
        a2gl2_vbo_ensure(id);
        out[i] = (int)id;
    }
}

static void JNICALL a2gl2_stub_nglDeleteBuffers(JNIEnv *env, jclass cls, jint n, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0) return;
    const int *ids = (const int *)(intptr_t)ptr;
    for (jint i = 0; i < n; i++) {
        A2GL2Vbo *b = a2gl2_vbo_find((unsigned)ids[i]);
        if (b != NULL) { free(b->data); b->data = NULL; b->size = 0; b->id = 0; }
    }
}

static void JNICALL a2gl2_stub_nglBufferData(JNIEnv *env, jclass cls,
        jint target, jlong size, jlong dataPtr, jint usage) {
    (void)env; (void)cls; (void)usage;
    if (target != A2GL2_GL_ARRAY_BUFFER || gVboBound == 0) return;
    A2GL2Vbo *b = a2gl2_vbo_ensure(gVboBound);
    if (b == NULL) return;
    free(b->data); b->data = NULL; b->size = 0;
    if (size <= 0) return;
    b->data = malloc((size_t)size);
    if (b->data == NULL) return;
    b->size = (size_t)size;
    if (dataPtr != 0) memcpy(b->data, (const void *)(intptr_t)dataPtr, (size_t)size);
}

static void JNICALL a2gl2_stub_nglBufferSubData(JNIEnv *env, jclass cls,
        jint target, jlong offset, jlong size, jlong dataPtr) {
    (void)env; (void)cls;
    if (target != A2GL2_GL_ARRAY_BUFFER) return;
    A2GL2Vbo *b = a2gl2_vbo_find(gVboBound);
    if (b == NULL || b->data == NULL) return;
    if (offset < 0 || (size_t)(offset + size) > b->size || dataPtr == 0) return;
    memcpy((uint8_t *)b->data + offset, (const void *)(intptr_t)dataPtr, (size_t)size);
}

static void JNICALL a2gl2_stub_nglGetBufferSubData(JNIEnv *env, jclass cls,
        jint target, jlong offset, jlong size, jlong dataPtr) {
    (void)env; (void)cls;
    if (target != A2GL2_GL_ARRAY_BUFFER) return;
    A2GL2Vbo *b = a2gl2_vbo_find(gVboBound);
    if (b == NULL || b->data == NULL) return;
    if (offset < 0 || (size_t)(offset + size) > b->size || dataPtr == 0) return;
    memcpy((void *)(intptr_t)dataPtr, (uint8_t *)b->data + offset, (size_t)size);
}

static jlong JNICALL a2gl2_stub_nglMapBuffer(JNIEnv *env, jclass cls, jint target, jint access) {
    (void)env; (void)cls; (void)access;
    if (target != A2GL2_GL_ARRAY_BUFFER) return 0;
    A2GL2Vbo *b = a2gl2_vbo_find(gVboBound);
    return (jlong)(intptr_t)((b != NULL) ? b->data : NULL);
}

static jboolean JNICALL a2gl2_stub_glUnmapBuffer(JNIEnv *env, jclass cls, jint target) {
    (void)env; (void)cls; (void)target;
    return JNI_TRUE;
}

static jboolean JNICALL a2gl2_stub_glIsBuffer(JNIEnv *env, jclass cls, jint id) {
    (void)env; (void)cls;
    return a2gl2_vbo_find((unsigned)id) != NULL ? JNI_TRUE : JNI_FALSE;
}

static void JNICALL a2gl2_stub_nglGetBufferParameteriv(JNIEnv *env, jclass cls,
        jint target, jint pname, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0) return;
    int *out = (int *)(intptr_t)ptr;
    A2GL2Vbo *b = (target == A2GL2_GL_ARRAY_BUFFER) ? a2gl2_vbo_find(gVboBound) : NULL;
    if (pname == A2GL2_GL_BUFFER_SIZE && b != NULL) out[0] = (int)b->size;
    else out[0] = 0;
}

// ★显示列表（display list）★★2026-11-06 真机 lastlog-205★
//   MC 1.12.2 的字体/世界渲染大量使用 glNewList/glCallList。原来这条是空实现，
//   glGenLists 返回 0 ⇒ MC 直接抛 "glGenLists returned an ID of 0"。
//   本轮先把「分配 id + 记录状态」打通（不崩）；真正的回放（把 COMPILE 期间的
//   绘制指令录下来再执行）留作下一步 —— 它需要复用 a2mtl_submit 的批次结构。
extern void a2gl2_metallum_list_begin(unsigned id, unsigned mode);
extern void a2gl2_metallum_list_end(void);
extern void a2gl2_metallum_list_call(unsigned id);
extern void a2gl2_metallum_list_delete(unsigned id, int range);

static int gA2GL2NextListId = 1;
static int gA2GL2RecordingList = 0;

static jint JNICALL a2gl2_stub_glGenLists(JNIEnv *env, jclass cls, jint range) {
    (void)env; (void)cls;
    if (range <= 0) return 0;
    jint id = gA2GL2NextListId;
    gA2GL2NextListId += (range < 1 ? 1 : range);
    return id;
}

static void JNICALL a2gl2_stub_glNewList(JNIEnv *env, jclass cls, jint list, jint mode) {
    (void)env; (void)cls;
    gA2GL2RecordingList = (int)list;
    a2gl2_metallum_list_begin((unsigned)list, (unsigned)mode);
}

static void JNICALL a2gl2_stub_glEndList(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    static int logged = 0;
    if (logged < 3) { logged++; a2_log_f(@"[A2-GL2] 显示列表编译完成 id=%d（已录制，可回放）", gA2GL2RecordingList); }
    a2gl2_metallum_list_end();
    gA2GL2RecordingList = 0;
}

static void JNICALL a2gl2_stub_glCallList(JNIEnv *env, jclass cls, jint list) {
    (void)env; (void)cls;
    a2gl2_metallum_list_call((unsigned)list);
}

static void JNICALL a2gl2_stub_glDeleteLists(JNIEnv *env, jclass cls, jint list, jint range) {
    (void)env; (void)cls;
    a2gl2_metallum_list_delete((unsigned)list, (int)range);
}

static int gA2GL2ProxyW = 0;
static int gA2GL2ProxyH = 0;

static void JNICALL a2gl2_stub_nglGetTexLevelParameteriv(JNIEnv *env, jclass cls,
        jint target, jint level, jint pname, jlong ptr) {
    (void)env; (void)cls; (void)level;
    if (ptr == 0) return;
    int *out = (int *)(intptr_t)ptr;
    int v = 0;
    if (target == 32868 /*GL_PROXY_TEXTURE_2D*/) {
        if (pname == 4096 /*GL_TEXTURE_WIDTH*/)       v = gA2GL2ProxyW;
        else if (pname == 4097 /*GL_TEXTURE_HEIGHT*/) v = gA2GL2ProxyH;
    }
    out[0] = v;
}

static void JNICALL a2gl2_stub_nglTexImage2D(JNIEnv *env, jclass cls,
        jint target, jint level, jint internalFormat, jint width, jint height, jint border,
        jint format, jint type, jlong pixels) {
    (void)env; (void)cls; (void)internalFormat; (void)border;
    // ★代理纹理探测★ 只记账、不真的建纹理（MC 用它问「这么大能不能分配」）
    if ((int)target == 32868) {
        gA2GL2ProxyW = (int)width;
        gA2GL2ProxyH = (int)height;
        return;
    }
    a2gl2_metallum_texture_image((unsigned)gA2GL2BoundTex, (int)level, (int)width, (int)height,
                                 (int)format, (int)type, (const void *)(intptr_t)pixels, 0, 0);
}

static void JNICALL a2gl2_stub_nglTexSubImage2D(JNIEnv *env, jclass cls,
        jint target, jint level, jint xoffset, jint yoffset, jint width, jint height,
        jint format, jint type, jlong pixels) {
    (void)env; (void)cls; (void)target;
    a2gl2_metallum_texture_image((unsigned)gA2GL2BoundTex, (int)level, (int)width, (int)height,
                                 (int)format, (int)type, (const void *)(intptr_t)pixels,
                                 (int)xoffset, (int)yoffset);
}

/// ★2026-11-06 真机 lastlog-193★ MC 1.12 在 Initializing game 阶段报
///   "Unable to fit: minecraft:blocks/lava_flow - size: 32x32"。
///   根因：TextureUtil.getMaxTextureSize() 走 glGetInteger(GL_MAX_TEXTURE_SIZE)，
///   而本层这条是空实现（写 0）⇒ 图集上限算成 0 ⇒ 任何贴图都"放不下"。
///   这里按「本后端能力的保守值」回答 —— 数值本身不影响正确性，
///   只影响 MC 选多大的图集（16384 与真机 Metal 上限同量级）。
static void JNICALL a2gl2_stub_nglGetIntegerv(JNIEnv *env, jclass cls, jint pname, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0) return;
    int *out = (int *)(intptr_t)ptr;
    switch (pname) {
        case 0x0D33: out[0] = 16384; break;                 // GL_MAX_TEXTURE_SIZE
        case 0x0D3A: out[0] = 16384; out[1] = 16384; break; // GL_MAX_VIEWPORT_DIMS（2 个值）
        case 0x8869: out[0] = 16; break;                    // GL_MAX_VERTEX_ATTRIBS
        case 0x8872: out[0] = 16; break;                    // GL_MAX_TEXTURE_IMAGE_UNITS
        case 0x8B4C: out[0] = 16; break;                    // GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS
        case 0x8B4D: out[0] = 32; break;                    // GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS
        case 0x84E8: out[0] = 16384; break;                 // GL_MAX_RENDERBUFFER_SIZE
        case 0x8073: out[0] = 16384; break;                 // GL_MAX_3D_TEXTURE_SIZE
        case 0x88FF: out[0] = 16384; break;                 // GL_MAX_ARRAY_TEXTURE_LAYERS
        case 0x80E8: out[0] = 30000; break;                 // GL_MAX_ELEMENTS_VERTICES
        case 0x80E9: out[0] = 30000; break;                 // GL_MAX_ELEMENTS_INDICES
        case 0x86A3: out[0] = 2048; break;                  // GL_MAX_TEXTURE_BUFFER_SIZE
        default:     out[0] = 0; break;                     // 未知 ⇒ 维持原空实现语义
    }
}

typedef struct {
    int         declClass;
    const char *name;
    const char *sig;
    void       *fn;
} A2GL2StubOverride;

/// 值敏感入口的覆盖表（★只许放上面那类「返回 0 会变空指针」的入口★）。
static const A2GL2StubOverride kA2GL2StubOverrides[] = {
    { A2GL2_CLASS_GL11C, "nglGetString",   "(I)J",  (void *)a2gl2_stub_nglGetString },
    { A2GL2_CLASS_GL11C, "nglGetIntegerv", "(IJ)V", (void *)a2gl2_stub_nglGetIntegerv },
    { A2GL2_CLASS_GL11C, "nglGenTextures",    "(IJ)V",         (void *)a2gl2_stub_nglGenTextures },
    { A2GL2_CLASS_GL11C, "nglDeleteTextures", "(IJ)V",         (void *)a2gl2_stub_nglDeleteTextures },
    { A2GL2_CLASS_GL11C, "glBindTexture",     "(II)V",         (void *)a2gl2_stub_glBindTexture },
    { A2GL2_CLASS_GL11C, "nglTexImage2D",     "(IIIIIIIIJ)V",  (void *)a2gl2_stub_nglTexImage2D },
    { A2GL2_CLASS_GL11C, "nglTexSubImage2D",  "(IIIIIIIIJ)V",  (void *)a2gl2_stub_nglTexSubImage2D },
    { A2GL2_CLASS_GL11C, "nglGetTexLevelParameteriv", "(IIIJ)V", (void *)a2gl2_stub_nglGetTexLevelParameteriv },
    // 显示列表：先保证分配/记录不崩（回放下一步）
    { A2GL2_CLASS_GL11, "glGenLists",    "(I)I",  (void *)a2gl2_stub_glGenLists },
    { A2GL2_CLASS_GL11, "glNewList",     "(II)V", (void *)a2gl2_stub_glNewList },
    { A2GL2_CLASS_GL11, "glEndList",     "()V",   (void *)a2gl2_stub_glEndList },
    { A2GL2_CLASS_GL11, "glCallList",    "(I)V",  (void *)a2gl2_stub_glCallList },
    { A2GL2_CLASS_GL11, "glDeleteLists", "(II)V", (void *)a2gl2_stub_glDeleteLists },
};

/// 取某个 stub 条目实际要注册的函数指针：覆盖表优先，否则用生成表里的 no-op。
/// @return 非 NULL（生成表保证每个描述符都有一个 no-op）
/// 调用点：`a2gl2_install_stubs()` 的每一条（本文件唯一调用点）。
static void *a2gl2_stub_fn(const A2GL2StubMethod *s) {
    for (int i = 0; i < A2GL2_COUNT_OF(kA2GL2StubOverrides); i++) {
        const A2GL2StubOverride *o = &kA2GL2StubOverrides[i];
        if (o->declClass == s->declClass && strcmp(o->name, s->name) == 0
            && strcmp(o->sig, s->sig) == 0) {
            return o->fn;
        }
    }
    return s->fn;
}

/// 把 stub 表里「没被真实现占住」的每条都注册成 no-op。
/// @param out 统计输出（调用方据此打「空实现 M 条」那行判据）
/// 调用点：`a2_gl2_jni_install()` 的 ③（本文件唯一调用点）。
static void a2gl2_install_stubs(JNIEnv *env, jclass gl11, jclass gl11c, A2GL2StubStats *out) {
    out->total = A2GL2_STUB_COUNT;
    out->ok = out->covered = out->failed = 0;
    for (int i = 0; i < A2GL2_STUB_COUNT; i++) {
        const A2GL2StubMethod *s = &kA2GL2Stubs[i];
        if (a2gl2_taken_has(s->declClass, s->name, s->sig)) {
            out->covered++;      // ★真实现优先★：这条已经由 68 条里的一条接管，绝不换成 no-op
            continue;
        }
        jclass cls = (s->declClass == A2GL2_CLASS_GL11) ? gl11 : gl11c;
        const char *why = NULL;
        void *fn = a2gl2_stub_fn(s);           // 覆盖表优先（值敏感入口给安全常量），否则生成表的 no-op
        if (cls == NULL) {
            why = "该类的 jclass 为 NULL（Java 侧没给）⇒ 这条只能留给 LWJGL（有踩空风险）";
        } else if (a2gl2_register_raw(env, cls, s->name, s->sig, fn, &why)) {
            out->ok++;
            a2gl2_taken_add(s->declClass, s->name, s->sig);   // 防同一 (类,名,描述符) 被装两次
            continue;
        }
        out->failed++;
        a2_log_criterion(@"[A2-GL2] ★空实现未装★ %s.%s%s：%s",
                         a2gl2_class_name(s->declClass), s->name, s->sig,
                         (why != NULL) ? why : "未知原因");
    }
}

// ============================================================================
//  ⑫ 安装（唯一入口；调用点见 .h）
// ============================================================================
int a2_gl2_jni_install(JNIEnv *env, jclass gl11, jclass gl11c) {
    // ★幂等★：第二次进来直接回真实现条数（与第一次的返回值一致，不让调用方看到漂移的值）。
    if (gInstalled >= 0) return gRealCount;
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

    const int total = A2GL2_COUNT_OF(kA2GL2Methods);
    int ok = 0;
    int skipped = 0;

    // ① 静态跳过：本层实现了、但 jar 里没有可登记的 native 声明。
    for (int i = 0; i < A2GL2_COUNT_OF(kA2GL2Skips); i++) {
        skipped++;
        a2_log_criterion(@"[A2-GL2] ★跳过★ %s：%s", kA2GL2Skips[i].glName, kA2GL2Skips[i].why);
    }

    // ② 逐条登记：先主名字（jar 实测的 native 名），再另一套命名；每套都先首选类再另一类。
    //    任何一条失败都只跳过它自己。
    //    ★另一套命名是什么★：LWJGL 3 把指针入口的 native 叫 `nglXxx`，而 LWJGL 2 的
    //    同一入口就写 `glXxx`（同一个描述符）。真机上先试表里的主名字，那条不存在时
    //    才试 gl 名 —— 名字与描述符是不是真的，全部由 GetStaticMethodID + native 校验
    //    当场判定，所以这条兜底不会「装错入口」，最差就是不登记。
    for (int i = 0; i < total; i++) {
        const A2GL2Method *m = &kA2GL2Methods[i];
        const char *whyFirst = NULL;
        int landed = -1;
        const char *landedName = NULL;
        const int kinds[2]  = { m->declClass, 1 - m->declClass };
        const char *names[2] = { m->jniName, m->glName };
        const int nNames = (strcmp(names[0], names[1]) == 0) ? 1 : 2;
        for (int ni = 0; ni < nNames && landed < 0; ni++) {
            for (int ci = 0; ci < 2 && landed < 0; ci++) {
                const int kind = kinds[ci];
                jclass cls = (kind == A2GL2_CLASS_GL11) ? gl11 : gl11c;
                const char *why = NULL;
                if (cls == NULL) {
                    why = "该类的 jclass 为 NULL（Java 侧没给）";
                } else if (!shimOn && a2gl2_orig(m->idx) == NULL) {
                    // 只取证模式（A2_GL2_PROBE=1 且本层未启用）：抢过来却没人接 ⇒ 必须能转发回原实现，
                    // 否则这一条就真丢了（表现为缺件/全黑）。拿不到原实现就干脆不接管。
                    why = "只取证模式下原实现不可用 ⇒ 不接管（否则等于丢调用）";
                } else if (a2gl2_register_one(env, cls, m, names[ni], &why)) {
                    landed = kind;
                    landedName = names[ni];
                }
                if (landed < 0 && whyFirst == NULL) whyFirst = why;
            }
        }
        if (landed < 0) {
            skipped++;
            a2_log_criterion(@"[A2-GL2] ★跳过★ %s（%s%s）：%s",
                             m->glName, m->jniName, m->sig,
                             (whyFirst != NULL) ? whyFirst : "未知原因");
            continue;
        }
        ok++;
        // ★真实现占用登记★：把这条实际落地的 (类, 名字, 描述符) 记进 taken 集，
        // 后面装空实现时逐条查它 ⇒ 已实现的入口绝不会被 no-op 顶掉。
        // 为什么连「另一类」和「GL 名」也记：同一个 GL 入口可能以两个名字/两个类出现，
        // 只要有一条真实现接管了它，另一侧的 stub 就不许抢（抢了就等于把真实现关掉）。
        a2gl2_taken_add(landed, landedName, m->sig);
        a2gl2_taken_add(1 - landed, landedName, m->sig);
        a2gl2_taken_add(landed, m->glName, m->sig);
        a2gl2_taken_add(1 - landed, m->glName, m->sig);
        if (strcmp(landedName, m->jniName) != 0 || landed != m->declClass) {
            a2_log_f(@"[A2-GL2] 入口 %s 登记为 %s.%s（表里的主落点是 %s.%s）",
                     m->glName, a2gl2_class_name(landed), landedName,
                     a2gl2_class_name(m->declClass), m->jniName);
        }
    }

    // ③ 空实现：把 GL11/GL11C 上**剩下的** native 全部注册成 no-op
    //    —— 这才是「LWJGL 函数指针为 NULL 一调就踩空」这条路被彻底关掉的地方。
    //    判据：A2_GL2_STUB（默认开；=0 可关，仅用于二分「是 stub 还是真实现的问题」）。
    //    ★只在本层启用时装★：no-op 会改变行为，A2_GL2_PROBE=1「只取证不改行为」的承诺优先。
    A2GL2StubStats st;
    st.total = A2GL2_STUB_COUNT;
    st.ok = st.covered = st.failed = 0;
    const char *stubEnv = getenv("A2_GL2_STUB");
    const int stubOn = (stubEnv == NULL || stubEnv[0] == '\0' || strcmp(stubEnv, "0") != 0);
    if (!shimOn) {
        a2_log_criterion(@"[A2-GL2] 空实现=一条都不装（A2_GL2_SHIM 未启用 ⇒ 只取证模式）"
                         @"★注意★：此模式下未实现入口仍走 LWJGL，仍有 NULL 指针踩空风险");
    } else if (!stubOn) {
        a2_log_criterion(@"[A2-GL2] 空实现=一条都不装（A2_GL2_STUB=0，仅供二分定位）"
                         @"★注意★：未实现的 %d 条入口仍走 LWJGL，SIGSEGV 会复现",
                         A2GL2_STUB_COUNT);
    } else {
        a2gl2_install_stubs(env, gl11, gl11c, &st);
    }

    gInstalled = ok + st.ok;
    gRealCount = ok;

    // ★判据行（唯一口径）★：已实现 N 条 / 空实现 M 条 / 总计 T
    //  T = GL11+GL11C 上 native 总数（javap 实测，由 gen_gl2_stub_table.py 自检）；
    //  N = 走 a2_gl2_shim.m 真实实现的条数；M = 装成 no-op 的条数。
    //  恒等式：N + M == T（N + covered == T 同理）—— 不成立就说明接管面有洞，必须吼出来。
    a2_log_criterion(@"[A2-GL2] 已实现 %d 条 / 空实现 %d 条 / 总计 %d（判据：grep `[A2-GL2] 已实现`）",
                     ok, st.ok, A2GL2_STUB_COUNT);
    a2_log_criterion(@"[A2-GL2] 明细：免装 %d 条（已由真实现接管）· 空实现失败 %d 条 · "
                     @"静态跳过 %d 条（本层实现但 jar 无可登记声明）· "
                     @"A2_GL2_SHIM=%d A2_GL2_STUB=%d A2_GL2_PROBE=%d",
                     st.covered, st.failed, skipped, shimOn, stubOn, probeOn);
    if (stubOn && shimOn && (st.ok + st.covered) != A2GL2_STUB_COUNT) {
        a2_log_criterion(@"[A2-GL2] ★接管面不完整★ 空实现 %d + 免装 %d = %d ≠ 总计 %d"
                         @"⇒ 差的那 %d 条仍会走 LWJGL，可能再次踩空（看上面的逐条日志）",
                         st.ok, st.covered, st.ok + st.covered, A2GL2_STUB_COUNT,
                         A2GL2_STUB_COUNT - st.ok - st.covered);
    }
    if (ok + st.ok > 0) {
        a2_log_criterion(@"[A2-GL2] ★GL11/GL11C 入口全接管=生效★ %d 条真实现 + %d 条空实现"
                         @"＝ %d / %d 条 native 已由本进程接管（不再有任何 native 落回 LWJGL 的 NULL 函数表）",
                         ok, st.ok, ok + st.ok, A2GL2_STUB_COUNT);
    }
    if (st.ok > 0) {
        // ★语义边界（必须在真机日志里看得见，别让「不崩了」被误读成「效果对了」）★
        a2_log_criterion(@"[A2-GL2] ★空实现只保证不踩空，不保证有效果★ 这 %d 条 no-op 里包含"
                         @"nglGenTextures/nglTexImage2D/nglGetIntegerv 等资源与取数入口 ⇒ "
                         @"纹理不会真的生成、读状态不会写回；需要真效果请在 a2_gl2_shim.m 补真实现",
                         st.ok);
    }
    return ok;
}

// ============================================================================
//  ⑬ JNI 面（唯一调用点：JavaApp/src/launcher/.../A2Gl2Gl11Bind.java:install()）
// ----------------------------------------------------------------------------
//  宿主约定：主可执行文件即 JNI 符号宿主（A2Entry → A2NativeLibrary.load）。
//  ★返回值口径不变★：仍然是**真实现**条数（Java 侧文案按它写）；空实现条数只出现在
//  `[A2-GL2] 已实现 N 条 / 空实现 M 条 / 总计 T` 这行判据日志里。
// ============================================================================
JNIEXPORT jint JNICALL Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_install
(JNIEnv *env, jclass self, jclass gl11, jclass gl11c) {
    (void)self;
    return (jint)a2_gl2_jni_install(env, gl11, gl11c);
}

// ============================================================================
//  ⑭ 石山自检 —— 本轮新增的每个符号：它是什么、谁调它（文件:行）
// ----------------------------------------------------------------------------
//  规矩：本文件不新增「没人调」的符号。空实现表是唯一的例外面（336 行由表逐条引用），
//  但它的**读取点**也只有一处。行号按本文件当前内容；改代码后行号会漂，但「谁调谁」
//  这层关系不该变 —— 变了一定是有人在加石山。
//
//  ── 本文件（Natives/Renderer/a2_gl2_jni_bind.m）──
//  符号                                定义      谁调它
//  gReflectMethodClass                 617       同文件 a2gl2_native_state() L628/631/634/642
//                                                 （反射面缓存：336+68 次 native 校验只取一次类）
//  gReflectGetModifiers                618       同文件 a2gl2_native_state() L634/642/643
//  gRealCount                          200       a2_gl2_jni_install() L910（写）/ L803（幂等返回）
//                                                 ⇒ 对外契约：「返回值=真实现条数」不随空实现漂移
//  A2GL2Taken（类型）                  529       L533 gTaken 数组元素
//  gTaken / gTakenCount                533/534   a2gl2_taken_add() L540-550 · a2gl2_taken_has() L558-560
//  a2gl2_taken_add()                   538       a2gl2_install_stubs() L788（stub 装上后记一笔）
//                                                 · a2_gl2_jni_install() L878-881（真实现成功后 4 笔：
//                                                 落地类/另一类 × 主名字/GL 名）
//  a2gl2_taken_has()                   556       a2gl2_install_stubs() L777（★真实现优先的唯一闸门★）
//  a2gl2_stub_class_kind_must_match    525       无调用者（编译期断言：typedef 数组长度 -1 会直接编译失败）
//  a2gl2_register_raw()                655       a2gl2_register_one() L686（真实现）·
//                                                 a2gl2_install_stubs() L786（空实现）—— 唯一登记口
//  a2gl2_register_one()                684       a2_gl2_jni_install() L859（真实现逐条登记）
//  A2GL2StubStats（类型）              713       a2gl2_install_stubs() L772（出参）· install() L893（局部）
//  kA2GL2StubString                    733       a2gl2_stub_nglGetString() L740（返回值）
//  a2gl2_stub_nglGetString()           736       kA2GL2StubOverrides[] L752（表行引用）
//  A2GL2StubOverride（类型）           748       L751 表定义 · L759 a2gl2_stub_fn() 取字段
//  kA2GL2StubOverrides                 751       a2gl2_stub_fn() L760（遍历）
//  a2gl2_stub_fn()                     758       a2gl2_install_stubs() L783（每条取函数指针）
//  a2gl2_install_stubs()               772       a2_gl2_jni_install() L906（③ 段唯一调用点）
//  环境变量 A2_GL2_STUB                 896       a2_gl2_jni_install() L896-898（默认开；=0 关，仅二分用）
//
//  ── 生成面（Natives/Renderer/a2_gl2_stub_table.h，由 scripts/gen_gl2_stub_table.py 产出）──
//  A2GL2StubMethod（类型）             header       L758/L776（同文件 a2gl2_stub_fn / install_stubs 的参数类型）
//  a2gl2_stub_<描述符>（55 个 no-op）  header       引用点=同文件 kA2GL2Stubs[] 的表行（一条描述符一个函数，
//                                                 336 行共用 55 个实现）⇒ 运行期唯一读取点 a2gl2_install_stubs()
//                                                 L776（取 s->fn）与 a2gl2_stub_fn() L783
//  kA2GL2Stubs[]（336 行）             header       a2gl2_install_stubs() L776（唯一读取点）
//  A2GL2_STUB_COUNT                    header       L533（gTaken 容量）· L773/775（统计初值）·
//                                                 L894/904/917/922/925/926/931（判据行）
//
//  ── 依赖方向（不是石山，是外部引用）──
//  a2_log_criterion()/a2_log_f()       Natives/Support/a2_log.h   本文件 20 处判据行
//  a2_gl2_shim_enabled()/lookup()      Natives/Renderer/a2_gl2_shim.h   真实现面的唯一查询口（未改）
//  a2_gl2_probe_*                      Natives/Renderer/a2_gl2_jni_probe.h   表序核对 + 原实现符号名（未改）
//
//  ── 本轮**没有**新增的东西（防止被误判为遗漏）──
//  · 没有新增对 liblwjgl_opengl.dylib 的引用：空实现一律 no-op，不转调（转调=原地再踩一次空）。
//  · 没有新增 Java 侧符号：A2Gl2Gl11Bind.install() 的签名与返回值口径都没变。
//  · 没有新增注册表：336 行是生成出来的，不是手写的第二张表。
// ============================================================================

// ============================================================================
//  ⑬ GL30 FBO/RBO 入口（真机 lastlog-191：nglGenFramebuffers 踩空 SIGSEGV）
//   ★为什么放在本文件★：本文件一定在编译单元里；新开 .m 要动 gen_sources 清单。
// ----------------------------------------------------------------------------
#define A2GL2_FBO_COMPLETE 0x8CD5

static int gA2GL2FboNextId = 1;      ///< 假句柄分配器（FBO/RBO 共用即可：本层不区分类型）

// ---- nglGenFramebuffers(int n, long ptr) / nglGenRenderbuffers ----
//  ptr 指向 int[] 首地址（LWJGL 把 jintArray 的临界区地址传进来）
static void JNICALL a2gl2f_genNames(JNIEnv *env, jclass cls, jint n, jlong ptr) {
    (void)env; (void)cls;
    if (ptr == 0 || n <= 0) return;
    int *out = (int *)(intptr_t)ptr;
    for (jint i = 0; i < n; i++) out[i] = gA2GL2FboNextId++;
}

static void JNICALL a2gl2f_noopII(JNIEnv *env, jclass cls, jint a, jint b) {
    (void)env; (void)cls; (void)a; (void)b;
}

static void JNICALL a2gl2f_noopIII(JNIEnv *env, jclass cls, jint a, jint b, jint c) {
    (void)env; (void)cls; (void)a; (void)b; (void)c;
}

static void JNICALL a2gl2f_noopIIIII(JNIEnv *env, jclass cls, jint a, jint b, jint c, jint d, jint e) {
    (void)env; (void)cls; (void)a; (void)b; (void)c; (void)d; (void)e;
}

static void JNICALL a2gl2f_noopI(JNIEnv *env, jclass cls, jint a) {
    (void)env; (void)cls; (void)a;
}

static void JNICALL a2gl2f_noopIIII(JNIEnv *env, jclass cls, jint a, jint b, jint c, jint d) {
    (void)env; (void)cls; (void)a; (void)b; (void)c; (void)d;
}

static void JNICALL a2gl2f_noopIIIIII(JNIEnv *env, jclass cls, jint a, jint b, jint c,
                                      jint d, jint e, jint f) {
    (void)env; (void)cls; (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
}

static jboolean JNICALL a2gl2f_isTrue(JNIEnv *env, jclass cls, jint id) {
    (void)env; (void)cls; (void)id;
    return JNI_TRUE;   // 本层分配过 id ⇒ 一律认定存在
}

static jint JNICALL a2gl2f_checkStatus(JNIEnv *env, jclass cls, jint target) {
    (void)env; (void)cls; (void)target;
    return A2GL2_FBO_COMPLETE;   // 本层没有独立附件 ⇒ 永远「完整」
}

typedef struct { const char *name; const char *sig; void *fn; } A2GL2FboMethod;

static const A2GL2FboMethod kA2GL2FboMethods[] = {
    // ★描述符全部取自 lwjgl-opengl-3.3.3.jar 的 javap -s（GL30C）★
    //   (IJ)V  指针入口：n=个数，ptr=jint 数组首地址
    { "nglGenFramebuffers",      "(IJ)V", (void *)a2gl2f_genNames },
    { "nglDeleteFramebuffers",   "(IJ)V", (void *)a2gl2f_noopII },
    { "nglGenRenderbuffers",     "(IJ)V", (void *)a2gl2f_genNames },
    { "nglDeleteRenderbuffers",  "(IJ)V", (void *)a2gl2f_noopII },
    { "nglGetRenderbufferParameteriv", "(IIJ)V", (void *)a2gl2f_noopIII },
    // 绑定 / 查询
    { "glBindFramebuffer",        "(II)V",  (void *)a2gl2f_noopII },
    { "glBindRenderbuffer",       "(II)V",  (void *)a2gl2f_noopII },
    { "glCheckFramebufferStatus", "(I)I",   (void *)a2gl2f_checkStatus },
    { "glIsFramebuffer",          "(I)Z",   (void *)a2gl2f_isTrue },
    { "glIsRenderbuffer",         "(I)Z",   (void *)a2gl2f_isTrue },
    // 附件
    { "glFramebufferTexture2D",     "(IIIII)V",  (void *)a2gl2f_noopIIIII },
    { "glFramebufferTexture1D",     "(IIIII)V",  (void *)a2gl2f_noopIIIII },
    { "glFramebufferTextureLayer",  "(IIIII)V",  (void *)a2gl2f_noopIIIII },
    { "glFramebufferTexture3D",     "(IIIIII)V", (void *)a2gl2f_noopIIIIII },
    { "glFramebufferRenderbuffer",  "(IIII)V",   (void *)a2gl2f_noopIIII },
    // 存储
    { "glRenderbufferStorage",             "(IIII)V",  (void *)a2gl2f_noopIIII },
    { "glRenderbufferStorageMultisample",  "(IIIII)V", (void *)a2gl2f_noopIIIII },
    { NULL, NULL, NULL }
};

/// 逐条注册（某条不存在/不是 native 只跳过，绝不阻断）。
static int a2gl2f_register(JNIEnv *env, jclass cls, const char *tag) {
    if (cls == NULL) {
        a2_log_criterion(@"[A2-GL2-FBO] %s 类为 NULL ⇒ 跳过", tag);
        return 0;
    }
    int ok = 0, skipped = 0;
    for (int i = 0; kA2GL2FboMethods[i].name != NULL; i++) {
        JNINativeMethod nm = { (char *)kA2GL2FboMethods[i].name,
                               (char *)kA2GL2FboMethods[i].sig,
                               kA2GL2FboMethods[i].fn };
        if ((*env)->RegisterNatives(env, cls, &nm, 1) == JNI_OK) ok++;
        else { skipped++; (*env)->ExceptionClear(env); }
    }
    a2_log_criterion(@"[A2-GL2-FBO] %s 注册完成：成功 %d 条，跳过 %d 条（不在该类或不匹配）",
                     tag, ok, skipped);
    return ok;
}

/// Java 侧唯一入口：A2Gl2Gl11Bind.bindFbo(loader) → 这里。
JNIEXPORT void JNICALL
Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_bindFboNative(JNIEnv *env, jclass cls,
                                                         jclass gl30, jclass gl30c) {
    (void)cls;
    a2gl2f_register(env, gl30c, "GL30C");
    a2gl2f_register(env, gl30,  "GL30");
}

// ============================================================================
//  ★GL15C 注册入口★ 由 Java 的 A2Gl2Gl11Bind.bindVbo(loader) 调用。
//  这里是「批量注册」的唯一位置：逐条走 a2gl2_register_raw（它自带 native 校验）。
// ============================================================================
JNIEXPORT void JNICALL
Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_bindVboNative(JNIEnv *env, jclass cls, jclass gl15c) {
    (void)cls;
    if (gl15c == NULL) {
        a2_log_criterion(@"[A2-GL2-VBO] GL15C 为 NULL ⇒ 跳过");
        return;
    }
    typedef struct { const char *name; const char *sig; void *fn; } A2VboM;
    static const A2VboM m[] = {
        { "glBindBuffer",          "(II)V",    (void *)a2gl2_stub_glBindBuffer },
        { "nglGenBuffers",         "(IJ)V",    (void *)a2gl2_stub_nglGenBuffers },
        { "nglDeleteBuffers",      "(IJ)V",    (void *)a2gl2_stub_nglDeleteBuffers },
        { "nglBufferData",         "(IJJI)V",  (void *)a2gl2_stub_nglBufferData },
        { "nglBufferSubData",      "(IJJJ)V",  (void *)a2gl2_stub_nglBufferSubData },
        { "nglGetBufferSubData",   "(IJJJ)V",  (void *)a2gl2_stub_nglGetBufferSubData },
        { "nglMapBuffer",          "(II)J",    (void *)a2gl2_stub_nglMapBuffer },
        { "glUnmapBuffer",         "(I)Z",     (void *)a2gl2_stub_glUnmapBuffer },
        { "glIsBuffer",            "(I)Z",     (void *)a2gl2_stub_glIsBuffer },
        { "nglGetBufferParameteriv","(IIJ)V",  (void *)a2gl2_stub_nglGetBufferParameteriv },
        { NULL, NULL, NULL }
    };
    int ok = 0, skip = 0;
    for (int i = 0; m[i].name != NULL; i++) {
        const char *why = NULL;
        if (a2gl2_register_raw(env, gl15c, m[i].name, m[i].sig, m[i].fn, &why)) ok++;
        else {
            skip++;
            if (skip <= 3) a2_log_criterion(@"[A2-GL2-VBO] %s 跳过：%s", m[i].name,
                                            (why != NULL) ? why : "未知");
        }
    }
    a2_log_criterion(@"[A2-GL2-VBO] GL15C 注册：成功 %d 条，跳过 %d 条", ok, skip);
}

// ============================================================================
//  ★GL20（着色器）接管★ 2026-11-07 真机 lastlog-212
//  崩溃：libmobileglues.dylib glCreateShader+80（pc=0）
//  —— MC 调 GL20 的着色器接口时落到了 MG，而 MG 在我们的后端下没有上下文。
//  本层不编译 GLSL（固定管线用不到），因此返回「假句柄 + 恒编译/链接成功」。
// ============================================================================
static int gA2GL2NextShaderId = 1;

static jint JNICALL a2gl2_stub_glCreateProgram(JNIEnv *env, jclass cls) {
    (void)env; (void)cls; return gA2GL2NextShaderId++;
}
static jint JNICALL a2gl2_stub_glCreateShader(JNIEnv *env, jclass cls, jint type) {
    (void)env; (void)cls; (void)type; return gA2GL2NextShaderId++;
}
static void JNICALL a2gl2_stub_vII_gl20(JNIEnv *env, jclass cls, jint a, jint b) {
    (void)env; (void)cls; (void)a; (void)b;
}
static void JNICALL a2gl2_stub_vI_gl20(JNIEnv *env, jclass cls, jint a) {
    (void)env; (void)cls; (void)a;
}
static void JNICALL a2gl2_stub_nglShaderSource(JNIEnv *env, jclass cls, jint s, jint c, jlong a, jlong b) {
    (void)env; (void)cls; (void)s; (void)c; (void)a; (void)b;
}
static void JNICALL a2gl2_stub_nglGetShaderProgramiv(JNIEnv *env, jclass cls, jint obj, jint pname, jlong ptr) {
    (void)env; (void)cls; (void)obj;
    if (ptr == 0) return;
    int *out = (int *)(intptr_t)ptr;
    // GL_COMPILE_STATUS(0x8B81) / GL_LINK_STATUS(0x8B82) / GL_VALIDATE_STATUS(0x8B83) ⇒ 恒成功
    if (pname == 0x8B81 || pname == 0x8B82 || pname == 0x8B83) out[0] = 1;
    else out[0] = 0;
}
static void JNICALL a2gl2_stub_nglGetInfoLog(JNIEnv *env, jclass cls, jint obj, jint maxLen, jlong lenPtr, jlong bufPtr) {
    (void)env; (void)cls; (void)obj; (void)maxLen; (void)bufPtr;
    if (lenPtr != 0) *(int *)(intptr_t)lenPtr = 0;
}
static jint JNICALL a2gl2_stub_nglGetLocation(JNIEnv *env, jclass cls, jint obj, jlong namePtr) {
    (void)env; (void)cls; (void)obj; (void)namePtr;
    return 0;    // 无效位置 ⇒ MC 的 glUniform* 会被忽略
}
static void JNICALL a2gl2_stub_nglBindAttrib(JNIEnv *env, jclass cls, jint prog, jint index, jlong namePtr) {
    (void)env; (void)cls; (void)prog; (void)index; (void)namePtr;
}

typedef struct { const char *name; const char *sig; void *fn; } A2GL20M;
static const A2GL20M kA2GL20Methods[] = {
    { "glCreateProgram",        "()I",     (void *)a2gl2_stub_glCreateProgram },
    { "glCreateShader",         "(I)I",    (void *)a2gl2_stub_glCreateShader },
    { "glAttachShader",         "(II)V",   (void *)a2gl2_stub_vII_gl20 },
    { "glCompileShader",        "(I)V",    (void *)a2gl2_stub_vI_gl20 },
    { "glLinkProgram",          "(I)V",    (void *)a2gl2_stub_vI_gl20 },
    { "glUseProgram",           "(I)V",    (void *)a2gl2_stub_vI_gl20 },
    { "nglShaderSource",        "(IIJJ)V", (void *)a2gl2_stub_nglShaderSource },
    { "nglGetShaderiv",         "(IIJ)V",  (void *)a2gl2_stub_nglGetShaderProgramiv },
    { "nglGetProgramiv",        "(IIJ)V",  (void *)a2gl2_stub_nglGetShaderProgramiv },
    { "nglGetShaderInfoLog",    "(IIJJ)V", (void *)a2gl2_stub_nglGetInfoLog },
    { "nglGetProgramInfoLog",   "(IIJJ)V", (void *)a2gl2_stub_nglGetInfoLog },
    { "nglGetUniformLocation",  "(IJ)I",   (void *)a2gl2_stub_nglGetLocation },
    { "nglGetAttribLocation",   "(IJ)I",   (void *)a2gl2_stub_nglGetLocation },
    { "nglBindAttribLocation",  "(IIJ)V",  (void *)a2gl2_stub_nglBindAttrib },
    { NULL, NULL, NULL }
};

JNIEXPORT void JNICALL
Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_bindGl20Native(JNIEnv *env, jclass cls, jclass gl20c) {
    (void)cls;
    if (gl20c == NULL) { a2_log_criterion(@"[A2-GL2-GL20] GL20C 为 NULL ⇒ 跳过"); return; }
    int ok = 0, skip = 0;
    for (int i = 0; kA2GL20Methods[i].name != NULL; i++) {
        const char *why = NULL;
        if (a2gl2_register_raw(env, gl20c, kA2GL20Methods[i].name,
                               kA2GL20Methods[i].sig, kA2GL20Methods[i].fn, &why)) ok++;
        else { skip++; if (skip <= 3) a2_log_f(@"[A2-GL2-GL20] %s 跳过：%s", kA2GL20Methods[i].name, why ?: "?"); }
    }
    a2_log_criterion(@"[A2-GL2-GL20] GL20C 注册：成功 %d 条，跳过 %d 条", ok, skip);
}

// ============================================================================
//  ★GL12C..GL32C 全量空实现注册★ 2026-11-07
//  背景：MC 1.12 会用到 GL13/GL14/GL21/GL30/GL31 的边角入口；没接管 ⇒ LWJGL 的
//  native 指针为 NULL ⇒ JIT 直接间接调用 ⇒ SIGSEGV pc=0（lastlog-212/213 实证）。
//  做法：把 javap 列出的全部 native 注册成安全空实现；★顺序★ 这些是「最后兜底」，
//  必须在 bindFbo / bindVbo / bindGl20 之前调用，被它们覆盖成真实现。
// ============================================================================
// ===== 自动生成：GL12C..GL32C 安全空实现（255 条方法 / 66 种描述符）=====
// 生成器：gen_glx_stubs.py（javap -p -s lwjgl-lwjglx.jar）
static jint JNICALL a2gx__I(JNIEnv *env, jclass cls) {(void)env; (void)cls; return 0; }
static void JNICALL a2gx__V(JNIEnv *env, jclass cls) {(void)env; (void)cls; }
static void JNICALL a2gx_FFFF_V(JNIEnv *env, jclass cls, jfloat p0, jfloat p1, jfloat p2, jfloat p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_FZ_V(JNIEnv *env, jclass cls, jfloat p0, jboolean p1) {(void)p0; (void)p1; (void)env; (void)cls; }
static jint JNICALL a2gx_I_I(JNIEnv *env, jclass cls, jint p0) {(void)p0; (void)env; (void)cls; return 0; }
static void JNICALL a2gx_I_V(JNIEnv *env, jclass cls, jint p0) {(void)p0; (void)env; (void)cls; }
static jboolean JNICALL a2gx_I_Z(JNIEnv *env, jclass cls, jint p0) {(void)p0; (void)env; (void)cls; return JNI_FALSE; }
static void JNICALL a2gx_IBBBB_V(JNIEnv *env, jclass cls, jint p0, jbyte p1, jbyte p2, jbyte p3, jbyte p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_ID_V(JNIEnv *env, jclass cls, jint p0, jdouble p1) {(void)p0; (void)p1; (void)env; (void)cls; }
static void JNICALL a2gx_IDD_V(JNIEnv *env, jclass cls, jint p0, jdouble p1, jdouble p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }
static void JNICALL a2gx_IDDD_V(JNIEnv *env, jclass cls, jint p0, jdouble p1, jdouble p2, jdouble p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IDDDD_V(JNIEnv *env, jclass cls, jint p0, jdouble p1, jdouble p2, jdouble p3, jdouble p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IF_V(JNIEnv *env, jclass cls, jint p0, jfloat p1) {(void)p0; (void)p1; (void)env; (void)cls; }
static void JNICALL a2gx_IFF_V(JNIEnv *env, jclass cls, jint p0, jfloat p1, jfloat p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }
static void JNICALL a2gx_IFFF_V(JNIEnv *env, jclass cls, jint p0, jfloat p1, jfloat p2, jfloat p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IFFFF_V(JNIEnv *env, jclass cls, jint p0, jfloat p1, jfloat p2, jfloat p3, jfloat p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static jlong JNICALL a2gx_II_J(JNIEnv *env, jclass cls, jint p0, jint p1) {(void)p0; (void)p1; (void)env; (void)cls; return 0; }
static void JNICALL a2gx_II_V(JNIEnv *env, jclass cls, jint p0, jint p1) {(void)p0; (void)p1; (void)env; (void)cls; }
static jboolean JNICALL a2gx_II_Z(JNIEnv *env, jclass cls, jint p0, jint p1) {(void)p0; (void)p1; (void)env; (void)cls; return JNI_FALSE; }
static void JNICALL a2gx_IIFI_V(JNIEnv *env, jclass cls, jint p0, jint p1, jfloat p2, jint p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_III_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }
static void JNICALL a2gx_IIII_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IIIII_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIII_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIIII_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jint p6, jint p7, jint p8) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)p7; (void)p8; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIIIII_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jint p6, jint p7, jint p8, jint p9) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)p7; (void)p8; (void)p9; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIIIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jint p6, jint p7, jint p8, jint p9, jlong p10) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)p7; (void)p8; (void)p9; (void)p10; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jint p6, jint p7, jint p8, jlong p9) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)p7; (void)p8; (void)p9; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jint p6, jint p7, jlong p8) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)p7; (void)p8; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jint p6, jlong p7) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)p7; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jlong p6) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIIZ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jint p5, jboolean p6) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jlong p5) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIJI_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jlong p5, jint p6) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIIZ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jint p4, jboolean p5) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)env; (void)cls; }
static void JNICALL a2gx_IIIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jint p3, jlong p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IIIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jlong p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IIIJI_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jlong p3, jint p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IIIJII_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jlong p3, jint p4, jint p5) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)env; (void)cls; }
static void JNICALL a2gx_IIIJJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jlong p3, jlong p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IIIJJJJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jlong p3, jlong p4, jlong p5, jlong p6) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)p6; (void)env; (void)cls; }
static void JNICALL a2gx_IIIZIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jint p2, jboolean p3, jint p4, jlong p5) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)env; (void)cls; }
static void JNICALL a2gx_IIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jlong p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }
static void JNICALL a2gx_IIJI_V(JNIEnv *env, jclass cls, jint p0, jint p1, jlong p2, jint p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IIJIJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jlong p2, jint p3, jlong p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IIJJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jlong p2, jlong p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IIJJJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jlong p2, jlong p3, jlong p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IIZJ_V(JNIEnv *env, jclass cls, jint p0, jint p1, jboolean p2, jlong p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static jint JNICALL a2gx_IJ_I(JNIEnv *env, jclass cls, jint p0, jlong p1) {(void)p0; (void)p1; (void)env; (void)cls; return 0; }
static void JNICALL a2gx_IJ_V(JNIEnv *env, jclass cls, jint p0, jlong p1) {(void)p0; (void)p1; (void)env; (void)cls; }
static void JNICALL a2gx_IJIJI_V(JNIEnv *env, jclass cls, jint p0, jlong p1, jint p2, jlong p3, jint p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IJIJIJ_V(JNIEnv *env, jclass cls, jint p0, jlong p1, jint p2, jlong p3, jint p4, jlong p5) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)p5; (void)env; (void)cls; }
static void JNICALL a2gx_IJJ_V(JNIEnv *env, jclass cls, jint p0, jlong p1, jlong p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }
static jlong JNICALL a2gx_IJJI_J(JNIEnv *env, jclass cls, jint p0, jlong p1, jlong p2, jint p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; return 0; }
static void JNICALL a2gx_IJJI_V(JNIEnv *env, jclass cls, jint p0, jlong p1, jlong p2, jint p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IJJJ_V(JNIEnv *env, jclass cls, jint p0, jlong p1, jlong p2, jlong p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_IS_V(JNIEnv *env, jclass cls, jint p0, jshort p1) {(void)p0; (void)p1; (void)env; (void)cls; }
static void JNICALL a2gx_ISS_V(JNIEnv *env, jclass cls, jint p0, jshort p1, jshort p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }
static void JNICALL a2gx_ISSS_V(JNIEnv *env, jclass cls, jint p0, jshort p1, jshort p2, jshort p3) {(void)p0; (void)p1; (void)p2; (void)p3; (void)env; (void)cls; }
static void JNICALL a2gx_ISSSS_V(JNIEnv *env, jclass cls, jint p0, jshort p1, jshort p2, jshort p3, jshort p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_IZZZZ_V(JNIEnv *env, jclass cls, jint p0, jboolean p1, jboolean p2, jboolean p3, jboolean p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static void JNICALL a2gx_J_V(JNIEnv *env, jclass cls, jlong p0) {(void)p0; (void)env; (void)cls; }
static jboolean JNICALL a2gx_J_Z(JNIEnv *env, jclass cls, jlong p0) {(void)p0; (void)env; (void)cls; return JNI_FALSE; }
static void JNICALL a2gx_JIIJJ_V(JNIEnv *env, jclass cls, jlong p0, jint p1, jint p2, jlong p3, jlong p4) {(void)p0; (void)p1; (void)p2; (void)p3; (void)p4; (void)env; (void)cls; }
static jint JNICALL a2gx_JIJ_I(JNIEnv *env, jclass cls, jlong p0, jint p1, jlong p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; return 0; }
static void JNICALL a2gx_JIJ_V(JNIEnv *env, jclass cls, jlong p0, jint p1, jlong p2) {(void)p0; (void)p1; (void)p2; (void)env; (void)cls; }

typedef struct { const char *cls; const char *name; const char *sig; void *fn; } A2GX;
static const A2GX kA2GX[] = {
    { "GL12C", "nglTexImage3D", "(IIIIIIIIIJ)V", (void *)a2gx_IIIIIIIIIJ_V },
    { "GL12C", "nglTexSubImage3D", "(IIIIIIIIIIJ)V", (void *)a2gx_IIIIIIIIIIJ_V },
    { "GL12C", "glCopyTexSubImage3D", "(IIIIIIIII)V", (void *)a2gx_IIIIIIIII_V },
    { "GL12C", "nglDrawRangeElements", "(IIIIIJ)V", (void *)a2gx_IIIIIJ_V },
    { "GL13C", "nglCompressedTexImage3D", "(IIIIIIIIJ)V", (void *)a2gx_IIIIIIIIJ_V },
    { "GL13C", "nglCompressedTexImage2D", "(IIIIIIIJ)V", (void *)a2gx_IIIIIIIJ_V },
    { "GL13C", "nglCompressedTexImage1D", "(IIIIIIJ)V", (void *)a2gx_IIIIIIJ_V },
    { "GL13C", "nglCompressedTexSubImage3D", "(IIIIIIIIIIJ)V", (void *)a2gx_IIIIIIIIIIJ_V },
    { "GL13C", "nglCompressedTexSubImage2D", "(IIIIIIIIJ)V", (void *)a2gx_IIIIIIIIJ_V },
    { "GL13C", "nglCompressedTexSubImage1D", "(IIIIIIJ)V", (void *)a2gx_IIIIIIJ_V },
    { "GL13C", "nglGetCompressedTexImage", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL13C", "glSampleCoverage", "(FZ)V", (void *)a2gx_FZ_V },
    { "GL13C", "glActiveTexture", "(I)V", (void *)a2gx_I_V },
    { "GL14C", "glBlendColor", "(FFFF)V", (void *)a2gx_FFFF_V },
    { "GL14C", "glBlendEquation", "(I)V", (void *)a2gx_I_V },
    { "GL14C", "nglMultiDrawArrays", "(IJJI)V", (void *)a2gx_IJJI_V },
    { "GL14C", "nglMultiDrawElements", "(IJIJI)V", (void *)a2gx_IJIJI_V },
    { "GL14C", "glPointParameterf", "(IF)V", (void *)a2gx_IF_V },
    { "GL14C", "glPointParameteri", "(II)V", (void *)a2gx_II_V },
    { "GL14C", "nglPointParameterfv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL14C", "nglPointParameteriv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL14C", "glBlendFuncSeparate", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL15C", "glBindBuffer", "(II)V", (void *)a2gx_II_V },
    { "GL15C", "nglDeleteBuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL15C", "nglGenBuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL15C", "glIsBuffer", "(I)Z", (void *)a2gx_I_Z },
    { "GL15C", "nglBufferData", "(IJJI)V", (void *)a2gx_IJJI_V },
    { "GL15C", "nglBufferSubData", "(IJJJ)V", (void *)a2gx_IJJJ_V },
    { "GL15C", "nglGetBufferSubData", "(IJJJ)V", (void *)a2gx_IJJJ_V },
    { "GL15C", "nglMapBuffer", "(II)J", (void *)a2gx_II_J },
    { "GL15C", "glUnmapBuffer", "(I)Z", (void *)a2gx_I_Z },
    { "GL15C", "nglGetBufferParameteriv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL15C", "nglGetBufferPointerv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL15C", "nglGenQueries", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL15C", "nglDeleteQueries", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL15C", "glIsQuery", "(I)Z", (void *)a2gx_I_Z },
    { "GL15C", "glBeginQuery", "(II)V", (void *)a2gx_II_V },
    { "GL15C", "glEndQuery", "(I)V", (void *)a2gx_I_V },
    { "GL15C", "nglGetQueryiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL15C", "nglGetQueryObjectiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL15C", "nglGetQueryObjectuiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "glCreateProgram", "()I", (void *)a2gx__I },
    { "GL20C", "glDeleteProgram", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glIsProgram", "(I)Z", (void *)a2gx_I_Z },
    { "GL20C", "glCreateShader", "(I)I", (void *)a2gx_I_I },
    { "GL20C", "glDeleteShader", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glIsShader", "(I)Z", (void *)a2gx_I_Z },
    { "GL20C", "glAttachShader", "(II)V", (void *)a2gx_II_V },
    { "GL20C", "glDetachShader", "(II)V", (void *)a2gx_II_V },
    { "GL20C", "nglShaderSource", "(IIJJ)V", (void *)a2gx_IIJJ_V },
    { "GL20C", "glCompileShader", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glLinkProgram", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glUseProgram", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glValidateProgram", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glUniform1f", "(IF)V", (void *)a2gx_IF_V },
    { "GL20C", "glUniform2f", "(IFF)V", (void *)a2gx_IFF_V },
    { "GL20C", "glUniform3f", "(IFFF)V", (void *)a2gx_IFFF_V },
    { "GL20C", "glUniform4f", "(IFFFF)V", (void *)a2gx_IFFFF_V },
    { "GL20C", "glUniform1i", "(II)V", (void *)a2gx_II_V },
    { "GL20C", "glUniform2i", "(III)V", (void *)a2gx_III_V },
    { "GL20C", "glUniform3i", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL20C", "glUniform4i", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL20C", "nglUniform1fv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform2fv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform3fv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform4fv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform1iv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform2iv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform3iv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniform4iv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglUniformMatrix2fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL20C", "nglUniformMatrix3fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL20C", "nglUniformMatrix4fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL20C", "nglGetShaderiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetProgramiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetShaderInfoLog", "(IIJJ)V", (void *)a2gx_IIJJ_V },
    { "GL20C", "nglGetProgramInfoLog", "(IIJJ)V", (void *)a2gx_IIJJ_V },
    { "GL20C", "nglGetAttachedShaders", "(IIJJ)V", (void *)a2gx_IIJJ_V },
    { "GL20C", "nglGetUniformLocation", "(IJ)I", (void *)a2gx_IJ_I },
    { "GL20C", "nglGetActiveUniform", "(IIIJJJJ)V", (void *)a2gx_IIIJJJJ_V },
    { "GL20C", "nglGetUniformfv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetUniformiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetShaderSource", "(IIJJ)V", (void *)a2gx_IIJJ_V },
    { "GL20C", "glVertexAttrib1f", "(IF)V", (void *)a2gx_IF_V },
    { "GL20C", "glVertexAttrib1s", "(IS)V", (void *)a2gx_IS_V },
    { "GL20C", "glVertexAttrib1d", "(ID)V", (void *)a2gx_ID_V },
    { "GL20C", "glVertexAttrib2f", "(IFF)V", (void *)a2gx_IFF_V },
    { "GL20C", "glVertexAttrib2s", "(ISS)V", (void *)a2gx_ISS_V },
    { "GL20C", "glVertexAttrib2d", "(IDD)V", (void *)a2gx_IDD_V },
    { "GL20C", "glVertexAttrib3f", "(IFFF)V", (void *)a2gx_IFFF_V },
    { "GL20C", "glVertexAttrib3s", "(ISSS)V", (void *)a2gx_ISSS_V },
    { "GL20C", "glVertexAttrib3d", "(IDDD)V", (void *)a2gx_IDDD_V },
    { "GL20C", "glVertexAttrib4f", "(IFFFF)V", (void *)a2gx_IFFFF_V },
    { "GL20C", "glVertexAttrib4s", "(ISSSS)V", (void *)a2gx_ISSSS_V },
    { "GL20C", "glVertexAttrib4d", "(IDDDD)V", (void *)a2gx_IDDDD_V },
    { "GL20C", "glVertexAttrib4Nub", "(IBBBB)V", (void *)a2gx_IBBBB_V },
    { "GL20C", "nglVertexAttrib1fv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib1sv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib1dv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib2fv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib2sv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib2dv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib3fv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib3sv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib3dv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4fv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4sv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4dv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4iv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4bv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4ubv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4usv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4uiv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4Nbv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4Nsv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4Niv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4Nubv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4Nusv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttrib4Nuiv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "nglVertexAttribPointer", "(IIIZIJ)V", (void *)a2gx_IIIZIJ_V },
    { "GL20C", "glEnableVertexAttribArray", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "glDisableVertexAttribArray", "(I)V", (void *)a2gx_I_V },
    { "GL20C", "nglBindAttribLocation", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetActiveAttrib", "(IIIJJJJ)V", (void *)a2gx_IIIJJJJ_V },
    { "GL20C", "nglGetAttribLocation", "(IJ)I", (void *)a2gx_IJ_I },
    { "GL20C", "nglGetVertexAttribiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetVertexAttribfv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetVertexAttribdv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglGetVertexAttribPointerv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL20C", "nglDrawBuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL20C", "glBlendEquationSeparate", "(II)V", (void *)a2gx_II_V },
    { "GL20C", "glStencilOpSeparate", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL20C", "glStencilFuncSeparate", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL20C", "glStencilMaskSeparate", "(II)V", (void *)a2gx_II_V },
    { "GL21C", "nglUniformMatrix2x3fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL21C", "nglUniformMatrix3x2fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL21C", "nglUniformMatrix2x4fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL21C", "nglUniformMatrix4x2fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL21C", "nglUniformMatrix3x4fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL21C", "nglUniformMatrix4x3fv", "(IIZJ)V", (void *)a2gx_IIZJ_V },
    { "GL30C", "nglGetStringi", "(II)J", (void *)a2gx_II_J },
    { "GL30C", "nglClearBufferiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglClearBufferuiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglClearBufferfv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "glClearBufferfi", "(IIFI)V", (void *)a2gx_IIFI_V },
    { "GL30C", "glVertexAttribI1i", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glVertexAttribI2i", "(III)V", (void *)a2gx_III_V },
    { "GL30C", "glVertexAttribI3i", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL30C", "glVertexAttribI4i", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "glVertexAttribI1ui", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glVertexAttribI2ui", "(III)V", (void *)a2gx_III_V },
    { "GL30C", "glVertexAttribI3ui", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL30C", "glVertexAttribI4ui", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "nglVertexAttribI1iv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI2iv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI3iv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI4iv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI1uiv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI2uiv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI3uiv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI4uiv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI4bv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI4sv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI4ubv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribI4usv", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglVertexAttribIPointer", "(IIIIJ)V", (void *)a2gx_IIIIJ_V },
    { "GL30C", "nglGetVertexAttribIiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglGetVertexAttribIuiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "glUniform1ui", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glUniform2ui", "(III)V", (void *)a2gx_III_V },
    { "GL30C", "glUniform3ui", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL30C", "glUniform4ui", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "nglUniform1uiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglUniform2uiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglUniform3uiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglUniform4uiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglGetUniformuiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglBindFragDataLocation", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglGetFragDataLocation", "(IJ)I", (void *)a2gx_IJ_I },
    { "GL30C", "glBeginConditionalRender", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glEndConditionalRender", "()V", (void *)a2gx__V },
    { "GL30C", "nglMapBufferRange", "(IJJI)J", (void *)a2gx_IJJI_J },
    { "GL30C", "glFlushMappedBufferRange", "(IJJ)V", (void *)a2gx_IJJ_V },
    { "GL30C", "glClampColor", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glIsRenderbuffer", "(I)Z", (void *)a2gx_I_Z },
    { "GL30C", "glBindRenderbuffer", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "nglDeleteRenderbuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglGenRenderbuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "glRenderbufferStorage", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL30C", "glRenderbufferStorageMultisample", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "nglGetRenderbufferParameteriv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "glIsFramebuffer", "(I)Z", (void *)a2gx_I_Z },
    { "GL30C", "glBindFramebuffer", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "nglDeleteFramebuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglGenFramebuffers", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "glCheckFramebufferStatus", "(I)I", (void *)a2gx_I_I },
    { "GL30C", "glFramebufferTexture1D", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "glFramebufferTexture2D", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "glFramebufferTexture3D", "(IIIIII)V", (void *)a2gx_IIIIII_V },
    { "GL30C", "glFramebufferTextureLayer", "(IIIII)V", (void *)a2gx_IIIII_V },
    { "GL30C", "glFramebufferRenderbuffer", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL30C", "nglGetFramebufferAttachmentParameteriv", "(IIIJ)V", (void *)a2gx_IIIJ_V },
    { "GL30C", "glBlitFramebuffer", "(IIIIIIIIII)V", (void *)a2gx_IIIIIIIIII_V },
    { "GL30C", "glGenerateMipmap", "(I)V", (void *)a2gx_I_V },
    { "GL30C", "nglTexParameterIiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglTexParameterIuiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglGetTexParameterIiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglGetTexParameterIuiv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "glColorMaski", "(IZZZZ)V", (void *)a2gx_IZZZZ_V },
    { "GL30C", "nglGetBooleani_v", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "nglGetIntegeri_v", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL30C", "glEnablei", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glDisablei", "(II)V", (void *)a2gx_II_V },
    { "GL30C", "glIsEnabledi", "(II)Z", (void *)a2gx_II_Z },
    { "GL30C", "glBindBufferRange", "(IIIJJ)V", (void *)a2gx_IIIJJ_V },
    { "GL30C", "glBindBufferBase", "(III)V", (void *)a2gx_III_V },
    { "GL30C", "glBeginTransformFeedback", "(I)V", (void *)a2gx_I_V },
    { "GL30C", "glEndTransformFeedback", "()V", (void *)a2gx__V },
    { "GL30C", "nglTransformFeedbackVaryings", "(IIJI)V", (void *)a2gx_IIJI_V },
    { "GL30C", "nglGetTransformFeedbackVarying", "(IIIJJJJ)V", (void *)a2gx_IIIJJJJ_V },
    { "GL30C", "glBindVertexArray", "(I)V", (void *)a2gx_I_V },
    { "GL30C", "nglDeleteVertexArrays", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "nglGenVertexArrays", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL30C", "glIsVertexArray", "(I)Z", (void *)a2gx_I_Z },
    { "GL31C", "glDrawArraysInstanced", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL31C", "nglDrawElementsInstanced", "(IIIJI)V", (void *)a2gx_IIIJI_V },
    { "GL31C", "glCopyBufferSubData", "(IIJJJ)V", (void *)a2gx_IIJJJ_V },
    { "GL31C", "glPrimitiveRestartIndex", "(I)V", (void *)a2gx_I_V },
    { "GL31C", "glTexBuffer", "(III)V", (void *)a2gx_III_V },
    { "GL31C", "nglGetUniformIndices", "(IIJJ)V", (void *)a2gx_IIJJ_V },
    { "GL31C", "nglGetActiveUniformsiv", "(IIJIJ)V", (void *)a2gx_IIJIJ_V },
    { "GL31C", "nglGetActiveUniformName", "(IIIJJ)V", (void *)a2gx_IIIJJ_V },
    { "GL31C", "nglGetUniformBlockIndex", "(IJ)I", (void *)a2gx_IJ_I },
    { "GL31C", "nglGetActiveUniformBlockiv", "(IIIJ)V", (void *)a2gx_IIIJ_V },
    { "GL31C", "nglGetActiveUniformBlockName", "(IIIJJ)V", (void *)a2gx_IIIJJ_V },
    { "GL31C", "glUniformBlockBinding", "(III)V", (void *)a2gx_III_V },
    { "GL32C", "nglGetBufferParameteri64v", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL32C", "nglDrawElementsBaseVertex", "(IIIJI)V", (void *)a2gx_IIIJI_V },
    { "GL32C", "nglDrawRangeElementsBaseVertex", "(IIIIIJI)V", (void *)a2gx_IIIIIJI_V },
    { "GL32C", "nglDrawElementsInstancedBaseVertex", "(IIIJII)V", (void *)a2gx_IIIJII_V },
    { "GL32C", "nglMultiDrawElementsBaseVertex", "(IJIJIJ)V", (void *)a2gx_IJIJIJ_V },
    { "GL32C", "glProvokingVertex", "(I)V", (void *)a2gx_I_V },
    { "GL32C", "glTexImage2DMultisample", "(IIIIIZ)V", (void *)a2gx_IIIIIZ_V },
    { "GL32C", "glTexImage3DMultisample", "(IIIIIIZ)V", (void *)a2gx_IIIIIIZ_V },
    { "GL32C", "nglGetMultisamplefv", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL32C", "glSampleMaski", "(II)V", (void *)a2gx_II_V },
    { "GL32C", "glFramebufferTexture", "(IIII)V", (void *)a2gx_IIII_V },
    { "GL32C", "glFenceSync", "(II)J", (void *)a2gx_II_J },
    { "GL32C", "nglIsSync", "(J)Z", (void *)a2gx_J_Z },
    { "GL32C", "nglDeleteSync", "(J)V", (void *)a2gx_J_V },
    { "GL32C", "nglClientWaitSync", "(JIJ)I", (void *)a2gx_JIJ_I },
    { "GL32C", "nglWaitSync", "(JIJ)V", (void *)a2gx_JIJ_V },
    { "GL32C", "nglGetInteger64v", "(IJ)V", (void *)a2gx_IJ_V },
    { "GL32C", "nglGetInteger64i_v", "(IIJ)V", (void *)a2gx_IIJ_V },
    { "GL32C", "nglGetSynciv", "(JIIJJ)V", (void *)a2gx_JIIJJ_V },
    { NULL, NULL, NULL, NULL }
};

JNIEXPORT void JNICALL
Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_bindExtrasNative(JNIEnv *env, jclass cls,
                                                            jobjectArray classes,
                                                            jobjectArray names) {
    (void)cls;
    if (classes == NULL || names == NULL) return;
    const jsize n = (*env)->GetArrayLength(env, classes);
    for (jsize i = 0; i < n; i++) {
        jclass k = (jclass)(*env)->GetObjectArrayElement(env, classes, i);
        jstring js = (jstring)(*env)->GetObjectArrayElement(env, names, i);
        if (k == NULL || js == NULL) continue;
        const char *nm = (*env)->GetStringUTFChars(env, js, NULL);
        int ok = 0, skip = 0;
        for (int t = 0; kA2GX[t].cls != NULL; t++) {
            if (strcmp(kA2GX[t].cls, nm) != 0) continue;
            const char *why = NULL;
            if (a2gl2_register_raw(env, k, kA2GX[t].name, kA2GX[t].sig, kA2GX[t].fn, &why)) ok++;
            else skip++;
        }
        a2_log_criterion(@"[A2-GL2-EXT] %s 空实现注册：成功 %d 条，跳过 %d 条", nm, ok, skip);
        (*env)->ReleaseStringUTFChars(env, js, nm);
        (*env)->DeleteLocalRef(env, js);
        (*env)->DeleteLocalRef(env, k);
    }
}

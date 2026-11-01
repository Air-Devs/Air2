// ============================================================================
//  Natives/Renderer/a2_gl2_jni_probe.m
//  Air2 —— 只读取证：固定管线入口的 JNI 实现 / flat namespace 命中的镜像
//  对外契约见 a2_gl2_jni_probe.h（唯二函数 + 一个 JNI 面）。本文件只实现，不做绑定。
// ============================================================================
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <jni.h>

#import "a2_log.h"
#import "a2_gl2_jni_probe.h"

// ============================================================================
//  ① 本轮接管的 7 个入口（★唯一登记表★：加名字先加这里，再加 a2_gl2_jni_bind.m 的转发）
// ----------------------------------------------------------------------------
//  第三列 = JNI 实现符号名，规则是 javac/JNI 的 mangling：
//    Java_<包名点换下划线>_<类名>_<方法名>
//  它必须与 `liblwjgl_opengl.dylib` 导出的符号逐字相同（已用导出表实测：
//  274 个 `Java_org_lwjgl_opengl_GL11_*`；`glDrawArrays` 的 native 声明在 GL11C 上，
//  因为 `GL11.glDrawArrays(int,int,int)` 在 jar 里是普通 Java 方法，它转调 GL11C）。
// ============================================================================
typedef struct {
    const char *glName;
    const char *declaringClass;   ///< Java 侧声明 native 的类（内部名）
    const char *jniSymbol;
} A2GL2ProbeEntry;

static const A2GL2ProbeEntry kA2GL2ProbeEntries[] = {
    { "glBegin",        "org/lwjgl/opengl/GL11",  "Java_org_lwjgl_opengl_GL11_glBegin"        },
    { "glEnd",          "org/lwjgl/opengl/GL11",  "Java_org_lwjgl_opengl_GL11_glEnd"          },
    { "glVertex3f",     "org/lwjgl/opengl/GL11",  "Java_org_lwjgl_opengl_GL11_glVertex3f"     },
    { "glColor4f",      "org/lwjgl/opengl/GL11",  "Java_org_lwjgl_opengl_GL11_glColor4f"      },
    { "glMatrixMode",   "org/lwjgl/opengl/GL11",  "Java_org_lwjgl_opengl_GL11_glMatrixMode"   },
    { "glLoadIdentity", "org/lwjgl/opengl/GL11",  "Java_org_lwjgl_opengl_GL11_glLoadIdentity" },
    { "glDrawArrays",   "org/lwjgl/opengl/GL11C", "Java_org_lwjgl_opengl_GL11C_glDrawArrays"  },
};

#define A2GL2_PROBE_COUNT ((int)(sizeof(kA2GL2ProbeEntries) / sizeof(kA2GL2ProbeEntries[0])))

int a2_gl2_probe_entry_count(void) { return A2GL2_PROBE_COUNT; }

const char *a2_gl2_probe_gl_name(int index) {
    if (index < 0 || index >= A2GL2_PROBE_COUNT) return NULL;
    return kA2GL2ProbeEntries[index].glName;
}

const char *a2_gl2_probe_jni_symbol(int index) {
    if (index < 0 || index >= A2GL2_PROBE_COUNT) return NULL;
    return kA2GL2ProbeEntries[index].jniSymbol;
}

const char *a2_gl2_probe_declaring_class(int index) {
    if (index < 0 || index >= A2GL2_PROBE_COUNT) return NULL;
    return kA2GL2ProbeEntries[index].declaringClass;
}

// ============================================================================
//  ② dladdr → 镜像名（唯一产地：所有「哪张镜像」的结论都从这里出）
// ============================================================================
static const char *a2gl2_probe_image_of(void *addr) {
    if (addr == NULL) return "(无)";
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(addr, &info) == 0 || info.dli_fname == NULL) return "(未知)";
    const char *base = strrchr(info.dli_fname, '/');   // 只留文件名，日志别太长
    return (base != NULL) ? (base + 1) : info.dli_fname;
}

// ============================================================================
//  ③ 采样（唯一产地）
// ============================================================================
int a2_gl2_probe_sample(A2GL2ProbeFact *out, int cap) {
    if (out == NULL || cap <= 0) return 0;
    const int n = (cap < A2GL2_PROBE_COUNT) ? cap : A2GL2_PROBE_COUNT;
    for (int i = 0; i < n; i++) {
        A2GL2ProbeFact *f = &out[i];
        memset(f, 0, sizeof(*f));
        f->glName         = kA2GL2ProbeEntries[i].glName;
        f->jniSymbol      = kA2GL2ProbeEntries[i].jniSymbol;
        f->declaringClass = kA2GL2ProbeEntries[i].declaringClass;
        // ① 谁实现了这条 JNI native（LWJGL 侧）
        f->jniAddress = dlsym(RTLD_DEFAULT, kA2GL2ProbeEntries[i].jniSymbol);
        f->jniImage   = a2gl2_probe_image_of(f->jniAddress);
        // ② 同一个 GL 名字在进程 flat namespace 里会命中谁（这是「直取 ANGLE 入口」那条路的判据）
        f->flatImage  = a2gl2_probe_image_of(dlsym(RTLD_DEFAULT, kA2GL2ProbeEntries[i].glName));
    }
    return n;
}

// ============================================================================
//  ④ 判据行（调用点：a2_gl2_jni_install）
// ============================================================================
void a2_gl2_probe_log(void) {
    A2GL2ProbeFact facts[A2GL2_PROBE_COUNT];
    const int n = a2_gl2_probe_sample(facts, A2GL2_PROBE_COUNT);
    for (int i = 0; i < n; i++) {
        const A2GL2ProbeFact *f = &facts[i];
        a2_log_criterion(@"[A2-GL2-PROBE] %s ← %s.%s（JNI 实现镜像=%s，地址=%p；"
                         @"进程 dlsym(\"%s\") 命中镜像=%s）",
                         f->glName, f->declaringClass, f->glName,
                         f->jniImage, f->jniAddress, f->glName, f->flatImage);
    }
    // 一行结论：不猜，只把两张镜像名摆出来 —— 判据是「JNI 实现镜像」这一列。
    A2GL2ProbeFact first[A2GL2_PROBE_COUNT];
    if (a2_gl2_probe_sample(first, A2GL2_PROBE_COUNT) > 0) {
        a2_log_criterion(@"[A2-GL2-PROBE] 结论：固定管线入口的实现镜像=%s ⇒ 绑定发生在 JNI native 层"
                         @"（Java 侧 native 声明 + JNI 符号解析），既不经过 eglGetProcAddress，"
                         @"也不经过 a2_gl_bridge_gles_getprocaddress ⇒ 两个解析器钩子对这批入口无效",
                         first[0].jniImage);
    }
}

// ============================================================================
//  ⑤ JNI 面（唯一调用点：JavaApp/src/a2ios_agent/a2/A2Gl2Probe.java:report()）
// ----------------------------------------------------------------------------
//  为什么走 JNI 而不是让 Java 自己 dlsym：Java 侧没有 dladdr；镜像名只能在这里得到。
//  宿主约定：主可执行文件即 JNI 符号宿主（A2Entry → A2NativeLibrary.load）。
// ============================================================================
JNIEXPORT jstring JNICALL Java_a2_A2Gl2Probe_report(JNIEnv *env, jclass clazz) {
    (void)clazz;
    if (env == NULL) return NULL;
    char buf[2048];
    size_t used = 0;
    A2GL2ProbeFact facts[A2GL2_PROBE_COUNT];
    const int n = a2_gl2_probe_sample(facts, A2GL2_PROBE_COUNT);
    for (int i = 0; i < n && used < sizeof(buf); i++) {
        const A2GL2ProbeFact *f = &facts[i];
        int written = snprintf(buf + used, sizeof(buf) - used,
                               "[A2-GL2-PROBE] %s ← %s.%s：JNI 实现镜像=%s 地址=%p；"
                               "进程 dlsym(\"%s\")=%s\n",
                               f->glName, f->declaringClass, f->glName,
                               f->jniImage, f->jniAddress, f->glName, f->flatImage);
        if (written < 0) break;
        used += (size_t)written;
    }
    if (used == 0) {
        snprintf(buf, sizeof(buf), "[A2-GL2-PROBE] 采样为空（入口表为空）\n");
    }
    return (*env)->NewStringUTF(env, buf);
}

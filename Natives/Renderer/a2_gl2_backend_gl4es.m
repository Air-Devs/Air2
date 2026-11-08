//
//  a2_gl2_backend_gl4es.m
//  Air2
//
//  ★C 路线后端实现★：把 GL 固定管线转发给 gl4es（libgl4es_114.dylib）。
//
//  设计要点（为什么这么做，见 .h 头注释）：
//    JNI 接管层（a2_gl2_jni_bind）负责「把 LWJGL 的 native 抢下来」，
//    本文件负责「抢下来之后把调用转给 gl4es」。
//    两者缺一不可：只换渲染器 dylib 会被 LWJGL 写死的 libGLESv2 吃掉（10-25 已证）。
//
//  只转发「固定管线/GL1.x」这批名字；EGL/上下文/swap 一律不碰 —— 那是宿主的事。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import "a2_gl2_backend_gl4es.h"

/// 只让 gl4es 接管这些前缀的名字：固定管线 + GL1.x 状态机。
/// ★不要放宽★：GLES2/3 的现代入口（glCreateShader/glTexImage2D 等）
/// 仍由我们自己的层或原路径处理，混进来会打乱两条链的边界。
static const char *kA2GL4Forwards[] = {
    "glBegin", "glEnd", "glVertex", "glColor", "glNormal", "glTexCoord",
    "glMaterial", "glLight", "glFog", "glShadeModel", "glPolygonMode",
    "glMatrixMode", "glLoadIdentity", "glLoadMatrix", "glMultMatrix",
    "glPushMatrix", "glPopMatrix", "glRotate", "glTranslate", "glScale",
    "glOrtho", "glFrustum", "glViewport", "glScissor",
    "glEnable", "glDisable", "glIsEnabled", "glGetBooleanv", "glGetFloatv", "glGetIntegerv",
    "glBlendFunc", "glAlphaFunc", "glDepthFunc", "glDepthMask", "glDepthRange",
    "glCullFace", "glFrontFace", "glPolygonOffset", "glLineWidth", "glPointSize",
    "glClear", "glClearColor", "glClearDepth", "glColorMask",
    "glDrawArrays", "glDrawElements", "glGenBuffers", "glBindBuffer",
    "glBufferData", "glBufferSubData", "glDeleteBuffers",
    "glGenTextures", "glBindTexture", "glTexImage2D", "glTexSubImage2D",
    "glTexParameter", "glDeleteTextures", "glPixelStore",
    "glNewList", "glEndList", "glCallList", "glGenLists", "glDeleteLists", "glIsList",
    "glReadPixels", "glFinish", "glFlush", "glGetError", "glGetString",
    NULL
};

static void *gA2GL4Handle = NULL;
static int   gA2GL4Tried  = 0;
static int   gA2GL4OK     = 0;
static unsigned long gA2GL4Hits = 0;

static int a2gl4_name_allowed(const char *name) {
    if (name == NULL || name[0] == '\0') return 0;
    for (int i = 0; kA2GL4Forwards[i] != NULL; i++) {
        if (strncmp(name, kA2GL4Forwards[i], strlen(kA2GL4Forwards[i])) == 0) return 1;
    }
    return 0;
}

int a2gl4_backend_enabled(void) {
    const char *b = getenv("A2_GL2_BACKEND");
    return (b != NULL && strcmp(b, "gl4es") == 0) ? 1 : 0;
}

int a2gl4_load(void) {
    if (gA2GL4Tried) return gA2GL4OK;
    gA2GL4Tried = 1;

    // ★必须先设，再 dlopen★：gl4es 在构造函数里读这些环境变量。
    //   LIBGL_NOINTOVLHACK / LIBGL_NORMALIZE 与老 Air 一致（见 a2_gl_bridge.m:2414 的注释）；
    //   LIBGL_ES=2：明确走 GLES2 后端（我们下面接的是 MG 提供的 GLES 上下文）。
    setenv("LIBGL_NOINTOVLHACK", "1", 1);
    setenv("LIBGL_NORMALIZE", "1", 1);
    if (getenv("LIBGL_ES") == NULL) setenv("LIBGL_ES", "2", 1);
    if (getenv("LIBGL_GL") == NULL) setenv("LIBGL_GL", "21", 1);

    // 与 metallum 后端同一套查找顺序：先 <App>/Frameworks，再交给 @rpath
    NSString *fw = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks"];
    NSString *full = [fw stringByAppendingPathComponent:@"libgl4es_114.dylib"];
    const char *path = full.fileSystemRepresentation;
    gA2GL4Handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (gA2GL4Handle == NULL) {
        gA2GL4Handle = dlopen("libgl4es_114.dylib", RTLD_NOW | RTLD_GLOBAL);
    }
    if (gA2GL4Handle == NULL) {
        const char *err = dlerror();
        NSLog(@"[A2-GL4] ★加载失败★ libgl4es_114.dylib：%s（回落原路径）", err ? err : "(null)");
        return 0;
    }
    gA2GL4OK = 1;
    NSLog(@"[A2-GL4] 已加载 libgl4es_114.dylib（C 路线：JNI 接管 + gl4es 固定管线）");
    return 1;
}

void *a2gl4_symbol(const char *name) {
    if (!a2gl4_backend_enabled()) return NULL;
    if (!a2gl4_name_allowed(name)) return NULL;
    if (!a2gl4_load()) return NULL;

    void *sym = dlsym(gA2GL4Handle, name);
    if (sym == NULL) {
        // 名字在允许表里但 gl4es 没导出：直接放过（继续走我们的层/原实现）
        if (gA2GL4Hits < 8) {
            NSLog(@"[A2-GL4] gl4es 未导出 %s ⇒ 交回本层", name);
        }
        return NULL;
    }
    if (gA2GL4Hits < 16) {
        NSLog(@"[A2-GL4] 转发 %s ⇒ gl4es %p", name, sym);
        gA2GL4Hits++;
    }
    return sym;
}

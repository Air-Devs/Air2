// ============================================================================
//  Natives/Renderer/a2_gl2_backend_metallum.h
//  Air2 —— ★GL2 语义层的「后端接缝」+ metallum（Metal）后端安装入口★
// ----------------------------------------------------------------------------
//  分层：Natives/Renderer（与 a2_gl2_shim.* / a2_gl2_jni_bind.* 同一层）。
//
//  ★本文件解决两件事★
//    ① 把 GL2 语义层唯一的下游接缝 `A2GL2ES3`（28 个 ES3 入口）从
//       `a2_gl2_shim.m` 的**文件内部 typedef** 提出来变成**单一真源头**：
//       语义层与后端（GLES / metallum）看的是同一份字段表，字段增删只有一处。
//    ② 声明 metallum 后端的三个入口（探测 / 安装 / 失败原因）。
//
//  ★调用点（谁 include 它）★
//    · `Natives/Renderer/a2_gl2_shim.m`          —— 用 `A2GL2ES3`（接缝字段表）；
//                                                   `a2gl2_resolve_es3()` 里调
//                                                   `a2gl2_metallum_install()`
//                                                   （只看 `a2_gl2_shim_enabled()` 为真时才走到）；
//    · `Natives/Renderer/a2_gl2_backend_metallum.m` —— 实现（唯一实现者）。
//
//  ★本头文件不 include 任何 GL/GLES/Metal 头★：理由与 `a2_gl2_shim.m` 文件头①相同 ——
//    `<OpenGLES/…>` 会经 module map 触发 `-framework OpenGLES` 自动链接，把系统 GLES 的
//    `gl*` 塞进 flat namespace，改掉现有 ANGLE/MG 路径的 `dlsym(RTLD_DEFAULT)` 结果；
//    `<Metal/…>` 则会把后端绑死在编译期（本层刻意只走 dlsym，见 .m 文件头②）。
//    ⇒ GL 标量类型在本文件里**自带一份**（`A2GL2_GL_TYPES_DEFINED` 守卫，防重复定义）。
// ============================================================================
#ifndef A2_GL2_BACKEND_METALLUM_H
#define A2_GL2_BACKEND_METALLUM_H

#include <stddef.h>
#include <stdint.h>   // intptr_t（GLintptr/GLsizeiptr）；不依赖包含方的包含顺序

#ifdef __cplusplus
extern "C" {
#endif

// ----------------------------------------------------------------------------
//  ① GL 标量类型（★本地自带，不 include GL 头★；守卫让包含方可以共存）
// ----------------------------------------------------------------------------
#ifndef A2GL2_GL_TYPES_DEFINED
#define A2GL2_GL_TYPES_DEFINED
typedef unsigned int   GLenum;
typedef unsigned char  GLboolean;
typedef unsigned int   GLbitfield;
typedef void           GLvoid;
typedef int            GLint;
typedef unsigned int   GLuint;
typedef int            GLsizei;
typedef float          GLfloat;
typedef double         GLdouble;
typedef char           GLchar;
typedef intptr_t       GLintptr;
typedef intptr_t       GLsizeiptr;
typedef unsigned char  GLubyte;
typedef short          GLshort;
typedef unsigned short GLushort;
#endif /* A2GL2_GL_TYPES_DEFINED */

// ----------------------------------------------------------------------------
//  ② 后端接缝：28 个 ES3 入口（★唯一字段表★）
// ----------------------------------------------------------------------------
//  语义（GL2 层的期望，后端必须满足）：
//    · `gen*` 返回的句柄只需**非 0**（语义层仅判 `!= 0`）；
//    · `createShader/compileShader/linkProgram` 必须能「成功」（语义层据此判断着色器可用）；
//    · `getAttribLocation/getUniformLocation` 对 aPos/aColor/aUV 与 6 个 uniform 名必须 >= 0；
//    · `bufferData` 之后紧跟 `drawArrays/drawElements`（语义层每帧流式上传，不复用 VBO）；
//    · `enable/disable` 只收到「ES3 里存在」的开关（GL_BLEND/GL_DEPTH_TEST/GL_CULL_FACE…），
//      固定管线专属开关（GL_TEXTURE_2D/GL_ALPHA_TEST…）已被语义层自己吞掉。
//
//  ★为什么字段顺序与 a2_gl2_shim.m 原 typedef 逐字一致★：那段 typedef 曾是唯一声明处，
//    本文件接管后顺序保持不变 ⇒ 逐字段对照时不必重新排查（diff 只看一眼）。
// ----------------------------------------------------------------------------
#ifndef A2GL2_ES3_STRUCT_DEFINED
#define A2GL2_ES3_STRUCT_DEFINED

typedef void      (*A2GL2PFN_glGenBuffers)(GLsizei, GLuint *);
typedef void      (*A2GL2PFN_glBindBuffer)(GLenum, GLuint);
typedef void      (*A2GL2PFN_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
typedef void      (*A2GL2PFN_glGenVertexArrays)(GLsizei, GLuint *);
typedef void      (*A2GL2PFN_glBindVertexArray)(GLuint);
typedef void      (*A2GL2PFN_glVertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
typedef void      (*A2GL2PFN_glEnableVertexAttribArray)(GLuint);
typedef void      (*A2GL2PFN_glDrawArrays)(GLenum, GLint, GLsizei);
typedef void      (*A2GL2PFN_glDrawElements)(GLenum, GLsizei, GLenum, const void *);
typedef GLuint    (*A2GL2PFN_glCreateShader)(GLenum);
typedef void      (*A2GL2PFN_glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *);
typedef void      (*A2GL2PFN_glCompileShader)(GLuint);
typedef void      (*A2GL2PFN_glGetShaderiv)(GLuint, GLenum, GLint *);
typedef void      (*A2GL2PFN_glGetShaderInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef GLuint    (*A2GL2PFN_glCreateProgram)(void);
typedef void      (*A2GL2PFN_glAttachShader)(GLuint, GLuint);
typedef void      (*A2GL2PFN_glLinkProgram)(GLuint);
typedef void      (*A2GL2PFN_glGetProgramiv)(GLuint, GLenum, GLint *);
typedef void      (*A2GL2PFN_glGetProgramInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef void      (*A2GL2PFN_glUseProgram)(GLuint);
typedef GLint     (*A2GL2PFN_glGetAttribLocation)(GLuint, const GLchar *);
typedef GLint     (*A2GL2PFN_glGetUniformLocation)(GLuint, const GLchar *);
typedef void      (*A2GL2PFN_glUniformMatrix4fv)(GLint, GLsizei, GLboolean, const GLfloat *);
typedef void      (*A2GL2PFN_glUniform1i)(GLint, GLint);
typedef void      (*A2GL2PFN_glUniform1f)(GLint, GLfloat);
typedef void      (*A2GL2PFN_glEnable)(GLenum);
typedef void      (*A2GL2PFN_glDisable)(GLenum);
typedef void      (*A2GL2PFN_glTexParameteri)(GLenum, GLenum, GLint);

typedef struct {
    A2GL2PFN_glGenBuffers              genBuffers;
    A2GL2PFN_glBindBuffer              bindBuffer;
    A2GL2PFN_glBufferData              bufferData;
    A2GL2PFN_glGenVertexArrays         genVertexArrays;
    A2GL2PFN_glBindVertexArray         bindVertexArray;
    A2GL2PFN_glVertexAttribPointer     vertexAttribPointer;
    A2GL2PFN_glEnableVertexAttribArray enableVertexAttribArray;
    A2GL2PFN_glDrawArrays              drawArrays;
    A2GL2PFN_glDrawElements            drawElements;
    A2GL2PFN_glCreateShader            createShader;
    A2GL2PFN_glShaderSource            shaderSource;
    A2GL2PFN_glCompileShader           compileShader;
    A2GL2PFN_glGetShaderiv             getShaderiv;
    A2GL2PFN_glGetShaderInfoLog        getShaderInfoLog;
    A2GL2PFN_glCreateProgram           createProgram;
    A2GL2PFN_glAttachShader            attachShader;
    A2GL2PFN_glLinkProgram             linkProgram;
    A2GL2PFN_glGetProgramiv            getProgramiv;
    A2GL2PFN_glGetProgramInfoLog       getProgramInfoLog;
    A2GL2PFN_glUseProgram              useProgram;
    A2GL2PFN_glGetAttribLocation       getAttribLocation;
    A2GL2PFN_glGetUniformLocation      getUniformLocation;
    A2GL2PFN_glUniformMatrix4fv        uniformMatrix4fv;
    A2GL2PFN_glUniform1i               uniform1i;
    A2GL2PFN_glUniform1f               uniform1f;
    A2GL2PFN_glEnable                  enable;
    A2GL2PFN_glDisable                 disable;
    A2GL2PFN_glTexParameteri           texParameteri;
} A2GL2ES3;

#endif /* A2GL2_ES3_STRUCT_DEFINED */

/// 接缝字段数（★唯一计数★：`a2gl2_metallum_install` 满装时返回它，语义层按它判「整层可用」）。
/// ★新增/删除字段必须同时改这里★：`scripts/verify_gl2_metallum.py` 会数 `out->field =` 的条数
/// 与结构体字段数是否都等于本值（对不上直接失败）。
#define A2GL2_ES3_COUNT 28

// ----------------------------------------------------------------------------
//  ③ metallum 后端入口（三个，全部幂等、绝不抛异常/abort）
// ----------------------------------------------------------------------------

/// 探测 libmetallum 与**全部必需符号**。幂等（首次探测结果缓存，只打一行判据）。
/// 探测口径：① `dlsym(RTLD_DEFAULT, …)`（已被 a2_renderer_load_named 以 RTLD_GLOBAL 加载的情形）
///          ② 否则 dlopen `@rpath/libmetallum.dylib` → `<mainBundle>/Frameworks/libmetallum.dylib`。
/// @return 1 = 可用（设备也建起来了）；0 = 不可用（缺哪条见日志与 `a2gl2_metallum_reason()`）。
int a2gl2_metallum_available(void);

/// 把 28 个接缝入口全部指向 metallum（Metal）实现。
/// @param out 语义层的入口表（非 NULL）；**只写函数指针**，不读旧值。
/// @return `A2GL2_ES3_COUNT`（=28）= 满装；< 28 = 失败（已写入的部分由调用方自行 memset 掉）。
/// ★失败时不留半装状态★：本函数在所有前置条件（符号/设备）满足后才开始写 `out`。
int a2gl2_metallum_install(A2GL2ES3 *out);

/// 最近一次 `available()/install()` 失败的原因（★静态字符串，永不返回 NULL★）。
/// 调用点：`a2_gl2_shim.m` 的 `a2gl2_resolve_es3()` 回落日志（`[A2-MTL] 回落后端=GLES（原因=…）`）。
const char *a2gl2_metallum_reason(void);

#ifdef __cplusplus
}
#endif

#endif /* A2_GL2_BACKEND_METALLUM_H */

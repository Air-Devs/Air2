// ============================================================================
//  Natives/Renderer/a2_gl2_shim.m
//  Air2 —— ★自研固定管线（GL2 立即模式 → GLES3）最小实现★
// ----------------------------------------------------------------------------
//  对外契约见 a2_gl2_shim.h（只有两个函数）。本文件只实现。
//
//  ★为什么要有它★
//    MC ≤1.12.2 用 LWJGL2 时代的 **固定管线**：`glBegin/glEnd` 立即模式、
//    `glVertexPointer` 一族**客户端顶点数组** + `glDrawArrays(GL_QUADS)`、
//    `glMatrixMode/glOrtho/glPushMatrix` 矩阵栈、`glEnable(GL_TEXTURE_2D/GL_ALPHA_TEST)`。
//    iOS 只有 GLES2/3，没有这些入口 ⇒ 必须有人在中间翻译（KW/gl4es/SWFPE 干的就是这件事）。
//    本层是「最小自研替代」：只做**主菜单能显示**所需的那一份，不做完整 FPE。
//
//  ★调用链（谁调它，逐处）★
//    ① 渲染器解析器：`a2_gl_bridge_gles_getprocaddress()`（a2_gl_bridge.m）
//       在「KW 白名单/GLES1 拒绝」之前先问本层 ⇒ 拿到 `a2_gl2_shim_lookup(name)` 的实现。
//    ② 宿主假 EGL：`eglGetProcAddress()`（a2_eagl_egl.m）在最前面问本层。
//    ③ 档位判据：`A2DefaultRendererForVersion()`（A2LaunchSession.m）打 `[A2-GL2]` 行。
//    三条都只在 `a2_gl2_shim_enabled()`（环境变量 `A2_GL2_SHIM=1`）为真时生效。
//
//  ★绘制口径（一句话）★
//    所有固定管线绘制最终都走同一个出口 `a2gl2_draw()`：
//      收集/转换顶点 → 交错顶点（pos3f + color4ub + uv2f，24 B）→ 上传 VBO →
//      `glDrawArrays`（QUADS/POLYGON/LINE_LOOP 用索引表摊成 ES3 支持的图元）。
//    MVP 在 CPU 侧由矩阵栈算好，作为 uniform 传进去（不在着色器里模拟固定管线矩阵）。
//
//  ★本层明确不做（见交付分析 A 的「可先空实现」）★
//    光照/雾/裁剪面/逻辑运算/多边形模式/显示列表/求值器/选择-反馈/glGetFloatv 矩阵回读。
//    这些入口若被 MC 调用：要么落到渲染器解析器的空桩（桥路径），要么落回宿主 GLES（假 EGL 路径）
//    —— 两条都不崩、只是「效果缺失」，不阻断首帧。
// ============================================================================

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>
#import <stdint.h>

#import "a2_gl2_shim.h"
#import "a2_log.h"       // Natives/Support —— [A2-GL2] 日志出口

// ============================================================================
//  ① GL 常量（★不 include 任何 GL/GLES 头★）
// ----------------------------------------------------------------------------
//  理由同 a2_eagl_egl.m 文件头：`#import <OpenGLES/…>` 会经 module map 触发
//  `-framework OpenGLES` 自动链接 ⇒ 系统 GLES 的 `gl*` 进 flat namespace，
//  把现有 ANGLE/MG 路径的 `dlsym(RTLD_DEFAULT)` 结果改掉。本层只写需要的常量。
// ============================================================================
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

#define A2GL2_FALSE                    0
#define A2GL2_TRUE                     1

#define A2GL2_LINES                    0x0001
#define A2GL2_LINE_LOOP                0x0002
#define A2GL2_LINE_STRIP               0x0003
#define A2GL2_TRIANGLES                0x0004
#define A2GL2_TRIANGLE_FAN             0x0006
#define A2GL2_QUADS                    0x0007
#define A2GL2_POLYGON                  0x0009
#define A2GL2_POINTS                   0x0000
#define A2GL2_TRIANGLE_STRIP           0x0005
#define A2GL2_QUAD_STRIP               0x0008

#define A2GL2_UNSIGNED_BYTE            0x1401
#define A2GL2_SHORT                    0x1402
#define A2GL2_UNSIGNED_SHORT           0x1403
#define A2GL2_INT                      0x1404
#define A2GL2_UNSIGNED_INT             0x1405
#define A2GL2_FLOAT                    0x1406
#define A2GL2_DOUBLE                   0x140A

#define A2GL2_TEXTURE_2D               0x0DE1
#define A2GL2_ALPHA_TEST               0x0BC0
#define A2GL2_LIGHTING                 0x0B50
#define A2GL2_FOG                      0x0B60
#define A2GL2_NORMALIZE                0x0BA1
#define A2GL2_COLOR_MATERIAL           0x0B57

#define A2GL2_MODELVIEW                0x1700
#define A2GL2_PROJECTION               0x1701
#define A2GL2_TEXTURE                  0x1702
#define A2GL2_VERTEX_ARRAY             0x8074
#define A2GL2_NORMAL_ARRAY             0x8075
#define A2GL2_COLOR_ARRAY              0x8076
#define A2GL2_TEXTURE_COORD_ARRAY      0x8078

#define A2GL2_TEXTURE_ENV              0x2300
#define A2GL2_TEXTURE_ENV_MODE         0x2200
#define A2GL2_MODULATE                 0x2100
#define A2GL2_REPLACE                  0x1E01
#define A2GL2_CLAMP                    0x2900
#define A2GL2_CLAMP_TO_EDGE            0x812F

#define A2GL2_NEVER                    0x0200
#define A2GL2_LESS                     0x0201
#define A2GL2_EQUAL                    0x0202
#define A2GL2_LEQUAL                   0x0203
#define A2GL2_GREATER                  0x0204
#define A2GL2_NOTEQUAL                 0x0205
#define A2GL2_GEQUAL                   0x0206
#define A2GL2_ALWAYS                   0x0207

#define A2GL2_ARRAY_BUFFER             0x8892
#define A2GL2_ELEMENT_ARRAY_BUFFER     0x8893
#define A2GL2_STREAM_DRAW              0x88E0
#define A2GL2_FRAGMENT_SHADER          0x8B30
#define A2GL2_VERTEX_SHADER            0x8B31
#define A2GL2_COMPILE_STATUS           0x8B81
#define A2GL2_LINK_STATUS              0x8B82

// ============================================================================
//  ② GLES3 入口（本层唯一「下游」）
// ----------------------------------------------------------------------------
//  取法与 a2_eagl_egl.m 同口径：`dlsym(RTLD_DEFAULT, …)`（ANGLE 的 libGLESv2 以
//  RTLD_GLOBAL 进 flat namespace，见 a2_gl_bridge.m:578）。
//  唯一调用点：`a2gl2_resolve_es3()`（首次用到本层时一次）；失败 ⇒ 打一行 [A2-GL2] 并
//  把 `gA2GL2Broken` 置位（之后 `a2_gl2_shim_lookup` 一律返回 NULL ⇒ 整层回到接入前行为）。
// ============================================================================
typedef void      (*A2PFN2_glGenBuffers)(GLsizei, GLuint *);
typedef void      (*A2PFN2_glBindBuffer)(GLenum, GLuint);
typedef void      (*A2PFN2_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
typedef void      (*A2PFN2_glGenVertexArrays)(GLsizei, GLuint *);
typedef void      (*A2PFN2_glBindVertexArray)(GLuint);
typedef void      (*A2PFN2_glVertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
typedef void      (*A2PFN2_glEnableVertexAttribArray)(GLuint);
typedef void      (*A2PFN2_glDrawArrays)(GLenum, GLint, GLsizei);
typedef void      (*A2PFN2_glDrawElements)(GLenum, GLsizei, GLenum, const void *);
typedef GLuint    (*A2PFN2_glCreateShader)(GLenum);
typedef void      (*A2PFN2_glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *);
typedef void      (*A2PFN2_glCompileShader)(GLuint);
typedef void      (*A2PFN2_glGetShaderiv)(GLuint, GLenum, GLint *);
typedef void      (*A2PFN2_glGetShaderInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef GLuint    (*A2PFN2_glCreateProgram)(void);
typedef void      (*A2PFN2_glAttachShader)(GLuint, GLuint);
typedef void      (*A2PFN2_glLinkProgram)(GLuint);
typedef void      (*A2PFN2_glGetProgramiv)(GLuint, GLenum, GLint *);
typedef void      (*A2PFN2_glGetProgramInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef void      (*A2PFN2_glUseProgram)(GLuint);
typedef GLint     (*A2PFN2_glGetAttribLocation)(GLuint, const GLchar *);
typedef GLint     (*A2PFN2_glGetUniformLocation)(GLuint, const GLchar *);
typedef void      (*A2PFN2_glUniformMatrix4fv)(GLint, GLsizei, GLboolean, const GLfloat *);
typedef void      (*A2PFN2_glUniform1i)(GLint, GLint);
typedef void      (*A2PFN2_glUniform1f)(GLint, GLfloat);
typedef void      (*A2PFN2_glEnable)(GLenum);
typedef void      (*A2PFN2_glDisable)(GLenum);
typedef void      (*A2PFN2_glBlendFunc)(GLenum, GLenum);
typedef void      (*A2PFN2_glTexParameteri)(GLenum, GLenum, GLint);

typedef struct {
    A2PFN2_glGenBuffers                genBuffers;
    A2PFN2_glBindBuffer                bindBuffer;
    A2PFN2_glBufferData                bufferData;
    A2PFN2_glGenVertexArrays           genVertexArrays;
    A2PFN2_glBindVertexArray           bindVertexArray;
    A2PFN2_glVertexAttribPointer       vertexAttribPointer;
    A2PFN2_glEnableVertexAttribArray   enableVertexAttribArray;
    A2PFN2_glDrawArrays                drawArrays;
    A2PFN2_glDrawElements              drawElements;
    A2PFN2_glCreateShader              createShader;
    A2PFN2_glShaderSource              shaderSource;
    A2PFN2_glCompileShader             compileShader;
    A2PFN2_glGetShaderiv               getShaderiv;
    A2PFN2_glGetShaderInfoLog          getShaderInfoLog;
    A2PFN2_glCreateProgram             createProgram;
    A2PFN2_glAttachShader              attachShader;
    A2PFN2_glLinkProgram               linkProgram;
    A2PFN2_glGetProgramiv              getProgramiv;
    A2PFN2_glGetProgramInfoLog         getProgramInfoLog;
    A2PFN2_glUseProgram                useProgram;
    A2PFN2_glGetAttribLocation         getAttribLocation;
    A2PFN2_glGetUniformLocation        getUniformLocation;
    A2PFN2_glUniformMatrix4fv          uniformMatrix4fv;
    A2PFN2_glUniform1i                 uniform1i;
    A2PFN2_glUniform1f                 uniform1f;
    A2PFN2_glEnable                    enable;
    A2PFN2_glDisable                   disable;
    A2PFN2_glTexParameteri             texParameteri;
} A2GL2ES3;

static A2GL2ES3 gES3;
static int      gA2GL2Resolved = 0;   ///< 0=未解析 1=解析成功 -1=解析失败（缺入口）
static int      gA2GL2Broken   = 0;   ///< 位 = 着色器/VBO 建失败 ⇒ 整层退回（不崩、只缺画面）

/// ★取一个 ES3 入口★（唯一调用点：`a2gl2_resolve_es3`）。缺失返回 NULL，由调用方统一报缺。
static void *a2gl2_sym(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

/// ★解析全部 ES3 入口★（唯一调用点：`a2gl2_ready()`）。★幂等★：只做一次。
/// 必需项（缺则整层失效）与否决口径写在必需项列表里，不逐项判。
static int a2gl2_resolve_es3(void) {
    if (gA2GL2Resolved != 0) return gA2GL2Resolved == 1;
    gA2GL2Resolved = -1;

#define A2GL2_REQ(field, name) \
    gES3.field = (void *)a2gl2_sym(name); \
    if (gES3.field == NULL) { missing = name; goto fail; }

    const char *missing = NULL;
    A2GL2_REQ(genBuffers,              "glGenBuffers")
    A2GL2_REQ(bindBuffer,              "glBindBuffer")
    A2GL2_REQ(bufferData,              "glBufferData")
    A2GL2_REQ(genVertexArrays,         "glGenVertexArrays")
    A2GL2_REQ(bindVertexArray,         "glBindVertexArray")
    A2GL2_REQ(vertexAttribPointer,     "glVertexAttribPointer")
    A2GL2_REQ(enableVertexAttribArray, "glEnableVertexAttribArray")
    A2GL2_REQ(drawArrays,              "glDrawArrays")
    A2GL2_REQ(createShader,            "glCreateShader")
    A2GL2_REQ(shaderSource,            "glShaderSource")
    A2GL2_REQ(compileShader,           "glCompileShader")
    A2GL2_REQ(getShaderiv,             "glGetShaderiv")
    A2GL2_REQ(getShaderInfoLog,        "glGetShaderInfoLog")
    A2GL2_REQ(createProgram,           "glCreateProgram")
    A2GL2_REQ(attachShader,            "glAttachShader")
    A2GL2_REQ(linkProgram,             "glLinkProgram")
    A2GL2_REQ(getProgramiv,            "glGetProgramiv")
    A2GL2_REQ(getProgramInfoLog,       "glGetProgramInfoLog")
    A2GL2_REQ(useProgram,              "glUseProgram")
    A2GL2_REQ(getAttribLocation,       "glGetAttribLocation")
    A2GL2_REQ(getUniformLocation,      "glGetUniformLocation")
    A2GL2_REQ(uniformMatrix4fv,        "glUniformMatrix4fv")
    A2GL2_REQ(uniform1i,               "glUniform1i")
    A2GL2_REQ(enable,                  "glEnable")
    A2GL2_REQ(disable,                 "glDisable")
    A2GL2_REQ(texParameteri,           "glTexParameteri")
#undef A2GL2_REQ

    // 可选项：缺了只影响个别路径（带索引绘制 / alpha 阈值），不整层失效。
    gES3.drawElements    = (void *)a2gl2_sym("glDrawElements");
    gES3.uniform1f       = (void *)a2gl2_sym("glUniform1f");

    gA2GL2Resolved = 1;
    return 1;

fail:
    a2_log_criterion(@"[A2-GL2] ★本层失效★ 取不到 GLES3 入口 %s（flat namespace 里没有可用的 GLES 实现）"
                     @" ⇒ a2_gl2_shim_lookup 一律返回 NULL，调用方回到原路径",
                     (missing != NULL) ? missing : "(未注明)");
    return 0;
}

// ============================================================================
//  ③ 固定管线状态（★全部是本层私有的 CPU 状态★）
// ----------------------------------------------------------------------------
//  只有「ES3 里不存在的状态」才记在这里；ES3 里存在的一律**直接转发**（如 GL_BLEND/
//  GL_DEPTH_TEST），避免两层各记一份状态而分叉。
// ============================================================================
#define A2GL2_MAT_STACK 32
#define A2GL2_MAX_VERTS 65536          ///< 单次绘制顶点上限（一批 GUI 远小于此值）
#define A2GL2_MAX_ATTR_PUSH 8

typedef struct { GLfloat m[16]; } A2GL2Mat4;     ///< 列主序（与 GL 一致）

typedef struct {
    GLboolean enabled;
    GLint     size;
    GLenum    type;
    GLsizei   stride;
    const void *ptr;
} A2GL2ClientArray;

typedef struct {
    // 矩阵栈
    GLenum    matrixMode;
    A2GL2Mat4 mv[A2GL2_MAT_STACK], proj[A2GL2_MAT_STACK], tex[A2GL2_MAT_STACK];
    int       mvTop, projTop, texTop;
    // 当前属性
    GLfloat   color[4];
    GLfloat   texCoord[2];
    GLfloat   normal[3];
    // 开关（只记 ES3 没有的）
    GLboolean texture2D;
    GLboolean alphaTest;
    GLboolean lighting;
    GLboolean fog;
    GLboolean shadeSmooth;
    // alpha test 参数
    GLenum    alphaFunc;
    GLfloat   alphaRef;
    // 纹理环境
    GLint     texEnvMode;
    // 客户端数组
    A2GL2ClientArray vertexArr, colorArr, texCoordArr, normalArr;
    // 立即模式
    GLboolean inBegin;
    GLenum    beginMode;
} A2GL2State;

static A2GL2State gS;

/// 状态快照（`glPushAttrib/glPopAttrib` 用；客户端数组不在此列，见 PushClientAttrib）
static A2GL2State gAttrStack[A2GL2_MAX_ATTR_PUSH];
static int        gAttrTop = 0;

/// 顶点缓冲：交错布局 {pos3f, color4ub, uv2f} = 24 B（★唯一顶点格式★）
typedef struct {
    GLfloat px, py, pz;
    GLubyte cr, cg, cb, ca;
    GLfloat u, v;
} A2GL2Vertex;
#define A2GL2_VERTEX_STRIDE ((GLsizei)sizeof(A2GL2Vertex))

static A2GL2Vertex gVerts[A2GL2_MAX_VERTS];
static GLuint       gIndex[A2GL2_MAX_VERTS * 3 / 2 + 16];  ///< QUADS 摊三角用（n 个顶点 ⇒ 1.5n 个索引）
static int          gVertCount = 0;

/// GLES3 资源（★幂等★：首次绘制时建）
static GLuint gProg = 0, gVBO = 0, gVAO = 0, gEBO = 0;
static GLint  gLocPos = -1, gLocColor = -1, gLocUV = -1;
static GLint  gLocMVP = -1, gLocUseTex = -1, gLocTexEnv = -1;
static GLint  gLocAlphaTest = -1, gLocAlphaFunc = -1, gLocAlphaRef = -1;

/// 判据计数（日志里可核对「本层真的被用上了」）
static int gLookupHits = 0, gDraws = 0;

// ============================================================================
//  ④ 矩阵（列主序，与 GL 一致；MVP 在 CPU 侧算好）
// ============================================================================
static void a2gl2_mat_identity(A2GL2Mat4 *o) {
    memset(o, 0, sizeof(*o));
    o->m[0] = o->m[5] = o->m[10] = o->m[15] = 1.0f;
}

/// o = a * b（GL 语义：后乘 ⇒ 变换按「先 b 后 a」作用在顶点上）
static void a2gl2_mat_mul(A2GL2Mat4 *o, const A2GL2Mat4 *a, const A2GL2Mat4 *b) {
    A2GL2Mat4 r;
    for (int c = 0; c < 4; c++) {
        for (int r2 = 0; r2 < 4; r2++) {
            GLfloat s = 0.0f;
            for (int k = 0; k < 4; k++) s += a->m[k * 4 + r2] * b->m[c * 4 + k];
            r.m[c * 4 + r2] = s;
        }
    }
    *o = r;
}

/// 当前模式的栈顶（`glMatrixMode` 之外的唯一读法：矩阵类入口全走它）
static A2GL2Mat4 *a2gl2_cur(void) {
    switch (gS.matrixMode) {
        case A2GL2_PROJECTION: return &gS.proj[gS.projTop];
        case A2GL2_TEXTURE:    return &gS.tex[gS.texTop];
        default:               return &gS.mv[gS.mvTop];
    }
}

// ============================================================================
//  ⑤ 着色器（ES 3.00）：一个程序，两个开关（是否采样纹理 / alpha test）
// ----------------------------------------------------------------------------
//  固定管线的其余特性（光照/雾）**不在着色器里模拟**：本层明确不做（见文件头）。
// ============================================================================
static const char *const kA2GL2VS =
    "#version 300 es\n"
    "in vec3 aPos;\n"
    "in vec4 aColor;\n"
    "in vec2 aUV;\n"
    "uniform mat4 uMVP;\n"
    "out vec4 vColor;\n"
    "out vec2 vUV;\n"
    "void main() {\n"
    "    gl_Position = uMVP * vec4(aPos, 1.0);\n"
    "    vColor = aColor;\n"
    "    vUV = aUV;\n"
    "}\n";

static const char *const kA2GL2FS =
    "#version 300 es\n"
    "precision mediump float;\n"
    "in vec4 vColor;\n"
    "in vec2 vUV;\n"
    "uniform sampler2D uTex;\n"
    "uniform int  uUseTex;\n"
    "uniform int  uTexEnv;\n"
    "uniform int  uAlphaTest;\n"
    "uniform int  uAlphaFunc;\n"
    "uniform float uAlphaRef;\n"
    "out vec4 oColor;\n"
    "void main() {\n"
    "    vec4 c = vColor;\n"
    "    if (uUseTex == 1) {\n"
    "        vec4 t = texture(uTex, vUV);\n"
    "        c = (uTexEnv == 1) ? t : (t * c);\n"
    "    }\n"
    "    if (uAlphaTest == 1) {\n"
    "        bool ok = true;\n"
    "        if      (uAlphaFunc == 0) ok = false;\n"
    "        else if (uAlphaFunc == 1) ok = (c.a <  uAlphaRef);\n"
    "        else if (uAlphaFunc == 2) ok = (c.a == uAlphaRef);\n"
    "        else if (uAlphaFunc == 3) ok = (c.a <= uAlphaRef);\n"
    "        else if (uAlphaFunc == 4) ok = (c.a >  uAlphaRef);\n"
    "        else if (uAlphaFunc == 5) ok = (c.a != uAlphaRef);\n"
    "        else if (uAlphaFunc == 6) ok = (c.a >= uAlphaRef);\n"
    "        if (!ok) discard;\n"
    "    }\n"
    "    oColor = c;\n"
    "}\n";

/// 编译一段着色器；失败返回 0 并打日志（★不抛异常、不中断★）。
static GLuint a2gl2_compile(GLenum type, const char *src) {
    GLuint sh = gES3.createShader(type);
    if (sh == 0) return 0;
    gES3.shaderSource(sh, 1, &src, NULL);
    gES3.compileShader(sh);
    GLint ok = 0;
    gES3.getShaderiv(sh, A2GL2_COMPILE_STATUS, &ok);
    if (ok == 0) {
        char log[512];
        log[0] = '\0';
        gES3.getShaderInfoLog(sh, (GLsizei)sizeof(log) - 1, NULL, log);
        a2_log_criterion(@"[A2-GL2] ★本层失效★ 着色器编译失败（type=0x%x）：%s",
                         (unsigned)type, log);
        return 0;
    }
    return sh;
}

/// 建程序 + VAO/VBO（★唯一调用点：`a2gl2_ensure_resources`★）。返回 1 = 就绪。
static int a2gl2_build_program(void) {
    GLuint vs = a2gl2_compile(A2GL2_VERTEX_SHADER, kA2GL2VS);
    if (vs == 0) return 0;
    GLuint fs = a2gl2_compile(A2GL2_FRAGMENT_SHADER, kA2GL2FS);
    if (fs == 0) return 0;
    gProg = gES3.createProgram();
    if (gProg == 0) return 0;
    gES3.attachShader(gProg, vs);
    gES3.attachShader(gProg, fs);
    gES3.linkProgram(gProg);
    GLint ok = 0;
    gES3.getProgramiv(gProg, A2GL2_LINK_STATUS, &ok);
    if (ok == 0) {
        char log[512];
        log[0] = '\0';
        gES3.getProgramInfoLog(gProg, (GLsizei)sizeof(log) - 1, NULL, log);
        a2_log_criterion(@"[A2-GL2] ★本层失效★ 程序链接失败：%s", log);
        gProg = 0;
        return 0;
    }
    gLocPos       = gES3.getAttribLocation(gProg, "aPos");
    gLocColor     = gES3.getAttribLocation(gProg, "aColor");
    gLocUV        = gES3.getAttribLocation(gProg, "aUV");
    gLocMVP       = gES3.getUniformLocation(gProg, "uMVP");
    gLocUseTex    = gES3.getUniformLocation(gProg, "uUseTex");
    gLocTexEnv    = gES3.getUniformLocation(gProg, "uTexEnv");
    gLocAlphaTest = gES3.getUniformLocation(gProg, "uAlphaTest");
    gLocAlphaFunc = gES3.getUniformLocation(gProg, "uAlphaFunc");
    gLocAlphaRef  = gES3.getUniformLocation(gProg, "uAlphaRef");
    if (gLocPos < 0 || gLocColor < 0 || gLocUV < 0) {
        a2_log_criterion(@"[A2-GL2] ★本层失效★ 属性位置取不到（pos=%d color=%d uv=%d）"
                         @" ⇒ 着色器与本层顶点布局不匹配", gLocPos, gLocColor, gLocUV);
        gProg = 0;
        return 0;
    }

    gES3.genVertexArrays(1, &gVAO);
    gES3.bindVertexArray(gVAO);
    gES3.genBuffers(1, &gVBO);
    gES3.bindBuffer(A2GL2_ARRAY_BUFFER, gVBO);
    // 属性布局：pos(0) color(12) uv(16)，stride 24（★与 A2GL2Vertex 严格对应★）
    gES3.enableVertexAttribArray((GLuint)gLocPos);
    gES3.vertexAttribPointer((GLuint)gLocPos, 3, A2GL2_FLOAT, A2GL2_FALSE, A2GL2_VERTEX_STRIDE, (const void *)0);
    gES3.enableVertexAttribArray((GLuint)gLocColor);
    gES3.vertexAttribPointer((GLuint)gLocColor, 4, A2GL2_UNSIGNED_BYTE, A2GL2_TRUE, A2GL2_VERTEX_STRIDE, (const void *)12);
    gES3.enableVertexAttribArray((GLuint)gLocUV);
    gES3.vertexAttribPointer((GLuint)gLocUV, 2, A2GL2_FLOAT, A2GL2_FALSE, A2GL2_VERTEX_STRIDE, (const void *)16);
    if (gES3.drawElements != NULL) gES3.genBuffers(1, &gEBO);
    a2_log_f(@"[A2-GL2] GLES3 资源就绪：program=%u vao=%u vbo=%u（顶点格式 pos3f+color4ub+uv2f=24B）",
             gProg, gVAO, gVBO);
    return 1;
}

/// ★就绪判据（唯一入口）★：解析入口 + 建程序。返回 1 才能绘制。
/// 失败 ⇒ `gA2GL2Broken` 置位（之后 lookup 一律 NULL ⇒ 调用方回到原路径）。
static int a2gl2_ready(void) {
    if (gA2GL2Broken) return 0;
    if (!a2gl2_resolve_es3()) { gA2GL2Broken = 1; return 0; }
    if (gProg == 0 && !a2gl2_build_program()) { gA2GL2Broken = 1; return 0; }
    return 1;
}

// ============================================================================
//  ⑥ 顶点转换 + 绘制（★全部固定管线绘制的唯一出口★）
// ----------------------------------------------------------------------------
//  调用点：`glEnd`（立即模式收集完）、`glDrawArrays`（客户端数组）、
//          `glDrawElements`（带索引的客户端数组）。
// ============================================================================
/// 一种顶点数组元素类型的字节宽（★唯一产地★：读标量与默认步长共用）
static size_t a2gl2_type_size(GLenum type) {
    switch (type) {
        case A2GL2_DOUBLE:         return sizeof(double);
        case A2GL2_UNSIGNED_BYTE:  return sizeof(unsigned char);
        case A2GL2_SHORT:          return sizeof(short);
        case A2GL2_UNSIGNED_SHORT: return sizeof(unsigned short);
        case A2GL2_INT:            return sizeof(int);
        default:                   return sizeof(float);
    }
}

/// 从客户端数组里按类型/步长读一个标量（`base` 指向第 0 个元素）。
/// @param normalized 仅**颜色数组**为 1（UNSIGNED_BYTE 颜色按 /255 归一化）；
///        坐标/纹理坐标不归一化（GL 语义：位置用 ubyte 时取原值）。
static GLfloat a2gl2_read_scalar(const void *base, GLenum type, GLsizei stride, int elem, int comp, int normalized) {
    const size_t ts = a2gl2_type_size(type);
    const char *p = (const char *)base + (size_t)elem * (size_t)(stride > 0 ? stride : 0) + (size_t)comp * ts;
    switch (type) {
        case A2GL2_DOUBLE:         return (GLfloat)(*(const double *)p);
        case A2GL2_UNSIGNED_BYTE: {
            const GLfloat v = (GLfloat)(*(const unsigned char *)p);
            return normalized ? (v / 255.0f) : v;
        }
        case A2GL2_SHORT:          return (GLfloat)(*(const short *)p);
        case A2GL2_UNSIGNED_SHORT: return (GLfloat)(*(const unsigned short *)p);
        case A2GL2_INT:            return (GLfloat)(*(const int *)p);
        default:                   return *(const float *)p;
    }
}

static GLubyte a2gl2_to_u8(GLfloat f) {
    if (f <= 0.0f) return 0;
    if (f >= 1.0f) return 255;
    return (GLubyte)(f * 255.0f + 0.5f);
}

/// 默认步长（stride==0 时按 分量数×类型宽 计算；一处口径，客户端数组与索引路径共用）。
static GLsizei a2gl2_stride_of(GLenum type, GLint size) {
    return (GLsizei)(a2gl2_type_size(type) * (size_t)(size > 0 ? size : 1));
}

/// 把「客户端数组 + 当前属性」的顶点 i 落到交错缓冲（★唯一产地★：立即模式与数组路径共用）。
static void a2gl2_fetch_vertex(A2GL2Vertex *out, int i) {
    if (gS.vertexArr.enabled && gS.vertexArr.ptr != NULL) {
        const GLint n = gS.vertexArr.size > 0 ? gS.vertexArr.size : 3;
        const GLsizei st = gS.vertexArr.stride > 0 ? gS.vertexArr.stride
                                                   : a2gl2_stride_of(gS.vertexArr.type, n);
        out->px = a2gl2_read_scalar(gS.vertexArr.ptr, gS.vertexArr.type, st, i, 0, 0);
        out->py = (n > 1) ? a2gl2_read_scalar(gS.vertexArr.ptr, gS.vertexArr.type, st, i, 1, 0) : 0.0f;
        out->pz = (n > 2) ? a2gl2_read_scalar(gS.vertexArr.ptr, gS.vertexArr.type, st, i, 2, 0) : 0.0f;
    }
    if (gS.colorArr.enabled && gS.colorArr.ptr != NULL) {
        const GLint n = gS.colorArr.size > 0 ? gS.colorArr.size : 4;
        const GLsizei st = gS.colorArr.stride > 0 ? gS.colorArr.stride
                                                  : a2gl2_stride_of(gS.colorArr.type, n);
        GLfloat c[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
        for (int k = 0; k < n && k < 4; k++)
            c[k] = a2gl2_read_scalar(gS.colorArr.ptr, gS.colorArr.type, st, i, k, 1);
        out->cr = a2gl2_to_u8(c[0]); out->cg = a2gl2_to_u8(c[1]);
        out->cb = a2gl2_to_u8(c[2]); out->ca = a2gl2_to_u8(c[3]);
    } else {
        out->cr = a2gl2_to_u8(gS.color[0]); out->cg = a2gl2_to_u8(gS.color[1]);
        out->cb = a2gl2_to_u8(gS.color[2]); out->ca = a2gl2_to_u8(gS.color[3]);
    }
    if (gS.texCoordArr.enabled && gS.texCoordArr.ptr != NULL) {
        const GLint n = gS.texCoordArr.size > 0 ? gS.texCoordArr.size : 2;
        const GLsizei st = gS.texCoordArr.stride > 0 ? gS.texCoordArr.stride
                                                     : a2gl2_stride_of(gS.texCoordArr.type, n);
        out->u = a2gl2_read_scalar(gS.texCoordArr.ptr, gS.texCoordArr.type, st, i, 0, 0);
        out->v = (n > 1) ? a2gl2_read_scalar(gS.texCoordArr.ptr, gS.texCoordArr.type, st, i, 1, 0) : 0.0f;
    } else {
        out->u = gS.texCoord[0];
        out->v = gS.texCoord[1];
    }
}

/// 当前 MVP = projection * modelview（★唯一产地★）
static void a2gl2_mvp(A2GL2Mat4 *out) {
    a2gl2_mat_mul(out, &gS.proj[gS.projTop], &gS.mv[gS.mvTop]);
}

/// alpha func 的 GL 枚举 → 着色器里的整数码（不改语义，只做表映射）
static GLint a2gl2_alpha_code(GLenum f) {
    switch (f) {
        case A2GL2_NEVER:    return 0;
        case A2GL2_LESS:     return 1;
        case A2GL2_EQUAL:    return 2;
        case A2GL2_LEQUAL:   return 3;
        case A2GL2_GREATER:  return 4;
        case A2GL2_NOTEQUAL: return 5;
        case A2GL2_GEQUAL:   return 6;
        default:             return 7;   // ALWAYS
    }
}

/// ★上载并绘制 `n` 个已经落在 `gVerts` 里的顶点★（`mode` 为 GL 图元，含 ES3 没有的 QUADS）。
/// 调用点：`glEnd` / `glDrawArrays` / `glDrawElements` 三处（都先填 gVerts 再调它）。
static void a2gl2_draw(GLenum mode, int n) {
    if (n <= 0) return;
    if (!a2gl2_ready()) return;

    A2GL2Mat4 mvp;
    a2gl2_mvp(&mvp);

    gES3.useProgram(gProg);
    gES3.bindVertexArray(gVAO);
    gES3.bindBuffer(A2GL2_ARRAY_BUFFER, gVBO);
    gES3.bufferData(A2GL2_ARRAY_BUFFER, (GLsizeiptr)((size_t)n * sizeof(A2GL2Vertex)), gVerts, A2GL2_STREAM_DRAW);
    if (gLocMVP >= 0)    gES3.uniformMatrix4fv(gLocMVP, 1, A2GL2_FALSE, mvp.m);
    if (gLocUseTex >= 0) gES3.uniform1i(gLocUseTex, gS.texture2D ? 1 : 0);
    if (gLocTexEnv >= 0) gES3.uniform1i(gLocTexEnv, (gS.texEnvMode == A2GL2_REPLACE) ? 1 : 0);
    if (gLocAlphaTest >= 0) gES3.uniform1i(gLocAlphaTest, gS.alphaTest ? 1 : 0);
    if (gLocAlphaFunc >= 0) gES3.uniform1i(gLocAlphaFunc, a2gl2_alpha_code(gS.alphaFunc));
    if (gLocAlphaRef >= 0 && gES3.uniform1f != NULL) gES3.uniform1f(gLocAlphaRef, gS.alphaRef);

    // ★ES3 没有的图元在这里摊开★：QUADS/POLYGON → TRIANGLES；LINE_LOOP → LINE_STRIP(+闭合点)
    if (mode == A2GL2_QUADS) {
        const int quads = n / 4;
        int k = 0;
        for (int q = 0; q < quads; q++) {
            const GLuint b = (GLuint)(q * 4);
            gIndex[k++] = b;     gIndex[k++] = b + 1; gIndex[k++] = b + 2;
            gIndex[k++] = b;     gIndex[k++] = b + 2; gIndex[k++] = b + 3;
        }
        if (k > 0 && gES3.drawElements == NULL) {
            static int warned = 0;
            if (!warned) { warned = 1; a2_log_f(@"[A2-GL2] ★缺 glDrawElements★：QUADS 无法摊成三角形（本批 %d 顶点丢弃）", n); }
        }
        if (k > 0 && gES3.drawElements != NULL) {
            gES3.bindBuffer(A2GL2_ELEMENT_ARRAY_BUFFER, gEBO);
            gES3.bufferData(A2GL2_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)((size_t)k * sizeof(GLuint)), gIndex, A2GL2_STREAM_DRAW);
            gES3.drawElements(A2GL2_TRIANGLES, k, A2GL2_UNSIGNED_INT, (const void *)0);
        }
    } else if (mode == A2GL2_POLYGON) {
        gES3.drawArrays(A2GL2_TRIANGLE_FAN, 0, n);
    } else if (mode == A2GL2_LINE_LOOP) {
        // 闭合：把首顶点补到末尾再画 LINE_STRIP（ES3 没有 LINE_LOOP）
        if (n + 1 < A2GL2_MAX_VERTS) {
            gVerts[n] = gVerts[0];
            gES3.bufferData(A2GL2_ARRAY_BUFFER, (GLsizeiptr)((size_t)(n + 1) * sizeof(A2GL2Vertex)), gVerts, A2GL2_STREAM_DRAW);
            gES3.drawArrays(A2GL2_LINE_STRIP, 0, n + 1);
        } else {
            gES3.drawArrays(A2GL2_LINE_STRIP, 0, n);
        }
    } else {
        // ★ES3 原生支持的图元直接下发★；QUAD_STRIP 等 ES3 不认的（MC 主菜单不产生）
        //   在这里一次性点名，避免「没有报错但画不出来」。
        const int native = (mode == A2GL2_POINTS || mode == A2GL2_LINES ||
                            mode == A2GL2_LINE_STRIP || mode == A2GL2_TRIANGLES ||
                            mode == A2GL2_TRIANGLE_STRIP || mode == A2GL2_TRIANGLE_FAN);
        if (!native) {
            static int warned = 0;
            if (!warned) { warned = 1; a2_log_f(@"[A2-GL2] ★未支持图元★ mode=0x%x（本层只摊 QUADS/POLYGON/LINE_LOOP）", (unsigned)mode); }
        } else {
            gES3.drawArrays(mode, 0, n);
        }
    }

    gDraws++;
    if (gDraws <= 3 || (gDraws % 600) == 0) {
        a2_log_f(@"[A2-GL2] 绘制 #%d：mode=0x%x 顶点=%d 纹理=%s alphaTest=%s（MVP 由矩阵栈算）",
                 gDraws, (unsigned)mode, n,
                 gS.texture2D ? "开" : "关", gS.alphaTest ? "开" : "关");
    }
}

// ============================================================================
//  ⑦ 固定管线入口实现
// ----------------------------------------------------------------------------
//  签名与 GL 规范严格一致（这些函数地址会被直接当函数指针交给下载器/渲染器调用）。
// ============================================================================

// ---- 立即模式 -------------------------------------------------------------
static void gl2_glBegin(GLenum mode) {
    gS.inBegin = A2GL2_TRUE;
    gS.beginMode = mode;
    gVertCount = 0;
}

static void gl2_glEnd(void) {
    if (!gS.inBegin) return;
    gS.inBegin = A2GL2_FALSE;
    a2gl2_draw(gS.beginMode, gVertCount);
    gVertCount = 0;
}

/// 立即模式推一个顶点（★唯一产地★：所有 glVertex* 都走它）
static void a2gl2_push_vertex(GLfloat x, GLfloat y, GLfloat z) {
    if (!gS.inBegin) return;
    if (gVertCount >= A2GL2_MAX_VERTS) {          // 溢出 ⇒ 先画一批（不丢顶点、不越界）
        a2gl2_draw(gS.beginMode, gVertCount);
        gVertCount = 0;
    }
    A2GL2Vertex *v = &gVerts[gVertCount++];
    v->px = x; v->py = y; v->pz = z;
    v->cr = a2gl2_to_u8(gS.color[0]); v->cg = a2gl2_to_u8(gS.color[1]);
    v->cb = a2gl2_to_u8(gS.color[2]); v->ca = a2gl2_to_u8(gS.color[3]);
    v->u = gS.texCoord[0]; v->v = gS.texCoord[1];
}

static void gl2_glVertex2f(GLfloat x, GLfloat y)  { a2gl2_push_vertex(x, y, 0.0f); }
static void gl2_glVertex3f(GLfloat x, GLfloat y, GLfloat z) { a2gl2_push_vertex(x, y, z); }
static void gl2_glVertex2d(GLdouble x, GLdouble y) { a2gl2_push_vertex((GLfloat)x, (GLfloat)y, 0.0f); }
static void gl2_glVertex3d(GLdouble x, GLdouble y, GLdouble z) { a2gl2_push_vertex((GLfloat)x, (GLfloat)y, (GLfloat)z); }
static void gl2_glVertex2i(GLint x, GLint y)      { a2gl2_push_vertex((GLfloat)x, (GLfloat)y, 0.0f); }
static void gl2_glVertex3i(GLint x, GLint y, GLint z) { a2gl2_push_vertex((GLfloat)x, (GLfloat)y, (GLfloat)z); }
static void gl2_glVertex2fv(const GLfloat *v)     { if (v) a2gl2_push_vertex(v[0], v[1], 0.0f); }
static void gl2_glVertex3fv(const GLfloat *v)     { if (v) a2gl2_push_vertex(v[0], v[1], v[2]); }

static void gl2_glColor3f(GLfloat r, GLfloat g, GLfloat b) { gS.color[0]=r; gS.color[1]=g; gS.color[2]=b; gS.color[3]=1.0f; }
static void gl2_glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) { gS.color[0]=r; gS.color[1]=g; gS.color[2]=b; gS.color[3]=a; }
static void gl2_glColor3ub(GLubyte r, GLubyte g, GLubyte b) { gl2_glColor3f(r/255.0f, g/255.0f, b/255.0f); }
static void gl2_glColor4ub(GLubyte r, GLubyte g, GLubyte b, GLubyte a) { gl2_glColor4f(r/255.0f, g/255.0f, b/255.0f, a/255.0f); }
static void gl2_glColor4fv(const GLfloat *v) { if (v) gl2_glColor4f(v[0], v[1], v[2], v[3]); }

static void gl2_glTexCoord2f(GLfloat s, GLfloat t) { gS.texCoord[0]=s; gS.texCoord[1]=t; }
static void gl2_glTexCoord2d(GLdouble s, GLdouble t) { gS.texCoord[0]=(GLfloat)s; gS.texCoord[1]=(GLfloat)t; }
static void gl2_glTexCoord2fv(const GLfloat *v) { if (v) gl2_glTexCoord2f(v[0], v[1]); }

static void gl2_glNormal3f(GLfloat x, GLfloat y, GLfloat z) { gS.normal[0]=x; gS.normal[1]=y; gS.normal[2]=z; }
static void gl2_glNormal3fv(const GLfloat *v) { if (v) gl2_glNormal3f(v[0], v[1], v[2]); }

// ---- 矩阵栈 ---------------------------------------------------------------
static void gl2_glMatrixMode(GLenum mode) {
    if (mode == A2GL2_MODELVIEW || mode == A2GL2_PROJECTION || mode == A2GL2_TEXTURE) gS.matrixMode = mode;
}

static void gl2_glLoadIdentity(void) { a2gl2_mat_identity(a2gl2_cur()); }

static void gl2_glLoadMatrixf(const GLfloat *m) {
    if (m != NULL) memcpy(a2gl2_cur()->m, m, sizeof(GLfloat) * 16);
}

static void gl2_glMultMatrixf(const GLfloat *m) {
    if (m == NULL) return;
    A2GL2Mat4 t;
    memcpy(t.m, m, sizeof(t.m));
    A2GL2Mat4 r;
    a2gl2_mat_mul(&r, a2gl2_cur(), &t);
    *a2gl2_cur() = r;
}

static void gl2_glPushMatrix(void) {
    switch (gS.matrixMode) {
        case A2GL2_PROJECTION:
            if (gS.projTop + 1 < A2GL2_MAT_STACK) { gS.proj[gS.projTop + 1] = gS.proj[gS.projTop]; gS.projTop++; }
            break;
        case A2GL2_TEXTURE:
            if (gS.texTop + 1 < A2GL2_MAT_STACK) { gS.tex[gS.texTop + 1] = gS.tex[gS.texTop]; gS.texTop++; }
            break;
        default:
            if (gS.mvTop + 1 < A2GL2_MAT_STACK) { gS.mv[gS.mvTop + 1] = gS.mv[gS.mvTop]; gS.mvTop++; }
            break;
    }
}

static void gl2_glPopMatrix(void) {
    switch (gS.matrixMode) {
        case A2GL2_PROJECTION: if (gS.projTop > 0) gS.projTop--; break;
        case A2GL2_TEXTURE:    if (gS.texTop  > 0) gS.texTop--;  break;
        default:               if (gS.mvTop   > 0) gS.mvTop--;   break;
    }
}

static void gl2_glTranslatef(GLfloat x, GLfloat y, GLfloat z) {
    A2GL2Mat4 t; a2gl2_mat_identity(&t);
    t.m[12] = x; t.m[13] = y; t.m[14] = z;
    A2GL2Mat4 r; a2gl2_mat_mul(&r, a2gl2_cur(), &t);
    *a2gl2_cur() = r;
}

static void gl2_glScalef(GLfloat x, GLfloat y, GLfloat z) {
    A2GL2Mat4 t; a2gl2_mat_identity(&t);
    t.m[0] = x; t.m[5] = y; t.m[10] = z;
    A2GL2Mat4 r; a2gl2_mat_mul(&r, a2gl2_cur(), &t);
    *a2gl2_cur() = r;
}

static void gl2_glRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z) {
    const GLfloat len = sqrtf(x * x + y * y + z * z);
    if (len <= 0.0f) return;
    const GLfloat rad = angle * 3.14159265358979323846f / 180.0f;
    const GLfloat c = cosf(rad), s = sinf(rad);
    const GLfloat nx = x / len, ny = y / len, nz = z / len;
    A2GL2Mat4 t; a2gl2_mat_identity(&t);
    t.m[0]  = c + nx * nx * (1 - c);       t.m[1]  = ny * nx * (1 - c) + nz * s; t.m[2]  = nz * nx * (1 - c) - ny * s;
    t.m[4]  = nx * ny * (1 - c) - nz * s;  t.m[5]  = c + ny * ny * (1 - c);      t.m[6]  = nz * ny * (1 - c) + nx * s;
    t.m[8]  = nx * nz * (1 - c) + ny * s;  t.m[9]  = ny * nz * (1 - c) - nx * s; t.m[10] = c + nz * nz * (1 - c);
    A2GL2Mat4 r; a2gl2_mat_mul(&r, a2gl2_cur(), &t);
    *a2gl2_cur() = r;
}

/// glOrtho/glFrustum 的共用出口（★唯一产地★：float/double 两版都调它）
static void a2gl2_ortho(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f) {
    A2GL2Mat4 m; a2gl2_mat_identity(&m);
    const GLdouble rl = r - l, tb = t - b, fn = f - n;
    if (rl == 0.0 || tb == 0.0 || fn == 0.0) return;
    m.m[0]  = (GLfloat)(2.0 / rl);
    m.m[5]  = (GLfloat)(2.0 / tb);
    m.m[10] = (GLfloat)(-2.0 / fn);
    m.m[12] = (GLfloat)(-(r + l) / rl);
    m.m[13] = (GLfloat)(-(t + b) / tb);
    m.m[14] = (GLfloat)(-(f + n) / fn);
    A2GL2Mat4 out; a2gl2_mat_mul(&out, a2gl2_cur(), &m);
    *a2gl2_cur() = out;
}

static void gl2_glOrtho(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f) {
    a2gl2_ortho(l, r, b, t, n, f);
}
static void gl2_glOrthof(GLfloat l, GLfloat r, GLfloat b, GLfloat t, GLfloat n, GLfloat f) {
    a2gl2_ortho(l, r, b, t, n, f);
}

static void a2gl2_frustum(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f) {
    if (n <= 0.0 || f <= n) return;
    A2GL2Mat4 m; memset(&m, 0, sizeof(m));
    m.m[0]  = (GLfloat)(2.0 * n / (r - l));
    m.m[5]  = (GLfloat)(2.0 * n / (t - b));
    m.m[8]  = (GLfloat)((r + l) / (r - l));
    m.m[9]  = (GLfloat)((t + b) / (t - b));
    m.m[10] = (GLfloat)(-(f + n) / (f - n));
    m.m[11] = -1.0f;
    m.m[14] = (GLfloat)(-(2.0 * f * n) / (f - n));
    A2GL2Mat4 out; a2gl2_mat_mul(&out, a2gl2_cur(), &m);
    *a2gl2_cur() = out;
}

static void gl2_glFrustum(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f) {
    a2gl2_frustum(l, r, b, t, n, f);
}
static void gl2_glFrustumf(GLfloat l, GLfloat r, GLfloat b, GLfloat t, GLfloat n, GLfloat f) {
    a2gl2_frustum(l, r, b, t, n, f);
}

// ---- 开关 -----------------------------------------------------------------
/// ES3 里**不存在**的开关（只记账，不转发）——★唯一判据★，glEnable/glDisable 共用。
static int a2gl2_is_fixed_only(GLenum cap) {
    switch (cap) {
        case A2GL2_TEXTURE_2D: case A2GL2_ALPHA_TEST: case A2GL2_LIGHTING:
        case A2GL2_FOG: case A2GL2_NORMALIZE: case A2GL2_COLOR_MATERIAL:
            return 1;
        default:
            return 0;
    }
}

static void gl2_glEnable(GLenum cap) {
    switch (cap) {
        case A2GL2_TEXTURE_2D:     gS.texture2D = A2GL2_TRUE; return;
        case A2GL2_ALPHA_TEST:     gS.alphaTest = A2GL2_TRUE; return;
        case A2GL2_LIGHTING:       gS.lighting  = A2GL2_TRUE; return;   // 本层不模拟光照（见文件头）
        case A2GL2_FOG:            gS.fog       = A2GL2_TRUE; return;
        default: break;
    }
    if (a2gl2_is_fixed_only(cap)) return;
    if (a2gl2_ready()) gES3.enable(cap);     // ES3 有的开关一律转发（不记第二份状态）
}

static void gl2_glDisable(GLenum cap) {
    switch (cap) {
        case A2GL2_TEXTURE_2D:     gS.texture2D = A2GL2_FALSE; return;
        case A2GL2_ALPHA_TEST:     gS.alphaTest = A2GL2_FALSE; return;
        case A2GL2_LIGHTING:       gS.lighting  = A2GL2_FALSE; return;
        case A2GL2_FOG:            gS.fog       = A2GL2_FALSE; return;
        default: break;
    }
    if (a2gl2_is_fixed_only(cap)) return;
    if (a2gl2_ready()) gES3.disable(cap);
}

static void gl2_glEnableClientState(GLenum arr) {
    switch (arr) {
        case A2GL2_VERTEX_ARRAY:        gS.vertexArr.enabled   = A2GL2_TRUE; return;
        case A2GL2_COLOR_ARRAY:         gS.colorArr.enabled    = A2GL2_TRUE; return;
        case A2GL2_TEXTURE_COORD_ARRAY: gS.texCoordArr.enabled = A2GL2_TRUE; return;
        case A2GL2_NORMAL_ARRAY:        gS.normalArr.enabled   = A2GL2_TRUE; return;
        default: return;
    }
}

static void gl2_glDisableClientState(GLenum arr) {
    switch (arr) {
        case A2GL2_VERTEX_ARRAY:        gS.vertexArr.enabled   = A2GL2_FALSE; return;
        case A2GL2_COLOR_ARRAY:         gS.colorArr.enabled    = A2GL2_FALSE; return;
        case A2GL2_TEXTURE_COORD_ARRAY: gS.texCoordArr.enabled = A2GL2_FALSE; return;
        case A2GL2_NORMAL_ARRAY:        gS.normalArr.enabled   = A2GL2_FALSE; return;
        default: return;
    }
}

static void gl2_glPushAttrib(GLbitfield mask) {
    (void)mask;   // 本层状态量小，一律整份快照（GL 允许「多存」的语义等价）
    if (gAttrTop < A2GL2_MAX_ATTR_PUSH) gAttrStack[gAttrTop++] = gS;
}
static void gl2_glPopAttrib(void) {
    if (gAttrTop > 0) gS = gAttrStack[--gAttrTop];
}
// ★客户端数组另用一个栈★：`glPushClientAttrib` 与 `glPushAttrib` 的语义不同 ——
//   前者只回滚「哪些数组开着、指向哪里」，把矩阵/开关一起回滚会让变换莫名复位（GL 不允许）。
typedef struct {
    A2GL2ClientArray vertexArr, colorArr, texCoordArr, normalArr;
} A2GL2ClientSnapshot;
static A2GL2ClientSnapshot gClientStack[A2GL2_MAX_ATTR_PUSH];
static int                 gClientTop = 0;

static void gl2_glPushClientAttrib(GLbitfield mask) {
    (void)mask;
    if (gClientTop >= A2GL2_MAX_ATTR_PUSH) return;
    gClientStack[gClientTop].vertexArr   = gS.vertexArr;
    gClientStack[gClientTop].colorArr    = gS.colorArr;
    gClientStack[gClientTop].texCoordArr = gS.texCoordArr;
    gClientStack[gClientTop].normalArr   = gS.normalArr;
    gClientTop++;
}
static void gl2_glPopClientAttrib(void) {
    if (gClientTop <= 0) return;
    gClientTop--;
    gS.vertexArr   = gClientStack[gClientTop].vertexArr;
    gS.colorArr    = gClientStack[gClientTop].colorArr;
    gS.texCoordArr = gClientStack[gClientTop].texCoordArr;
    gS.normalArr   = gClientStack[gClientTop].normalArr;
}

static void gl2_glShadeModel(GLenum mode) { gS.shadeSmooth = (mode == 0x1D01) ? A2GL2_TRUE : A2GL2_FALSE; }
static void gl2_glAlphaFunc(GLenum func, GLfloat ref) { gS.alphaFunc = func; gS.alphaRef = ref; }

// ---- 客户端顶点数组 -------------------------------------------------------
static void gl2_glVertexPointer(GLint size, GLenum type, GLsizei stride, const void *ptr) {
    gS.vertexArr.size = size; gS.vertexArr.type = type; gS.vertexArr.stride = stride; gS.vertexArr.ptr = ptr;
}
static void gl2_glColorPointer(GLint size, GLenum type, GLsizei stride, const void *ptr) {
    gS.colorArr.size = size; gS.colorArr.type = type; gS.colorArr.stride = stride; gS.colorArr.ptr = ptr;
}
static void gl2_glTexCoordPointer(GLint size, GLenum type, GLsizei stride, const void *ptr) {
    gS.texCoordArr.size = size; gS.texCoordArr.type = type; gS.texCoordArr.stride = stride; gS.texCoordArr.ptr = ptr;
}
static void gl2_glNormalPointer(GLenum type, GLsizei stride, const void *ptr) {
    gS.normalArr.size = 3; gS.normalArr.type = type; gS.normalArr.stride = stride; gS.normalArr.ptr = ptr;
}

/// ★客户端数组 → 交错缓冲★（唯一调用点：glDrawArrays / glDrawElements）
static int a2gl2_gather(int first, int count) {
    if (!gS.vertexArr.enabled || gS.vertexArr.ptr == NULL) return 0;
    if (count <= 0) return 0;
    if (count > A2GL2_MAX_VERTS) count = A2GL2_MAX_VERTS;
    for (int i = 0; i < count; i++) a2gl2_fetch_vertex(&gVerts[i], first + i);
    return count;
}

static void gl2_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    const int n = a2gl2_gather(first, count);
    a2gl2_draw(mode, n);
}

static void gl2_glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices) {
    if (indices == NULL || count <= 0) return;
    if (count > A2GL2_MAX_VERTS) count = A2GL2_MAX_VERTS;
    // 索引可能不是 0..n 连续，且客户端数组按索引取值 ⇒ 逐个摊开（不做 baseVertex）。
    // ★直接写 gVerts★：`a2gl2_fetch_vertex` 只读客户端内存/当前属性，不读 gVerts ⇒ 无别名冲突。
    for (int i = 0; i < count; i++) {
        int idx = 0;
        switch (type) {
            case A2GL2_UNSIGNED_BYTE:  idx = (int)((const unsigned char *)indices)[i]; break;
            case A2GL2_UNSIGNED_SHORT: idx = (int)((const unsigned short *)indices)[i]; break;
            case A2GL2_UNSIGNED_INT:   idx = (int)((const unsigned int *)indices)[i]; break;
            default:                   idx = (int)((const unsigned short *)indices)[i]; break;
        }
        a2gl2_fetch_vertex(&gVerts[i], idx);
    }
    a2gl2_draw(mode, count);
}

// ---- 纹理状态（只接「ES3 不认的那几个」）--------------------------------
static void gl2_glTexEnvi(GLenum target, GLenum pname, GLint param) {
    if (target == A2GL2_TEXTURE_ENV && pname == A2GL2_TEXTURE_ENV_MODE) gS.texEnvMode = param;
}
static void gl2_glTexEnvf(GLenum target, GLenum pname, GLfloat param) {
    gl2_glTexEnvi(target, pname, (GLint)param);
}

/// ★GL_CLAMP → GL_CLAMP_TO_EDGE★（ES3 不认 GL_CLAMP；MC 大量用 CLAMP）——本层唯一的
/// 纹理参数改写点，其余参数原样转发。
static void gl2_glTexParameteri(GLenum target, GLenum pname, GLint param) {
    if (!a2gl2_resolve_es3()) return;   // 只解析入口：本入口与着色器无关，不能因未绘制而吞参数
    if (param == A2GL2_CLAMP) param = A2GL2_CLAMP_TO_EDGE;
    gES3.texParameteri(target, pname, param);
}
static void gl2_glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    gl2_glTexParameteri(target, pname, (GLint)param);
}

// ---- 一律忽略的固定管线设置项（★共用同一个实现★，与 a2_gl_bridge 的兜底桩同思路：
//      这些入口全部 void 返回、只收标量/指针、无变参 ⇒ `void(void)` 原型在 arm64 上安全）----
static void gl2_ignored(void) { /* 本层不模拟：光照/雾/材质/裁剪面/逻辑运算/多边形模式/提示 */ }

// ---- 已标识但本层不接管的名字（返回 NULL 让调用方回落原路径的，不在此表内）----

// ----------------------------------------------------------------------------
//  ★状态初值★（唯一调用点：`a2_gl2_shim_lookup` 首次命中时）
//  为什么必须有：`gS` 是静态零值 —— 矩阵全零 ⇒ MVP 全零 ⇒ 一个像素都画不出来；
//  而 GL 语义里当前颜色初值是 (1,1,1,1)、alpha func 初值是 ALWAYS、纹理环境是 MODULATE。
// ----------------------------------------------------------------------------
static void a2gl2_state_init(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    memset(&gS, 0, sizeof(gS));
    a2gl2_mat_identity(&gS.mv[0]);
    a2gl2_mat_identity(&gS.proj[0]);
    a2gl2_mat_identity(&gS.tex[0]);
    gS.matrixMode  = A2GL2_MODELVIEW;
    gS.color[0] = gS.color[1] = gS.color[2] = gS.color[3] = 1.0f;
    gS.texEnvMode  = A2GL2_MODULATE;
    gS.alphaFunc   = A2GL2_ALWAYS;
    gS.alphaRef    = 0.0f;
    gS.shadeSmooth = A2GL2_TRUE;
    a2_log_f(@"[A2-GL2] 状态初值：矩阵=单位阵 颜色=白(1,1,1,1) 纹理环境=MODULATE alphaFunc=ALWAYS");
}

// ============================================================================
//  ⑧ 名字 → 实现（★唯一登记表★：每个新增入口都在这里，注释写清「对应固定管线语义」）
// ============================================================================
typedef struct { const char *name; void *fn; } A2GL2Entry;

static const A2GL2Entry kA2GL2Entries[] = {
    // 立即模式
    { "glBegin",            (void *)gl2_glBegin },
    { "glEnd",              (void *)gl2_glEnd },
    { "glVertex2f",         (void *)gl2_glVertex2f },
    { "glVertex3f",         (void *)gl2_glVertex3f },
    { "glVertex2d",         (void *)gl2_glVertex2d },
    { "glVertex3d",         (void *)gl2_glVertex3d },
    { "glVertex2i",         (void *)gl2_glVertex2i },
    { "glVertex3i",         (void *)gl2_glVertex3i },
    { "glVertex2fv",        (void *)gl2_glVertex2fv },
    { "glVertex3fv",        (void *)gl2_glVertex3fv },
    { "glColor3f",          (void *)gl2_glColor3f },
    { "glColor4f",          (void *)gl2_glColor4f },
    { "glColor3ub",         (void *)gl2_glColor3ub },
    { "glColor4ub",         (void *)gl2_glColor4ub },
    { "glColor4fv",         (void *)gl2_glColor4fv },
    { "glTexCoord2f",       (void *)gl2_glTexCoord2f },
    { "glTexCoord2d",       (void *)gl2_glTexCoord2d },
    { "glTexCoord2fv",      (void *)gl2_glTexCoord2fv },
    { "glNormal3f",         (void *)gl2_glNormal3f },
    { "glNormal3fv",        (void *)gl2_glNormal3fv },
    // 矩阵栈
    { "glMatrixMode",       (void *)gl2_glMatrixMode },
    { "glLoadIdentity",     (void *)gl2_glLoadIdentity },
    { "glLoadMatrixf",      (void *)gl2_glLoadMatrixf },
    { "glMultMatrixf",      (void *)gl2_glMultMatrixf },
    { "glPushMatrix",       (void *)gl2_glPushMatrix },
    { "glPopMatrix",        (void *)gl2_glPopMatrix },
    { "glTranslatef",       (void *)gl2_glTranslatef },
    { "glScalef",           (void *)gl2_glScalef },
    { "glRotatef",          (void *)gl2_glRotatef },
    { "glOrtho",            (void *)gl2_glOrtho },
    { "glOrthof",           (void *)gl2_glOrthof },
    { "glFrustum",          (void *)gl2_glFrustum },
    { "glFrustumf",         (void *)gl2_glFrustumf },
    // 开关 / 状态
    { "glEnable",           (void *)gl2_glEnable },
    { "glDisable",          (void *)gl2_glDisable },
    { "glEnableClientState",  (void *)gl2_glEnableClientState },
    { "glDisableClientState", (void *)gl2_glDisableClientState },
    { "glPushAttrib",       (void *)gl2_glPushAttrib },
    { "glPopAttrib",        (void *)gl2_glPopAttrib },
    { "glPushClientAttrib", (void *)gl2_glPushClientAttrib },
    { "glPopClientAttrib",  (void *)gl2_glPopClientAttrib },
    { "glShadeModel",       (void *)gl2_glShadeModel },
    { "glAlphaFunc",        (void *)gl2_glAlphaFunc },
    // 客户端数组 + 绘制
    { "glVertexPointer",    (void *)gl2_glVertexPointer },
    { "glColorPointer",     (void *)gl2_glColorPointer },
    { "glTexCoordPointer",  (void *)gl2_glTexCoordPointer },
    { "glNormalPointer",    (void *)gl2_glNormalPointer },
    { "glDrawArrays",       (void *)gl2_glDrawArrays },
    { "glDrawElements",     (void *)gl2_glDrawElements },
    // 纹理状态改写
    { "glTexEnvi",          (void *)gl2_glTexEnvi },
    { "glTexEnvf",          (void *)gl2_glTexEnvf },
    { "glTexParameteri",    (void *)gl2_glTexParameteri },
    { "glTexParameterf",    (void *)gl2_glTexParameterf },
    // 明确忽略（固定管线专属、本层不模拟；★共用一个实现★）
    { "glLightf",           (void *)gl2_ignored },
    { "glLighti",           (void *)gl2_ignored },
    { "glLightfv",          (void *)gl2_ignored },
    { "glLightiv",          (void *)gl2_ignored },
    { "glLightModelf",      (void *)gl2_ignored },
    { "glLightModelfv",     (void *)gl2_ignored },
    { "glMaterialf",        (void *)gl2_ignored },
    { "glMaterialfv",       (void *)gl2_ignored },
    { "glColorMaterial",    (void *)gl2_ignored },
    { "glFogf",             (void *)gl2_ignored },
    { "glFogi",             (void *)gl2_ignored },
    { "glFogfv",            (void *)gl2_ignored },
    { "glClipPlane",        (void *)gl2_ignored },
    { "glPolygonMode",      (void *)gl2_ignored },
    { "glHint",             (void *)gl2_ignored },
    { "glLogicOp",          (void *)gl2_ignored },
    { "glPointSize",        (void *)gl2_ignored },
    { NULL, NULL }
};

// ============================================================================
//  ⑨ 对外两个函数（见 a2_gl2_shim.h 的调用点注释）
// ============================================================================
static int gA2GL2Enabled = -1;   ///< -1=未判 0=关 1=开（★唯一缓存★）

int a2_gl2_shim_enabled(void) {
    if (gA2GL2Enabled >= 0) return gA2GL2Enabled;
    const char *env = getenv("A2_GL2_SHIM");
    const int on = (env != NULL && env[0] != '\0' && strcmp(env, "0") != 0);
    gA2GL2Enabled = on ? 1 : 0;
    // ★判据行★：真机 grep `[A2-GL2]`
    if (on) {
        a2_log_criterion(@"[A2-GL2] ★自研固定管线档位=启用★（判据：环境变量 A2_GL2_SHIM=%s）"
                         @"——立即模式/矩阵栈/客户端顶点数组 → GLES3 VBO 绘制", env);
    } else {
        a2_log_criterion(@"[A2-GL2] 自研固定管线档位=未启用（判据：A2_GL2_SHIM=%s ⇒ 默认关闭，"
                         @"本层对全部渲染器不生效）", (env != NULL) ? env : "(未设)");
    }
    return gA2GL2Enabled;
}

void *a2_gl2_shim_lookup(const char *name) {
    if (name == NULL) return NULL;
    if (!a2_gl2_shim_enabled()) return NULL;       // ★关闭 ⇒ 完全透明★
    a2gl2_state_init();                            // 首次命中前把状态摆到 GL 初值
    for (int i = 0; kA2GL2Entries[i].name != NULL; i++) {
        if (strcmp(kA2GL2Entries[i].name, name) == 0) {
            if (gLookupHits < 64) {                // 首见打一行（去重：每个名字只报一次）
                a2_log_f(@"[A2-GL2] 解析 %s ⇒ 本层实现（首见；命中计数 %d）", name, gLookupHits + 1);
            }
            gLookupHits++;
            return kA2GL2Entries[i].fn;
        }
    }
    return NULL;                                    // 不归本层 ⇒ 调用方走原逻辑
}

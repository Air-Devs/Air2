// ============================================================================
//  Natives/Renderer/a2_gl2_backend_metallum.m
//  Air2 —— ★GL2 语义层的 Metal 后端（libmetallum 的 C API）★
// ----------------------------------------------------------------------------
//  目标链路（本次要打通的最后一段）：
//
//    MC → LWJGL → a2_gl2_shim.m（GL 语义层，28 个 ES3 接缝）
//                        ├─ A. 现状：gES3.* → dlsym 到 MG / ANGLE 的 GLES3
//                        └─ B. 本层：gES3.* → libmetallum.dylib → Metal
//
//  本层**只实现那 28 个接缝**，不碰语义层的翻译算法（立即模式收集、矩阵栈、图元摊平、
//  客户端数组取样全在 a2_gl2_shim.m 里，一行没动）。
//
//  ★调用点（谁调它，逐处）★
//    ① `a2_gl2_shim.m` 的 `a2gl2_resolve_es3()`：★唯一安装点★
//       开关：环境变量 `A2_GL2_BACKEND=metallum`，或未设/为空时按 `A2_GL2_METAL=1`；
//       成功 ⇒ `[A2-MTL] 后端=metallum 已安装 28/28 入口`；
//       失败 ⇒ `[A2-MTL] 回落后端=GLES（原因=…）`，随后照旧走 dlsym GLES（行为与接入前一致）。
//    ② `a2_gl2_shim.m` 的 `a2gl2_resolve_es3()` 失败分支读 `a2gl2_metallum_reason()`。
//    ★注意★：`A2_GL2_SHIM=1` 是整层的前置开关（见 a2_gl2_shim.m）；本后端只在语义层
//    启用后才可能被安装 —— 关掉 `A2_GL2_SHIM` ⇒ 本文件一行都不执行。
//
//  ★本层对 GL 的假设（★必须写清，否则后人会以为漏做★）★
//    语义层只用**一个自带的 uber-shader**（`kA2GL2VS/kA2GL2FS`，ES 3.00 文本）。
//    本层不实现 GLSL 编译器，也不读那份文本：
//      · createShader / shaderSource / compileShader / linkProgram = **记账 + 返回假句柄**；
//      · useProgram 直接启用本层内置的 MSL 管线。
//    判据行：`[A2-MTL] 使用内置 MSL uber-shader（GLSL 忽略）`（首次 shaderSource 时打一次）。
//    ⇒ 语义层若换成"每个程序真的编译"的路径，本层必须同步换掉（届时才需要 GLSL→MSL）。
//
//  ★已知接缝缺口（28 个入口之外的 GL 状态本层拿不到 ⇒ 明确不做，不假装做了）★
//    · glClear / glClearColor / glViewport / glScissor：不在接缝内 ⇒ 本层不清屏、
//      视口固定为整张颜色附件；画面可能叠影（M2 补这些入口时一起补）；
//    · glBindTexture / glTexImage2D / glGenTextures：不在接缝内 ⇒ 纹理表恒为空，
//      采样恒为 1×1 白纹理 ⇒ 片元 = 顶点色（几何/颜色能验，贴图 M2 补）；
//    · glBlendFunc / glDepthFunc / glCullFace：不在接缝内 ⇒ 分别固定为
//      SRC_ALPHA/ONE_MINUS_SRC_ALPHA、LESS+写、CULL_BACK（开/关仍随 glEnable 走）。
//
//  ★★签名风险（★未验签★：本机没有 libmetallum 的 C 头文件）★★
//    dlsym 只认符号名，不认签名。下面 §② 里每条都写了「假定签名」；参数个数/顺序若与
//    真头文件不同，表现是**首帧崩或静默不画**，不是编译错误。核对清单见文件末 §⑪。
//    缓解：① 全部调用集中在 §② 的 gApi 表（改签名只改一处）；
//          ② 初始化分阶段（设备→队列→着色器→管线→表面），每阶段一行 `[A2-MTL]` 判据，
//             崩在哪一阶段一眼可见；
//          ③ `A2_MTL_OFFSCREEN=1` 可跳过 surface/present（先验"能编码"再验"能上屏"）。
//    ★未编译、未真机验证★（本机无 ObjC/C 编译器，编译由远端 Mac 做）。
// ============================================================================

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <stdarg.h>
#import <stdint.h>
#import <time.h>

#import "a2_gl2_backend_metallum.h"
#import <Metal/Metal.h>   // ★描述符走 ObjC API★（metallum 的 Swift 导出签名无法核对）
#import "a2_log.h"
#include "a2_glfw_window.h"   // a2_glfw_window_game_view()：拿游戏宿主 UIView
#include "a2_gl_bridge.h"     // a2_gl_bridge_renderable_for_game_view()：取视图 backing layer

// ============================================================================
//  ① 常量（★不 include 任何 GL / GLES / Metal 头★）
// ----------------------------------------------------------------------------
//  GL 侧：与 a2_gl2_shim.m 同一个口径（那层也只写需要的常量）。
//  Metal 侧：值是 MTL* 枚举的 rawValue（★未验证★——本机没有 Metal 头可对）；
//            全部可用环境变量覆盖（见 §③），真机对不上时不必改代码。
// ============================================================================

// ---- GL：图元 ----
#define A2MTL_GL_POINTS             0x0000
#define A2MTL_GL_LINES              0x0001
#define A2MTL_GL_LINE_LOOP          0x0002
#define A2MTL_GL_LINE_STRIP         0x0003
#define A2MTL_GL_TRIANGLES          0x0004
#define A2MTL_GL_TRIANGLE_STRIP     0x0005
#define A2MTL_GL_TRIANGLE_FAN       0x0006

// ---- GL：缓冲目标 / 索引类型 ----
#define A2MTL_GL_ARRAY_BUFFER           0x8892
#define A2MTL_GL_ELEMENT_ARRAY_BUFFER   0x8893
#define A2MTL_GL_FLOAT                  0x1406
#define A2MTL_GL_UNSIGNED_BYTE          0x1401
#define A2MTL_GL_UNSIGNED_SHORT         0x1403
#define A2MTL_GL_UNSIGNED_INT           0x1405

// ---- GL：可转发开关（语义层只会把"ES3 里存在"的开关交下来）----
#define A2MTL_GL_BLEND                  0x0BE2
#define A2MTL_GL_DEPTH_TEST             0x0B71
#define A2MTL_GL_CULL_FACE              0x0B44
#define A2MTL_GL_SCISSOR_TEST           0x0C11
#define A2MTL_GL_POLYGON_OFFSET_FILL    0x8037
#define A2MTL_GL_STENCIL_TEST           0x0B90
#define A2MTL_GL_DITHER                 0x0BD0
#define A2MTL_GL_LINE_SMOOTH            0x0B20
#define A2MTL_GL_MULTISAMPLE            0x809D
#define A2MTL_GL_COLOR_LOGIC_OP         0x0BF2

// ---- GL：着色器对象查询 ----
#define A2MTL_GL_COMPILE_STATUS         0x8B81
#define A2MTL_GL_LINK_STATUS            0x8B82

// ---- Metal：图元类型（MTLPrimitiveType）----
#define A2MTL_PRIM_POINT                0
#define A2MTL_PRIM_LINE                 1
#define A2MTL_PRIM_LINE_STRIP           2
#define A2MTL_PRIM_TRIANGLE             3
#define A2MTL_PRIM_TRIANGLE_STRIP       4

// ---- Metal：索引类型（MTLIndexType）----
#define A2MTL_INDEX_UINT16              0
#define A2MTL_INDEX_UINT32              1

// ---- Metal：比较函数（MTLCompareFunction；与 GL 的 0x0200+ 同序 ⇒ 减 0x0200 即可）----
#define A2MTL_COMPARE_NEVER             0
#define A2MTL_COMPARE_LESS              1
#define A2MTL_COMPARE_EQUAL             2
#define A2MTL_COMPARE_LESS_EQUAL        3
#define A2MTL_COMPARE_GREATER           4
#define A2MTL_COMPARE_NOT_EQUAL         5
#define A2MTL_COMPARE_GREATER_EQUAL     6
#define A2MTL_COMPARE_ALWAYS            7

// ---- Metal：剔除 / 绕向 ----
#define A2MTL_CULL_NONE                 0
#define A2MTL_CULL_FRONT                1
#define A2MTL_CULL_BACK                 2
#define A2MTL_WINDING_CLOCKWISE         0
#define A2MTL_WINDING_COUNTER_CLOCKWISE 1

// ---- Metal：混合因子（MTLBlendFactor；只用到 4 个）----
#define A2MTL_BLEND_ZERO                0
#define A2MTL_BLEND_ONE                 1
#define A2MTL_BLEND_SRC_ALPHA           4
#define A2MTL_BLEND_ONE_MINUS_SRC_ALPHA 5

// ---- Metal：像素格式（★未验证★，可用 A2_MTL_COLOR_FORMAT / A2_MTL_DEPTH_FORMAT 覆盖）----
#define A2MTL_PIXELFORMAT_RGBA8UNORM    70
#define A2MTL_PIXELFORMAT_BGRA8UNORM    80
#define A2MTL_PIXELFORMAT_DEPTH32FLOAT  252

// ---- Metal：顶点格式（★未验证★：MTLVertexFormatFloat3=30 / Float2=29 / UChar4Normalized=9）----
#define A2MTL_VERTEXFORMAT_FLOAT2       29
#define A2MTL_VERTEXFORMAT_FLOAT3       30
#define A2MTL_VERTEXFORMAT_UCHAR4_NORM   9

// ---- Metal：纹理 usage / storage ----
#define A2MTL_TEXTURE_USAGE_SHADER_READ 1
#define A2MTL_TEXTURE_USAGE_RENDER_TARGET 4
#define A2MTL_STORAGE_MODE_SHARED       0
#define A2MTL_STORAGE_MODE_PRIVATE      2

// ---- Metal：采样器（★未验证★：MTLSamplerMinMagFilter / MTLSamplerAddressMode）----
#define A2MTL_SAMPLER_FILTER_NEAREST    0
#define A2MTL_SAMPLER_FILTER_LINEAR     1
#define A2MTL_SAMPLER_ADDRESS_CLAMP     0
#define A2MTL_SAMPLER_ADDRESS_REPEAT    2

// ---- 本层资源参数 ----
#define A2MTL_RING_ALIGN                256u          ///< Metal 对 buffer 偏移的要求（256B）
#define A2MTL_RING_DEFAULT_MB           16            ///< 单帧顶点+索引+uniform 的环形缓冲上限
#define A2MTL_TEX_MAX                   256           ///< 纹理表容量（GL 名 → MTLTexture）
#define A2MTL_ATTR_POS                  0             ///< 顶点属性槽（与 MSL 的 attribute(n) 对应）
#define A2MTL_ATTR_COLOR                1
#define A2MTL_ATTR_UV                   2
#define A2MTL_UNI_MVP                   0             ///< uniform 槽（getUniformLocation 返回值）
#define A2MTL_UNI_USETEX                1
#define A2MTL_UNI_TEXENV                2
#define A2MTL_UNI_ALPHATEST             3
#define A2MTL_UNI_ALPHAFUNC             4
#define A2MTL_UNI_ALPHAREF              5

// ============================================================================
//  ② libmetallum 的 C API 表（★唯一 dlsym 处；签名全部"假定"，见文件头★）
// ----------------------------------------------------------------------------
//  为什么用表而不是逐条 #define：① 加载/探测/调用三处共用同一份清单（不会漏一条）；
//  ② 真头文件到手后，只改本表与调用点的一行，不用满仓库搜。
//  `required` = 1 表示"缺它本层就没有意义"（探测失败 ⇒ 回落 GLES）；0 表示可缺（有则用）。
// ============================================================================
typedef struct {
    // ---- 设备 / 队列 ----
    /// 假定：`void *f(void)` ⇒ MTLDevice*（nil = 无 Metal 设备）
    void *(*create_system_default_device)(void);
    /// 假定：`void *f(void *device)` ⇒ MTLCommandQueue*
    void *(*device_make_command_queue)(void *device);
    /// 假定：`void *f(void *queue)` ⇒ MTLCommandBuffer*
    void *(*queue_make_command_buffer)(void *queue);
    /// 假定：`void *f(void *device, size_t length, unsigned options)` ⇒ MTLBuffer*
    void *(*create_buffer)(void *device, size_t length, unsigned options);
    /// 假定：`void *f(void *buffer)` ⇒ CPU 可写首地址（仅 Shared 存储模式有效）
    void *(*get_buffer_contents)(void *buffer);
    /// 假定：`void *f(void *device, int pixelFormat, int w, int h, int depth,
    ///              unsigned usage, unsigned storage, const void *bytes, size_t bytesPerRow)`
    /// ★签名已核（Swift 符号去修饰）★
    /// ★参数个数由反汇编证实★ x0=device x1=pixelFormat x2..x6=5×UInt64 x7=usage
    ///   stack1=storage stack2=bytes（wrapper 也从栈上取两个再转发）
    /// metallum_create_texture_2d(device, pixelFormat, UInt64×5, usage, storage, bytes)
    /// 旧写法少了第 4 个 UInt64 且多传了 bytesPerRow ⇒ 参数整体左移
    /// ⇒ Metal 收到 storageMode(4)/usage(0x102e00840) 并断言崩溃（真机 lastlog-179）
    void *(*create_texture_2d)(void *device, int pixelFormat,
                               uint64_t w, uint64_t h, uint64_t c, uint64_t d, uint64_t e,
                               unsigned usage, unsigned storage, const void *bytes);
    /// 假定：`void *f(void *device, const char *msl, size_t mslLen)` ⇒ MTLFunction*
    /// ★依据真机 lastlog-181 的崩溃栈★ 第三个参数不是长度——它是**字符串**（被 strlen）。
    ///   我们传 strlen(msl) 时，那个数字被当作 char* ⇒ _platform_strlen SIGSEGV。
    ///   C ABI: metallum_create_shader_function(device, msl: char*, name: char*?) -> MTLFunction?
    void *(*create_shader_function)(void *device, const char *msl, const char *entryName);
    /// 假定：`int f(void *device)` ⇒ 0=成功（metallum 自带的 clear/present 管线）
    int   (*init_pipelines)(void *device);

    // ---- 管线描述符 ----
    /// 假定：`void *f(void)` ⇒ MTLRenderPipelineDescriptor*
    void *(*rpdesc_create)(void);
    /// 假定：`int f(void *desc, int colorFormat, int depthFormat)`
    /// ★符号去修饰★ metallum_MTLRenderPipelineDescriptor_setAttachmentFormats(
    ///     desc, MTLPixelFormat, MTLPixelFormat, MTLPixelFormat) —— 三个格式：color / depth / stencil
    ///   旧签名只传两个 ⇒ stencil 取到垃圾 ⇒ Render Pipeline Descriptor 断言（真机 lastlog-183）
    int   (*rpdesc_set_attachment_formats)(void *desc, int colorFormat, int depthFormat, int stencilFormat);
    /// ★符号去修饰★ metallum_MTLRenderPipelineDescriptor_setBlendState(
    ///     desc, Int32 enabled, MTLBlendFactor src, MTLBlendFactor dst,
    ///     MTLBlendOperation opRGB, MTLBlendOperation opAlpha, MTLColorWriteMask mask)
    ///   —— 七个参数。旧签名少 opAlpha/mask 两个 ⇒ 枚举值错位 ⇒
    ///   「func is not a valid MTLBlendOperation」断言（真机 lastlog-187）
    /// ★源码已核（MetallumNative.swift:2127）★
    /// setBlendState(desc, enabled, srcRgb, dstRgb, opRgb, srcAlpha, dstAlpha, opAlpha, writeMask)
    int   (*rpdesc_set_blend_state)(void *desc, int enabled, int srcFactor, int dstFactor,
                                    int opRGB, int srcAlpha, int dstAlpha, int opAlpha,
                                    int writeMask);
    /// 假定：`int f(void *desc, void *vertexFunction, void *fragmentFunction)`
    int   (*rpdesc_set_compiled_functions)(void *desc, void *vertexFunction, void *fragmentFunction);
    /// 假定：`int f(void *desc, void *vertexDescriptor)`
    int   (*rpdesc_set_vertex_descriptor)(void *desc, void *vertexDescriptor);
    /// 假定：`void *f(void)` ⇒ MTLVertexDescriptor*
    void *(*vdesc_create)(void);
    /// 假定：`int f(void *vd, unsigned index, int format, size_t offset, unsigned bufferIndex)`
    int   (*vdesc_set_attribute)(void *vd, unsigned index, int format, size_t offset,
                                 unsigned bufferIndex);
    /// ★符号去修饰★ metallum_MTLVertexDescriptor_setLayout(vd, Int, Int, MTLVertexStepFunction, Int)
    ///   —— 五个参数（最后一个是 stepRate）。旧签名少一个 ⇒ stepRate 取到垃圾 ⇒
    ///   「stepRate must be zero if stepFunction is Constant」断言（真机 lastlog-184）
    int   (*vdesc_set_layout)(void *vd, int64_t bufferIndex, int64_t stride,
                              int stepFunction, int64_t stepRate);
    /// 假定：`void *f(void *device, void *descriptor)` ⇒ MTLRenderPipelineState*
    void *(*device_make_render_pipeline_state)(void *device, void *descriptor);
    /// 假定：`void *f(void *device, int compareFunction, int writeEnabled)` ⇒ MTLDepthStencilState*
    void *(*device_make_depth_stencil_state)(void *device, int compareFunction, int writeEnabled);

    // ---- 采样器 / 表面 ----
    /// ★符号去修饰★ metallum_create_sampler(device, MTLSamplerAddressMode, MTLSamplerAddressMode,
    ///   MTLSamplerMinMagFilter, MTLSamplerMinMagFilter, MTLSamplerMipFilter, Int32, Double)
    ///   = (device, wrapS, wrapT, minFilter, magFilter, mipFilter, maxAniso, lodMax)
    void *(*create_sampler)(void *device, int wrapS, int wrapT, int minFilter, int magFilter,
                            int mipFilter, int maxAnisotropy, double lodMax);
    /// ★符号去修饰★ metallum_create_metal_layer(device: MTLDevice, Double) ⇒ CAMetalLayer*
    void *(*create_metal_layer)(void *device, double scale);
    /// 假定：`void *f(void)` ⇒ 宿主视图上已有的 CAMetalLayer*（没有则 nil）
    /// ★源码已核（D:/CTF/mlrepo/src/main/native/MetallumNative.swift:577）★
    /// metallum_ios_get_view_metal_layer(view: UIView, device: MTLDevice, contentsScale: Double)
    void *(*ios_get_view_metal_layer)(void *view, void *device, double contentsScale);
    /// `void *f(void)` —— 找承载游戏的那个 surface view（metallum 自己的查找口径）
    void *(*ios_find_surface_view)(void);
    /// `void f(NSView *view, CAMetalLayer *layer)` —— ★把 layer 注册给 metallum★
    /// 不调它，encodePresentTextureToDrawable 就不知道往哪个 drawable 呈现（真机黑屏的成因）
    void (*set_metal_layer)(void *view, void *layer);
    /// ★符号去修饰★ metallum_configure_layer(layer, Double, Double, Int32)
    ///   = (layer, width, height, pixelFormat)
    int   (*configure_layer)(void *layer, double width, double height, int immediatePresentMode);

    // ---- 编码器 ----
    /// 假定：`void *f(void *commandBuffer, void *colorTexture, void *depthTexture)` ⇒ MTLRenderCommandEncoder*
    void *(*cb_make_render_encoder)(void *commandBuffer, void *colorTexture, void *depthTexture);
    /// 假定：均为 `int f(void *encoder, …)`，返回 0=成功
    int   (*enc_set_render_pipeline_state)(void *encoder, void *state);
    int   (*enc_set_depth_stencil_state)(void *encoder, void *state);
    /// 假定：`int f(void *encoder, void *buffer, size_t offset, unsigned index)`
    int   (*enc_set_buffer)(void *encoder, void *buffer, size_t offset, unsigned index);
    /// 假定：`int f(void *encoder, void *texture, void *sampler, unsigned index)`
    int   (*enc_set_texture_and_sampler)(void *encoder, void *texture, void *sampler,
                                         unsigned index);
    /// 假定：`int f(void *encoder, int cullMode)` / `int f(void *encoder, int winding)`
    int   (*enc_set_cull_mode)(void *encoder, int cullMode);
    int   (*enc_set_front_facing_winding)(void *encoder, int winding);
    /// 假定：`int f(void *encoder, int x, int y, int w, int h)`
    int   (*enc_set_scissor_rect)(void *encoder, int x, int y, int width, int height);
    /// 假定：`int f(void *encoder, float depthBias, float slopeScale, float clamp)`
    int   (*enc_set_depth_bias)(void *encoder, float depthBias, float slopeScale, float clamp);
    /// 假定：`int f(void *encoder, int primitiveType, unsigned vertexStart, unsigned vertexCount)`
    int   (*enc_draw_primitives)(void *encoder, int primitiveType, unsigned vertexStart,
                                 unsigned vertexCount);
    /// 假定：`int f(void *encoder, int primitiveType, unsigned indexCount, int indexType,
    ///              void *indexBuffer, size_t indexBufferOffset)`
    int   (*enc_draw_indexed_primitives)(void *encoder, int primitiveType, unsigned indexCount,
                                         int indexType, void *indexBuffer,
                                         size_t indexBufferOffset);

    // ---- 命令缓冲 ----
    /// 假定：均为 `int f(void *encoderOrBuffer, …)`，返回 0=成功
    int   (*encoder_end_encoding)(void *encoder);
    int   (*command_buffer_commit)(void *commandBuffer);
    /// 假定：`int f(void *commandBuffer, void *texture)`（把 texture 呈到 layer 的 drawable）
    /// ★源码已核（MetallumNative.swift:1674）★
    /// encodePresentTextureToDrawable(commandBuffer, layer: CAMetalLayer, sourceTexture, globalFence?)
    /// 旧签名只有 (cmdBuffer, texture) ⇒ layer 位拿到纹理对象 ⇒ Swift retain 野指针 SIGTRAP（.ips 2026-11-07）
    /// ★源码已核★ 该函数返回 **Void**（不是 int）：
    ///   原来按 int 读返回值 ⇒ 读到垃圾；且呈现失败（nextDrawable 为 nil）时
    ///   后面还无条件 waitUntilCompleted ⇒ 卡十几秒（真机反馈）。
    void  (*command_buffer_present_texture)(void *commandBuffer, void *layer,
                                            void *texture, void *globalFence);
    /// 假定：`int f(void *commandBuffer)`（阻塞到 GPU 完成）
    int   (*command_buffer_wait)(void *commandBuffer);

    // ---- 杂项 ----
    /// 假定：`void f(void *object)`（ObjC 对象 release）
    void  (*release_object)(void *object);
    /// 假定：`const char *f(void)`（最近一条错误文本；NULL = 无）
    const char *(*get_last_error)(void);
    /// 假定：`int f(char *buffer, size_t capacity)`（设备名）
    /// Swift 侧签名：metallum_copy_device_name(device: MTLDevice, buffer: UnsafeMutablePointer<CChar>?,
    ///                                     capacity: Int64) -> Int32
    int   (*copy_device_name)(void *device, char *buffer, int64_t capacity);
} A2MTLAPI;

static A2MTLAPI gApi;                    ///< ★唯一 API 表实例★（探测通过后才非空）
static void    *gLibHandle = NULL;       ///< dlopen 句柄（已加载时保持 NULL，不再 dlclose）
static int      gProbe = -1;             ///< -1=未探测 0=不可用 1=可用（★唯一缓存★）
static char     gReason[256] = "未探测";  ///< ★静态原因★（a2gl2_metallum_reason 返回它）

/// 一条符号 → API 表字段的映射（★唯一符号清单★：加载、探测、判据、自检脚本都读它）。
typedef struct {
    const char *symbol;
    size_t      offset;      ///< offsetof(A2MTLAPI, field)
    int         required;
} A2MTLSymEntry;

#define A2MTL_FIELD(f) offsetof(A2MTLAPI, f)

static const A2MTLSymEntry kA2MTLSyms[] = {
    { "metallum_create_system_default_device",            A2MTL_FIELD(create_system_default_device),    1 },
    { "metallum_MTLDevice_makeCommandQueue",              A2MTL_FIELD(device_make_command_queue),       1 },
    { "metallum_MTLCommandQueue_makeCommandBuffer",       A2MTL_FIELD(queue_make_command_buffer),       1 },
    { "metallum_create_buffer",                           A2MTL_FIELD(create_buffer),                   1 },
    { "metallum_get_buffer_contents",                     A2MTL_FIELD(get_buffer_contents),             1 },
    { "metallum_create_texture_2d",                       A2MTL_FIELD(create_texture_2d),               1 },
    { "metallum_create_shader_function",                  A2MTL_FIELD(create_shader_function),          1 },
    { "metallum_init_pipelines",                          A2MTL_FIELD(init_pipelines),                  0 },
    { "metallum_MTLRenderPipelineDescriptor_create",       A2MTL_FIELD(rpdesc_create),                   1 },
    { "metallum_MTLRenderPipelineDescriptor_setAttachmentFormats", A2MTL_FIELD(rpdesc_set_attachment_formats), 1 },
    { "metallum_MTLRenderPipelineDescriptor_setBlendState", A2MTL_FIELD(rpdesc_set_blend_state),         1 },
    { "metallum_MTLRenderPipelineDescriptor_setCompiledFunctions", A2MTL_FIELD(rpdesc_set_compiled_functions), 1 },
    { "metallum_MTLRenderPipelineDescriptor_setVertexDescriptor", A2MTL_FIELD(rpdesc_set_vertex_descriptor), 1 },
    { "metallum_MTLVertexDescriptor_create",              A2MTL_FIELD(vdesc_create),                    1 },
    { "metallum_MTLVertexDescriptor_setAttribute",        A2MTL_FIELD(vdesc_set_attribute),             1 },
    { "metallum_MTLVertexDescriptor_setLayout",           A2MTL_FIELD(vdesc_set_layout),                1 },
    { "metallum_MTLDevice_makeRenderPipelineState",       A2MTL_FIELD(device_make_render_pipeline_state), 1 },
    { "metallum_MTLDevice_makeDepthStencilState",         A2MTL_FIELD(device_make_depth_stencil_state), 1 },
    { "metallum_create_sampler",                          A2MTL_FIELD(create_sampler),                  1 },
    { "metallum_create_metal_layer",                      A2MTL_FIELD(create_metal_layer),              0 },
    { "metallum_ios_get_view_metal_layer",                A2MTL_FIELD(ios_get_view_metal_layer),        1 },
    { "metallum_ios_find_surface_view",                   A2MTL_FIELD(ios_find_surface_view),           0 },
    { "metallum_NSView_setMetalLayer",                    A2MTL_FIELD(set_metal_layer),                 1 },
    { "metallum_configure_layer",                         A2MTL_FIELD(configure_layer),                 0 },
    { "metallum_MTLCommandBuffer_makeRenderCommandEncoder", A2MTL_FIELD(cb_make_render_encoder),        1 },
    { "metallum_MTLRenderCommandEncoder_setRenderPipelineState", A2MTL_FIELD(enc_set_render_pipeline_state), 1 },
    { "metallum_MTLRenderCommandEncoder_setDepthStencilState", A2MTL_FIELD(enc_set_depth_stencil_state),  1 },
    { "metallum_MTLRenderCommandEncoder_setBuffer",       A2MTL_FIELD(enc_set_buffer),                  1 },
    { "metallum_MTLRenderCommandEncoder_setTextureAndSampler", A2MTL_FIELD(enc_set_texture_and_sampler), 1 },
    { "metallum_MTLRenderCommandEncoder_setCullMode",     A2MTL_FIELD(enc_set_cull_mode),               1 },
    { "metallum_MTLRenderCommandEncoder_setFrontFacingWinding", A2MTL_FIELD(enc_set_front_facing_winding), 0 },
    { "metallum_MTLRenderCommandEncoder_setScissorRect",  A2MTL_FIELD(enc_set_scissor_rect),            1 },
    { "metallum_MTLRenderCommandEncoder_setDepthBias",    A2MTL_FIELD(enc_set_depth_bias),              0 },
    { "metallum_MTLRenderCommandEncoder_drawPrimitives",  A2MTL_FIELD(enc_draw_primitives),             1 },
    { "metallum_MTLRenderCommandEncoder_drawIndexedPrimitives", A2MTL_FIELD(enc_draw_indexed_primitives), 1 },
    { "metallum_MTLCommandEncoder_endEncoding",           A2MTL_FIELD(encoder_end_encoding),            1 },
    { "metallum_MTLCommandBuffer_commit",                 A2MTL_FIELD(command_buffer_commit),           1 },
    { "metallum_MTLCommandBuffer_encodePresentTextureToDrawable", A2MTL_FIELD(command_buffer_present_texture), 1 },
    { "metallum_MTLCommandBuffer_waitUntilCompleted",     A2MTL_FIELD(command_buffer_wait),             0 },
    { "metallum_release_object",                          A2MTL_FIELD(release_object),                  0 },
    { "metallum_get_last_error",                          A2MTL_FIELD(get_last_error),                  0 },
    { "metallum_copy_device_name",                        A2MTL_FIELD(copy_device_name),                0 },
    { NULL, 0, 0 }
};

/// 设失败原因（★唯一写入口★：日志与 `a2gl2_metallum_reason()` 看的是同一份文本）。
static void a2mtl_reason(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gReason, sizeof(gReason), fmt, ap);
    va_end(ap);
}

/// 取一个符号（先 flat namespace，再本层 dlopen 的句柄）。
/// 先问 flat namespace 的理由：渲染器可能已被 `a2_renderer_load_named` 以 RTLD_GLOBAL 加载，
/// 那时 `dlsym(RTLD_DEFAULT, …)` 已经能命中，不必再 dlopen 一次（也就不会多一份引用计数）。
static void *a2mtl_sym(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p != NULL) return p;
    if (gLibHandle == NULL) {
        // ① @rpath（air2 的可执行文件带 -rpath @executable_path/Frameworks，见 a2_frameworks.cmake）
        gLibHandle = dlopen("@rpath/libmetallum.dylib", RTLD_NOW | RTLD_GLOBAL);   // ★RTLD_NOW★ Swift 元数据必须立即绑定
        // ② 包内绝对路径兜底（@rpath 没配上的包）
        if (gLibHandle == NULL) {
            NSString *path = [[NSBundle mainBundle] pathForResource:@"libmetallum" ofType:@"dylib"
                                                            inDirectory:@"Frameworks"];
            if (path.length > 0) gLibHandle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);   // ★RTLD_NOW★ 同上
        }
    }
    if (gLibHandle == NULL) return NULL;
    return dlsym(gLibHandle, name);
}

/// 加载全部符号（★唯一调用点：`a2gl2_metallum_available`★）。缺任一条必需符号 ⇒ 失败。
static int a2mtl_load_api(void) {
    const char *missing = NULL;
    for (int i = 0; kA2MTLSyms[i].symbol != NULL; i++) {
        void *sym = a2mtl_sym(kA2MTLSyms[i].symbol);
        void **slot = (void **)((char *)&gApi + kA2MTLSyms[i].offset);
        *slot = sym;
        if (sym == NULL && kA2MTLSyms[i].required) {
            if (missing == NULL) missing = kA2MTLSyms[i].symbol;
            a2_log_f(@"[A2-MTL] ★缺符号★ %s（必需）", kA2MTLSyms[i].symbol);
        } else if (sym == NULL) {
            a2_log_f(@"[A2-MTL] 可选符号缺失：%s（本层相应功能降级）", kA2MTLSyms[i].symbol);
        }
    }
    if (missing != NULL) {
        a2mtl_reason("libmetallum 取不到必需符号 %s（dylib 未随包 / 未导出 / 版本不匹配）", missing);
        return 0;
    }
    return 1;
}

// ============================================================================
//  ③ 环境开关（★全部"未设即默认"，默认值 = 能出画面的保守值★）
// ----------------------------------------------------------------------------
//  A2_GL2_BACKEND / A2_GL2_METAL 由 a2_gl2_shim.m 判（决定要不要装本后端），不在这里读。
//  这里只放"后端内部"的调参项 —— 真机对不上枚举/尺寸时用它现场纠，不必改代码重编。
// ============================================================================
static int a2mtl_env_int(const char *name, int fallback) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return fallback;
    char *end = NULL;
    const long n = strtol(v, &end, 10);
    if (end == v) return fallback;
    return (int)n;
}

static double a2mtl_env_double(const char *name, double fallback) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return fallback;
    char *end = NULL;
    const double n = strtod(v, &end);
    if (end == v) return fallback;
    return n;
}

/// 像素格式 / 环形缓冲大小 / 帧间隔 / 上屏开关（★各自只读一次★，首次用到时缓存）。
static int    a2mtl_color_format(void)  { static int v = -1; if (v < 0) v = a2mtl_env_int("A2_MTL_COLOR_FORMAT", A2MTL_PIXELFORMAT_BGRA8UNORM); return v; }
static int    a2mtl_depth_format(void)  { static int v = -1; if (v < 0) v = a2mtl_env_int("A2_MTL_DEPTH_FORMAT", A2MTL_PIXELFORMAT_DEPTH32FLOAT); return v; }
static int    a2mtl_ring_mb(void)       { static int v = -1; if (v < 0) { v = a2mtl_env_int("A2_MTL_RING_MB", A2MTL_RING_DEFAULT_MB); if (v < 1) v = 1; if (v > 256) v = 256; } return v; }
static double a2mtl_frame_gap_ms(void)  { static double v = -1; if (v < 0) { v = a2mtl_env_double("A2_MTL_FRAME_GAP_MS", 2.0); if (v <= 0.0) v = 2.0; } return v; }
static int    a2mtl_flip_y(void)        { static int v = -1; if (v < 0) v = a2mtl_env_int("A2_MTL_FLIP_Y", 1); return v; }
static int    a2mtl_offscreen(void)     { static int v = -1; if (v < 0) v = a2mtl_env_int("A2_MTL_OFFSCREEN", 0); return v; }
static int    a2mtl_sampler_nearest(void) { static int v = -1; if (v < 0) v = a2mtl_env_int("A2_MTL_SAMPLER", 0); return v; }

// ============================================================================
//  ④ 内置 MSL uber-shader（★本层唯一的着色器★）
// ----------------------------------------------------------------------------
//  语义层那份 ES 3.00 文本（`kA2GL2VS/kA2GL2FS`）本层不看、也不编译 —— 见文件头
//  「本层对 GL 的假设」。两边必须保持的**契约**只有三条（改任一边都要同步）：
//    ① 顶点布局：pos3f @0 / color4ub-normalized @12 / uv2f @16，stride 24（= A2GL2Vertex）；
//    ② 顶点属性槽：aPos=0 / aColor=1 / aUV=2（= getAttribLocation 的返回值）；
//    ③ uniform 语义：MVP（列主序）× pos、texture×color（MODULATE/REPLACE）、alpha test discard、
//       裁剪空间 z 从 GL 的 [-1,1] 换到 Metal 的 [0,1]；
//       另外 y 翻转由 `flipY` 开关控制（★画面上下颠倒时第一个要动的旋钮★）。
//
//  ★为什么 uniform 只喂顶点阶段★：`metallum_MTLRenderCommandEncoder_setBuffer` 是否区分
//    vertex/fragment 分段**未验签**。把全部 uniform 用 [[flat]] varying 传给片元，
//    就只需要一次 setBuffer ⇒ 不依赖那个未验签的语义。
// ============================================================================
static const char *const kA2MTLMSLCommon =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct A2Uniforms {\n"
    "    float4x4 mvp;\n"
    "    float alphaRef;\n"
    "    int useTex;\n"
    "    int texEnv;\n"
    "    int alphaTest;\n"
    "    int alphaFunc;\n"
    "    int flipY;\n"
    "    int pad0;\n"
    "    int pad1;\n"
    "};\n"
    "struct A2VertexIn {\n"
    "    float3 position [[attribute(0)]];\n"
    "    float4 color    [[attribute(1)]];\n"
    "    float2 uv       [[attribute(2)]];\n"
    "};\n"
    "struct A2VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "    float2 uv;\n"
    "    float alphaRef  [[flat]];\n"
    "    int   useTex    [[flat]];\n"
    "    int   texEnv    [[flat]];\n"
    "    int   alphaTest [[flat]];\n"
    "    int   alphaFunc [[flat]];\n"
    "};\n";

static const char *const kA2MTLMSLVertex =
    "vertex A2VertexOut a2_gl2_vertex(A2VertexIn in [[stage_in]],\n"
    "                                 constant A2Uniforms &u [[buffer(1)]]) {\n"
    "    A2VertexOut o;\n"
    "    float4 p = u.mvp * float4(in.position, 1.0);\n"
    "    float y = (u.flipY != 0) ? -p.y : p.y;\n"
    "    o.position = float4(p.x, y, p.z * 0.5 + p.w * 0.5, p.w);\n"
    "    o.color = in.color;\n"
    "    o.uv = in.uv;\n"
    "    o.alphaRef = u.alphaRef;\n"
    "    o.useTex = u.useTex;\n"
    "    o.texEnv = u.texEnv;\n"
    "    o.alphaTest = u.alphaTest;\n"
    "    o.alphaFunc = u.alphaFunc;\n"
    "    return o;\n"
    "}\n";

static const char *const kA2MTLMSLFragment =
    "fragment float4 a2_gl2_fragment(A2VertexOut in [[stage_in]],\n"
    "                                texture2d<float> tex [[texture(0)]],\n"
    "                                sampler smp [[sampler(0)]]) {\n"
    "    float4 c = in.color;\n"
    "    if (in.useTex != 0) {\n"
    "        float4 t = tex.sample(smp, in.uv);\n"
    "        c = (in.texEnv != 0) ? t : (t * c);\n"
    "    }\n"
    "    if (in.alphaTest != 0) {\n"
    "        bool ok = true;\n"
    "        if      (in.alphaFunc == 0) ok = false;\n"
    "        else if (in.alphaFunc == 1) ok = (c.a <  in.alphaRef);\n"
    "        else if (in.alphaFunc == 2) ok = (c.a == in.alphaRef);\n"
    "        else if (in.alphaFunc == 3) ok = (c.a <= in.alphaRef);\n"
    "        else if (in.alphaFunc == 4) ok = (c.a >  in.alphaRef);\n"
    "        else if (in.alphaFunc == 5) ok = (c.a != in.alphaRef);\n"
    "        else if (in.alphaFunc == 6) ok = (c.a >= in.alphaRef);\n"
    "        if (!ok) { discard_fragment(); }\n"
    "    }\n"
    "    return c;\n"
    "}\n";

/// 与 MSL 的 A2Uniforms **逐字段对齐**（★改一处必改另一处★）。
typedef struct {
    float mvp[16];       ///< 列主序（与 GL 一致；语义层算好的 projection*modelview）
    float alphaRef;
    int   useTex;
    int   texEnv;
    int   alphaTest;
    int   alphaFunc;
    int   flipY;
    int   pad0;
    int   pad1;
} A2MTLUniforms;

// ============================================================================
//  ⑤ 纹理表（GL 名 → MTLTexture）
// ----------------------------------------------------------------------------
//  ★现状（必须明说）★：28 个接缝里没有 glBindTexture / glTexImage2D，所以本层拿不到
//  「当前绑定的是哪张 GL 纹理」，也拿不到像素。表里目前只有一格：name=0 ⇒ 1×1 白纹理。
//  ⇒ 采样恒为白 ⇒ 片元 = 顶点色（几何/颜色/alpha test 能验，贴图等 M2 接缝补齐）。
//  ★表本身不是石山★：唯一写入者 `a2mtl_tex_register`（默认白纹理）+ 唯一读者
//  `a2mtl_tex_get`（每次绘制取当前纹理）。M2 的 glBindTexture 接缝会用同一个写入者，
//  届时把 `a2mtl_tex_register` 提成公开入口即可，不需要第二张表。
// ============================================================================
typedef struct {
    GLuint name;     ///< GL 纹理名（0 = 默认白纹理）
    void  *texture;  ///< MTLTexture*
    int    width, height;
} A2MTLTextureSlot;

static A2MTLTextureSlot gTexTable[A2MTL_TEX_MAX];
static int              gTexCount = 0;

/// 登记/替换一条 GL 名 → MTLTexture 映射（★唯一写入者★）。
/// 调用点：`a2mtl_ensure_resources()` 里登记 name=0 的 1×1 白纹理。
static void a2mtl_tex_register(GLuint name, void *texture, int width, int height) {
    for (int i = 0; i < gTexCount; i++) {
        if (gTexTable[i].name == name) {
            gTexTable[i].texture = texture;
            gTexTable[i].width = width;
            gTexTable[i].height = height;
            return;
        }
    }
    if (gTexCount >= A2MTL_TEX_MAX) {
        a2_log_f(@"[A2-MTL] ★纹理表已满★（%d 格）⇒ 丢弃 GL 名 %u 的映射", A2MTL_TEX_MAX, (unsigned)name);
        return;
    }
    gTexTable[gTexCount].name = name;
    gTexTable[gTexCount].texture = texture;
    gTexTable[gTexCount].width = width;
    gTexTable[gTexCount].height = height;
    gTexCount++;
}

/// 按 GL 名取纹理（★唯一读者★；调用点：每次绘制绑定 texture(0)）。查不到 ⇒ 白纹理。
static void *a2mtl_tex_get(GLuint name) {
    for (int i = 0; i < gTexCount; i++) {
        if (gTexTable[i].name == name) return gTexTable[i].texture;
    }
    for (int i = 0; i < gTexCount; i++) {
        if (gTexTable[i].name == 0) return gTexTable[i].texture;   // 兜底：白纹理
    }
    return NULL;
}

// ============================================================================
//  ⑥ 后端状态（★全部本层私有★）
// ============================================================================
typedef struct {
    // 设备 / 表面
    void   *device;
    void   *queue;
    void   *layer;
    int     width;              ///< 颜色附件的像素宽
    int     height;
    double  scale;
    void   *colorTex;
    void   *depthTex;

    // 环形缓冲（顶点 + 索引 + uniform 共用；每帧复位，不每帧分配）
    void   *ringBuffer;
    void   *ringContents;       ///< CPU 可写首地址（get_buffer_contents）
    size_t  ringSize;
    size_t  ringOffset;
    int     ringOverflowWarned;

    // 帧
    void   *cmdBuffer;
    void   *encoder;
    int     encoderOpen;
    double  lastEncodeTime;
    unsigned long long frames, draws, drawsThisFrame, dropped;

    // 待上传（glBufferData 只记账；真正拷贝推迟到绘制时 ⇒ 环形缓冲的复位点永远安全）
    const void *pendingVertex;
    size_t      pendingVertexBytes;
    const void *pendingIndex;
    size_t      pendingIndexBytes;

    // 固定资源
    void   *whiteTex;
    void   *sampler;            ///< 线性采样器（默认）
    void   *samplerNearest;     ///< 最近邻采样器（A2_MTL_SAMPLER=1 时用）
    void   *vertexDescriptor;
    void   *vsFunc, *fsFunc;
    void   *pipeBlend, *pipeOpaque;
    void   *depthStateOn, *depthStateOff;

    // GL 状态镜像（只镜像"接缝能看见的那几条"）
    int     blendOn;
    int     depthOn;
    int     cullOn;
    int     polygonOffset;
    float   depthBias, depthSlope, depthClamp;
    GLuint  boundTexName;
    int     programValid;

    // 一次性告警旗标（避免每帧刷屏）
    int     glslIgnoredLogged;
    int     attribLayoutWarned;
    int     texParamWarned;
    int     fanWarned;
    int     indexTypeWarned;
    int     stencilWarned;
    int     layerWarned;

    A2MTLUniforms uni;          ///< 当前 uniform（由 28 入口里的 uniform* 写入）
} A2MTLState;

static A2MTLState gM;

// ============================================================================
/// 前置声明（纹理登记表定义在后面的 §⑤，本块先用到）
static void a2mtl_tex_register(GLuint name, void *texture, int width, int height);

//  ★纹理接缝（M2）★ 2026-11-06 起由 GL2 语义层调用：
//    glGenTextures → a2gl2_metallum_texture_gen
//    glBindTexture → a2gl2_metallum_texture_bind
//    glTexImage2D/glTexSubImage2D → a2gl2_metallum_texture_image
//    glDeleteTextures → a2gl2_metallum_texture_delete
//  只支持 level=0 与 8 位 RGBA/BGRA（MC 1.12 的图集与 UI 贴图都是这两种）；
//  其它格式/级别记一行日志后忽略 —— 宁可不显示，也不写坏内存。
// ============================================================================
static GLuint gTexNextName = 1;      ///< 假 GL 名分配器（MC 只拿它当句柄用）

void a2gl2_metallum_texture_gen(int n, int *out) {
    if (out == NULL || n <= 0) return;
    for (int i = 0; i < n; i++) out[i] = (int)(gTexNextName++);
}

void a2gl2_metallum_texture_bind(unsigned name) {
    gM.boundTexName = (GLuint)name;
}

void a2gl2_metallum_texture_delete(unsigned name) {
    for (int i = 0; i < gTexCount; i++) {
        if (gTexTable[i].name == (GLuint)name) {
            gTexTable[i] = gTexTable[gTexCount - 1];
            gTexCount--;
            return;
        }
    }
}

/// 建/更新一张 GL 名对应的 MTLTexture 并上传像素。
/// @param format 0x1908=GL_RGBA / 0x80E1=GL_BGRA；type 需为 0x1401(GL_UNSIGNED_BYTE)
static int a2mtl_texture_slot(unsigned name, int w, int h, int format, void **outTex) {
    for (int i = 0; i < gTexCount; i++) {
        if (gTexTable[i].name == (GLuint)name) {
            *outTex = gTexTable[i].texture;
            if (gTexTable[i].width != w || gTexTable[i].height != h) return 0;  // 尺寸变了 ⇒ 重建
            return 1;
        }
    }
    *outTex = NULL;
    return 0;
}

void a2gl2_metallum_texture_image(unsigned name, int level, int w, int h,
                                  int format, int type, const void *pixels,
                                  int xoff, int yoff) {
    if (name == 0 || w <= 0 || h <= 0) return;
    if (level != 0) return;                                  // 只支持 level 0
    if (type != 0x1401 /*GL_UNSIGNED_BYTE*/) {
        static int warned = 0;
        if (!warned) { warned = 1; a2_log_f(@"[A2-MTL] 纹理：type=0x%x 不支持（只认 UNSIGNED_BYTE）⇒ 忽略", type); }
        return;
    }
    const BOOL bgra = (format == 0x80E1 /*GL_BGRA*/);
    if (format != 0x1908 /*GL_RGBA*/ && !bgra) {
        static int warned2 = 0;
        if (!warned2) { warned2 = 1; a2_log_f(@"[A2-MTL] 纹理：format=0x%x 不支持（只认 RGBA/BGRA）⇒ 忽略", format); }
        return;
    }

    void *existing = NULL;
    if (a2mtl_texture_slot(name, w, h, format, &existing) && existing != NULL) {
        if (pixels != NULL) {
            MTLRegion region = MTLRegionMake2D((NSUInteger)xoff, (NSUInteger)yoff,
                                               (NSUInteger)w, (NSUInteger)h);
            [(__bridge id<MTLTexture>)existing replaceRegion:region mipmapLevel:0
                                                 withBytes:pixels bytesPerRow:(NSUInteger)(w * 4)];
        }
        return;
    }

    id<MTLDevice> dev = (__bridge id<MTLDevice>)gM.device;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(bgra ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm)
                                                           width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    if (tex == nil) { a2_log_f(@"[A2-MTL] 纹理创建失败 %dx%d", w, h); return; }
    if (pixels != NULL) {
        [tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h) mipmapLevel:0
                 withBytes:pixels bytesPerRow:(NSUInteger)(w * 4)];
    }
    a2mtl_tex_register((GLuint)name, (__bridge_retained void *)tex, w, h);
    {
        static int logged = 0;
        if (logged < 8) { logged++; a2_log_criterion(@"[A2-MTL] 纹理建好 #%u %dx%d fmt=0x%x", name, w, h, format); }
    }
}


static GLuint     gNextObject = 0;   ///< 假句柄分配器（着色器/程序/缓冲/VAO 共用）

/// 单调时钟（秒）。用 CLOCK_MONOTONIC：不受系统时间调整影响（帧间隔判据必须稳）。
static double a2mtl_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0.0;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/// 打一行 metallum 自己的最近错误（有 `metallum_get_last_error` 时才打；不改变返回值）。
static void a2mtl_log_last_error(const char *stage) {
    if (gApi.get_last_error == NULL) return;
    const char *err = gApi.get_last_error();
    if (err != NULL && err[0] != '\0') {
        a2_log_f(@"[A2-MTL] metallum 错误（%s）：%s", stage, err);
    }
}

// ============================================================================
//  ⑦ CAMetalLayer 尺寸探测
// ----------------------------------------------------------------------------
//  为什么用 ObjC 消息而不是 metallum 的查询接口：metallum 没导出 "取 drawableSize" 的函数，
//  而 CAMetalLayer 就是个 CALayer ⇒ `bounds` / `contentsScale` 是公开且稳定的（QuartzCore 已链接）。
//  ★本文件不 include <Metal/Metal.h> 也不 include <QuartzCore/…>★：只声明本层用到的两个方法。
// ============================================================================
@interface A2MTLLayerProbe : NSObject
- (CGRect)bounds;
- (CGFloat)contentsScale;
@end

/// 取 layer 的像素尺寸（失败 ⇒ 0）。★调用点：`a2mtl_ensure_surface`★。
static void a2mtl_layer_pixel_size(void *layer, double *outWidth, double *outHeight, double *outScale) {
    double w = 0.0, h = 0.0, s = 1.0;
    if (layer != NULL) {
        A2MTLLayerProbe *probe = (__bridge A2MTLLayerProbe *)layer;
        const CGRect bounds = [probe bounds];
        const CGFloat scale = [probe contentsScale];
        s = (scale > 0.0) ? (double)scale : 1.0;
        w = (double)bounds.size.width * s;
        h = (double)bounds.size.height * s;
    }
    if (outWidth != NULL)  *outWidth = w;
    if (outHeight != NULL) *outHeight = h;
    if (outScale != NULL)  *outScale = s;
}

// ============================================================================
//  ⑧ 设备 / 资源（★懒初始化：首次真正要绘制时一次建齐★）
// ============================================================================

/// 建环形缓冲（大小 = A2_MTL_RING_MB）。失败 ⇒ 原因已设，返回 0。
static int a2mtl_create_ring(void) {
    if (gM.ringBuffer != NULL) return 1;
    const size_t bytes = (size_t)a2mtl_ring_mb() * 1024u * 1024u;
    // options：0 = MTLResourceStorageModeShared（iOS 上 CPU 可写；get_buffer_contents 才有内容）
    // ★源码已核（MetallumNative.swift）★ create_buffer(device, Int, MTLResourceOptions)
    //   options=0 ⇒ MTLResourceStorageModeShared（CPU 可写，get_buffer_contents 才有内容）
    const unsigned options = (unsigned)a2mtl_env_int("A2_MTL_BUFFER_OPTIONS", A2MTL_STORAGE_MODE_SHARED);
    gM.ringBuffer = gApi.create_buffer(gM.device, bytes, options);
    if (gM.ringBuffer == NULL) {
        a2mtl_log_last_error("create_buffer");
        a2mtl_reason("metallum_create_buffer 失败（%zu 字节，options=%u）", bytes, options);
        return 0;
    }
    gM.ringContents = gApi.get_buffer_contents(gM.ringBuffer);
    if (gM.ringContents == NULL) {
        a2mtl_reason("metallum_get_buffer_contents 返回 NULL（非 Shared 存储？）");
        return 0;
    }
    gM.ringSize = bytes;
    gM.ringOffset = 0;
    a2_log_criterion(@"[A2-MTL] 环形缓冲就绪：%zu MB（顶点+索引+uniform 共用，每帧复位）", bytes / (1024u * 1024u));
    return 1;
}

/// 建 1×1 白纹理 + 采样器（纹理接缝未接入时的兜底采样源）。失败 ⇒ 原因已设。
static int a2mtl_create_texture_defaults(void) {
    if (gM.whiteTex == NULL) {
        static const unsigned char kWhite[4] = { 255, 255, 255, 255 };
        // 建纹理走 metallum API；像素上传仍用 ObjC replaceRegion（metallum 只给 blit 路径）
        gM.whiteTex = gApi.create_texture_2d(gM.device, A2MTL_PIXELFORMAT_RGBA8UNORM,
                                             1, 1, 1, 1, 0 /*非 cube*/,
                                             A2MTL_TEXTURE_USAGE_SHADER_READ,
                                             A2MTL_STORAGE_MODE_SHARED, NULL);
        if (gM.whiteTex == NULL) {
            a2mtl_log_last_error("create_texture_2d(white)");
            a2mtl_reason("建 1×1 白纹理失败");
            return 0;
        }
        [(__bridge id<MTLTexture>)gM.whiteTex replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                                               mipmapLevel:0 withBytes:kWhite bytesPerRow:4];
        a2mtl_tex_register(0, gM.whiteTex, 1, 1);   // ★纹理表的唯一写入点★
    }
    id<MTLDevice> dev = (__bridge id<MTLDevice>)gM.device;
    if (gM.sampler == NULL) {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.mipFilter = MTLSamplerMipFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        gM.sampler = (__bridge_retained void *)[dev newSamplerStateWithDescriptor:sd];
        if (gM.sampler == NULL) { a2mtl_reason("newSamplerState（线性）失败"); return 0; }
    }
    if (gM.samplerNearest == NULL) {
        MTLSamplerDescriptor *sn = [[MTLSamplerDescriptor alloc] init];
        sn.minFilter = MTLSamplerMinMagFilterNearest;
        sn.magFilter = MTLSamplerMinMagFilterNearest;
        sn.mipFilter = MTLSamplerMipFilterNearest;
        sn.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sn.tAddressMode = MTLSamplerAddressModeClampToEdge;
        gM.samplerNearest = (__bridge_retained void *)[dev newSamplerStateWithDescriptor:sn];
        if (gM.samplerNearest == NULL) gM.samplerNearest = gM.sampler;   // 画质选项，失败不阻断
    }
    return 1;
}

/// 编译内置 MSL + 建"管线缓存"（★2 条：不透明 / alpha 混合★）。
/// ★为什么只有 2 条（而不是"混合×深度×alphaTest"的笛卡尔积）★：
///   · 深度在 Metal 里是**独立对象** MTLDepthStencilState（不参与管线键）⇒ 见下面的 depthStateOn/Off；
///   · alpha test 在本层是**片元 uniform**（discard）⇒ 不参与管线键；
///   · 混合因子不在 28 接缝里（glBlendFunc 拿不到）⇒ 固定 SRC_ALPHA/ONE_MINUS_SRC_ALPHA。
///   ⇒ 实际键只有 {BLEND 开/关}；M2+ 补 glBlendFunc/glDepthFunc 时这里扩到 4~8 条即可。
/// 失败 ⇒ 原因已设。
static int a2mtl_create_pipelines(void) {
    if (gM.pipeOpaque != NULL && gM.pipeBlend != NULL) return 1;

    if (!gM.glslIgnoredLogged) {
        gM.glslIgnoredLogged = 1;
        a2_log_criterion(@"[A2-MTL] 使用内置 MSL uber-shader（GLSL 忽略）：语义层的 ES 3.00 文本"
                         @"本后端不编译、也不读 —— 顶点布局 pos3f+color4ub+uv2f/24B 与"
                         @"属性槽 aPos=0/aColor=1/aUV=2 是两边的唯一契约");
    }

    // ★2026-11-01 决策★ 描述符不再走 metallum 的 C 导出。
    //   那些是 Swift 函数，参数排列无法从头文件核对，已连续撞 4 次 Metal 断言
    //   （texture / pipeline / blend / vertex）。这里改用 ObjC Metal API 直接建对象，
    //   建好把对象指针交给 metallum 的 encoder 使用 —— 同一批 MTL 对象，类型无关。
    id<MTLDevice> dev = (__bridge id<MTLDevice>)gM.device;
    if (dev == nil) { a2mtl_reason("MTLDevice 为空"); return 0; }

    static char vsSource[4096];
    static char fsSource[4096];
    snprintf(vsSource, sizeof(vsSource), "%s%s", kA2MTLMSLCommon, kA2MTLMSLVertex);
    snprintf(fsSource, sizeof(fsSource), "%s%s", kA2MTLMSLCommon, kA2MTLMSLFragment);

    // ★按源码回到 metallum C API★（MetallumNative.swift 2002/1982/2051/2127/2154）
    //   理由：签名有源码兜底；makeRenderPipelineState 自带 shader archive 缓存。
    if (gM.vsFunc == NULL || gM.fsFunc == NULL) {
        gM.vsFunc = gApi.create_shader_function(gM.device, vsSource, "a2_gl2_vertex");
        if (gM.vsFunc == NULL) {
            a2mtl_log_last_error("create_shader_function(vs)");
            a2mtl_reason("顶点 MSL 编译失败（内置 uber-shader）");
            return 0;
        }
        gM.fsFunc = gApi.create_shader_function(gM.device, fsSource, "a2_gl2_fragment");
        if (gM.fsFunc == NULL) {
            a2mtl_log_last_error("create_shader_function(fs)");
            a2mtl_reason("片元 MSL 编译失败（内置 uber-shader）");
            return 0;
        }
    }

    if (gM.vertexDescriptor == NULL) {
        gM.vertexDescriptor = gApi.vdesc_create();
        if (gM.vertexDescriptor == NULL) { a2mtl_reason("MTLVertexDescriptor_create 失败"); return 0; }
        gApi.vdesc_set_attribute(gM.vertexDescriptor, 0, A2MTL_VERTEXFORMAT_FLOAT3, 0, 0);
        gApi.vdesc_set_attribute(gM.vertexDescriptor, 1, A2MTL_VERTEXFORMAT_UCHAR4_NORM, 12, 0);
        gApi.vdesc_set_attribute(gM.vertexDescriptor, 2, A2MTL_VERTEXFORMAT_FLOAT2, 16, 0);
        gApi.vdesc_set_layout(gM.vertexDescriptor, 0, 24, /*PerVertex*/1, /*stepRate*/1);
    }

    for (int pass = 0; pass < 2; pass++) {
        const int blend = (pass == 1);
        void *desc = gApi.rpdesc_create();
        if (desc == NULL) { a2mtl_reason("MTLRenderPipelineDescriptor_create 失败"); return 0; }
        gApi.rpdesc_set_attachment_formats(desc, a2mtl_color_format(), a2mtl_depth_format(), 0);
        gApi.rpdesc_set_compiled_functions(desc, gM.vsFunc, gM.fsFunc);
        gApi.rpdesc_set_vertex_descriptor(desc, gM.vertexDescriptor);
        // (enabled, srcRgb, dstRgb, opRgb=Add, srcAlpha, dstAlpha, opAlpha=Add, writeMask=RGBA)
        gApi.rpdesc_set_blend_state(desc, blend ? 1 : 0,
                                    A2MTL_BLEND_SRC_ALPHA, A2MTL_BLEND_ONE_MINUS_SRC_ALPHA, 0,
                                    A2MTL_BLEND_ONE, A2MTL_BLEND_ONE_MINUS_SRC_ALPHA, 0,
                                    0xF);
        void *state = gApi.device_make_render_pipeline_state(gM.device, desc);
        if (gApi.release_object != NULL) gApi.release_object(desc);
        if (state == NULL) {
            a2mtl_log_last_error("makeRenderPipelineState");
            a2mtl_reason("makeRenderPipelineState 失败（blend=%d）", blend);
            return 0;
        }
        if (blend) gM.pipeBlend = state; else gM.pipeOpaque = state;
    }

    // 深度状态：metallum 的 C 导出（device, compareFunction, writeEnabled）
    if (gM.depthStateOn == NULL) {
        gM.depthStateOn = gApi.device_make_depth_stencil_state(gM.device, A2MTL_COMPARE_LESS_EQUAL, 1);
    }
    if (gM.depthStateOff == NULL) {
        gM.depthStateOff = gApi.device_make_depth_stencil_state(gM.device, A2MTL_COMPARE_ALWAYS, 0);
    }
    if (gM.depthStateOn == NULL || gM.depthStateOff == NULL) {
        a2mtl_log_last_error("makeDepthStencilState");
        a2mtl_reason("makeDepthStencilState 失败");
        return 0;
    }

    a2_log_criterion(@"[A2-MTL] 管线就绪：不透明 + alpha 混合（SRC_ALPHA/ONE_MINUS_SRC_ALPHA）"
                     @"；颜色格式=%d 深度格式=%d", a2mtl_color_format(), a2mtl_depth_format());
    return 1;
}

/// 拿 surface（CAMetalLayer）+ 建颜色/深度附件。★上屏只依赖 layer；建不出 layer 时
/// 仍然建附件并继续编码（离线可验），只是不上屏★。
static int a2mtl_ensure_surface(void) {
    if (gM.colorTex != NULL && gM.depthTex != NULL) return 1;

    if (gM.layer == NULL && !a2mtl_offscreen()) {
        // ★源码已核（MetallumNative.swift:577）★ 官方路径：传 view/device/contentsScale；
        //   它返回 view.layer（不 retain），并把 device/framebufferOnly 设好。
        //   之前按 0 参调用 ⇒ Swift 里拿野指针 retain ⇒ SIGSEGV（真机 lastlog-190）。
        void *surfaceView = a2_glfw_window_game_view();
        if (surfaceView != NULL && gApi.ios_get_view_metal_layer != NULL) {
            gM.layer = gApi.ios_get_view_metal_layer(surfaceView, gM.device,
                                                     (gM.scale > 0.0) ? gM.scale : 1.0);
        }
        if (gM.layer == NULL) {
            // ★对齐 1.20.1 的实证修法（d43e935 / 5d6e7df）★
            //   外挂子层不会上屏，只有「视图的 backing layer」才会被合成；且 drawableSize 必须显式设。
            //   a2_gl_bridge_renderable_for_game_view() 走的就是那条已验证路径。
            gM.layer = a2_gl_bridge_renderable_for_game_view();
            if (gM.layer != NULL) {
                a2_log_f(@"[A2-MTL] 呈现目标=游戏视图 backing layer（对齐 1.20.1 路径）layer=%p", gM.layer);
            }
        }
        if (gM.layer == NULL && gApi.create_metal_layer != NULL) {
            gM.layer = gApi.create_metal_layer(gM.device, (gM.scale > 0.0) ? gM.scale : 1.0);
            a2_log_f(@"[A2-MTL] 回退：自建 CAMetalLayer=%p（外挂层，可能不上屏）", gM.layer);
        }
        // ★源码已核（MetallumNative.swift:608）★ metallum_NSView_setMetalLayer 在 iOS 上
        //   是空实现（注释原文：layer 已经挂在 view 上），且首个参数是 MetallumView 类型。
        //   传普通 UIView 只会带来类型风险，这里不调用。
        if (gM.layer == NULL && !gM.layerWarned) {
            gM.layerWarned = 1;
            a2_log_criterion(@"[A2-MTL] ★取不到 CAMetalLayer★ ⇒ 本层只编码不上屏"
                             @"（A2_MTL_OFFSCREEN=1 时不尝试；检查宿主视图是否已建 Metal 层）");
        }
    }

    // 尺寸优先级：A2_MTL_DRAWABLE=WxH > layer 的像素尺寸 > 1280x720
    int w = 0, h = 0;
    const char *drawable = getenv("A2_MTL_DRAWABLE");
    if (drawable != NULL && drawable[0] != '\0') {
        int vw = 0, vh = 0;
        if (sscanf(drawable, "%dx%d", &vw, &vh) == 2 && vw > 0 && vh > 0) { w = vw; h = vh; }
    }
    if (w <= 0 || h <= 0) {
        double lw = 0.0, lh = 0.0, ls = 1.0;
        a2mtl_layer_pixel_size(gM.layer, &lw, &lh, &ls);
        if (lw >= 1.0 && lh >= 1.0) {
            w = (int)(lw + 0.5);
            h = (int)(lh + 0.5);
            gM.scale = ls;
        }
    }
    if (w <= 0 || h <= 0) { w = 1280; h = 720; }
    if (w > 8192) w = 8192;
    if (h > 8192) h = 8192;
    gM.width = w;
    gM.height = h;

    const unsigned usage = A2MTL_TEXTURE_USAGE_RENDER_TARGET | A2MTL_TEXTURE_USAGE_SHADER_READ;
    const unsigned storage = (unsigned)a2mtl_env_int("A2_MTL_TEXTURE_STORAGE", A2MTL_STORAGE_MODE_PRIVATE);

    gM.colorTex = gApi.create_texture_2d(gM.device, a2mtl_color_format(),
                                         (uint64_t)w, (uint64_t)h, 1, 1, 0,
                                         usage, storage, NULL);
    if (gM.colorTex == NULL) {
        a2mtl_log_last_error("create_texture_2d(color)");
        a2mtl_reason("颜色附件创建失败（%dx%d 格式=%d）", w, h, a2mtl_color_format());
        return 0;
    }
    gM.depthTex = gApi.create_texture_2d(gM.device, a2mtl_depth_format(),
                                         (uint64_t)w, (uint64_t)h, 1, 1, 0,
                                         A2MTL_TEXTURE_USAGE_RENDER_TARGET, storage, NULL);
    if (gM.depthTex == NULL) {
        a2mtl_log_last_error("create_texture_2d(depth)");
        a2mtl_reason("深度附件创建失败（%dx%d 格式=%d）", w, h, a2mtl_depth_format());
        return 0;
    }

    if (gM.layer != NULL && gApi.configure_layer != NULL) {
        // 源码：configure_layer(layer, width, height, immediatePresentMode) —— 0 = displaySync 开
        const int rc = gApi.configure_layer(gM.layer, (double)w, (double)h, 0);
        if (rc != 0) a2_log_f(@"[A2-MTL] configure_layer 返回 %d（非 0 不阻断，先继续）", rc);
    }
    a2_log_criterion(@"[A2-MTL] 表面=%@ %dx%d scale=%.2f 颜色格式=%d 深度格式=%d",
                     (gM.layer != NULL) ? @"CAMetalLayer" : @"(无 layer，离线编码)",
                     w, h, (gM.scale > 0.0) ? gM.scale : 1.0,
                     a2mtl_color_format(), a2mtl_depth_format());
    return 1;
}

/// ★设备 + 全部资源（唯一初始化入口）★。幂等；失败置原因并返回 0。
static int a2mtl_ensure_device(void) {
    if (gM.device != NULL && gM.colorTex != NULL) return 1;

    if (gM.device == NULL) {
        gM.device = gApi.create_system_default_device();
        if (gM.device == NULL) {
            a2mtl_reason("MTLCreateSystemDefaultDevice 返回 nil（本机无 Metal 设备 / 模拟器不支持）");
            return 0;
        }
        // ★2026-11-01 真机 .ips★ 这个入口是 Swift 导出
        //   metallum_copy_device_name(device: MTLDevice, buffer: UnsafeMutablePointer<CChar>?, capacity: Int64) -> Int32
        //   我们曾按 (buf, cap) 调 ⇒ 函数把 char 缓冲区当 MTLDevice 发消息 ⇒ objc_msgSend SIGSEGV。
        //   它只用于一行日志，而 C ABI 无法在拿不到头文件时验证 ⇒ 不再调用（宁可少一行设备名）。
        char name[128];
        snprintf(name, sizeof(name), "(未取名：本层不调用 metallum_copy_device_name)");
        a2_log_criterion(@"[A2-MTL] 设备=%s（后端=metallum，libmetallum 的 Metal C API）", name);

        gM.queue = gApi.device_make_command_queue(gM.device);
        if (gM.queue == NULL) {
            a2mtl_log_last_error("makeCommandQueue");
            a2mtl_reason("MTLDevice.makeCommandQueue 失败");
            return 0;
        }
        if (gApi.init_pipelines != NULL) {
            const int rc = gApi.init_pipelines(gM.device);
            if (rc != 0) a2_log_f(@"[A2-MTL] metallum_init_pipelines 返回 %d（不阻断本层的管线）", rc);
        }
    }

    if (!a2mtl_create_ring()) return 0;
    if (!a2mtl_create_texture_defaults()) return 0;
    if (!a2mtl_create_pipelines()) return 0;
    if (!a2mtl_ensure_surface()) return 0;

    gM.uni.flipY = a2mtl_flip_y() ? 1 : 0;
    for (int i = 0; i < 16; i++) gM.uni.mvp[i] = (i % 5 == 0) ? 1.0f : 0.0f;   // 单位阵（防首帧全零）
    gM.uni.alphaRef = 0.0f;
    gM.uni.useTex = 0;
    gM.uni.texEnv = 0;
    gM.uni.alphaTest = 0;
    gM.uni.alphaFunc = A2MTL_COMPARE_ALWAYS;
    return 1;
}

// ============================================================================
//  ⑨ 帧模型 + 环形缓冲
// ----------------------------------------------------------------------------
//  ★为什么是"启发式帧边界"★：28 个接缝里**没有** beginFrame/endFrame/swapBuffers
//  （呈现由 EGL 那条链负责，本后端不经过 EGL）。本层能看到的只有"一串绘制调用"。
//  做法：每次绘制前看「距上一次编码过了多久」——
//    · < A2_MTL_FRAME_GAP_MS（默认 2ms）⇒ 同一帧，继续累积；
//    · ≥ 该间隔 ⇒ 认为是新的一帧 ⇒ 先把上一帧 commit + present + 等完成。
//  代价：一帧的画面晚一个"间隔"上屏（≈1 帧延迟）；MC 若在一帧内停顿 >2ms 会多切一刀
//  （画面仍正确，只是多一次 present）。M2 接上 glClear/EGL swap 后换成显式边界。
//  ★环形缓冲的安全前提★：复位只发生在 `a2mtl_frame_end()`（此刻环里没有任何待用数据，
//  且已 waitUntilCompleted）⇒ 不会出现"绘制读到被覆盖的顶点"。
// ============================================================================

/// 从环里切一块（256B 对齐）。返回 NULL = 本帧已超预算（调用方丢这次绘制并点名一次）。
static void *a2mtl_ring_alloc(size_t bytes, size_t *outOffset) {
    if (gM.ringContents == NULL || bytes == 0) return NULL;
    const size_t aligned = (bytes + (A2MTL_RING_ALIGN - 1)) & ~(size_t)(A2MTL_RING_ALIGN - 1);
    if (gM.ringOffset + aligned > gM.ringSize) {
        if (!gM.ringOverflowWarned) {
            gM.ringOverflowWarned = 1;
            a2_log_f(@"[A2-MTL] ★环形缓冲不足★ 本帧已用 %zu/%zu 字节（A2_MTL_RING_MB=%d）"
                     @"⇒ 本次绘制丢弃；调大该开关后重试", gM.ringOffset, gM.ringSize, a2mtl_ring_mb());
        }
        return NULL;
    }
    void *p = (void *)((char *)gM.ringContents + gM.ringOffset);
    if (outOffset != NULL) *outOffset = gM.ringOffset;
    gM.ringOffset += aligned;
    return p;
}

/// 开一帧（命令缓冲 + 渲染编码器）。失败 ⇒ 告警一次并返回 0（本帧不画）。
static int a2mtl_frame_begin(void) {
    if (gM.encoderOpen) return 1;
    gM.cmdBuffer = gApi.queue_make_command_buffer(gM.queue);
    if (gM.cmdBuffer == NULL) {
        a2mtl_log_last_error("makeCommandBuffer");
        return 0;
    }
    gM.encoder = gApi.cb_make_render_encoder(gM.cmdBuffer, gM.colorTex, gM.depthTex);
    if (gM.encoder == NULL) {
        a2mtl_log_last_error("makeRenderCommandEncoder");
        if (gApi.release_object != NULL) gApi.release_object(gM.cmdBuffer);
        gM.cmdBuffer = NULL;
        return 0;
    }
    gApi.enc_set_scissor_rect(gM.encoder, 0, 0, gM.width, gM.height);
    gM.encoderOpen = 1;
    gM.drawsThisFrame = 0;
    gM.ringOffset = 0;
    return 1;
}

static void a2mtl_frame_end(void);

/// ★对外入口：立刻收帧并呈现★ 调用点：GL 桥的 a2_gl_bridge_swap_buffers。
/// 为什么必须有它：metallum 的 frame_end 原来只在「帧间隔 ≥ 阈值」时触发，
/// 连续绘制时永远不触发 ⇒ 从不 present ⇒ 黑屏（真机 lastlog-216：600 次绘制、0 次呈现）。
void a2gl2_metallum_present_now(void) { a2mtl_frame_end(); }

/// 收一帧：关编码器 → present → commit → 等 GPU 完成（环形缓冲才能安全复位）。
static void a2mtl_frame_end(void) {
    if (!gM.encoderOpen) { gM.ringOffset = 0; return; }
    if (gM.encoder != NULL) {
        gApi.encoder_end_encoding(gM.encoder);
        if (gApi.release_object != NULL) gApi.release_object(gM.encoder);
        gM.encoder = NULL;
    }
    if (gM.cmdBuffer != NULL) {
        const BOOL canPresent = (gM.layer != NULL && gM.colorTex != NULL
                                 && gApi.command_buffer_present_texture != NULL);
        if (canPresent) {
            // ★不再读返回值★ 该导出是 Void；呈现失败由 metallum 自己打 warning
            gApi.command_buffer_present_texture(gM.cmdBuffer, gM.layer, gM.colorTex, NULL);
        } else {
            static int warnedNoLayer = 0;
            if (!warnedNoLayer) { warnedNoLayer = 1; a2_log_f(@"[A2-MTL] 无法呈现：layer/colorTex 为空（只做离屏编码）"); }
        }
        gApi.command_buffer_commit(gM.cmdBuffer);
        // ★等待也限流★：只有能呈现（有 drawable）时才等；否则直接放行，
        //   避免 nextDrawable 拿不到时卡十几秒（真机反馈的「点启动后卡死再闪退」）。
        // ★不再同步等 GPU★：等待会让单次绘制飙到 1 秒（lastlog-219 #401=1007ms）。
        //   环形缓冲 16MB + 每帧复位，正常情况下 GPU 早已读完；宁可偶发撕裂，也不卡死 UI。
        static int waitWarned = 0;
        if (!waitWarned) {
            waitWarned = 1;
            a2_log_f(@"[A2-MTL] 已关闭 submit 内的 GPU 同步等待（改成 swap 驱动）");
        }
        if (gApi.release_object != NULL) gApi.release_object(gM.cmdBuffer);
        gM.cmdBuffer = NULL;
    }
    gM.encoderOpen = 0;
    gM.ringOffset = 0;
    gM.frames++;
    // ★判据★：第一帧与每 60 帧各打一行，用来判断「到底有没有真的画/提交」
    if (gM.frames == 1 || (gM.frames % 60) == 0) {
        a2_log_f(@"[A2-MTL] 帧 #%lu 已提交（draw=%lu 丢弃=%lu layer=%p tex=%p）",
                 (unsigned long)gM.frames, (unsigned long)gM.draws, (unsigned long)gM.dropped,
                 gM.layer, gM.colorTex);
    }
}

/// 帧边界判据（★唯一调用点：每次绘制开头★）。
static void a2mtl_submit_impl(GLenum mode, GLint first, GLsizei count, int indexed, GLenum indexType);

/// ★每绘制耗时判据★ 2026-11-07：真机首帧 600 次绘制用了 30 秒（~40ms/次）。
/// 这里只做分段计时（不改逻辑）：前 10 次 + 任何 >=15ms 的都打出来，直接指出瓶颈。
static void a2mtl_submit(GLenum mode, GLint first, GLsizei count, int indexed, GLenum indexType) {
    static unsigned long n = 0;
    const double t0 = CFAbsoluteTimeGetCurrent();
    a2mtl_submit_impl(mode, first, count, indexed, indexType);
    const double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    n++;
    if (n <= 10 || (ms >= 15.0 && n < 3000)) {
        a2_log_f(@"[A2-MTL-TIME] 绘制 #%lu 用时 %.1f ms（mode=0x%x count=%d indexed=%d）",
                 n, ms, (unsigned)mode, (int)count, indexed);
    }
}

static void a2mtl_frame_maybe_end(void) {
    if (!gM.encoderOpen) return;
    const double gapMs = (a2mtl_now() - gM.lastEncodeTime) * 1000.0;
    // ★2026-11-07 真机 lastlog-219★ 原逻辑：绘制间隙超过阈值就收帧（present + 等 GPU）。
    //   实测出现单次 1007ms 的绘制 ⇒ 一帧被切成多段、每次都等 GPU。
    //   现在改为**只在 swap 时收帧**（a2gl2_metallum_present_now），中途不再打断。
    (void)gapMs;
}

// ============================================================================
//  ⑩ 绘制编码（★唯一的绘制出口★）
// ----------------------------------------------------------------------------
//  调用点：28 入口里的 `a2mtl_glDrawArrays` / `a2mtl_glDrawElements`（两处）。
//  流程：帧边界判据 → 一次从环里切出 [顶点][索引][uniform] → 设状态 → 一次 draw。
// ============================================================================

/// GL 图元 → Metal 图元类型。返回 -1 = 本层不支持（调用方点名并跳过）。
static int a2mtl_primitive_type(GLenum mode) {
    switch (mode) {
        case A2MTL_GL_POINTS:         return A2MTL_PRIM_POINT;
        case A2MTL_GL_LINES:          return A2MTL_PRIM_LINE;
        case A2MTL_GL_LINE_LOOP:      return A2MTL_PRIM_LINE_STRIP;    // Metal 无 LOOP：中间补首点的索引（见下）
        case A2MTL_GL_LINE_STRIP:     return A2MTL_PRIM_LINE_STRIP;
        case A2MTL_GL_TRIANGLES:      return A2MTL_PRIM_TRIANGLE;
        case A2MTL_GL_TRIANGLE_STRIP: return A2MTL_PRIM_TRIANGLE_STRIP;
        case A2MTL_GL_TRIANGLE_FAN:   return A2MTL_PRIM_TRIANGLE;      // Metal 无 FAN：摊成三角形（见下）
        default:                      return -1;
    }
}

/// 当前该用的采样器（A2_MTL_SAMPLER=1 ⇒ 最近邻）。
static void *a2mtl_current_sampler(void) {
    if (a2mtl_sampler_nearest() && gM.samplerNearest != NULL) return gM.samplerNearest;
    return gM.sampler;
}

/// 当前纹理（GL 名 0 ⇒ 白纹理；见 §⑤ 的现状说明）。
static void *a2mtl_current_texture(void) {
    void *tex = a2mtl_tex_get(gM.boundTexName);
    if (tex == NULL) tex = gM.whiteTex;
    return tex;
}

/// ★提交一次绘制★。
/// @param mode      GL 图元
/// @param first     起始顶点（非索引路径）
/// @param count     顶点数（非索引）或索引个数（索引路径）
/// @param indexed   1 = 用 `gM.pendingIndex` 里的索引
/// @param indexType GL 索引类型（UNSIGNED_BYTE/SHORT/INT）
typedef struct {
    GLenum mode;
    GLint  first;
    GLsizei count;
    int    indexed;
    GLenum indexType;
    GLuint tex;
    void  *verts;  size_t vBytes;
    void  *idx;    size_t iBytes;
} A2DLRec;

typedef struct {
    GLuint    id;
    A2DLRec  *recs;
    int       count;
    int       cap;
} A2DLList;

#define A2DL_MAX_LISTS   512
#define A2DL_MAX_RECS    65536

static A2DLList gDL[A2DL_MAX_LISTS];
static int      gDLCount = 0;
static A2DLList *gDLRec = NULL;
static int      gDLExec = 1;

static A2DLList *a2dl_find(GLuint id) {
    for (int i = 0; i < gDLCount; i++) if (gDL[i].id == id) return &gDL[i];
    return NULL;
}

static void a2dl_clear(A2DLList *l) {
    for (int i = 0; i < l->count; i++) { free(l->recs[i].verts); free(l->recs[i].idx); }
    free(l->recs);
    l->recs = NULL; l->count = 0; l->cap = 0;
}

static void a2dl_record(GLenum mode, GLint first, GLsizei count, int indexed,
                        GLenum indexType, const void *v, size_t vBytes,
                        const void *idx, size_t iBytes, GLuint tex) {
    A2DLList *l = gDLRec;
    if (l == NULL || v == NULL || vBytes == 0) return;
    // ★单条上限 8MB★：区块级列表的顶点数据非常大，整份复制会把原生内存吃光
    // （真机 lastlog-208 的 OOM 就是这一类）。超限只记一次日志，不复制。
    if (vBytes > (8u << 20)) {
        static int warnedBig = 0;
        if (!warnedBig) { warnedBig = 1; a2_log_f(@"[A2-GL2] 显示列表单条过大（%zu 字节）⇒ 跳过录制", vBytes); }
        return;
    }
    if (l->count >= A2DL_MAX_RECS) return;
    if (l->count == l->cap) {
        int ncap = (l->cap == 0) ? 16 : l->cap * 2;
        A2DLRec *nr = realloc(l->recs, (size_t)ncap * sizeof(A2DLRec));
        if (nr == NULL) return;
        l->recs = nr; l->cap = ncap;
    }
    A2DLRec *r = &l->recs[l->count];
    r->mode = mode; r->first = first; r->count = count;
    r->indexed = indexed; r->indexType = indexType; r->tex = tex;
    r->verts = malloc(vBytes);
    if (r->verts == NULL) return;
    memcpy(r->verts, v, vBytes);
    r->vBytes = vBytes;
    r->idx = NULL; r->iBytes = 0;
    if (indexed && idx != NULL && iBytes > 0) {
        r->idx = malloc(iBytes);
        if (r->idx != NULL) { memcpy(r->idx, idx, iBytes); r->iBytes = iBytes; }
    }
    l->count++;
}


static void a2mtl_submit_impl(GLenum mode, GLint first, GLsizei count, int indexed, GLenum indexType) {
    if (count <= 0) return;

    // ★先取走待上传数据并清空记账★：无论本次是否真的画出去，都不让下一批误用上一批的指针。
    const void *vSrc = gM.pendingVertex;
    const size_t vBytes = gM.pendingVertexBytes;
    const void *iSrc = gM.pendingIndex;
    const size_t iSrcBytes = gM.pendingIndexBytes;
    gM.pendingVertex = NULL;
    gM.pendingVertexBytes = 0;
    gM.pendingIndex = NULL;
    gM.pendingIndexBytes = 0;
    // ★显示列表录制★ 见文件末尾 a2gl2_metallum_list_* 的实现。
    //   COMPILE 模式只录不画；COMPILE_AND_EXECUTE 录完继续走正常绘制。
    if (gDLRec != NULL && vBytes > 0 && vSrc != NULL) {
        a2dl_record(mode, first, count, indexed, indexType, vSrc, vBytes,
                    iSrc, iSrcBytes, gM.boundTexName);
        if (!gDLExec) return;
    }

    if (vBytes == 0 || vSrc == NULL) {
        gM.dropped++;
        static unsigned long dropNoVertex = 0;
        dropNoVertex++;
        if (dropNoVertex == 1 || (dropNoVertex % 300) == 0) {
            a2_log_criterion(@"[A2-MTL] 丢弃=无顶点数据 累计 %lu（绘制成功 %lu）",
                             dropNoVertex, (unsigned long)gM.draws);
        }
        return;                                                        // 没有顶点数据 ⇒ 不画
    }
    if (indexed && (iSrcBytes == 0 || iSrc == NULL)) { gM.dropped++; return; }

    a2mtl_frame_maybe_end();              // 帧边界判据（可能顺带 present 上一帧）
    if (!gM.encoderOpen && !a2mtl_frame_begin()) { gM.dropped++; return; }

    const int prim = a2mtl_primitive_type(mode);
    if (prim < 0) {
        if (!gM.fanWarned) {
            gM.fanWarned = 1;
            a2_log_f(@"[A2-MTL] ★未支持图元★ mode=0x%x（Metal 无该图元，本层不猜）⇒ 本批丢弃",
                     (unsigned)mode);
        }
        gM.dropped++;
        return;
    }

    // ---- ① 一次切出：顶点 + （可选）索引 + uniform ----
    // ★带索引的 FAN/LOOP 不支持★：它们的索引表要按 GL 语义重排（上面那两条只处理
    // "非索引 + 由本层生成索引"的情形）。语义层不会这么调（它自己先摊平），故点名丢弃。
    if (indexed && (mode == A2MTL_GL_TRIANGLE_FAN || mode == A2MTL_GL_LINE_LOOP)) {
        if (!gM.fanWarned) {
            gM.fanWarned = 1;
            a2_log_f(@"[A2-MTL] ★带索引的 FAN/LOOP 未支持★ mode=0x%x（本层只重排非索引的）⇒ 本批丢弃",
                     (unsigned)mode);
        }
        gM.dropped++;
        return;
    }
    const int needFanIndices = (!indexed && mode == A2MTL_GL_TRIANGLE_FAN && count >= 3);
    const int needLoopIndices = (!indexed && mode == A2MTL_GL_LINE_LOOP && count >= 2);
    const size_t iBytes = indexed ? iSrcBytes
                                 : (needFanIndices ? (size_t)(count - 2) * 3u * sizeof(uint32_t)
                                                   : (needLoopIndices ? (size_t)(count + 1u) * sizeof(uint32_t) : 0u));

    size_t vOff = 0, iOff = 0, uOff = 0;
    void *vDst = a2mtl_ring_alloc(vBytes, &vOff);
    void *iDst = (iBytes > 0) ? a2mtl_ring_alloc(iBytes, &iOff) : NULL;
    void *uDst = a2mtl_ring_alloc(sizeof(A2MTLUniforms), &uOff);
    if (vDst == NULL || (iBytes > 0 && iDst == NULL) || uDst == NULL) { gM.dropped++; return; }

    memcpy(vDst, vSrc, vBytes);
    memcpy(uDst, &gM.uni, sizeof(A2MTLUniforms));

    int finalIndexed = indexed;
    int metalIndexType = A2MTL_INDEX_UINT32;

    if (indexed) {
        // ★索引宽度★：Metal 只有 UINT16/UINT32（没有 UBYTE）⇒ 只直传 SHORT/INT，UBYTE 点名跳过。
        // 语义层的带索引路径只用 UNSIGNED_INT（QUADS 摊三角，见 a2gl2_draw）。
        if (indexType == A2MTL_GL_UNSIGNED_INT) {
            metalIndexType = A2MTL_INDEX_UINT32;
        } else if (indexType == A2MTL_GL_UNSIGNED_SHORT) {
            metalIndexType = A2MTL_INDEX_UINT16;
        } else {
            if (!gM.indexTypeWarned) {
                gM.indexTypeWarned = 1;
                a2_log_f(@"[A2-MTL] ★索引类型未支持★ type=0x%x（只支持 UNSIGNED_SHORT/INT）⇒ 本批丢弃",
                         (unsigned)indexType);
            }
            gM.dropped++;
            return;
        }
        memcpy(iDst, iSrc, iBytes);
    } else if (needFanIndices) {
        // FAN → 三角形：索引 {0,i,i+1}
        uint32_t *idx = (uint32_t *)iDst;
        size_t k = 0;
        for (GLsizei i = 1; i + 1 < count; i++) {
            idx[k++] = 0u;
            idx[k++] = (uint32_t)i;
            idx[k++] = (uint32_t)(i + 1);
        }
        finalIndexed = 1;
        metalIndexType = A2MTL_INDEX_UINT32;
    } else if (needLoopIndices) {
        // LINE_LOOP → LINE_STRIP 的索引 0..count-1 + 0
        uint32_t *idx = (uint32_t *)iDst;
        for (GLsizei i = 0; i < count; i++) idx[i] = (uint32_t)i;
        idx[count] = 0u;
        finalIndexed = 1;
        metalIndexType = A2MTL_INDEX_UINT32;
    }

    // ---- ② 状态（★去重★：值没变就不调 Metal）----
    // 真机 600+ 次绘制/帧，其中绝大多数状态是重复的；Metal 每次调用都有开销。
    static void *lastPipeline = NULL;
    static void *lastDepthState = NULL;
    static int   lastCull = -1;
    static int   lastBiasOn = -1;

    void *pipeline = gM.blendOn ? gM.pipeBlend : gM.pipeOpaque;
    if (pipeline == NULL) pipeline = gM.pipeOpaque;
    if (pipeline != lastPipeline) {
        gApi.enc_set_render_pipeline_state(gM.encoder, pipeline);
        lastPipeline = pipeline;
    }
    void *depthState = gM.depthOn ? gM.depthStateOn : gM.depthStateOff;
    if (depthState != lastDepthState) {
        gApi.enc_set_depth_stencil_state(gM.encoder, depthState);
        lastDepthState = depthState;
    }
    const int cull = gM.cullOn ? A2MTL_CULL_BACK : A2MTL_CULL_NONE;
    if (cull != lastCull) {
        gApi.enc_set_cull_mode(gM.encoder, cull);
        if (gApi.enc_set_front_facing_winding != NULL) {
            gApi.enc_set_front_facing_winding(gM.encoder, A2MTL_WINDING_COUNTER_CLOCKWISE);
        }
        lastCull = cull;
    }
    const int biasOn = gM.polygonOffset ? 1 : 0;
    if (gApi.enc_set_depth_bias != NULL && biasOn != lastBiasOn) {
        if (biasOn) gApi.enc_set_depth_bias(gM.encoder, gM.depthBias, gM.depthSlope, gM.depthClamp);
        else        gApi.enc_set_depth_bias(gM.encoder, 0.0f, 0.0f, 0.0f);
        lastBiasOn = biasOn;
    }

    // ---- ③ 绑定 + 绘制 ----
    gApi.enc_set_buffer(gM.encoder, gM.ringBuffer, vOff, 0);                                  // 顶点流
    gApi.enc_set_buffer(gM.encoder, gM.ringBuffer, uOff, 1);                                  // uniform
    if (gApi.enc_set_texture_and_sampler != NULL) {
        gApi.enc_set_texture_and_sampler(gM.encoder, a2mtl_current_texture(),
                                         a2mtl_current_sampler(), 0);
    }
    if (finalIndexed) {
        const unsigned indexCount = needFanIndices
            ? (unsigned)((count - 2) * 3)
            : (needLoopIndices ? (unsigned)(count + 1) : (unsigned)count);
        gApi.enc_draw_indexed_primitives(gM.encoder, prim, indexCount, metalIndexType,
                                         gM.ringBuffer, iOff);
    } else {
        gApi.enc_draw_primitives(gM.encoder, prim, (unsigned)first, (unsigned)count);
    }

    // ---- ④ 记账（待上传数据已在入口处清空）----
    gM.draws++;
    gM.drawsThisFrame++;
    gM.lastEncodeTime = a2mtl_now();
    if (gM.draws <= 3 || (gM.draws % 600) == 0) {
        a2_log_f(@"[A2-MTL] 绘制 #%llu：mode=0x%x prim=%d 顶点=%d 索引=%d 帧内=%llu 环=%zu/%zu",
                 gM.draws, (unsigned)mode, prim, (int)count, finalIndexed ? 1 : 0,
                 gM.drawsThisFrame, gM.ringOffset, gM.ringSize);
    }
}

// ============================================================================
//  ⑪ 28 个接缝入口（★顺序与 A2GL2ES3 字段一一对应★）
// ----------------------------------------------------------------------------
//  每条都注明「语义层怎么用它」——这是本层唯一需要满足的契约；其余 GL 语义不归本层。
// ============================================================================

// ---- 缓冲 / VAO（本层只有一个环形缓冲，GL 名仅作记账，句柄非 0 即可）----
static void a2mtl_glGenBuffers(GLsizei n, GLuint *buffers) {
    if (buffers == NULL || n <= 0) return;
    for (GLsizei i = 0; i < n; i++) buffers[i] = ++gNextObject;
}

static void a2mtl_glBindBuffer(GLenum target, GLuint buffer) {
    (void)buffer;   // 本层不按 GL 名分离缓冲（语义层每帧流式上传，见 §⑨）
    (void)target;
}

static void a2mtl_glBufferData(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
    (void)usage;
    if (size <= 0) return;
    // ★只记账、不拷贝★：真正拷贝推迟到绘制时（那时才切环形缓冲），
    // 这样"帧边界的环形缓冲复位"永远发生在没有待用数据的时候（见 §⑨ 的安全前提）。
    // ★假设★：`data` 在紧随其后的绘制调用时仍然有效 —— 本层的唯一调用方
    // （a2gl2_shim.m 的 a2gl2_draw）传的是它的静态 `gVerts/gIndex`。
    if (target == A2MTL_GL_ELEMENT_ARRAY_BUFFER) {
        gM.pendingIndex = data;
        gM.pendingIndexBytes = (size_t)size;
    } else {
        gM.pendingVertex = data;
        gM.pendingVertexBytes = (size_t)size;
    }
}

static void a2mtl_glGenVertexArrays(GLsizei n, GLuint *arrays) {
    if (arrays == NULL || n <= 0) return;
    for (GLsizei i = 0; i < n; i++) arrays[i] = ++gNextObject;
}

static void a2mtl_glBindVertexArray(GLuint array) {
    (void)array;   // 顶点布局由顶点描述符固定（§⑧），VAO 无语义
}

static void a2mtl_glVertexAttribPointer(GLuint index, GLint size, GLenum type,
                                        GLboolean normalized, GLsizei stride, const void *pointer) {
    // ★校验而不是记录★：本层的顶点描述符是写死的（pos3f/color4ubNorm/uv2f, stride 24）。
    // 语义层若改了顶点格式，这里点名一次 —— 否则现象是"画面全黑但没有任何报错"。
    const int ok = (stride == 24) &&
                   ((index == A2MTL_ATTR_POS   && size == 3 && type == A2MTL_GL_FLOAT) ||
                    (index == A2MTL_ATTR_COLOR && size == 4 && type == A2MTL_GL_UNSIGNED_BYTE && normalized) ||
                    (index == A2MTL_ATTR_UV    && size == 2 && type == A2MTL_GL_FLOAT));
    if (!ok && !gM.attribLayoutWarned) {
        gM.attribLayoutWarned = 1;
        a2_log_f(@"[A2-MTL] ★顶点布局不符★ idx=%u size=%d type=0x%x norm=%d stride=%d ptr=%p"
                 @"（本层固定 pos3f@0/color4ubNorm@12/uv2f@16, stride 24）⇒ 该属性被忽略",
                 (unsigned)index, (int)size, (unsigned)type, (int)normalized, (int)stride, pointer);
    }
}

static void a2mtl_glEnableVertexAttribArray(GLuint index) { (void)index; }

// ---- 绘制（★两条入口都落到 a2mtl_submit★）----
static void a2mtl_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    a2mtl_submit(mode, first, count, 0, A2MTL_GL_UNSIGNED_INT);
}

static void a2mtl_glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices) {
    (void)indices;   // 索引内容已由 bufferData(ELEMENT_ARRAY) 记账
    a2mtl_submit(mode, 0, count, 1, type);
}

// ---- 着色器对象：记账 + 假句柄（★本层不编译 GLSL，见文件头★）----
static GLuint a2mtl_glCreateShader(GLenum type) {
    (void)type;
    return ++gNextObject;
}

static void a2mtl_glShaderSource(GLuint shader, GLsizei count, const GLchar *const *string,
                                 const GLint *length) {
    (void)shader;
    if (!gM.glslIgnoredLogged) {
        gM.glslIgnoredLogged = 1;
        // ★判据行（任务要求的一行）★：GLSL 到了本层，但本层只用自己的 MSL
        a2_log_criterion(@"[A2-MTL] 使用内置 MSL uber-shader（GLSL 忽略）");
        GLsizei total = 0;
        for (GLsizei i = 0; i < count; i++) {
            if (string == NULL || string[i] == NULL) continue;
            total += (length != NULL && length[i] > 0) ? length[i]
                                                      : (GLsizei)strlen(string[i]);
        }
        a2_log_f(@"[A2-MTL] 语义层送来的 GLSL 共 %d 字节：不编译、不执行（等效于 useProgram 直接启用内置管线）",
                 (int)total);
    }
}

static void a2mtl_glCompileShader(GLuint shader) { (void)shader; }

static void a2mtl_glGetShaderiv(GLuint shader, GLenum pname, GLint *params) {
    (void)shader;
    if (params == NULL) return;
    *params = (pname == A2MTL_GL_COMPILE_STATUS) ? 1 : 0;   // ★必须报成功★：语义层据此判整层可用
}

static void a2mtl_glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog) {
    (void)shader;
    if (length != NULL) *length = 0;
    if (infoLog != NULL && bufSize > 0) infoLog[0] = '\0';
}

static GLuint a2mtl_glCreateProgram(void) { return ++gNextObject; }

static void a2mtl_glAttachShader(GLuint program, GLuint shader) { (void)program; (void)shader; }

static void a2mtl_glLinkProgram(GLuint program) { (void)program; }

static void a2mtl_glGetProgramiv(GLuint program, GLenum pname, GLint *params) {
    (void)program;
    if (params == NULL) return;
    *params = (pname == A2MTL_GL_LINK_STATUS) ? 1 : 0;
}

static void a2mtl_glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei *length, GLchar *infoLog) {
    (void)program;
    if (length != NULL) *length = 0;
    if (infoLog != NULL && bufSize > 0) infoLog[0] = '\0';
}

static void a2mtl_glUseProgram(GLuint program) {
    // 无论 program 是几，本层都启用内置管线（语义层只用一个 uber-shader）。
    gM.programValid = 1;
    if (program == 0) {
        static int warned = 0;
        if (!warned) {
            warned = 1;
            a2_log_f(@"[A2-MTL] useProgram(0)：本层仍用内置管线（本层没有「固定管线程序」这回事）");
        }
    }
}

static GLint a2mtl_glGetAttribLocation(GLuint program, const GLchar *name) {
    (void)program;
    if (name == NULL) return -1;
    if (strcmp(name, "aPos") == 0)   return A2MTL_ATTR_POS;
    if (strcmp(name, "aColor") == 0) return A2MTL_ATTR_COLOR;
    if (strcmp(name, "aUV") == 0)    return A2MTL_ATTR_UV;
    return -1;
}

static GLint a2mtl_glGetUniformLocation(GLuint program, const GLchar *name) {
    (void)program;
    if (name == NULL) return -1;
    if (strcmp(name, "uMVP") == 0)       return A2MTL_UNI_MVP;
    if (strcmp(name, "uUseTex") == 0)    return A2MTL_UNI_USETEX;
    if (strcmp(name, "uTexEnv") == 0)    return A2MTL_UNI_TEXENV;
    if (strcmp(name, "uAlphaTest") == 0) return A2MTL_UNI_ALPHATEST;
    if (strcmp(name, "uAlphaFunc") == 0) return A2MTL_UNI_ALPHAFUNC;
    if (strcmp(name, "uAlphaRef") == 0)  return A2MTL_UNI_ALPHAREF;
    return -1;
}

static void a2mtl_glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose,
                                     const GLfloat *value) {
    (void)location;
    if (value == NULL || count <= 0) return;
    if (!transpose) {
        memcpy(gM.uni.mvp, value, sizeof(gM.uni.mvp));
    } else {
        // 语义层传的永远是 GL_FALSE；这里仍按 GL 语义处理，免得将来换调用方时静默出错
        for (int c = 0; c < 4; c++) {
            for (int r = 0; r < 4; r++) gM.uni.mvp[c * 4 + r] = value[r * 4 + c];
        }
    }
}

static void a2mtl_glUniform1i(GLint location, GLint value) {
    switch (location) {
        case A2MTL_UNI_USETEX:    gM.uni.useTex = value; break;
        case A2MTL_UNI_TEXENV:    gM.uni.texEnv = value; break;
        case A2MTL_UNI_ALPHATEST: gM.uni.alphaTest = value; break;
        case A2MTL_UNI_ALPHAFUNC: gM.uni.alphaFunc = value; break;
        default: break;   // 未知槽：忽略（语义层的 6 个槽都已覆盖）
    }
}

static void a2mtl_glUniform1f(GLint location, GLfloat value) {
    if (location == A2MTL_UNI_ALPHAREF) gM.uni.alphaRef = value;
}

// ---- 开关（只映射接缝能看见的几条；其余记账后忽略）----
static void a2mtl_glEnable(GLenum cap) {
    switch (cap) {
        case A2MTL_GL_BLEND:               gM.blendOn = 1; return;
        case A2MTL_GL_DEPTH_TEST:          gM.depthOn = 1; return;
        case A2MTL_GL_CULL_FACE:           gM.cullOn = 1; return;
        case A2MTL_GL_POLYGON_OFFSET_FILL: gM.polygonOffset = 1; return;
        case A2MTL_GL_SCISSOR_TEST:
        case A2MTL_GL_DITHER:
        case A2MTL_GL_LINE_SMOOTH:
        case A2MTL_GL_MULTISAMPLE:
        case A2MTL_GL_COLOR_LOGIC_OP:
            return;   // 本层固定行为（全屏裁剪 / 无抖动开关 / 无逻辑运算）
        case A2MTL_GL_STENCIL_TEST:
            if (!gM.stencilWarned) {
                gM.stencilWarned = 1;
                a2_log_f(@"[A2-MTL] ★模板测试未实现★（本层不带 stencil 附件）⇒ glEnable(GL_STENCIL_TEST) 被忽略");
            }
            return;
        default:
            return;
    }
}

static void a2mtl_glDisable(GLenum cap) {
    switch (cap) {
        case A2MTL_GL_BLEND:               gM.blendOn = 0; return;
        case A2MTL_GL_DEPTH_TEST:          gM.depthOn = 0; return;
        case A2MTL_GL_CULL_FACE:           gM.cullOn = 0; return;
        case A2MTL_GL_POLYGON_OFFSET_FILL: gM.polygonOffset = 0; return;
        default:                           return;
    }
}

// ---- 纹理参数（记账；本层采样器固定）----
static void a2mtl_glTexParameteri(GLenum target, GLenum pname, GLint param) {
    (void)target; (void)pname; (void)param;
    if (!gM.texParamWarned) {
        gM.texParamWarned = 1;
        // ★注意★：a2_log_f 走 vsnprintf ⇒ 只能给 %s + C 字符串（不是 %@）
        a2_log_criterion(@"[A2-MTL] glTexParameteri 只记账不生效：采样器在设备初始化时固定为 %s + CLAMP_TO_EDGE"
                         @"（纹理绑定/上传接缝 M2 补）",
                         a2mtl_sampler_nearest() ? "NEAREST" : "LINEAR");
    }
}

// ============================================================================
//  ⑫ 对外三个函数（见 a2_gl2_backend_metallum.h）
// ============================================================================

int a2gl2_metallum_available(void) {
    if (gProbe >= 0) return gProbe;
    gProbe = 0;

    if (!a2mtl_load_api()) return 0;          // 原因已在 load_api 里设
    if (!a2mtl_ensure_device()) return 0;     // 原因已在 ensure_device 里设

    gProbe = 1;
    a2mtl_reason("（无）");
    int total = 0, required = 0;
    for (int i = 0; kA2MTLSyms[i].symbol != NULL; i++) {
        total++;
        if (kA2MTLSyms[i].required) required++;
    }
    a2_log_criterion(@"[A2-MTL] libmetallum 可用：%d 条符号（必需 %d 条全部命中）+ Metal 设备 + 管线就绪",
                     total, required);
    return 1;
}

int a2gl2_metallum_install(A2GL2ES3 *out) {
    if (out == NULL) {
        a2mtl_reason("install 收到 out=NULL");
        return 0;
    }
    if (!a2gl2_metallum_available()) return 0;   // 失败原因已在 reason 里（调用方直接打）

    // ★28 条逐条赋值★（不循环：字段改名/删字段时编译器会当场报错，而不是静默漏装）
    out->genBuffers              = a2mtl_glGenBuffers;
    out->bindBuffer             = a2mtl_glBindBuffer;
    out->bufferData             = a2mtl_glBufferData;
    out->genVertexArrays        = a2mtl_glGenVertexArrays;
    out->bindVertexArray        = a2mtl_glBindVertexArray;
    out->vertexAttribPointer    = a2mtl_glVertexAttribPointer;
    out->enableVertexAttribArray = a2mtl_glEnableVertexAttribArray;
    out->drawArrays             = a2mtl_glDrawArrays;
    out->drawElements           = a2mtl_glDrawElements;
    out->createShader           = a2mtl_glCreateShader;
    out->shaderSource           = a2mtl_glShaderSource;
    out->compileShader          = a2mtl_glCompileShader;
    out->getShaderiv            = a2mtl_glGetShaderiv;
    out->getShaderInfoLog       = a2mtl_glGetShaderInfoLog;
    out->createProgram          = a2mtl_glCreateProgram;
    out->attachShader           = a2mtl_glAttachShader;
    out->linkProgram            = a2mtl_glLinkProgram;
    out->getProgramiv           = a2mtl_glGetProgramiv;
    out->getProgramInfoLog      = a2mtl_glGetProgramInfoLog;
    out->useProgram             = a2mtl_glUseProgram;
    out->getAttribLocation      = a2mtl_glGetAttribLocation;
    out->getUniformLocation     = a2mtl_glGetUniformLocation;
    out->uniformMatrix4fv       = a2mtl_glUniformMatrix4fv;
    out->uniform1i              = a2mtl_glUniform1i;
    out->uniform1f              = a2mtl_glUniform1f;
    out->enable                 = a2mtl_glEnable;
    out->disable                = a2mtl_glDisable;
    out->texParameteri          = a2mtl_glTexParameteri;

    a2_log_criterion(@"[A2-MTL] 后端=metallum 已安装 %d/%d 入口（Metal 直出；不经过 GLES/ANGLE）",
                     A2GL2_ES3_COUNT, A2GL2_ES3_COUNT);
    return A2GL2_ES3_COUNT;
}

const char *a2gl2_metallum_reason(void) {
    return gReason;
}

// ============================================================================
//  ⑬ 石山自检（★新增符号 → 谁调它★）
// ----------------------------------------------------------------------------
//  「新符号」有两类：① 对外导出（头文件里的 3 个）；② 文件内 static。
//  规则：每一行都必须能指出**本仓库内**的调用点，否则说明它是死代码，不该存在。
//
//  ── 对外导出（a2_gl2_backend_metallum.h）──────────────────────────────
//   a2gl2_metallum_available  ← a2_gl2_backend_metallum.m 的 a2gl2_metallum_install（唯一外部调用者
//                               是 a2_gl2_shim.m 的 a2gl2_resolve_es3 → 间接）
//   a2gl2_metallum_install    ← Natives/Renderer/a2_gl2_shim.m 的 a2gl2_resolve_es3()
//   a2gl2_metallum_reason     ← Natives/Renderer/a2_gl2_shim.m 的 a2gl2_resolve_es3()（回落日志）
//
//  ── 文件内 static（★def 行 → 全部调用点，行号按本文件当前内容；由脚本生成，勿手改）──
//   a2mtl_reason                   def:341   ← 383, 696, 701, 721, 733, 754, 795, 803, 814, 829 …共 17 处
//   a2mtl_sym                      def:351   ← 372
//   a2mtl_load_api                 def:369   ← 1475
//   a2mtl_env_int                  def:395   ← 414, 415, 416, 418, 419, 420, 692, 891
//   a2mtl_env_double               def:404   ← 417
//   a2mtl_color_format             def:414   ← 817, 847, 893, 897, 911, 917
//   a2mtl_depth_format             def:415   ← 817, 847, 900, 904, 917
//   a2mtl_ring_mb                  def:416   ← 690, 992
//   a2mtl_frame_gap_ms             def:417   ← 1052
//   a2mtl_flip_y                   def:418   ← 960
//   a2mtl_offscreen                def:419   ← 856
//   a2mtl_sampler_nearest          def:420   ← 1078, 1463
//   a2mtl_tex_register             def:541   ← 724
//   a2mtl_tex_get                  def:562   ← 1084
//   a2mtl_now                      def:640   ← 1051, 1226
//   a2mtl_log_last_error           def:647   ← 695, 720, 732, 794, 802, 828, 896, 903, 945, 1007 …共 11 处
//   a2mtl_layer_pixel_size         def:668   ← 877
//   a2mtl_create_ring              def:688   ← 955
//   a2mtl_create_texture_defaults  def:711   ← 956
//   a2mtl_create_vertex_descriptor def:750   ← 808
//   a2mtl_create_pipelines         def:774   ← 957
//   a2mtl_ensure_surface           def:853   ← 958
//   a2mtl_ensure_device            def:922   ← 1476
//   a2mtl_ring_alloc               def:985   ← 1143, 1144, 1145
//   a2mtl_frame_begin              def:1003  ← 1111
//   a2mtl_frame_end                def:1025  ← 1052
//   a2mtl_frame_maybe_end          def:1049  ← 1110
//   a2mtl_primitive_type           def:1063  ← 1113
//   a2mtl_current_sampler          def:1077  ← 1211
//   a2mtl_current_texture          def:1083  ← 1210
//   a2mtl_submit                   def:1095  ← 1296, 1301
//
//  ── 28 个接缝实现：定义行 → 唯一"取用点"（install 的赋值行）──
//   a2mtl_glGenBuffers           def:1241  ← install:1498     a2mtl_glCreateProgram        def:1342  ← install:1512
//   a2mtl_glBindBuffer           def:1246  ← install:1499     a2mtl_glAttachShader         def:1344  ← install:1513
//   a2mtl_glBufferData           def:1251  ← install:1500     a2mtl_glLinkProgram          def:1346  ← install:1514
//   a2mtl_glGenVertexArrays      def:1267  ← install:1501     a2mtl_glGetProgramiv         def:1348  ← install:1515
//   a2mtl_glBindVertexArray      def:1272  ← install:1502     a2mtl_glGetProgramInfoLog    def:1354  ← install:1516
//   a2mtl_glVertexAttribPointer  def:1276  ← install:1503     a2mtl_glUseProgram           def:1360  ← install:1517
//   a2mtl_glEnableVertexAttribArray def:1292  ← install:1504     a2mtl_glGetAttribLocation    def:1372  ← install:1518
//   a2mtl_glDrawArrays           def:1295  ← install:1505     a2mtl_glGetUniformLocation   def:1381  ← install:1519
//   a2mtl_glDrawElements         def:1299  ← install:1506     a2mtl_glUniformMatrix4fv     def:1393  ← install:1520
//   a2mtl_glCreateShader         def:1305  ← install:1507     a2mtl_glUniform1i            def:1407  ← install:1521
//   a2mtl_glShaderSource         def:1310  ← install:1508     a2mtl_glUniform1f            def:1417  ← install:1522
//   a2mtl_glCompileShader        def:1328  ← install:1509     a2mtl_glEnable               def:1422  ← install:1523
//   a2mtl_glGetShaderiv          def:1330  ← install:1510     a2mtl_glDisable              def:1445  ← install:1524
//   a2mtl_glGetShaderInfoLog     def:1336  ← install:1511     a2mtl_glTexParameteri        def:1456  ← install:1525
//
//  （28 个 `a2mtl_gl*` 的「值」由 install 取用，「调用」发生在语义层 —— 语义层通过
//    a2_gl2_shim.m 的 `gES3.xxx(...)` 调用它们，那条链路见 a2_gl2_shim.m 的 a2gl2_draw。）
//
//  ── 本层**故意不新增**的符号（写了就成石山，故不写）──
//   · 公开的「设置 GL 名 → MTLTexture」入口：28 接缝里没有 glBindTexture，
//     此刻没有调用方 ⇒ 不导出（M2 接缝落地时再加，并同时补它的调用点）。
//   · 显式 beginFrame/endFrame：同上，没有调用方 ⇒ 帧边界走 §⑨ 的启发式。
//   · `metallum_MTLRenderCommandEncoder_setBufferOffset`：本层统一走带 offset 的 setBuffer，
//     登记它却没有调用点 ⇒ 已从 §② 的符号清单里删掉。
// ============================================================================

// ============================================================================
//  ★显示列表（display list）★ 2026-11-06
//  MC 1.12.2 用 glNewList(GL_COMPILE)/glCallList 作画：字体、GUI、世界区块渲染。
//  本层在 a2mtl_submit 入口录制「归一化后的绘制批次」（顶点/索引/图元/纹理名），
//  glCallList 时按记录重放。★不做 GL 命令级录制★：本层只认归一化批次，
//  重放走同一条 a2mtl_submit 路径，语义与直接绘制完全一致。
// ============================================================================

void a2gl2_metallum_list_begin(GLuint id, GLenum mode) {
    A2DLList *l = a2dl_find(id);
    if (l == NULL) {
        if (gDLCount >= A2DL_MAX_LISTS) return;
        l = &gDL[gDLCount++];
        l->id = id; l->recs = NULL; l->count = 0; l->cap = 0;
    } else {
        a2dl_clear(l);
    }
    gDLRec = l;
    gDLExec = (mode == 0x1301 /*GL_COMPILE_AND_EXECUTE*/);
}

void a2gl2_metallum_list_end(void) {
    gDLRec = NULL;
    gDLExec = 1;
}

void a2gl2_metallum_list_call(GLuint id) {
    A2DLList *l = a2dl_find(id);
    if (l == NULL) return;
    for (int i = 0; i < l->count; i++) {
        A2DLRec *r = &l->recs[i];
        // 保存并替换本批要用的顶点/索引/纹理
        const void *sv = gM.pendingVertex;  const size_t svb = gM.pendingVertexBytes;
        const void *si = gM.pendingIndex;   const size_t sib = gM.pendingIndexBytes;
        const GLuint st = gM.boundTexName;
        gM.pendingVertex = r->verts; gM.pendingVertexBytes = r->vBytes;
        gM.pendingIndex  = r->idx;   gM.pendingIndexBytes  = r->iBytes;
        gM.boundTexName  = r->tex;
        a2mtl_submit(r->mode, r->first, r->count, r->indexed, r->indexType);
        gM.pendingVertex = sv; gM.pendingVertexBytes = svb;
        gM.pendingIndex  = si; gM.pendingIndexBytes  = sib;
        gM.boundTexName  = st;
    }
}

void a2gl2_metallum_list_delete(GLuint id, GLsizei range) {
    if (range <= 0) range = 1;
    for (GLsizei k = 0; k < range; k++) {
        A2DLList *l = a2dl_find(id + (GLuint)k);
        if (l != NULL) { a2dl_clear(l); l->id = 0; }
    }
}


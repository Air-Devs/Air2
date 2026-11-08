# 纯 Metal 实现 GL 1.x/2.x 模拟：设计文档（PoC 阶段）

> 目标：**不经过 ANGLE / MobileGlues / EGL**，由我们自己的代码把 GL 1.x/2.x 固定管线直接翻译成 Metal 调用。
> 第一阶段只针对 **MC 1.12.2 及更早**；1.13+ 的 GLSL 着色器翻译单独立项，不在本阶段。
> 日期：2026-11-01 ｜ 分支：`feat/plugin-merge`（实验代码走独立开关，默认关）

---

## 1. 为什么做

```
 现状链路：MC → LWJGL → 我们的 GL2 语义层 → GLES3 → (MG 或 ANGLE) → Metal/GL
 目标链路：MC → LWJGL → 我们的 GL2 语义层 → Metal（直连）
```

三个收益：
1. **不依赖第三方**：MG 与 ANGLE 都不需要，渲染行为完全可控，出问题能定位到我们自己的一行。
2. **没有符号污染**：不加载 ANGLE 的 libEGL/libGLESv2 ⇒ 不存在 `egl*/gl*` 进 flat namespace 的问题（账号页闪退那条根因一并消失）。
3. **性能上限更高**：少两层翻译（GLES 语义重解释 + EGL 交换链），多一道命令编码。

代价：**我们要自己承担 GL 语义与 Metal 语义之间的全部差异**，这是本项目的核心工作量。

## 2. 边界（明确不做）

| 项 | 本阶段 | 说明 |
|---|---|---|
| MC 1.12 及更早（固定管线） | 做 | 立即模式、矩阵栈、客户端数组、显示列表 |
| MC 1.13–1.16 | 不做 | 需要 GLSL→MSL 翻译器，独立立项 |
| MC 1.17+ | 不做 | core profile，本来就不需要固定管线 |
| FBO / 多重渲染目标 | 暂不做 | 1.12 基础渲染不需要；mod 需要时再补 |
| 光照 / 雾的完整语义 | 先 stub | 语义可直接置默认值，不阻塞出画面 |
| 选择 / 反馈（glSelectBuffer） | 不做 | MC 正常渲染不使用，命中时日志点名 |
| MSAA | 暂不做 | 先关闭，画质再单独讨论 |
| 逻辑运算（glLogicOp） | 不做 | 极少数 mod 用 |

## 3. 架构分层

```
 ┌──────────────────────────────────────────────┐
 │ MC (Java)                                    │
 │   org.lwjgl.opengl.GL11 / GL11C              │
 └───────────────┬──────────────────────────────┘
                 │ JNI（RegisterNatives 或 agent 改道，二选一，见 §4）
 ┌───────────────▼──────────────────────────────┐
 │ GL 语义层  a2_gl2_shim.m（已有 70 个入口）    │
 │  · 立即模式收集 / 图元摊平（QUADS→三角形）    │
 │  · 矩阵栈（proj / modelview / texture）       │
 │  · 状态缓存（混合/深度/alpha/纹理环境）       │
 │  · 客户端数组（指针 + stride + 类型）         │
 │  · 显示列表录制/回放（阶段 M2 补）            │
 └───────────────┬──────────────────────────────┘
                 │ 渲染后端接口（抽象：draw / buffer / texture / state）
 ┌───────────────▼──────────────────────────────┐
 │ 后端（二选一，编译期或运行期开关）            │
 │  A. 现有：gES3.*（dlsym 自 MG / ANGLE）       │
 │  B. 新增：Metal 编码器 a2_metal_backend.mm    │
 │       MTLDevice / MTLCommandQueue /           │
 │       CAMetalLayer / PipelineState（缓存）    │
 └──────────────────────────────────────────────┘
```

关键设计：**GL 语义层不认识 Metal，也不认识 GLES**。它只发「画什么、用什么状态」的调用；后端负责落地。这样后端可以随时替换，也为将来 1.13+ 复用语义层留出空间。

## 4. 入口接线（两选一，先做 A）

```
 A（现状，已跑通）：JNI RegisterNatives 抢占 GL11/GL11C 的 native 方法
    · 已在 A2Entry → A2Gl2Gl11Bind → a2_gl2_jni_bind.m 落地，注册 68 条
    · 优点：不改 jar、不动类加载；缺点：只能覆盖 jar 里存在的 native

 B（备选，尚未做）：javaagent + ASM 改道
    · 把 GL11 的 native 方法改写成普通方法，直接调我们的 native
    · 先把原类克隆成 GL11Orig，未实现的入口转调它 ⇒ 不会缺件
    · 优点：生效更早、能覆盖 Java 包装方法（glVertexPointer 这类）；
      缺点：要处理类重定义时机与 LWJGL 提前加载库的问题
    · ★注意★：GL11 里大量 glXxx 是 Java 包装，真正 native 叫 nglXxx；
      指针类入口有 Buffer / 数组 / long 三种重载，改道必须全覆盖
```

本阶段先用 A（已验证），B 作为“覆盖不够时”的升级路径。

## 5. Metal 对象模型

```
 MTLDevice                 进程内唯一（a2_metal_device()）
 MTLCommandQueue           唯一，串行提交
 CAMetalLayer              drawable 提供者；尺寸/scale 由视图同步
 每帧：commandBuffer → renderEncoder → present（最多 2 帧 in-flight）
 MTLRenderPipelineState    按「混合/深度/alphaTest/纹理格式/顶点布局」缓存
 MTLDepthStencilState      按「深度测试函数 + 写开关」缓存
 MTLSamplerState           按「过滤 + wrap + mip」缓存
 MTLBuffer（顶点/索引）     环形缓冲，2~3 帧后重用（不等待 GPU 完成）
 MTLTexture                按 GL 纹理名映射，记录格式/尺寸/mip/参数
```

## 6. 语义映射（最容易错的地方）

### 6.1 裁剪空间
```
 GL    : z ∈ [-1, 1]，屏幕坐标 y 向上
 Metal : z ∈ [ 0, 1]，屏幕坐标 y 向下（framebuffer 原点左上）
 ⇒ 投影矩阵做一次变换：z' = (z + 1) / 2；视口 y 翻转在顶点着色器里处理
 ★这一条错了的表现是「全黑」或「只画出一半」★
```

### 6.2 状态映射
| GL | Metal |
|---|---|
| glEnable(GL_DEPTH_TEST) + glDepthFunc | MTLDepthStencilState（compareFunction / isDepthWriteEnabled） |
| glBlendFunc(s, d) | MTLRenderPipelineColorAttachmentDescriptor 的 sourceRGBBlendFactor / destinationRGBBlendFactor |
| glAlphaFunc + 参考值 | 片元着色器 discard（比较函数转整数码） |
| glCullFace / glFrontFace | MTLCullMode / MTLWinding |
| glPolygonOffset | setDepthBias:slopeScale:clamp: |
| glViewport + glScissor | setViewport: / setScissorRect: |
| glTexParameteri(MIN/MAG/WRAP) | MTLSamplerDescriptor（改参数 ⇒ 换 sampler state） |
| glTexEnvi(MODULATE) | 片元着色器：texel * 顶点色（默认语义） |

### 6.3 纹理
```
 GL_RGBA + GL_UNSIGNED_BYTE            → MTLPixelFormatRGBA8Unorm
 GL_RGB                                → 展开成 RGBA8（Metal 无 24 位格式）
 GL_BGRA                               → MTLPixelFormatBGRA8Unorm + 通道 swizzle
 GL_ALPHA / GL_LUMINANCE                → 上传时展开成 RGBA，shader 里取对应通道
 glTexImage2D 的 unpack 对齐（GL_UNPACK_ALIGNMENT）必须自己实现，不能假设 4 字节对齐
 mipmap 生成：自己写（Metal 没有 glGenerateMipmap）
```

## 7. 着色器策略

```
 一个 uber-shader（MSL 手写）+ 少量变体开关（用 #define 在编译期区分）：
   顶点属性：position(vec3) / color(vec4 uchar→float) / uv(vec2)
   uniform ：MVP(mat4)、纹理、alphaRef、fogColor/fogRange（阶段 M3）
   片元    ：texel * 顶点色 → alpha test discard → 雾混合 → 输出
 变体只在「有没有纹理 / 有没有 alpha test / 有没有雾」之间切，
 不做「每个 GL 状态组合一个着色器」——否则 pipeline 编译会爆炸。
```

## 8. 几何路径

```
 立即模式：glBegin → 收集；glVertex*/glColor*/glTexCoord* → 写进 native 顶点数组；
          glEnd → 摊平（QUADS→2 三角形、POLYGON→扇形、LINE_LOOP→补尾点）→ 一次 draw
 客户端数组：记录指针/类型/stride，绘制时按 stride 取样（CPU）或直接 MTLBuffer 包装
 索引绘制：glDrawElements 支持 UBYTE/USHORT/UINT
 顶点环形缓冲：每帧起始复位，超限就开新段；不阻塞 GPU
```

## 9. 显示列表（阶段 M2 的硬需求）

```
 MC 1.12 的区块渲染大量使用 glNewList/glCallList。
 设计：录制我们自己的指令流（不是 GL 调用）：
   list := [ {draw, mode, vertexCount, vertices...}, {state, ...}, {texture, id}, ... ]
 回放 = 顺序执行这些指令；列表可嵌套（glCallList 里再调 glCallList）。
 约束：列表里的顶点数据要拷贝保存（调用方的数组可能已释放）。
 不做显示列表 ⇒ 标题界面可能能看，但进世界后地面完全消失。
```

## 10. 帧模型

```
 每帧：
   1. 从 CAMetalLayer 取 drawable（nil ⇒ 跳过本帧）
   2. 建 command buffer + render pass descriptor（颜色 + 深度）
   3. 编码本帧所有 drawcall
   4. present + commit
   5. 维护 2 帧 in-flight 信号量，避免 CPU 追 GPU
 尺寸变化：drawableSize 必须跟随视图（这条我们在 GL 桥已经踩过一次坑）
```

## 11. 性能设计（M3 才做，但结构要预留）

```
 pipeline / depth-stencil / sampler 三套缓存，键是状态组合
 状态去重：同一组状态连续绘制不重复设置
 顶点批处理：同状态同纹理的连续 draw 合并（先不做，避免语义出错）
 避免每帧分配：所有临时缓冲预分配 + 复用
 目标：1.12.2 主菜单 60fps、世界中位机型 30fps 以上
```

## 12. 里程碑与验收判据

| 阶段 | 内容 | 判据（日志/现象） |
|---|---|---|
| M0 | 清屏 + 纹理四边形（不接 MC） | `[A2-METAL] 设备=… 帧=… 耗时=…ms`，屏幕看到棋盘格四边形 |
| M1 | 接 MC 1.12.2 标题界面 | 标题背景、按钮、文字正常显示；`[A2-GL2] 绘制 #N …` 持续增长 |
| M2 | 进世界 | 补显示列表 + 客户端数组；地形方块可见、能移动 |
| M3 | 性能与画质 | 稳定帧率、无闪烁、无内存增长 |

每阶段的开关都在版本设置里（按实例保存），默认关；出问题一键退回现有 MG/ANGLE 链路。

## 13. 风险与未决问题

```
 1. 显示列表：工作量最大的一块，且必须正确（否则进不了世界）
 2. 纹理格式：Mod 里的压缩纹理（ETC/ASTC）需要单独解码或拒绝，先记录再决定
 3. FBO：1.12 基础不需要，但 OptiFine/光影必需；本阶段明确不支持并日志提示
 4. 线程模型：Metal 编码必须在同一线程；MC 的渲染线程与我们的 JNI 调用线程要一致
 5. 内存：纹理与顶点缓冲的上限要设，避免被系统杀（Jetsam）
 6. 1.13+ 的 GLSL：本阶段不做，届时需要 GLSL→MSL 翻译器（独立大工程）
```

## 14. 代码落点（拟）

```
 Natives/Renderer/a2_gl2_shim.m        已有：GL 语义层（本次基本不动）
 Natives/Renderer/a2_gl2_jni_bind.m    已有：JNI 注册（68 条）
 Natives/Renderer/a2_metal_backend.mm  新增：Metal 后端（device/queue/layer/pipeline/texture）
 Natives/Renderer/a2_metal_backend.h   新增：后端接口（draw/buffer/texture/state）
 Natives/Renderer/a2_gl2_backend.h     新增：后端抽象（GLES 与 Metal 二选一）
 Air2/Player/A2LaunchSession.m         开关：A2_GL2_METAL=1 时启用 Metal 后端
 Air2/UI/Screens/Version/...           开关行：「GL2 后端：Metal（实验）」
```

★石山约束★：新增文件必须能指出调用点。`a2_metal_backend.mm` 的唯一调用方是 `a2_gl2_shim.m` 的后端选择处；`a2_gl2_backend.h` 只被 `a2_gl2_shim.m` 与两个后端实现包含。

### 14.1 M0 已落地（2026-11-01）

M0 先不接 MC，所以调用点是**一处**自我检测，而不是 §14 里的后端选择处：

```
 Natives/Renderer/a2_metal_backend.h/.mm   已落地：设备/队列/管线/采样器/深度 + 棋盘格纹理
                                           + 60fps 自检驱动（120 帧）
 调用点（唯一）                             Natives/Renderer/a2_gl_bridge.m 的 a2_gl_bridge_attach ⑨：
                                           if (a2_metal_selftest_requested())        // 只读环境变量
                                               a2_metal_selftest_schedule(图层, 像素宽, 像素高, 120);
 开关                                    环境变量 A2_METAL_SELFTEST=1（不设 ⇒ 一行都不执行，
                                           连 Metal 设备都不建 ⇒ 默认路径零影响）
 机器判据                                scripts/verify_metal_backend.py（make lint 会跑）
 真机判据日志                            [A2-METAL] 设备=… 后端=Metal …
                                           [A2-METAL] 自检帧 #N 耗时=X.XXms drawable=WxH
                                           [A2-METAL] 自检完成 平均帧耗时=X.XXms（…）
```

M1 起把这张图里的「自检驱动」换成 `a2_gl2_shim.m`：由 GL 语义层驱动
`begin_frame / draw / end_frame`，`a2_metal_selftest_*` 两段整体退役（届时一并删掉，
不留双入口）。

## 15. 与现有链路的关系

```
 1.17+ 与已跑通的版本：完全不受影响（不走 GL2 层）
 1.12 想走 Metal：开关打开；想退回：关掉即回到 MG/ANGLE
 账号页闪退：Metal 后端不需要加载 ANGLE ⇒ 符号污染不存在（但 GLES 链路仍需 RTLD_LOCAL 隔离）
```

---

## 附：与“agent 改 jar”的关系

`javaagent + ASM` 不是本方案的替代，而是**入口接线的另一种实现**（§4 的 B）。
它能做的是「把 GL 入口改道到我们的实现」，不能替我们完成「GL 语义 → Metal」的翻译工作。
本方案先走 A（RegisterNatives，已验证），B 作为覆盖不足时的升级路径。

---

## 16. M1-α 已落地（2026-11-01）：GL2 语义层的 Metal 后端

> 本节记录**实际交付的那一层**，与 §5/§7 的设计有出入的地方以本节为准。
> ★未编译、未真机验证★（本机无 ObjC/C 编译器；编译与首帧验证由远端 Mac 做）。

### 16.1 落点与接线

```
 Natives/Renderer/a2_gl2_backend_metallum.h   新增：接缝单一真源头 A2GL2ES3（28 入口）
                                              + 三个导出：available / install / reason
 Natives/Renderer/a2_gl2_backend_metallum.m   新增：28 入口的 Metal 实现（libmetallum C API，全 dlsym）
 Natives/Renderer/a2_gl2_shim.m               改：① A2GL2ES3 的 typedef/struct 搬到上面那个头文件
                                                ② a2gl2_resolve_es3() 优先尝试 metallum，失败回落 GLES
                                                ★翻译算法（立即模式/矩阵栈/图元摊平/客户端数组）一行未动★
 scripts/verify_gl2_metallum.py               新增：源码自检（括号/引号、28 装齐、符号↔dylib、调用点）
 Makefile                                     改：lint 里那段空的 if/else 补上这个脚本（原来 make lint 会语法错）
 Air2.xcodeproj/project.pbxproj               重新生成（scripts/gen_xcodeproj.py，246 编译单元）
                                              CMake 侧不用改：源清单由 scan_sources() 扫盘生成，已含新文件
```

框架依赖：`Metal` 与 `QuartzCore` **已在** `cmake/a2_frameworks.cmake` 的 `A2_SYSTEM_FRAMEWORKS` 里
（QuartzCore 那条注释就写着 CAMetalLayer），故未重复添加。

### 16.2 开关与判据行

```sh
A2_GL2_SHIM=1              # 前置：自研固定管线层（1.12 及更早由启动链设置）
A2_GL2_BACKEND=metallum    # 本后端；也可写 gles 强制走原链路
A2_GL2_METAL=1             # 兼容旧口径：A2_GL2_BACKEND 未设/为空时才看它
```

真机 grep 判据：

```
[A2-MTL] 设备=<GPU 名>（后端=metallum，libmetallum 的 Metal C API）      ← 设备与 dlsym 都通
[A2-MTL] libmetallum 可用：40 条符号（必需 31 条全部命中）+ ...          ← 符号探测
[A2-MTL] 使用内置 MSL uber-shader（GLSL 忽略）                          ← §7 的着色器策略
[A2-MTL] 管线就绪：不透明 + alpha 混合 …
[A2-MTL] 表面=CAMetalLayer 1080x1920 scale=3.00 颜色格式=80 深度格式=252
[A2-MTL] 后端=metallum 已安装 28/28 入口（Metal 直出；不经过 GLES/ANGLE）
[A2-MTL] 绘制 #1：mode=0x7 prim=3 顶点=4 索引=1 帧内=1 环=…
[A2-MTL] 回落后端=GLES（原因=…）                                        ← 任一环节失败走这条
```

调参开关（全部「未设即默认」，不必重编）：`A2_MTL_COLOR_FORMAT`、`A2_MTL_DEPTH_FORMAT`、
`A2_MTL_DRAWABLE=WxH`、`A2_MTL_FLIP_Y`（默认 1）、`A2_MTL_FRAME_GAP_MS`（默认 2）、
`A2_MTL_RING_MB`（默认 16）、`A2_MTL_SAMPLER`（1=最近邻）、`A2_MTL_OFFSCREEN`（1=不碰 surface）、
`A2_MTL_TEXTURE_STORAGE`、`A2_MTL_BUFFER_OPTIONS`。

### 16.3 ★签名核对清单（远端编译时必须做，本机无法做）★

`libmetallum.dylib` 的 C 头文件不在本仓，dlsym 只认符号名、不认签名。下表是**假定签名**
（`.m` 的 §② API 表里逐条同注）——请对着真头文件核一遍；不一致时**只改那张表**，调用点不动。

| 符号 | 假定签名 | 风险 |
|---|---|---|
| `create_system_default_device` | `void *f(void)` | 低 |
| `MTLDevice_makeCommandQueue` / `MTLCommandQueue_makeCommandBuffer` | `void *f(void *)` | 低 |
| `create_buffer` | `void *f(dev, size_t, unsigned)` | 中（options 语义） |
| `get_buffer_contents` | `void *f(buf)` | 低 |
| `create_texture_2d` | `void *f(dev, int fmt, int w, int h, int depth, unsigned usage, unsigned storage, const void *bytes, size_t bpr)` | 高（参数多） |
| `create_shader_function` | `void *f(dev, const char *msl, size_t len)` | **最高**（若第 3 参是入口名 ⇒ 必崩） |
| `init_pipelines` | `int f(dev)` | 低 |
| `MTLRenderPipelineDescriptor_create` | `void *f(void)` | 低 |
| `..._setAttachmentFormats` | `int f(desc, int colorFmt, int depthFmt)` | 中 |
| `..._setBlendState` | `int f(desc, int enabled, int srcRGB, int dstRGB, int srcA, int dstA)` | **高** |
| `..._setCompiledFunctions` | `int f(desc, vs, fs)` | 中 |
| `..._setVertexDescriptor` | `int f(desc, vd)` | 低 |
| `MTLVertexDescriptor_create` | `void *f(void)` | 低 |
| `..._setAttribute` | `int f(vd, unsigned index, int format, size_t offset, unsigned bufferIndex)` | 中 |
| `..._setLayout` | `int f(vd, unsigned bufferIndex, unsigned stride, int stepFunction)` | 中 |
| `MTLDevice_makeRenderPipelineState` | `void *f(dev, desc)` | 低 |
| `MTLDevice_makeDepthStencilState` | `void *f(dev, int compare, int writeEnabled)` | 中（可能收 descriptor 对象） |
| `create_sampler` | `void *f(dev, min, mag, wrapS, wrapT)` | **高** |
| `create_metal_layer` / `ios_get_view_metal_layer` | `void *f(void)` | 低 |
| `configure_layer` | `int f(layer, double w, double h, double scale, int fmt)` | 中 |
| `MTLCommandBuffer_makeRenderCommandEncoder` | `void *f(cb, colorTex, depthTex)` | **高**（可能还要 loadAction/clearColor） |
| `..._setBuffer` | `int f(enc, buffer, size_t offset, unsigned index)` | **高**（是否分 vertex/fragment 段） |
| `..._setTextureAndSampler` | `int f(enc, tex, sampler, unsigned index)` | 中 |
| `..._setScissorRect` / `setCullMode` / `setFrontFacingWinding` | `int f(enc, …)` | 低 |
| `..._setDepthBias` | `int f(enc, float, float, float)` | 低 |
| `..._drawPrimitives` | `int f(enc, int prim, unsigned start, unsigned count)` | 中 |
| `..._drawIndexedPrimitives` | `int f(enc, int prim, unsigned idxCount, int idxType, void *buf, size_t off)` | 中 |
| `MTLCommandEncoder_endEncoding` / `MTLCommandBuffer_commit` | `int f(obj)` | 低 |
| `MTLCommandBuffer_encodePresentTextureToDrawable` | `int f(cb, tex)` | 中 |
| `MTLCommandBuffer_waitUntilCompleted` | `int f(cb)` | 低 |
| `release_object` / `get_last_error` | `void f(obj)` / `const char *f(void)` | 中 |
| `copy_device_name` | `int f(char *buf, size_t cap)` | 中（只影响一行日志） |

为降低上面这些风险，`.m` 里做了三件事：
① 全部调用集中在 §② 的 `gApi` 表（改签名只改一处）；
② 初始化分阶段（设备 → 队列 → 着色器 → 顶点描述符 → 管线 → 表面），每阶段一行判据，
   崩在哪一段一眼可见；
③ uniform **只喂顶点阶段**（用 `[[flat]]` varying 传给片元），
   ⇒ 不依赖 `setBuffer` 是否区分 vertex/fragment 段这个未验签语义。

另：`metallum_init_pipelines` 的返回值、以及 dylib 内 MTL 枚举 rawValue（像素格式 70/80/252、
顶点格式 29/30/9、采样器 0/1/0/2）同样是「假定值」，都可用 §16.2 的环境变量覆盖。

**只验语法（不打包）的等价命令**（远端 Mac 上跑，`-I` 列表由仓内生成器给，不手抄）：

```sh
cd <repo>
INC=$(python3 scripts/gen_cmake_sources.py --json \
      | python3 -c 'import json,sys; print(" ".join("-I"+i for i in json.load(sys.stdin)["include_dirs"]))')
xcrun -sdk iphoneos clang -fsyntax-only -fobjc-arc -x objective-c $INC \
      Natives/Renderer/a2_gl2_backend_metallum.m
python3 scripts/verify_gl2_metallum.py        # 结构/符号/调用点自检（不需编译器）
```

### 16.4 本层明确不做的（接缝之外，不作为缺陷申报）

| 缺什么 | 原因 | 现象 |
|---|---|---|
| 清屏 / viewport / scissor | glClear/glViewport 不在 28 接缝内 | 颜色附件跨帧累积（叠影）；裁剪恒为整张附件 |
| 纹理内容 | glBindTexture/glTexImage2D 不在接缝内 | 采样恒为 1×1 白纹理 ⇒ 片元 = 顶点色 |
| glBlendFunc / glDepthFunc / glCullFace | 同上 | 固定 SRC_ALPHA/ONE_MINUS_SRC_ALPHA、LEQUAL+写、CULL_BACK |
| 模板 / MSAA / 逻辑运算 / 雾 / 光照 | §2 的边界 | 点名一次后忽略 |
| 真·每程序编译 | 语义层只有一个 uber-shader | 本层「记账 + 假句柄」，见 `.m` 文件头 |
| 显式帧边界 | 接缝里没有 begin/endFrame | 用「绘制间隔 ≥ A2_MTL_FRAME_GAP_MS（默认 2ms）」判新帧，代价 ≈1 帧延迟 |
| glBufferData 的"静态上传"语义 | 本层把拷贝推迟到绘制时（环形缓冲的复位点才安全） | 只上传不绘制的 VBO 数据会被丢弃 ⇒ `data` 必须在紧随的 draw 时仍有效 |

★关于「推迟拷贝」这条假设★：唯一调用方 `a2gl2_shim.m` 的 `a2gl2_draw()` 每帧都
`bufferData(gVerts/gIndex)` 紧跟一次 draw（流式上传），两个都是**静态数组** ⇒ 满足假设。
若将来有人给本层接一个"上传一次、反复画"的调用方，必须改成"bufferData 就地拷进环"
并重做环形缓冲的回收策略（那是 M3 换 fence/信号量时一起做的事）。

### 16.5 下一步（M1-β / M2）要补的接缝

按「先出画面、再出贴图」的顺序：

```
M1-β  glClear/glClearColor/glViewport/glScissor 三个入口进 kA2GL2Entries
      ⇒ 帧边界与清屏不用再猜（把 §16.4 第 1 条与启发式一起去掉）
M2    glGenTextures/glBindTexture/glTexImage2D/glTexSubImage2D/glDeleteTextures
      ⇒ 填 a2_gl2_backend_metallum.m 里那张「GL 名 → MTLTexture」表
         （表的读写函数已在：a2mtl_tex_register / a2mtl_tex_get，届时把 register 提成公开入口）
M2+   glBlendFunc/glDepthFunc/glCullFace/glDepthMask ⇒ 混合与深度的完整语义（管线变体扩到 4~8 条）
M3    显示列表（1.12 进世界必需）、环形缓冲换 fence/信号量（去掉帧末 waitUntilCompleted）
```

另有一条**可选**的清屏路径留给 M1-β：dylib 里导出了
`metallum_MTLCommandBuffer_clearColorDepthTexturesRegion` 与
`metallum_MTLRenderCommandEncoder_clearDraw`（名字见
`grep -a -o 'metallum_[A-Za-z0-9_]*' Libraries/Renderers/libmetallum.dylib | sort -u`），
本次**没有接**——它们的签名同样未验证，而在接缝里补 glClear 反而更干净（不用猜）。


# Air2 · EAGL 适配启动器实施计划（假 EGL 方案）

> 日期：2026-10-25 ｜ 状态：待评审 ｜ 不含任何 SWFPE 内容
> 核心思路：**用 EAGL 伪装成 EGL**。上层渲染器（MobileGlues 等 1.17+ 后端）只认 EGL，我们给它一套假 EGL，底层落到 `EAGLContext` + renderbuffer。

---

## 0. 背景与约束

| 事实 | 含义 |
|---|---|
| iOS 系统 OpenGL ES **停在 3.0**，已标记 deprecated，但**仍可用、未宣布移除** | 可以依赖，但要按 ES3.0 能力设计，不假设 3.1/3.2 |
| 1.17+ 的渲染器（MobileGlues 等）**走 EGL 接口**，不能直接换成 EAGL | 必须提供 EGL 语义；EAGL 是底层实现，不是对外接口 |
| 我们不引入 SWFPE | 固定管线方案另议，本文只做 EAGL 宿主与假 EGL |
| 26.x 用 metallum（直连 Metal） | 与本方案无关 |

**结论**：EAGL 这一层的产品形态是「**假 EGL + 真 EAGL**」：
- 对外：`eglGetDisplay/eglInitialize/eglChooseConfig/eglCreateContext/eglCreateWindowSurface/eglMakeCurrent/eglSwapBuffers/eglGetProcAddress/eglGetError/eglTerminate`
- 对内：`EAGLContext(api=ES3)` + renderbuffer/FBO（或 CAEAGLLayer）

---

## 1. 总体架构

```
渲染器（MobileGlues / gl4es / KW / …）
        │  调用 EGL API（它以为自己在用 EGL）
        ▼
   liba2fakeegl.dylib        ← 新增（假 EGL 层）
        │  转调
        ▼
   liba2eaglhost.dylib       ← 新增（EAGL 宿主：上下文/可绘制面/入口解析）
        │
        ▼
   系统 OpenGLES.framework → Metal
```

启动器只与两层打交道：
- 选宿主：`A2GLHostEGL_ANGLE`（现状） / `A2GLHostEAGL`（新）
- 拿入口：`a2_gl_host_getprocaddress(name)`

**一次启动只允许一条 GL 栈**（EAGL 与 ANGLE 不共存），避免线程 current 与符号互相顶替。

---

## 2. 假 EGL 层设计（核心）

### 2.1 十个函数的语义映射

| EGL API | 实现 |
|---|---|
| `eglGetDisplay` | 返回常量假句柄（如 `(EGLDisplay)0x1`） |
| `eglInitialize` | 校验版本，记录已初始化；返回 `EGL_TRUE` |
| `eglChooseConfig` | 解析请求属性（`RENDERABLE_TYPE` 必须含 `EGL_OPENGL_ES3_BIT`、`SURFACE_TYPE` 含 `WINDOW`），通过则回填 1 个 config 句柄；不含 ES3 位则返回 0 个 config（**显式失败，不静默降级**） |
| `eglCreateContext` | 读 `EGL_CONTEXT_CLIENT_VERSION`；只接受 3；创建 `EAGLContext(api=ES3)`，失败返回 `EGL_NO_CONTEXT` |
| `eglCreateWindowSurface` | 记录尺寸/缩放，创建 color+depth renderbuffer 与 FBO；返回 surface 句柄 |
| `eglMakeCurrent` | `[EAGLContext setCurrentContext:]`；保存/恢复线程绑定 |
| `eglSwapBuffers` | 绑定 color renderbuffer → `presentRenderbuffer:` → 计数与耗时日志 |
| `eglGetProcAddress` | 转 `a2_gl_host_getprocaddress`（dlsym `OpenGLES.framework`） |
| `eglGetError` | 返回本层最近一次错误码 |
| `eglTerminate` | 释放 FBO/renderbuffer、清 current、销毁上下文 |

### 2.2 必须明确的“不做”
- 不做多重采样/交换间隔等 EGL 扩展的“假实现”（不支持就返回失败，让调用方降级）
- 不模拟多个 config/多个 surface（只支持 1 个 window surface，够用）
- 不隐藏错误：任何不支持的属性组合都返回明确错误码

---

## 3. EAGL 宿主层设计

### 3.1 对外 C API
```c
int   a2_eagl_init(void);
int   a2_eagl_create_context(int apiVersion /*must be 3*/);
int   a2_eagl_bind_drawable(void *layerOrView, int wPx, int hPx, float scale);
int   a2_eagl_make_current(void);
int   a2_eagl_present(void);
void *a2_eagl_getprocaddress(const char *name);
const char *a2_eagl_backend_name(void);   // "eagl-es3"
void  a2_eagl_teardown(void);
```

### 3.2 绘制面
- 默认：**renderbuffer + FBO**（不依赖 CALayer，尺寸完全可控）
- 备选：`CAEAGLLayer`（需要真实 layer 时）；必须设 `contentsScale`
- 硬校验：请求像素尺寸 == renderbuffer 实际尺寸；不一致打判据

### 3.3 线程
- `EAGLContext` 绑定线程；`make_current` 幂等
- 渲染线程单线程独占；与其它 GL 栈禁止交叉

---

## 4. 启动器接入（P1）

### 4.1 宿主抽象
在 `Natives/Renderer/a2_gl_bridge.m` 增加宿主选择：
```
A2GLHostKind { A2GLHostEGL_ANGLE, A2GLHostEAGL }
```
两条宿主实现同一组内部接口：`create_context / bind_surface / make_current / present / getprocaddress`。

### 4.2 渲染器清单
新增条目：`EAGL (假 EGL · 系统 GLES 3.0)`
- 类型：宿主（Host），不是渲染器
- 默认：**不选中**；1.17+ 的 MG 等仍默认走 ANGLE，用户可显式切换做 A/B
- 选择后，渲染器的 EGL 调用被路由到 `liba2fakeegl`

### 4.3 启动计划
- `-Dorg.lwjgl.opengl.libname=<渲染器>`
- 若宿主=EAGL：把 `liba2fakeegl` 的 EGL 符号提供给渲染器（具体方式见 §5 符号学）

---

## 5. 符号与加载策略（决定成败）

| 场景 | 策略 |
|---|---|
| 宿主=EAGL | **不加载 ANGLE**（`libEGL`/`libGLESv2` 都不进进程），彻底避免符号互顶与 GLES1 状态机 |
| 宿主=ANGLE（现状） | 保持原样；EAGL 相关 dylib 不加载 |
| 渲染器加载 | 渲染器本体 `RTLD_GLOBAL`（让 MC 能解析 gl*）；假 EGL 层以“提供 EGL 符号”的身份先加载 |
| 入口解析 | 渲染器通过 `eglGetProcAddress`（假 EGL）拿到 `a2_eagl_getprocaddress` 的结果；禁止让它自己去 dlopen 系统 GLES |

**风险点**：若渲染器内部直接 `dlopen("libGLESv2")` 而不走 EGL，则假 EGL 会被绕过。缓解：
- 打包时**不携带** `libGLESv2.framework`（让它找不到）
- 若必须携带，则用同名 shim 顶替（指向 `a2_eagl_getprocaddress`）

---

## 6. 阶段计划

### P0（3 天）可行性前置
| 步骤 | 产出 | 判据 | 状态 |
|---|---|---|---|
| P0-1 | `tools/eagl_probe/` 独立探针 | 建 `EAGLContext(api=3)`；`glGetString(GL_VERSION)` 返回 `OpenGL ES 3.x`；present 300 帧不崩 | ✅ **已通过（2026-10-31 真机）** |
| P0-2 | `a2_eagl_getprocaddress` | 抽 20 个 GLES3 入口全部非 NULL | ✅ **已通过（2026-10-31 真机，20/20）** |
| P0-3 | 绘制面 | renderbuffer 实际尺寸 == 请求像素尺寸；Retina 缩放正确 | ✅ **已通过（2026-10-31 真机）** |

**P0-1 不过 ⇒ 整案停止**（回到 ANGLE 路线）。

#### P0-1 / P0-3 实测记录（2026-10-31，EAGLProbe v2，日志 `EAGLProbe-latest.log`）
```
context     EAGLContext(api = kEAGLRenderingAPIOpenGLES3) 创建成功
GL_VERSION  OpenGL ES 3.0 Metal - 99
GL_RENDERER Apple M2 GPU
GL_VENDOR   Apple Inc.
GLSL        OpenGL ES GLSL ES 3.00
drawable    2732x2048（与请求一致 ⇒ P0-3 尺寸/缩放判据通过）
300 帧       96.2 fps / 平均 10.39 ms / 无 glGetError / 无 present 失败
```
结论：EAGL + 系统 GLES3 在本代 iOS 上可用，ES3 上下文与完整帧循环成立 ⇒ 假 EGL（EGL → EAGL 转发）路线继续推进。
**尚未覆盖**：扩展面（GL_EXTENSIONS 条数与清单）与上限（GL_MAX_TEXTURE_SIZE / GL_MAX_RENDERBUFFER_SIZE / GL_MAX_VERTEX_ATTRIBS）——这是 P0-2 与 P2 的前置，必须补测。

#### P0-2 实测记录（2026-10-31 真机，EAGLProbe P0-2 版）
```
GL_NUM_EXTENSIONS = 19
GLES3 入口         ok=20 missing=0（glGenBuffers/BindBuffer/BufferData/GenTextures/TexImage2D/
                   GenFramebuffers/BindFramebuffer/FramebufferTexture2D/GenRenderbuffers/
                   RenderbufferStorage/CreateShader/CompileShader/CreateProgram/LinkProgram/
                   UseProgram/UniformMatrix4fv/VertexAttribPointer/DrawElements/DrawArrays/GetStringi）
上限               maxTexture=16384 maxRenderbuffer=16384 maxVertexAttribs=16 maxTexUnits=32 maxSamples=4
性能               300 帧 115.05 fps / 平均 8.69 ms（2732x2048）

扩展全表（19）
  GL_OES_standard_derivatives, GL_KHR_texture_compression_astc_ldr, GL_EXT_color_buffer_half_float,
  GL_EXT_debug_label, GL_EXT_debug_marker, GL_EXT_pvrtc_sRGB, GL_EXT_read_format_bgra,
  GL_EXT_separate_shader_objects, GL_EXT_shader_framebuffer_fetch, GL_EXT_shader_texture_lod,
  GL_EXT_shadow_samplers, GL_EXT_texture_filter_anisotropic, GL_APPLE_clip_distance,
  GL_APPLE_color_buffer_packed_float, GL_APPLE_copy_texture_levels, GL_APPLE_rgb_422,
  GL_APPLE_texture_format_BGRA8888, GL_IMG_read_format, GL_IMG_texture_compression_pvrtc
缺失但常被问到的：KHR_debug, OES_texture_float_linear, EXT_texture_storage, EXT_sRGB,
  EXT_multisampled_render_to_texture, EXT_disjoint_timer_query
```

#### 能力缺口清单（对照 MobileGlues，2026-10-31 修正）
- MG 最低要求 **GLES 3.0**（README 原文），3.1/3.2 特性由它自己的能力门控降级：
  `config/settings.cpp:605-606` 的 `has_es31` / `has_es32`、`gl/enable.cpp:203`、`gl/drawing.cpp:318`（间接绘制仍为 TODO）。
  ⇒ **ES3.0 上可运行**，走兼容路径（SSBO / indirect draw / compute 不启用，性能有折扣）。
- 需要在 P2 逐条实测的缺口：`KHR_debug`（调试输出缺失）、`OES_texture_float_linear`（浮点纹理线性过滤，
  光影/后处理可能受影响）、`EXT_texture_storage`（不可变纹理，性能）、`EXT_sRGB`、多重采样 RT。


#### 顺带记录：探针在编译期暴露的两个原版缺陷（已修）
1 `CALayer.autoresizingMask` / `kCALayerWidthSizable` 在 iOS SDK 里是 **unavailable**（macOS API）⇒ 原版直接编不过，已删（改由 `viewDidLayoutSubviews` 同步 frame）。
2 `build.sh` 只链 UIKit/OpenGLES/QuartzCore，缺 `Foundation`/`CoreGraphics` ⇒ `CGRectZero` 链接失败，已补。


### P1（1 周）假 EGL 层
- 实现 §2.1 十个函数 + 错误码
- 判据：一个纯 GLES3 三角形通过「假 EGL」画出来（不需要渲染器）

**状态：✅ 已通过（2026-10-31 真机，独立 demo `EGL2EAGLDemo`）**
```
eglInitialize 1.4 → eglChooseConfig n=1 → eglCreateContext(ES3) ok
→ eglCreateWindowSurface 375x812 → eglMakeCurrent ok
→ eglGetProcAddress: GL 入口缺 0/16（全部可解析）
→ frames=120 drawable=375x812 glError=0x0000 EGL error=0x3000(SUCCESS)
→ 屏幕渲染出旋转三角形
```
实现要点（demo 已验证的形状，P1 正式实现照此落地）：
- 上层只调 EGL 接口（`eglGetDisplay/Initialize/ChooseConfig/CreateContext/CreateWindowSurface/MakeCurrent/SwapBuffers/GetProcAddress/GetError`）
- 底层 EAGL：`EAGLContext(ES3)` + `CAEAGLLayer` + `renderbufferStorage:fromDrawable:` + `presentRenderbuffer`
- `eglGetError` 读后清零；`eglGetProcAddress` 先查本模块导出表再 `dlsym(RTLD_DEFAULT)`
- 编译坑（已踩）：iOS 无 `PFNGL*` typedef；`EGL_BAD_ALLOC`/`EGL_BAD_NATIVE_WINDOW`/`EGL_DRAW`/`EGL_READ` 需自定义；宏不能当三元表达式用


### P2（1–2 周）接 1.17+ 渲染器（MobileGlues）
- 把 MG 的 EGL 调用路由到假 EGL；MG 用 `a2_eagl_getprocaddress` 取 GLES 入口
- 判据：MC 1.17.1 能过 `GL caps init`、打出 `GL version OpenGL ES 3.0`
- 记录 **能力缺口清单**（ES3.0 缺 compute/SSBO/image load/store），逐条标注“影响哪些版本/特性”

### P3（1 周）装进启动器 + 默认策略
- 宿主选择落地、渲染器清单条目、失败页文案
- 默认策略：ANGLE 仍为默认；EAGL 作为可选实验宿主
- 判据：真机切换宿主后，启动链日志能明确显示 `host=EAGL / api=ES3`

---

## 7. 验收判据（真机，逐条 grep）

```
[A2-EAGL] init rc=0 api=ES3
[A2-EAGL] ctx created
[A2-EAGL] drawable rb=<w>x<h> scale=<s>（请求 <w>x<h>）
[A2-FAKEEGL] eglChooseConfig renderable=ES3_BIT ok
[A2-FAKEEGL] eglCreateContext version=3 ok
[A2-FAKEEGL] swap frame=<n> ms=<t>
```

失败时必须给出可读原因（哪个 EGL 调用、哪个属性不满足），不允许“静默回退到 ANGLE”。

---

## 8. 风险与对策

| 风险 | 概率 | 对策 |
|---|---|---|
| EAGL 在 iOS 26/27 建 ES3 上下文异常 | 低 | P0-1 一票否决 |
| 渲染器绕过 EGL 直接 dlopen GLES | 中 | 不打包 `libGLESv2`；或同名 shim 顶替 |
| ES3.0 能力不足（相对 MG 期望的 3.2） | 高 | P2 产出能力矩阵；按版本给“可用/降级”结论，不假装满血 |
| 系统 GL 性能不及 ANGLE | 中 | P2 做同场景帧率对照；低于阈值则该版本回退 ANGLE |
| Apple 未来移除 OpenGLES | 低 | 技术债，不提前规避 |

---

## 9. 交付物

- P0：`tools/eagl_probe/`、`docs/EAGL-P0-REPORT.md`
- P1：`Natives/EAGL/`（宿主层）、`Natives/FakeEGL/`（假 EGL 层）
- P2：MG-on-EAGL 能力矩阵、真机日志
- P3：启动器宿主选择、渲染器清单条目、默认策略说明

---

## 10. 明确不做

- 不做 SWFPE 或任何固定管线模拟（另案）
- 不做 EAGL/ANGLE 同进程共存（一次启动一条 GL 栈）
- 不做 ES2 降级（渲染器需要 ES3）
- 不碰 26.x metallum 路径

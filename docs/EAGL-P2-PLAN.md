# P2 方案：把 MobileGlues 的 EGL 调用路由到「假 EGL（EGL → EAGL）」

> 状态：方案稿（2026-10-31）。前置 P0（三项）与 P1（假 EGL 层）已在真机验证通过。

---

## 1. 目标与判据

**目标**：让 1.17+ 的渲染器（MobileGlues）在 iOS 上跑在 EAGL 之上，不再依赖 ANGLE 的 GLES1 状态机。

**判据（逐级）**
| 级 | 判据 | 失败含义 |
|---|---|---|
| P2-1 | MG 的 egl 初始化链全部走我们的假 EGL（日志出现 `[A2-FAKEEGL]`） | MG 仍在用别的 EGL 实现 |
| P2-2 | MG 报告 `GL version OpenGL ES 3.0`、`GL_RENDERER` 非空 | 宿主 GLES 提供不完整 |
| P2-3 | MC 1.17.1 过 `GL caps init`，进入菜单 | 能力/扩展不满足 |
| P2-4 | 出画面（非纯黑），帧回调持续 | 表面/同步问题 |

---

## 2. 现状（已验证的事实）

```
P0-1/P0-3  EAGL 可建 ES3 上下文；2732x2048；300 帧 96 fps
P0-2        GLES3 20 个入口 20/20 可解析；GL_NUM_EXTENSIONS=19
            maxTexture/maxRenderbuffer=16384；maxVertexAttribs=16；maxTexUnits=32；maxSamples=4
P1          独立 demo：上层只调 egl*，底层 EAGL，画三角形通过
            eglInitialize 1.5 A2-EAGL / eglChooseConfig / eglCreateContext(ES3) /
            eglCreateWindowSurface / eglMakeCurrent / eglSwapBuffers 全部 OK
```

缺失扩展（需在 P2 逐条评估影响）：`KHR_debug`、`OES_texture_float_linear`、`EXT_texture_storage`、`EXT_sRGB`、`EXT_multisampled_render_to_texture`、`EXT_disjoint_timer_query`。

MG 对 3.1/3.2 的能力有门控（`config/settings.cpp:605-606`、`gl/enable.cpp:203`），ES3.0 走降级路径，不阻塞。

---

## 3. 架构

```
MC (Java) → LWJGL → libGLESv2/MobileGlues（GLES 3.x 实现）
                          │  MG 内部通过它自己的 loader 找「宿主 GLES + EGL」
                          ▼
                   假 EGL（a2_eagl_egl）── 只做 EGL 语义
                          │
                          ▼
                   EAGL（EAGLContext + CAEAGLLayer/renderbuffer）
                          │
                          ▼
                    Metal（系统 GLES 驱动）
```

要点：**MG 本身是 GLES 实现**，它需要的是「宿主 GLES 3.x + 一套能用的 EGL」。我们的假 EGL 不改 MG，只替换它下面那一层。

---

## 4. 关键问题与对策

### 4.1 MG 怎么找宿主（实测源码）
```
config/gpu_utils.cpp:20-23
  gles3_lib[] = { "libGLESv3_CM.so", "libGLESv3.so" }
  egl_libs[]  = { "libEGL.so" }
  open_lib(names, override) —— 支持 override 直接给路径
gles/loader.cpp:88  支持 MG_ANGLE_DIR 环境变量指定目录
```
**对策**：两条同时用
1. 提供名为 `libEGL.dylib` / `libGLESv3.dylib` 的转发库（install_name 与 MG 期望名字一致），放进 `Frameworks/`
2. 启动时设置 `MG_ANGLE_DIR=<Frameworks 路径>`（若该版本认这个变量）

### 4.2 符号可见性（已知真机问题）
MG 会报 `[MG] SYMBOL THEFT: flat namespace resolves glXxx to 0x…, this layer's export is 0x…`。
**对策**：MG 后端时，ANGLE 的 `libEGL/libGLESv2` 用 `RTLD_LOCAL` 加载；假 EGL 同理。宿主 GL 入口一律通过 `eglGetProcAddress` 给出，避免进程级 flat namespace 抢先。

### 4.3 假 EGL 需要覆盖的面
P1 demo 已实现 23 个；P2 需要补的：
```
eglGetPlatformDisplay（若 MG 走扩展路径）
eglCreatePbufferSurface（离屏探测）
eglQueryContext / eglWaitGL / eglWaitClient / eglClientWaitSync（若 MG 建同步对象）
eglGetConfigs（枚举，已实现）
```
`eglGetProcAddress` 必须先查本模块导出表，再 `dlsym(RTLD_DEFAULT)`。

### 4.4 能力上报
- `eglQueryString(EGL_VERSION)` = `"1.5 A2-EAGL"`，`EGL_CLIENT_APIS = "OpenGL_ES"`
- `GL_VERSION` 由系统给出 `OpenGL ES 3.0 Metal - 99`，**不要伪装成 3.2**：伪装会让 MG 走未实现路径
- `eglChooseConfig` 支持 `EGL_RENDERABLE_TYPE=ES3_BIT`、RGBA8888、DEPTH 16/24、STENCIL 0/8

### 4.5 表面与尺寸
沿用 Air2 已有的宿主表面修复：`bounds × screen.scale` 得到像素尺寸，请求值/图层值/实现回报三者一致（`[A2-GLBRIDGE] drawable 尺寸核对` 判据）。

---

## 5. 实施步骤（每步都有判据）

| 步 | 内容 | 判据 |
|---|---|---|
| S1 | 把 demo 的 egl 实现整理成 `a2_eagl_egl.{h,m}`（Air2 内模块，已在 `feat/eagl-fakeegl` 分支有一版） | 设置页「假 EGL 自检」通过，`[A2-EAGL] selftest PASS` |
| S2 | 生成 `libEGL.dylib` 转发层（导出 egl*，内部调 a2_eagl_egl） | `nm -gU` 能看到 23 个 egl* 导出 |
| S3 | Air2 选 MG 时：不加载 ANGLE 的 libEGL/libGLESv2（或 RTLD_LOCAL），并把 MG 的宿主指向转发层 | 日志 `[A2-GLBRIDGE] 依赖加载旗标：RTLD_LOCAL`，MG 的 `SYMBOL THEFT` 消失 |
| S4 | 启动 1.17.1，观察 MG 的 EGL 初始化 | 出现 `[A2-FAKEEGL] eglInitialize / eglChooseConfig / eglCreateContext` |
| S5 | 让 MC 过 `GL caps init` | 日志出现 `GL version OpenGL ES 3.0`、无 `no OpenGL context current` |
| S6 | 出画面 | 帧回调连续、屏幕非纯黑 |

---

## 6. 风险与回退

| 风险 | 概率 | 回退 |
|---|---|---|
| MG 依赖某个缺失扩展（浮点纹理线性过滤等） | 中 | 按扩展逐条打桩/降级；记录影响的版本与特性 |
| MG 用 `eglGetPlatformDisplay` 等非常见入口 | 中 | 补实现，返回同一 display |
| 符号被抢（flat namespace） | 高（已见） | RTLD_LOCAL + 只经 eglGetProcAddress 暴露 |
| 性能不足（ES3.0 降级路径） | 中 | 先求通、再谈性能；必要时改走 ANGLE-Vulkan |
| EAGL 在未来 iOS 被移除 | 低 | 保留 ANGLE 路径作为默认兜底 |

---

## 7. 不做的事

- 不伪装 `GL_VERSION` 到 3.1/3.2（会让 MG 走未实现路径）
- 不改 MG 源码（只替换它下面的 EGL/GLES 宿主层）
- 不动 26.x（metallum 直连 Metal 更快）
- 不用 EAGL 跑 1.7–1.12（老版本走 KW/gl4es 那条线）

---

## 8. 待验证清单（P2 开始前）

1. MG 当前二进制里 `egl_libs[]` 是否仍为 `libEGL.so`（不同版本可能改过）
2. `MG_ANGLE_DIR` 在当前版本是否仍生效
3. 假 EGL 的 `eglGetProcAddress` 返回的 GL 入口是否够 MG 启动（20 个是 P0-2 的样本，实际可能更多）
4. 1.17.1 的 LWJGL 版本（3.2.x）对 EGL 的调用面

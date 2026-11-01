# Air2 · EAGL 框架设计（前置层）

> 状态：设计稿（未实现）｜ 目的：为 MC ≤1.12 的固定管线方案（上层渲染器）提供 iOS 原生 GLES 宿主
> 结论先行：**EAGL 只做“提供 GLES3 上下文 + 可绘制面”，不承担任何 GL 语义**；GL 固定管线的语义全部由 上层渲染器 负责。

---

## 0. 为什么是 EAGL，而不是 ANGLE

| 维度 | ANGLE（现状） | EAGL（本设计） |
|---|---|---|
| 角色 | 完整 GLES 实现（自带状态机 / 跳转表 / GLES1 模拟） | 只提供 ES 上下文 + renderbuffer 绑定 |
| 与 上层渲染器 叠加 | 两层各有状态机，语义互相猜（真机 SIGBUS 在 `gl::GLES1State::loadMatrix`） | 上层渲染器 独占 GL 语义，无冲突 |
| 依赖 | ANGLE（libEGL + libGLESv2，体积大、可执行页修补受限） | 系统 `OpenGLES.framework`（零额外体积） |
| 风险 | ANGLE 内部 bug 会传导（我们已踩） | 系统 GLES 弃用状态、性能未知（需 P0 实测） |

一句话：ANGLE 是「另一套 GL 实现」，EAGL 是「一块画布 + 一个上下文」。我们要的是后者。

---

## 1. 目标链路

```
Minecraft (GL 固定管线: glBegin/glMatrixMode/glLoadMatrix/glOrtho…)
        │  直接调用导出符号
        ▼
   上层渲染器（SimpleFPEWrapper）
        │  只要求宿主提供 GLES 3.x 入口（函数表/解析器）
        ▼
   EAGL 宿主层（本项目新增）
        │  EAGLContext(api=3) + renderbuffer(FBO)
        ▼
   系统 OpenGLES.framework → Metal（Apple 驱动内部实现）
```

**关键约束**：上层渲染器 不接管 EGL；它只要能拿到 GLES 入口。因此 EAGL 层的职责被压到最小。

---

## 2. EAGL 与 EGL 的语义对照（实现依据）

| EGL 概念 | EAGL 对应 | 说明 |
|---|---|---|
| `EGLDisplay` | 无（单设备） | 用一个常量句柄代替 |
| `EGLConfig` | 由 `EAGLContext.api` 隐含 | api=3 即 ES3；属性表只用于校验请求 |
| `EGLContext` | `EAGLContext` | 通过 `initWithAPI:EAGLRenderingAPIOpenGLES3` |
| `EGLSurface`（window） | `CAEAGLLayer` 或 renderbuffer | 无真实窗口时用 renderbuffer + FBO |
| `eglMakeCurrent` | `[EAGLContext setCurrentContext:]` | **同一线程只有一份当前上下文** |
| `eglSwapBuffers` | `presentRenderbuffer:` | 需先绑定 color renderbuffer |
| `eglGetProcAddress` | `dlsym(OpenGLES.framework)` | ES3 部分符号可能需要 `glGetStringi` 探测 |
| `eglQuerySurface` | 读 renderbuffer 尺寸 | 用于分辨率/缩放校验 |

---

## 3. 对外接口（建议最小集）

宿主层做成一个独立 dylib（`liba2eaglhost.dylib`），导出两套东西：

### 3.1 给启动器用的 C API（我们自己掌控）

```c
// 生命周期
int  a2_eagl_init(void);                                  // 0=OK
int  a2_eagl_create_context(int apiVersion /*3*/);         // 返回 0/错误码
int  a2_eagl_bind_drawable(void *caEAGLLayerOrUIView, int w, int h, float scale);
int  a2_eagl_make_current(void);
int  a2_eagl_present(void);
void a2_eagl_teardown(void);

// 给 上层渲染器/gl4es 家族的入口供给
void *a2_eagl_getprocaddress(const char *name);           // 只解析 GLES 入口
const char *a2_eagl_backend_name(void);                   // "eagl-es3"
```

### 3.2 假 EGL 兼容层（仅在 上层渲染器 需要 EGL 时启用）

```
eglGetDisplay / eglInitialize / eglChooseConfig / eglCreateContext /
eglCreateWindowSurface / eglMakeCurrent / eglSwapBuffers /
eglGetProcAddress / eglGetError / eglTerminate
```
实现要求：**全部转调 3.1**，不做第二套状态；`eglChooseConfig` 只校验 `RENDERABLE_TYPE` 与 `SURFACE_TYPE`，不匹配就返回 0 个 config（让调用方显式失败，而不是静默降级）。

---

## 4. 上下文与绘制面

### 4.1 上下文
- 一律 `EAGLRenderingAPIOpenGLES3`（上层渲染器 需要 GLES3 做 shader 生成）
- 若设备不支持 ES3（理论不存在，A8+ 都支持），**直接失败**，不降级到 ES2（语义不全，会给出错误画面）
- `EAGLContext` 与线程绑定：`a2_eagl_make_current` 内部记录 `(thread, ctx)`，重复调用要幂等

### 4.2 绘制面（两条路径，按场景选）
1. **renderbuffer + FBO（默认）**：不依赖 CAEAGLLayer，尺寸可控，适合我们这种“宿主表面由 SDL/GLFW 托管”的架构
2. **CAEAGLLayer（备选）**：需要真实 CALayer 时用；必须设 `contentsScale`，否则 Retina 下会糊

### 4.3 尺寸与缩放
- 逻辑尺寸 = 宿主 view 的 points；像素尺寸 = points × `UIScreen.scale`
- 必须校验“请求的像素尺寸”与“renderbuffer 实际尺寸”一致，不一致要打判据（历史坑：实现方忽略请求尺寸）

---

## 5. 线程模型

| 场景 | 规则 |
|---|---|
| 创建上下文 | 任意线程，但必须在 `make_current` 之前 |
| 渲染调用 | 只在“持有 current context”的那个线程 |
| 上下文切换 | 必须成对保存/恢复（`EAGLContext currentContext`） |
| 与 ANGLE 共存 | **禁止**在同一线程交替：两边都改线程级 current，切错就画到黑图上 |

推荐：渲染线程单线程独占，EAGL 层内部用 `pthread_getspecific` 记录绑定关系。

---

## 6. 符号隔离（必须做，否则必踩）

现状风险：我们以 `RTLD_GLOBAL` 加载 ANGLE 的 `libGLESv2`，它会把 `gl*` 暴露成全局，可能顶掉系统 GLES 的符号。

措施：
1. EAGL 路径下，ANGLE **一律不加载**（不同时启用两条 GL 栈）
2. 若未来要共存：ANGLE 改 `RTLD_LOCAL`，并只通过函数表调用，禁止依赖全局符号解析
3. 上层渲染器 拿到的入口表由 `a2_eagl_getprocaddress` 提供，**不从全局 dlsym 拿**

---

## 7. 错误处理与判据

每条关键路径必须有可 grep 的判据行（沿用项目习惯）：

```
[A2-EAGL] init rc=… api=ES3
[A2-EAGL] context created ctx=…
[A2-EAGL] drawable rb=%dx%d scale=%.2f（请求 %dx%d）
[A2-EAGL] makeCurrent tid=… rc=…
[A2-EAGL] present frame=… ms=…
[A2-EAGL] teardown
```

失败时返回明确错误码，不做“静默回退到 ANGLE”——回退会掩盖问题（历史教训：ANGLE 回退掩盖 ES3 config 不匹配）。

---

## 8. 与现有桥的关系

| 现有 | 变化 |
|---|---|
| `a2_gl_bridge.m`（EGL + ANGLE/MG/KW） | 保留，作为 **26.x / 1.13+** 的路径 |
| EAGL 宿主层 | 新增，只服务 **≤1.12（上层渲染器）** 路径 |
| 渲染器清单 | 新增一项 `EAGL + 上层渲染器`，默认仅用于 ≤1.12.2（可被用户显式选择覆盖） |

两条路径**互斥**：一次启动只允许初始化其中一条（避免全局符号/线程 current 冲突）。

---

## 9. 风险与未知

| 风险 | 影响 | 验证方式 |
|---|---|---|
| iOS 26 上系统 GLES 是否仍可用 | 决定性 | P0 探针：建 EAGLContext(api=3) 并读 `GL_VERSION` |
| 系统 GL 驱动性能 | 帧率 | 与 ANGLE 同场景对比（标题页 + 一个区块） |
| 上层渲染器 对入口表的要求 | 接入复杂度 | 读其 `backend/loader.cpp` 的取入口方式 |
| 系统 GL 的扩展缺失（如某些 FBO 格式） | 画面异常 | P0 后跑一遍能力矩阵 |
| Apple 未来移除 OpenGLES | 长期 | 记录为技术债：终局仍是 Metal 直连 |

---

## 10. P0 验证计划（先做这个，再谈接入）

**P0-1（半天）EAGL 可用性探针**
- 独立 dylib：建 `EAGLContext(api=3)` → 建 renderbuffer/FBO → 清屏 → `present`
- 判据：`glGetString(GL_VERSION)` 返回 ES 3.x 且无崩溃
- 失败 ⇒ 整条路线作废，回到 ANGLE + 上层渲染器（并重新评估兼容性）

**P0-2（1–2 天）假 EGL 层**
- 用 3.2 的 10 个函数打通“创建/绑定/呈现”闭环
- 判据：一个纯 GLES3 的三角形能通过这层画出来

**P0-3（2–3 天）上层渲染器 接线**
- 上层渲染器 以动态库形式加载，入口由 EAGL 层提供
- 判据：MC 1.7.10 能过 `GL caps init` 并打出 `OpenGL:` 信息（当前卡点）

**P1（1–2 周）1.7.10 进主菜单**

---

## 10. 能力边界：iOS 系统 GLES 只到 ES 3.0（重要约束）

Apple 的系统 OpenGL ES **停在 3.0**（3.1/3.2 从未提供），且已标记弃用、只做维护。这直接决定了 EAGL 的适用范围：

| 目标版本 | 需要的能力 | ES 3.0 是否满足 | 结论 |
|---|---|---|---|
| MC ≤1.12 | GL 2.1 语义：shader、MRT、VAO、纹理数组、instancing | ✅ 满足 | **EAGL 可用** |
| MC 1.17–1.21 | GL 3.2 core：compute shader、SSBO、image load/store、显式 uniform | ❌ 缺 compute/SSBO | EAGL 不可用 ⇒ 仍走 MG/ANGLE |
| MC 26.x | renderpearl | 无需 GL | metallum |

因此在**默认策略**里 `EAGL + 上层渲染器` 优先用于 ≤1.12.2；但 EAGL 宿主层本身是**通用**的（见 §12），1.13+ 可由 MG 挂接（能力按 ES3.0 实测，不假设满血）。一旦检测到 1.13+ 请求某个后端而该后端在 ES3.0 上不可用，应给出明确阻断文案而不是降级运行。

长期风险（记为技术债）：Apple 把系统 OpenGL ES 标记为 **deprecated（弃用）**，但**目前仍可用、也未宣布移除时间表**——所以这条路径现在完全可走。风险只在于未来某次 iOS 大版本若真的移除 `OpenGLES.framework`，≤1.12 需要转成“自研 Metal 直连”或继续依赖 ANGLE；在那之前不必提前规避。

---

## 12. 定位修正：EAGL 是**通用 GL 宿主**，不是 ≤1.12 专用

按产品要求，EAGL 层要能被**多个渲染器复用**，包括 1.17+ 的 MobileGlues。因此这一层只提供三件事：

1. **GLES 上下文**（`EAGLContext`，ES3.0）
2. **可绘制面**（renderbuffer + FBO，或 CAEAGLLayer）
3. **入口解析**（`a2_eagl_getprocaddress`，只解析 GLES/EGL 名字）

它**不含任何渲染器语义**：谁挂在上面，谁负责 GL 语义与状态机。

| 后端 | 挂 EAGL 的可行性 | 说明 |
|---|---|---|
| 上层渲染器（如 MG / KW） | ✅ 主目标 | 只要宿主给 GLES3 入口；固定管线语义由它自己实现 |
| MobileGlues（1.17+） | ⚠️ 可跑但有代价 | MG 官方最低 GLES 3.0（最佳 3.2）⇒ 在 ES3.0 上能启动，但 compute/SSBO/image load-store 缺失，相关特效或 1.18+ 特性会降级或不可用 |
| KW / NG-GL4ES | ⚠️ 备选 | 它自带完整转译（含 EGL 接管）；挂 EAGL 需让它只当「GL 语义层」，不要再自己建上下文 |
| metallum（26.x） | ❌ 不适用 | 直连 Metal，不经过 GL；EAGL 对它没有意义 |

**结论**：EAGL 的价值是「把 iOS 上 GL 的宿主收敛成一层」，让后端可替换；但**不能因此声称 1.17+ 在 ES3.0 上功能完整**——真实能力要在接入后按版本逐项验证（尤其 1.18 之后的新渲染特性）。

---

## 13. 不做的事（明确排除）

- 不在 EAGL 层里做任何 GL 状态模拟（那是 上层渲染器 的职责）
- 不做“EAGL 与 ANGLE 动态切换”（同一启动只走一条）
- 不为 ES2 降级（上层渲染器 需要 ES3）
- 不碰 26.x / 1.13+ 的现有渲染路径

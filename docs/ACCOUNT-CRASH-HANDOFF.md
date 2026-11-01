# 账号页闪退：符号隔离修复方案（eagl 分支）

> 结论先说：**不用 CPU 软渲染，也不用改系统类**。根因是我们自己把 GL/EGL 实现塞进了进程的全局符号表，
> 修法是把加载方式改成 `RTLD_LOCAL`，并且只从**句柄**解析我们需要的符号。
> 日期：2026-11-01 ｜ 分支：`feat/eagl-default` / `feat/plugin-merge`

---

## 1. 症状

- 账号管理页点「离线模式」或「第三方登录」→ 进程直接消失（不是回启动器）。
- 与输入框内容无关，点按钮即崩。
- 同设备上 `main` 分支不崩，`eagl` 分支崩。

## 2. 崩溃证据（两份 .ips，栈完全一致）

```
Air2-2026-11-01-103650.ips
Air2-2026-11-01-144104.ips

exception : EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0
thread    : com.apple.main-thread
stack     :
  CoreImage  CI::GLContext::GLContext(...)
  CoreImage  +[CIContext(Internal) internalContextWithEAGLContext:options:]
  CoreImage  -[CIContext initWithOptions:]
  CoreImage  +[CIContext contextWithOptions:]
  CoreUI     +[CUIShapeEffectStack sharedCIContext]
  CoreUI     -[CUICatalog imageByStylingImage:stylePresetName:...]
  UIKitCore  -[UIImage _imageWithStylePresets:tintColor:traitCollection:]
  UIKitCore  -[UIImageView _renditionForSource:size:symbolConfiguration:...]
```

第一份日志的时间线：进程 23:59 启动，10:36 崩，**连续运行 10.5 小时**，期间启动过游戏；崩溃瞬间进程内没有任何 GL/EGL/ANGLE 镜像。

## 3. 根因：符号污染（flat namespace）

```
 a2_gl_bridge 用 RTLD_GLOBAL 加载 ANGLE 的 libEGL / libGLESv2（以及渲染器 dylib）
 ⇒ 这些库导出的 egl* / gl* 进入进程的**全局符号空间**
 ⇒ 系统框架（CoreImage / CoreUI）建 EAGL 上下文时，解析到的是**我们的实现**
 ⇒ 它以为拿到的是系统 OpenGL ES，实际是 ANGLE 语义的实现 ⇒ CI::GLContext 构造时解引用 0x0
```

为什么 main 不崩：main 分支不会在启动器常驻期间把 ANGLE 以 `RTLD_GLOBAL` 拉进进程（只在游戏内加载、退出卸载），
进程干净时 CoreImage 解析到的是系统真正的 OpenGL ES。

> 两个已被证伪/被否决的结论，别再走：
> ① “我们导出的 23 个 egl\* 全局符号被系统框架误用” —— `main` 同样有 `a2_eagl_egl.m`，无此差异；
> ② “用 CPU 软渲染绕开” —— 能躲开崩溃但属降级，性能与画质都受影响，**已明确拒绝并删除实现**。

## 4. 修法：加载模式隔离（默认 LOCAL）

### 4.1 代码改动（`Natives/Renderer/a2_gl_bridge.m`）

```
 新增 a2_gl_bridge_use_global_rtld()：
   默认返回 0（LOCAL）；环境变量 A2_GL_RTLD=global|GLOBAL|1 时返回 1（GLOBAL，即旧行为）

 新增 a2_gl_bridge_rtld_flags()：
   RTLD_LAZY | (LOCAL ? RTLD_LOCAL : RTLD_GLOBAL)

 三处 dlopen 统一改用该 flags：
   ① 渲染器镜像      gRendererHandle = dlopen(rendererPath, a2_gl_bridge_rtld_flags())
   ② ANGLE libEGL    gEglHandle      = dlopen(eglPath,       a2_gl_bridge_rtld_flags())
   ③ ANGLE libGLESv2 gGlesHandle     = dlopen(glesPath,      a2_gl_bridge_rtld_flags())
```

### 4.2 符号解析规则（关键不变量）

```
 我们自己要用的 egl* / gl*：一律 dlsym(句柄, 名字)，句柄来自上面的 dlopen
 禁止 RTLD_DEFAULT / dlsym(RTLD_DEFAULT, ...)：那等于又回到全局查找
 MG 侧：靠 MG_DIRECTORY_PATH 自己 dlopen ANGLE，再用 eglGetProcAddress / dlsym 取入口
 LWJGL 侧：按 org.lwjgl.opengl.libname 自己 dlopen 渲染器，拿自己的句柄解析 gl*
 ⇒ 三方都不依赖 flat namespace
```

### 4.3 判据行

```
 [A2-GLBRIDGE] 加载模式=RTLD_LOCAL(隔离)（A2_GL_RTLD=(默认)）⇒ 渲染器镜像不进入 flat namespace
 回退时该行为：加载模式=RTLD_GLOBAL …
```

### 4.4 回退开关

```
 环境变量 A2_GL_RTLD=global → 恢复旧的全局加载（一处回退，不需要改代码重编）
```

## 5. 验证矩阵（缺一不可）

| # | 场景 | 判据 |
|---|------|------|
| 1 | 1.20.1 + MobileGlues | 能进标题界面；日志 `加载模式=RTLD_LOCAL`；无 `dlopen/dlsym 失败` |
| 2 | 1.16.5 + MobileGlues | 同上 |
| 3 | 冷启动 → 账号页点「离线」 | 不崩 |
| 4 | 冷启动 → 账号页点「第三方登录」 | 不崩 |
| 5 | 进游戏 → 退出 → 再点账号页 | 不崩（**最关键**：退出后镜像仍在进程内，正是原崩溃路径） |
| 6 | 1.13–1.18 + SFPEW | GL 门面由 SFPEW 提供，不再 `no OpenGL context current` |

第 5 条是这次崩溃的真实复现路径（崩溃进程跑了 10.5 小时且中间开过游戏）。

## 6. 风险与应对

```
 风险 A：MG 隐式依赖全局符号（内部 dlsym(RTLD_DEFAULT, "eglGetCurrentContext") 之类）
   ⇒ 现象：进游戏崩或上下文建不出来
   ⇒ 应对：A2_GL_RTLD=global 立即回退；再在 MG 侧定位具体符号，改为显式句柄

 风险 B：第三方渲染器（KW / ng-gl4es / gl4es）内部互相找符号
   ⇒ 应对同上；必要时只对 ANGLE 与 MG 生效，逐渲染器放开

 风险 C：SFPEW 兼容层后端解析
   ⇒ SFPEW_EGL 指向渲染器 dylib，其内部用 dlopen + eglGetProcAddress，不依赖 flat namespace
```

## 7. 相关文件

```
 Natives/Renderer/a2_gl_bridge.m    加载模式开关 + 三处 dlopen 统一 flags + 判据行
 Air2/App/A2AppDelegate.m           已移除 CIContext 兜底调用
 Air2/App/A2CIContextGuard.m        已删除（CPU 软渲染兜底，明确不再使用）
 cmake/a2_frameworks.cmake          已移除 CoreImage framework
```

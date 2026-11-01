# 账号页闪退（eagl 分支）交接文档

> 状态：**已定位根因并落地一版兜底；真机尚未确认修复。**
> 日期：2026-11-01 ｜ 分支：`feat/eagl-default`

---

## 1. 症状

- 账号管理页点「离线模式」或「第三方登录」→ App 直接闪退（不是回到启动器，是进程消失）。
- 与输入框内容无关，点按钮即崩。
- 该设备上 `main` 分支的包不崩，`eagl` 分支的包崩。

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

第一份日志还有一个关键时间线：进程 23:59 启动，10:36 崩，**连续运行 10.5 小时**，期间启动过游戏；崩溃瞬间进程内**没有任何 GL/EGL/ANGLE 镜像**。

## 3. 根因

CoreUI 给 SF Symbol 做样式化渲染时会懒加载共享 `CIContext`，而 `CIContext` 走 **EAGL（OpenGL ES）** 建上下文时，在 `CI::GLContext` 构造函数里解引用空指针。

为什么在我们这崩、在 main 不崩：

```
 eagl 链路会用 RTLD_GLOBAL 把 ANGLE 的 libEGL / libGLESv2 加载进进程的 flat namespace
 （MG 依赖这一点才能找到宿主实现）
 且 2026-10-31 我们把「退出游戏时 dlclose 后端镜像」改成了「不卸载」
 ⇒ 这两个库在整个进程生命周期都在，系统框架解析 EGL/GL 入口时命中的不是它预期的实现
 ⇒ CoreImage 建 EAGL 上下文失败 ⇒ 0x0 解引用
```

> 之前一版结论（“我们导出的 23 个 egl\* 全局符号被系统框架误用”）已证伪：`main` 分支同样有 `a2_eagl_egl.m`，没有该差异。

## 4. 已落地的修法（A2CIContextGuard）

新增 `Air2/App/A2CIContextGuard.m`，在 `AppDelegate didFinishLaunching` 最早期安装：

```
 目标：+[CIContext internalContextWithEAGLContext:options:]
 做法：忽略传进来的 EAGL 上下文，改用 kCIContextUseSoftwareRenderer=YES 建 CIContext
 边界：只替换这一条内部方法；CIContext 其它入口原样放行
 判据：[A2-CI-GUARD] 已接管 internalContextWithEAGLContext:options: ⇒ 改用软件渲染器
 降级：找不到该方法时打 [A2-CI-GUARD] 未找到… ⇒ 不拦截（系统行为不变）
```

配套构建改动：`cmake/a2_frameworks.cmake` 增加 `CoreImage`（否则链接报 `undefined symbol: _kCIContextUseSoftwareRenderer`）。

软件渲染只影响 CoreUI 的图标样式化（一次性小图），不影响游戏渲染。

## 5. 验证方法（尚未执行完）

```
 1. 冷启动（杀进程重开）→ 不进游戏 → 点「离线」→ 看点「第三方」
 2. 期望：不崩；日志出现 [A2-CI-GUARD] 已接管… 一行
 3. 反例：仍然崩 → 说明 CoreUI 走的不是这个入口，转第 6 节方案 B
```

## 6. 备选方案（按代价排序）

```
 A. 已做：CoreImage 走软件渲染（拦截 internalContextWithEAGLContext:）
 B. ANGLE 改 RTLD_LOCAL 加载（最干净，但 MG 的 flat namespace 依赖需先验证）
 C. 游戏退出后卸载 ANGLE（回到 dlclose；会重新引入“悬空绑定”风险，不推荐）
 D. 受影响视图改用 UIGraphicsImageRenderer 预渲染的位图图标（彻底不进 CoreImage，改动面大）
```

## 7. 已知边界与风险

- 该兜底是**系统方法替换**，属于临时手段；若系统改成走 Metal 建 CIContext，这段可以删。
- 软件渲染 CIContext 比 GPU 慢，但只用于图标样式化，不参与游戏绘制。
- 未验证 iOS 26 / iOS 16 上的行为（只在 iPhone18,1 / iOS 27.0.1 上复现过崩溃）。
- 该修法不解决“ANGLE 全局符号污染”本身，只绕开了受影响的那条路径；后续若出现别的系统框架（地图/视频/相机）也踩到这类问题，应回到方案 B。

## 8. 相关文件

```
 Air2/App/A2CIContextGuard.m            新增：CIContext 兜底
 Air2/App/A2AppDelegate.m               启动最早期调用 A2CIContextGuardInstall()
 cmake/a2_frameworks.cmake              新增 CoreImage framework
 Natives/Renderer/a2_gl_bridge.m        （背景）ANGLE 以 RTLD_GLOBAL 加载、teardown 不再 dlclose
```

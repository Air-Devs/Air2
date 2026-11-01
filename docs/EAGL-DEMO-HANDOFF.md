# EAGL Demo · 交接文档

> 用途：一个**完全独立**的最小 iOS App，用来验证 `EAGL(ES3)` 在真机上能否使用。
> 不碰 Air2 仓库、不改 Air2 任何代码；失败也不污染主线。

---

## 1. 这个 demo 到底测什么

只有五步，没有别的：

```
 1 建 EAGLContext(api = kEAGLRenderingAPIOpenGLES3)
 2 建 color + depth renderbuffer，绑到 FBO
 3 编译最小 GLES3 着色器（vertex + fragment），画一个旋转三角形
 4 presentRenderbuffer 上屏，连续 300 帧，测平均帧时间
 5 屏幕角落显示 + NSLog 打印：GL_VERSION / GL_RENDERER / GL_VENDOR / 平均帧时间
```

## 2. 它能证明什么

```
 · iOS 27 上 EAGL 是否还能建 ES3 上下文（苹果把 GLES 标 deprecated，但未移除）
 · 系统 GLES 实际给出的版本与能力（ES 3.0，无 3.1/3.2）
 · 帧率量级 —— 决定 EAGL 这条路值不值得继续投入
```

## 3. 它不能证明什么（先说清楚，避免误判）

```
 · 不验证「假 EGL 层」（那是 EAGL 适配计划的 P1）
 · 不验证 MobileGlues 能否挂在 EAGL 上（那是 P2）
 · 不证明任何 MC 版本能跑
```

---

## 4. 实现要点（给下一次接手的人）

### 4.1 单文件 ObjC（约 150 行）
- `UIApplicationMain` + 一个最小 `UIViewController`（不写 storyboard）
- `EAGLContext` 用 `initWithAPI:kEAGLRenderingAPIOpenGLES3`
- 用 `renderbufferStorage:fromDrawable:` 或直接 `glRenderbufferStorage`（不依赖 CAEAGLLayer 也可以，用 FBO + renderbuffer 更简单）
- 着色器源码直接内联字符串（GLSL ES 3.00）
- `CADisplayLink` 驱动渲染；计数到 300 帧后 `exit(0)` 或打印汇总后停
- 字体信息用 `UILabel`（`GL_VERSION` 等字符串从 `glGetString` 取）

### 4.2 不用 xcodeproj，手工组装
```bash
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=14.0 \
  -framework UIKit -framework OpenGLES -framework QuartzCore \
  -o EAGLProbe main.m

mkdir -p Payload/EAGLProbe.app
cp EAGLProbe Info.plist Payload/EAGLProbe.app/
```

`Info.plist` 关键字段：
```
 CFBundleIdentifier  = dev.airdevs.eaglprobe
 CFBundleExecutable  = EAGLProbe
 CFBundleName        = EAGLProbe
 CFBundleVersion     = 1
 CFBundleShortVersionString = 1.0
 MinimumOSVersion    = 14.0
 UILaunchScreen      = {}            # 必须，否则启动黑屏
```

### 4.3 出包
```
 未签名： zip -qry EAGLProbe.ipa Payload
 TrollStore： ldid -S<entitlements> 后打 .tipa（沿用项目既有的 entitlements）
```

---

## 5. 真机判据

装上点开，只看三点：

```
 ① 屏幕上出现一个转动的三角形 ⇒ EAGL(ES3) 可用
 ② 角落文字显示 OpenGL ES 3.0 / Apple GPU 型号 ⇒ 能力确认
 ③ 日志（Console 或 lastlog）出现：
      [EAGL-PROBE] version=OpenGL ES 3.0 renderer=<...> vendor=<...> fps=<n> ms=<t>
```

结论映射：

| 现象 | 含义 | 下一步 |
|---|---|---|
| 三角形 + ES 3.0 | EAGL 可用 | 继续 P1 假 EGL 层 |
| 建上下文失败（`nil`） | EAGL 在该 iOS 版本不可用 | 整案改用 ANGLE（回到现状路线） |
| 能建上下文但黑屏 | renderbuffer/FBO 配置问题 | 先修 demo，再判断 |
| 崩溃 | 系统 GLES 在该机型有问题 | 记录机型/iOS 版本，整案重估 |

---

## 6. 当前状态

```
 代码：未写（子代理在 2026-10-25 21:47 被停止，未产出文件）
 出包：无
 文档：本文
 阻塞：无（只差实现）
```

---

## 7. 为什么不能在 Mac 上测

`EAGLContext` / `CAEAGLLayer` 是 **iOS 专属**（UIKit + OpenGLES 体系），macOS 上没有对应实现（macOS 用 `NSOpenGL`/`CGL`）。所以：

```
 Mac 上编、Mac 上不能跑 ⇒ 必须真机
 iOS 模拟器：GLES 支持不稳定，且本机模拟器曾出现“装应用即卡死”
```

结论：这一步绕不开真机，但成本很低（一个几十行的小 App，一次出包）。

---

## 8. 下次开工的下一步

1. 写 `main.m` + `Info.plist`（按 §4）
2. Mac 上 clang 编译 → 手工组装 `.app` → 出 `.ipa` / `.tipa`
3. 推到设备（IP 会漂移，推前先扫 53317 端口）
4. 装、点开、看三角形与 `[EAGL-PROBE]` 日志
5. 把结论回填到 `docs/EAGL-ADAPTER-PLAN.md` 的 P0-1

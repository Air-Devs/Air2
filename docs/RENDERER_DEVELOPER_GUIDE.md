# 渲染器开发者指南

> 面向**渲染器作者**：给你一个 `.dylib`，怎么让它在 Air2 里出现并被选中。
> 想了解 Air2 内部渲染器系统怎么运作的，看 [RENDERER_REWRITE.md](RENDERER_REWRITE.md)。

---

## 0. 一句话

**Air2 的渲染器就是一个提供 EGL + GLES 符号的 dylib。** 你实现这些符号，打成 zip 或者做成一个 App，用户装上就能在设置页里选到。

不用改 Air2 源码，不用重新编译启动器。

---

## 1. Air2 会怎么用你的 dylib

```
JavaLauncher 注入
  -Dorg.lwjgl.opengl.libname=<你的库名去掉 lib 前缀和 .dylib 后缀>
       ↓
LWJGL 加载你的 dylib，游戏侧直接调 GL 函数
       ↓
gl_bridge 用 dlopen 加载你的 dylib，dlsym 取 EGL 符号
       ↓
gl_bridge 建 EGL context / surface，每帧调 eglSwapBuffers 呈现
```

两条路都指向同一个 dylib：**LWJGL 那条走 GL 入口，gl_bridge 那条走 EGL 入口**。所以你的库要能同时被两边用。

### 必须导出的符号（21 个）

`gl_bridge.m` 里 `dlsym_EGL` 会逐个解析，缺一个就初始化失败：

```c
eglGetDisplay
eglInitialize
eglTerminate
eglChooseConfig
eglGetConfigAttrib
eglCreateWindowSurface
eglCreatePbufferSurface
eglCreateContext
eglDestroyContext
eglDestroySurface
eglMakeCurrent
eglGetCurrentContext
eglGetCurrentSurface
eglGetError
eglSwapBuffers
eglSwapInterval
eglBindAPI
eglQuerySurface
eglReleaseThread
eglGetProcAddress
eglGetPlatformDisplay
```

GL / GLES 函数**不需要**在这里导出 —— 通过 `eglGetProcAddress` 提供即可，LWJGL 也会自己从库里找。

### 符号解析失败会怎样

| 情况 | 行为 |
|---|---|
| dylib 不存在 | `EGLBridge: failed to load <路径> for renderer <名>` → 启动失败 |
| 少数符号缺失 | `EGLBridge: failed to resolve <符号>` → 启动失败 |
| 初始化失败 | `[egl_bridge] pojavInitOpenGL failed (br_init() returned 1)` |

用 `amfid` 校验失败的 dylib 也会在这一步挂掉，见第 6 节签名说明。

---

## 2. 打包：三种方式

三种方式并存，按你的分发条件选。

### 方式 A · zip 导入（非越狱也能用）

用户从文件 App 里选 zip → Air2 解压到 `Documents/Air2/Renderers/<rendererId>/`。

```
myrenderer.zip
├── manifest.json          ← 必需
├── libmyrenderer.dylib    ← 你的库
└── libdep.dylib           ← 可选依赖，写进 dlopenLibPaths
```

适合作者分发：一个 zip 丢给用户就行。

### 方式 B · 直接丢目录

把 `.dylib` 拷进下面任一目录，下次进设置页自动出现：

| 目录 | 说明 |
|---|---|
| `Documents/Air2/Renderers/` | 用 Filza / 爱思助手直接放 |
| `/var/jb/usr/lib/air2-renderers/` | 越狱共享，多个启动器可以共用 |

**不需要 manifest 也能用**。没有 manifest 时：

- 显示名取文件名去掉 `lib` 前缀和 `.dylib` 后缀
- 没有描述、没有配置项，环境变量与 MC 版本范围走默认
- 用户在列表里能看到它，也能选中启动

想补信息的话，**在 dylib 旁边放一个同名 `.json`**（如 `libmyrenderer.dylib` 配 `libmyrenderer.json`），内容同第 3 节的 manifest。

> 这是发现流程的第 3 级「未识别」。能用，但用户看不到你的描述和配置项，正式分发建议还是提供 manifest。

### 方式 C · 独立 App（仅越狱，等价安卓的插件 APK）

做一个普通 iOS App，把 dylib 放在 `.app/` 里，`Info.plist` 加一个键：

```xml
<key>Air2RendererPlugin</key>
<string>renderer-manifest.json</string>   <!-- 相对 .app bundle 的路径 -->
```

或者直接内联：

```xml
<key>Air2RendererPlugin</key>
<dict>
  <key>formatVersion</key><integer>1</integer>
  <key>rendererId</key><string>com.example.mygl</string>
  ...
</dict>
```

Air2 启动时会扫 `/var/containers/Bundle/Application/*/*.app/Info.plist`，读到这个键就登记。

**这个路径只读 Info.plist，不会执行你 App 里的任何代码。** 你的 App 本体可以是空的，纯粹当容器。

> 为什么这条只在越狱可用：非越狱设备的沙盒禁止枚举其它 App，没有等价 API。安卓那边 `queryIntentActivities` 能做的事，iOS 只有越狱能做。

---

## 3. manifest.json

`formatVersion` 目前是 `1`。

```jsonc
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",       // 稳定唯一 ID，改了等于新渲染器
  "displayName": "MyGL",                   // 设置页显示名
  "description": "一句话描述",              // 可空
  "version": "1.0.0",
  "author": "你的名字",
  "homepage": "https://...",               // 可空

  "libraryLayout": "flat",                 // flat | separate
  "rendererGLPath": "libmyrenderer.dylib", // 相对包根
  "rendererEGLPath": "libmyrenderer.dylib",// 一般与 GL 相同
  "dlopenLibPaths": ["libdep.dylib"],      // 可选，按顺序预加载

  "minMCVer": "1.17",                      // 可空
  "maxMCVer": "1.21",
  "minSystemVersion": "14.0",              // iOS 版本下限
  "requiresJIT": false,                    // true 会提示用户开 JIT

  "ios": { "notes": "iOS 上的已知限制" },   // 可空

  "env": [
    { "type": "ToggleableEnv",  "key": "MYGL_DEBUG",   "title": "调试日志", "defaultOn": false },
    { "type": "SelectableEnv",  "key": "MYGL_BACKEND", "title": "后端",
      "values": [ {"value":"metal","title":"Metal"}, {"value":"vulkan","title":"Vulkan"} ],
      "defaultValue": "metal" },
    { "type": "CustomizableEnv","key": "MYGL_SCALE",   "title": "渲染缩放",
      "customDefault": "1.0" }
  ]
}
```

### 字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `formatVersion` | 是 | 目前只认 `1` |
| `rendererId` | 是 | 全局唯一。建议用反向域名。**这个值同时是设置页的存储键**，改了用户的旧选择就失效 |
| `displayName` | 是 | 可翻译前缀无意义，直接写最终显示文本 |
| `libraryLayout` | 否 | `flat`（默认，所有库在同一目录）或 `separate`（GL 与 EGL 分目录） |
| `rendererGLPath` | 是 | 相对 zip / bundle 根的路径 |
| `rendererEGLPath` | 否 | 缺省等于 `rendererGLPath` |
| `dlopenLibPaths` | 否 | 依赖库。**顺序有意义**，按数组顺序 dlopen |
| `minMCVer` / `maxMCVer` | 否 | 用于启动前检查。超范围时设置页会给提示，用户仍可强选 |
| `requiresJIT` | 否 | 置 true 时启动前会检查 JIT 状态 |
| `env` | 否 | 暴露给用户的配置项，见下 |

### `env` 三种类型

| `type` | UI 形态 | 写入行为 |
|---|---|---|
| `ToggleableEnv` | 开关 | 开 → 设 `key=value`（缺省 `"1"`），关 → 不设 |
| `SelectableEnv` | 下拉 | 选中项写 `key=value`（取自 `values[].value`） |
| `CustomizableEnv` | 输入框 | 用户输入原样写 `key=<输入>` |

`key` 就是环境变量名，Air2 在启动 JVM 前 `setenv` 好，你的库直接 `getenv` 读。

---

## 4. Air2 会给你设的环境变量

除了你自己 manifest 里声明 `env`，Air2 还会设这些，可以直接读：

| 变量 | 值 | 说明 |
|---|---|---|
| `AMETHYST_RENDERER` | 你的库文件名 | 例如 `libmyrenderer.dylib` |
| `AMETHYST_SFPEW_BACKEND` | 后端库名 | 仅当叠加 SimpleFPEWrapper 时 |
| `MOBILEGL_BACKEND_TYPE` | 后端类型 | 仅 MobileGL 系 |
| `GALLIUM_DRIVER` | `zink` | 仅 OSMesa 系 |
| `MVK_CONFIG_*` | 见下 | 仅 MoltenVK 系 |

MoltenVK 相关（`JavaLauncher.m:2163-2166`）：

```
MVK_CONFIG_RESUME_LOST_DEVICE=1
MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1
MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1
```

### 可选：自己声明 manifest 符号

如果你想被自动发现（而不是只靠文件名），在 dylib 里导出：

```c
__attribute__((visibility("default")))
const char *air2RendererManifestJSON(void) {
    return "{\"formatVersion\":1,\"rendererId\":\"com.example.mygl\",...}";
}
```

并且在文件里出现字符串 `AIR2RENDERER`（Air2 会先在 dylib 字节里搜这个标记，搜到才 dlopen 取符号 —— 这是为了避免对任意未知 dylib 执行 constructor）。

---

## 5. 调试

### 日志前缀

你的库打的日志和 Air2 的混在一起，建议用自己的前缀（如 `[MYGL]`），便于过滤：

```bash
# 设备上抓日志
grep -E "MYGL|EGLBridge|RenderDiag" /var/mobile/.../Documents/logs/log_*.log
```

### Air2 侧关键日志

| 前缀 | 含义 |
|---|---|
| `EGLBridge:` | dylib 加载、符号解析、EGL 初始化 |
| `[RenderDiag]` | 渲染诊断 |
| `[MG-Bridge]` | MobileGlues 引导 |
| `[SHADER-CAP]` | 着色器能力探测（会打印当前渲染器名） |
| `[RENDERER-GAP]` | gl4es 家族的延后初始化 |

### 确认自己有没有被选中

```bash
grep "\[SHADER-CAP\] renderer=" <日志文件>
```

这一行会打出当前实际生效的渲染器，如果显示的不是你的库名，说明回落了 —— 往上找 `RENDERER-GAP` / `EGLBridge:` 的失败原因。

---

## 6. 已知约束

### 签名

越狱环境下 Air2 用 `dyld_bypass_validation`（基于 xpnsec 的 DyldDeNeuralyzer，手动映射 Mach-O）绕过 dyld 校验，所以**未签名的 dylib 也能加载**。

但这不等于无条件可用：

- 你的 dylib 如果依赖其它库，那些库也要在 `dlopenLibPaths` 里列出来并一并分发
- 使用系统私有 API 的库在系统升级后可能失效

### 非越狱设备

| 能力 | 越狱 | 非越狱 |
|---|---|---|
| zip 导入 | ✅ | ✅ |
| 丢 dylib 进 `Documents/` | ✅ | ✅ |
| 独立 App 自动发现 | ✅ | ❌（沙盒禁止枚举其它 App） |
| 加载未签名 dylib | ✅ | ❌ |

非越狱设备上你的 dylib 必须由用户自签后重签进 Air2.app，或者走 zip 导入但库本身得是已签名的。

### MC 版本兼容

`minMCVer` / `maxMCVer` 只是**提示**，不会强制拦截。用户超范围选了也能启动 —— 所以你的库要自己处理不支持的版本，至少给出可读的报错而不是直接崩。

### 名字里不要带连字符

LWJGL 的 macOS 库名解析用正则 `(?:^|/)lib\w+(?:[.]\d+)*[.]dylib$`，`\w` **不包含 `-`**。所以 `libmy-gl.dylib` 这种名字会被误判成需要补 `lib` 前缀和 `.dylib` 后缀，最终找 `liblibmy-gl.dylib.dylib` 失败。

现有代码里 `libMobileGL-gles.dylib` 就中过招（`JavaLauncher.m:2186-2198` 有详细注释）。**用下划线，别用连字符。**

---

## 7. 最小可用示例

```
myrenderer.zip
├── manifest.json
└── libmyrenderer.dylib
```

`manifest.json`：

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.myrenderer",
  "displayName": "MyGL",
  "description": "实验性 GL-on-Metal 后端",
  "version": "0.1.0",
  "author": "you",
  "libraryLayout": "flat",
  "rendererGLPath": "libmyrenderer.dylib",
  "rendererEGLPath": "libmyrenderer.dylib",
  "minMCVer": "1.17"
}
```

`libmyrenderer.dylib` 导出第 1 节列出的 21 个 EGL 符号，`eglGetProcAddress` 返回你的 GLES 实现。

装法：设置 → 渲染器 → 导入，选 zip。

验证：进游戏 → 抓日志 → `grep "\[SHADER-CAP\] renderer="` 应该看到 `libmyrenderer.dylib`。

---

## 8. 参照现有实现

内置的 12 支渲染器都在 `Libraries/Frameworks/` 下，可以直接拿来对照：

| 库 | 类型 | 参考价值 |
|---|---|---|
| `libmobileglues.dylib` | GLES on Metal/Vulkan | 默认渲染器，最完整的实现 |
| `libtinygl4angle.dylib` | ANGLE 直出 Metal | 结构最简单，适合当模板 |
| `libgl4es_114.dylib` | 固定管线仿真 | 老版本 MC 兼容 |
| `libMobileGL.dylib` | MobileGL | 另一条 Metal 路线 |
| `libOSMesa.8.dylib` | 离屏 + SDL3 | 不走 EGL，走 OSMesa 桥 |
| `libvirgl_test_server.dylib` | VirGL | 虚拟化 GL |

其中 MobileGlues / GL4ES / NG-GL4ES / GL4ESZL2 / VGPU 这几支有构造函数不跑的问题，需要在真实 context current 之后由宿主补调 `initialize_gl4es()`（Air2 在 `gl4es_family_boot.m` 里做）。你自己写的话，**建议把初始化放在第一次 `eglMakeCurrent` 成功后**，不要依赖 constructor。

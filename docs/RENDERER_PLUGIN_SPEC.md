# Air2 渲染器插件规范 v1

> 一个 `.air2plugin`（zip）就是一个渲染器。导入后自动出现在「设置 → 渲染」里，无需重启。

---

## 一、包结构

```
myrenderer.air2plugin          ← 就是个 zip，扩展名改一下
├── manifest.json              ← 必需，渲染器描述
├── icon.png                   ← 可选，列表图标（建议 128x128）
└── libs/
    └── ...                    ← 动态库，数量取决于库布局（见 2.3）
```

**注意 `libs/` 里放几个文件，取决于你的库是怎么编的** —— 有三种情况，
manifest 里用 `libraryLayout` 字段声明。这是 iOS 上特有的问题：
Android 的 glName / eglName 总是两个独立的 `.so`，而 iOS 上很多是合并的。

**注意**：`libs/` 下的文件必须是 **iOS 可加载的 `.dylib`**（不是 Android 的 `.so`）。
如果是为 FCL 做的 `.so` 插件，**不能直接用**，需要用 iOS 工具链重新编译。

---

## 二、manifest.json

### 2.1 最小示例

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",
  "displayName": "MyGL",
  "description": "基于 Mesa 的 GL 转译层",
  "version": "1.0.0",
  "author": "example",
  "rendererGLPath": "libs/libmygl.dylib",
  "rendererEGLPath": "libs/libmyegl.dylib"
}
```

### 2.2 完整示例

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",
  "displayName": "MyGL",
  "description": "基于 Mesa 的 GL 转译层",
  "version": "1.0.0",
  "author": "example",
  "homepage": "https://github.com/example/mygl",

  "rendererGLPath": "libs/libmygl.dylib",
  "rendererEGLPath": "libs/libmyegl.dylib",
  "dlopenLibPaths": [
    "libs/libmygl_deps.dylib"
  ],

  "minMCVer": "1.16.5",
  "maxMCVer": "1.21.4",

  "env": [
    { "type": "NormalEnv",   "key": "MESA_GL_VERSION_OVERRIDE", "value": "4.0" },
    { "type": "ToggleableEnv","key": "ZINK_DEBUG", "value": "compact",
                               "title": "Zink 调试", "toggle": false },
    { "type": "SelectableEnv","key": "MESA_LOADER_DRIVER_OVERRIDE",
                               "title": "驱动",
                               "check": true,
                               "items": {
                                 "defaultValue": "zink",
                                 "values": [
                                   { "value": "zink",   "label": "Zink (Vulkan)" },
                                   { "value": "virpipe","label": "VirGL" }
                                 ]
                               } },
    { "type": "CustomizableEnv","key": "MESA_SHADER_CACHE_MAX_SIZE",
                                "title": "着色器缓存大小",
                                "defaultValue": "512M" }
  ],

  "ios": {
    "minSystemVersion": "14.0",
    "requiresJIT": false,
    "notes": "需要 Metal 设备"
  }
}
```

---

## 三、字段说明

### 3.1 顶层

| 字段 | 必需 | 说明 |
|---|---|---|
| `formatVersion` | ✅ | 目前固定 `1`；**其它值一律拒装**（不按 v1 猜） |
| `rendererId` | ✅ | 全局唯一，建议反向域名 |
| `displayName` | ✅ | 列表显示的短名 |
| `description` | | 一句话说明 |
| `version` | | 插件版本 |
| `author` | | 作者 |
| `homepage` | | 主页链接（**只解析、本版不展示**，插件详情页再接） |
| `rendererGLPath` | ✅ | GL 库相对路径（相对包根） |
| `rendererEGLPath` | ✅ | EGL 库相对路径 |
| `dlopenLibPaths` | | 额外需要预加载的库（依赖） |
| `minMCVer` / `maxMCVer` | | 支持的 MC 版本范围 |
| `env` | | 环境变量列表（见 3.2） |
| `ios` | | iOS 特有信息（见 3.3） |

### 3.1.1 库布局（libraryLayout）★ 重要

iOS 上 GL 与 EGL 可能编在同一个 dylib 里，也可能分开。**必须显式声明**，
否则加载顺序会错。

| 值 | 含义 | 典型例子 | libs/ 里放几个 |
|---|---|---|---|
| `combined` | **GL 与 EGL 在同一个 dylib** | **MobileGlues、NG-GL4ES** | 1 个 |
| `separate` | GL 与 EGL 各一个 dylib | Zink（libglxshim + libEGL_mesa）、VirGL | 2 个 |
| `glOnly` | 只有 GL，不需要 EGL | 部分 OSMesa 直连 | 1 个 |

**缺省时的自动推断**：

```
rendererEGLPath 为空            → combined
rendererEGLPath == rendererGLPath → combined
两个路径都非空且不同             → separate
```

**推荐显式写出来**，别依赖推断 —— 读 manifest 的人一眼就明白。

#### combined 示例（MobileGlues）

```json
{
  "rendererGLPath": "libs/libMobileGlues.dylib",
  "rendererEGLPath": "",
  "libraryLayout": "combined"
}
```

**只需一个 dylib** —— 它同时导出 `gl*` 与 `egl*` 符号。
加载时一次 `dlopen`，两个函数表都从同一个句柄取。

#### separate 示例（Zink）

```json
{
  "rendererGLPath": "libs/libglxshim.dylib",
  "rendererEGLPath": "libs/libEGL_mesa.dylib",
  "libraryLayout": "separate"
}
```

**加载顺序很重要**：必须先 `dlopen` EGL 且加 `RTLD_GLOBAL`，
再 `dlopen` GL。否则 GL 库找不到 `eglGetDisplay` 这些符号，
报 `symbol not found`。

#### glOnly 示例

```json
{
  "rendererGLPath": "libs/libOSMesa.dylib",
  "libraryLayout": "glOnly"
}
```

### 3.2 env 的四种类型

对应 FCL 的 v2 规格，**格式完全兼容**：

| type | 用途 | 关键字段 |
|---|---|---|
| `NormalEnv` | 固定值 | `key`, `value` |
| `ToggleableEnv` | 开关 | `key`, `value`, `title`, `toggle`（默认值） |
| `SelectableEnv` | 单选 | `key`, `title`, `check`, `items.defaultValue`, `items.values[]` |
| `CustomizableEnv` | 自由输入 | `key`, `title`, `defaultValue` |

本版状态（如实）：`env` 会被**解析并保留**（类型不认识按 `NormalEnv`，与 FCL 一致），
导入日志里记一行「env 声明 N 项」。**但启动链目前不消费渲染器的环境变量**
（`A2LaunchSession` → `a2_renderer` 只负责选 dylib 并 dlopen）——
「生成 UI 控件 / 按用户选择 setenv」这一步等真正有渲染器加载器时再做。
在这里声明 env 不会让插件装不上，也不会生效。

### 3.3 ios 块（Air2 扩展）

| 字段 | 说明 |
|---|---|
| `minSystemVersion` | 最低 iOS 版本 |
| `requiresJIT` | 是否依赖 JIT 权限 |
| `notes` | 给用户看的注意事项 |

> FCL 的 manifest 没有这一段。加它是因为 iOS 有 JIT / 签名这些额外约束，
> 渲染器作者需要能表达出来。

---

## 四、安装流程（原子安装 + 失败回滚）

```
用户选包（.air2plugin / .zip）
   ↓
① 解压到 staging：Documents/Air2/Renderers/.staging/<uuid>/
   · 逐条校验 zip 条目路径：拒绝 `..`、绝对路径、反斜杠、控制字符、`.` 段 / 空段
   · 跳过 macOS 的 __MACOSX/ 与 ._ 资源分支残留
   · 任一条不安全 ⇒ ★整包拒装★（不是「跳过这条继续装」）
   ↓
② 落盘复核（解压之后，对真实文件再来一遍）
   · 符号链接 ⇒ 拒装
   · 非普通文件（设备 / 管道）⇒ 拒装
   · manifest.json 份数：0 ⇒ 拒装；> 1 ⇒ 拒装（夹带第二个插件）
   ↓
③ 解析 manifest（`A2RendererPlugin`）
   · formatVersion 必须 == 1（不认识的版本拒装，不按 v1 硬读）
   · rendererId / displayName / rendererGLPath 必填
   · rendererId 必须是安全目录名：[A-Za-z0-9._-]，≤ 64 字符，不以 `.` 开头
   · 所有库路径必须是包内相对路径（同 ① 的判据，不允许绝对路径）
   · libraryLayout == separate 时 rendererEGLPath 必填
   ↓
④ 库文件静态校验（★不 dlopen★，见 4.2）
   · 存在 + 是普通文件（不是链接）+ 落在插件目录内
   · Mach-O：含 arm64 切片，且 filetype == MH_DYLIB（fat 包里必须有 arm64 切片）
   · 导出表里有 glGetString（N_EXT + N_SECT —— 只 import 的壳不算实现）
   ↓
⑤ 系统版本闸门：`ios.minSystemVersion` 高于本机系统 ⇒ 拒装（说清「需要 iOS ≥ x，本机 y」）
   ↓
⑥ 包摘要：解压后内容的 sha256（「排序后的相对路径 + 每个文件哈希」再整体哈希）
   · 同 id + 同 version + 不同内容 ⇒ ★拒装★（请改 manifest 的 version 再来）
   · 同 id + 同 version + 相同内容 ⇒ 幂等命中，磁盘不动
   ↓
⑦ 写安装记录 install.json（写在 staging 里，跟着目录一起被搬走）
   ↓
⑧ 原子换目录（同一卷 rename）
   staging/<包根> → .incoming/<uuid> → Renderers/{rendererId}
   已装旧目录 → .trash/<uuid> → 成功后删除
   任一步失败 ⇒ 旧目录挪回原位，staging / incoming 清掉
   ↓
⑨ 更新内存列表 + 发 A2RendererPluginsDidChangeNotification（管理页据此刷新）
```

**导入闸门 vs 启动扫描**：导入时必须 ①〜⑤ 全部通过；
App 启动时还会对已装目录再 `validate` 一遍（用户可能用「文件」App 删了某个库），
这一遍**不删目录**，只在列表里标「⚠ 原因」，让用户自己决定卸载。

### 4.1 install.json（安装记录）

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",
  "displayName": "MyGL",
  "version": "1.0.0",
  "packageHash": "sha256:…",
  "sourceFileName": "mygl.air2plugin",
  "installedAt": "2026-10-31T08:00:00Z"
}
```

它只用于两件事：**同版本内容判定** 与 **来源取证**（列表里显示「从哪个文件装的」）。
不是授权、不是签名 —— 它就放在被记录的目录里，改它不改变任何权限判定。

### 4.2 为什么导入阶段不 dlopen

`dlopen` 会真的执行库的 `__attribute__((constructor))`。GL 库的构造函数通常
假设 EGL 上下文已就绪 —— 导入阶段没有那个环境。实测：导入 MobileGlues 时崩在
`init_target_egl`（`dyld findAndRunAllInitializers → proc_init → init_target_egl`）。

所以导入闸门只用**静态判据**：文件 / 架构 / 导出符号。
真正的 `dlopen` 发生在启动链（`Natives/Renderer/a2_renderer.m`），那时才有 EGL 环境。

---

## 五、iOS 的限制（必须让用户知道）

| 环境 | 能否 dlopen 导入的 dylib |
|---|---|
| **TrollStore** | ✅ 可以（ldid 伪签名即可） |
| **越狱** | ✅ 可以 |
| **正常签名（AltStore / Sideloadly）** | ❌ 提示 "code signature invalid" |
| **App Store** | ❌ 同上 |

**导入页只陈述事实，不猜环境**（不做「探测一下能不能 dlopen」——那会崩，见 4.2）：

```
iOS 要求动态库与 App 使用相同签名。
TrollStore / 越狱环境下导入的库可以直接使用；
其他环境需要把库注入 Air2 后重新签名才能加载。
导入前会校验清单字段、库架构（必须是 iOS arm64 dylib）与导出符号。
```

---

## 六、兼容 FCL 插件

FCL 的插件是 APK（内含 Android 的 `.so`），**不能直接导入** ——
ELF 会在架构判定那一步被拒（提示「这是 Android 的 .so 文件」）。
能做的是**字段对照**，手工搬过来；`.so → .dylib` 必须用 iOS 工具链重新编译。

| FCL（APK 插件） | 本规范 | 说明 |
|---|---|---|
| `rendererId` | `rendererId` | 相同语义（反向域名） |
| `name` | `displayName` | 列表上的短名 |
| `description` / `author` / `version` | 同名 | 原样搬 |
| `glName`（如 `libgl4es_114.so`） | `rendererGLPath`（`libs/libgl4es_114.dylib`） | 换扩展名并放进 `libs/` |
| `eglName` | `rendererEGLPath` + `libraryLayout` | iOS 上常是合并库，见 3.1.1 |
| `env[]`（v2 EnvV2） | `env[]` | **格式完全兼容**，原样抄 |
| — | `ios` 块 | Air2 扩展，FCL 没有 |

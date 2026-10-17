# Air2

> iOS 端 Minecraft: Java Edition 启动器
> 原生 Objective-C 实现 · iOS 14.0+ · arm64

Air2 是 [Air-Devs](https://github.com/Air-Devs) 的 iOS 启动器项目。
设计参考 [ZL2](https://github.com/ZalithLauncher/ZalithLauncher2)（Android）与
[Amethyst](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)（iOS，同平台经验），
但**界面与实现均为 iOS 原生**，不是移植。

---

## 目录

- [一、设计原则](#一设计原则)
- [二、技术栈](#二技术栈)
- [三、目录结构](#三目录结构)
- [四、快速开始](#四快速开始)
- [五、渲染器插件体系](#五渲染器插件体系)
- [六、构建与 CI](#六构建与-ci)
- [七、静态检查](#七静态检查)
- [八、常见问题](#八常见问题)

---

## 一、设计原则

**禁止石山代码。** 以下为硬性约束，CI 会检查大部分：

1. **单一职责** —— 判断标准是「文件里是否存在两组不相干的关注点」，行数不作为拆分依据。
2. **分层清晰，禁止跨层调用** —— `App → UI → Player → Core → Bridge → Natives`。
   **Core 层禁止引用 UIKit / SwiftUI**（CI 强制）。
3. **无循环依赖** —— 模块间依赖必须是 DAG。
4. **显式优于隐式** —— 关键状态不藏在全局可变单例里。
5. **命名即文档** —— 禁止 `Utils2`、`ManagerNew`、`Common`、`Helper` 这类命名（CI 检查）。
6. **不留死代码** —— 永不执行的代码比没有更糟，它误导后来人。
7. **路径唯一出口** —— 所有游戏路径走 `A2GamePath`，禁止手写拼接。
8. **可测试** —— Core 层的纯逻辑必须能脱离 UIKit 单测。

> 违反以上任一条的 PR 不予合并。

### 关于参考 ZL2 的边界

用户明确要求过两件事，看起来矛盾，实际是分工：

| 参考 ZL2 ✅ | 自己设计 ❌ |
|---|---|
| 布局结构（横屏三区、左右分栏） | 配色方案 |
| 尺寸规格（30%/70% 分区、12 边距、28 圆角） | 具体视觉风格 |
| 交互决策（卡片形态、设置分组方式） | 动画曲线 |
| 算法（隔离规则、下载校验、双平台映射） | 图标与品牌 |

**读懂它的设计决策，用 iOS 的方式实现** —— 不要逐像素复刻。

---

## 二、技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| **UI** | **Objective-C** | 不是 SwiftUI。UIKit 布局 + 自绘组件 |
| **业务逻辑** | **Objective-C** | 账号、版本、下载、设置 |
| **原生层** | Objective-C / C | 渲染桥、输入注入、JIT 环境 |
| **启动核心** | Java（pojav 系） | 类加载、参数拼装、LWJGL 补丁 |
| **构建** | Xcode + Makefile + CMake | 产物 `.ipa` |

**Swift 仅保留为极少量衔接点** —— 当前工程里**没有 Swift 文件**。

### 关键依赖

| 依赖 | 用途 | 许可 |
|---|---|---|
| Mesa (kopper / zink) | OpenGL 实现 | MIT |
| MoltenVK | Vulkan → Metal | Apache-2.0 |
| LWJGL | Java 图形绑定 | BSD-3 |
| MobileGlues | GL 转译（可选渲染器） | LGPL-2.1 |

---

## 三、目录结构

```
Air2/
├── App/              应用入口、生命周期、根导航
│   ├── main.m
│   ├── A2AppDelegate        锁横屏
│   ├── A2SceneDelegate
│   ├── A2RootViewController 根容器 + 任务抽屉
│   ├── A2NavigationController 自定义转场
│   └── A2CrashGuard
│
├── Core/             【禁止 import UIKit】
│   ├── Account/      账号（微软 OAuth / 离线 / Yggdrasil / 皮肤）
│   ├── Addons/       加载器、双平台资源、zip、整合包
│   ├── Download/     下载引擎（引擎 / 批量 / 任务中心）
│   ├── Logging/      日志系统
│   ├── Multiplayer/  联机（陶瓦）
│   ├── Path/         路径解析与版本隔离
│   ├── Renderer/     ★ 渲染器注册与插件
│   └── Settings/     全局设置
│
├── Bridge/           Swift↔ObjC↔JVM 桥接（待实现）
├── Player/           游戏会话宿主（待实现）
│
├── UI/
│   ├── Screens/      页面
│   ├── Components/   可复用组件
│   ├── Control/      游戏内触控（待实现）
│   └── Theme/        主题色板
│
├── Natives/          ObjC/C 原生层（待实现）
├── JavaApp/          Java 启动核心（待实现）
├── Libraries/        预编译二进制
├── Assets/           Images.xcassets 等资源
├── cmake/ scripts/ docs/ tests/
└── Air2.xcodeproj/   ★ 脚本生成，勿手改
```

**新增顶层目录必须先登记 `docs/ARCHITECTURE.md`**，否则 CI 失败。

---

## 四、快速开始

```bash
# 1. 克隆
git clone https://github.com/Air-Devs/Air2.git
cd Air2

# 2. 生成 Xcode 工程（不要手改 pbxproj）
python3 scripts/gen_xcodeproj.py

# 3. 跑静态检查（提交前必做）
bash scripts/lint_structure.sh

# 4. 跑测试
python3 tests/Core/test_version_isolation.py
python3 tests/Core/test_download_ledger.py
python3 tests/Core/test_resume_validation.py
python3 tests/Core/test_zip_reader.py
```

**在 macOS 上构建**：
```bash
make package    # 产出 artifacts/Air2.ipa
```

---

## 五、渲染器插件体系

> 完整规范见 [`docs/RENDERER_PLUGIN_SPEC.md`](docs/RENDERER_PLUGIN_SPEC.md)

### 5.1 设计思路

**FCL 的做法**（`RendererPlugin.kt`）：
插件是独立 APK，Android **扫描已安装应用**发现，读 `meta-data` 里的配置。

**iOS 做不到这个** —— 沙箱不允许扫描第三方应用，`dlopen` 要求代码签名。

**Air2 的做法**：**导入 zip**。其余完全对齐：

```
FCL:  装个 APK  → 自动出现
Air2: 导入 zip  → 自动出现
```

### 5.2 用户视角

```
设置 → 渲染 → 渲染器插件 → 导入插件包 → 选 zip
                                        ↓
                            渲染器自动出现在列表里
```

**不需要重启** —— 发通知让 UI 刷新。

### 5.3 插件包结构

```
myrenderer.air2plugin          ← 就是个 zip
├── manifest.json              ← 必需
├── icon.png                   ← 可选，列表图标
└── libs/
    └── ...                    ← 库文件，数量取决于布局
```

**`libs/` 里放几个库，取决于你的库是怎么编的**（manifest 的 `libraryLayout` 字段）：

| layout | 含义 | 例子 | 文件数 |
|---|---|---|---|
| **`combined`** | **GL 与 EGL 在同一个 dylib** | **MobileGlues、NG-GL4ES** | 1 |
| `separate` | GL 与 EGL 各一个 | Zink、VirGL | 2 |
| `glOnly` | 只有 GL | OSMesa 直连 | 1 |

这是 iOS 特有的：Android 的 `glName`/`eglName` 总是两个独立 `.so`，
而 iOS 上很多实现（含 MobileGlues）把两者编在一起。

### 5.4 manifest.json

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",
  "displayName": "MyGL",
  "description": "基于 Mesa 的 GL 转译层",
  "version": "1.0.0",
  "author": "example",

  "rendererGLPath": "libs/libmygl.dylib",
  "rendererEGLPath": "libs/libmyegl.dylib",
  "libraryLayout": "separate",
  "dlopenLibPaths": ["libs/libdeps.dylib"],

  "minMCVer": "1.16.5",
  "maxMCVer": "1.21.4",

  "env": [
    { "type": "NormalEnv", "key": "MESA_GL_VERSION_OVERRIDE", "value": "4.0" },
    { "type": "ToggleableEnv", "key": "ZINK_DEBUG", "value": "compact",
      "title": "Zink 调试", "toggle": false },
    { "type": "SelectableEnv", "key": "MESA_LOADER_DRIVER_OVERRIDE",
      "title": "驱动",
      "items": {
        "defaultValue": "zink",
        "values": [
          { "value": "zink", "label": "Zink (Vulkan)" },
          { "value": "virpipe", "label": "VirGL" }
        ]
      } },
    { "type": "CustomizableEnv", "key": "MESA_SHADER_CACHE_MAX_SIZE",
      "title": "着色器缓存", "defaultValue": "512M" }
  ],

  "ios": {
    "minSystemVersion": "14.0",
    "requiresJIT": false,
    "notes": "需要 Metal 设备"
  }
}
```

**`env` 格式完全兼容 FCL 的 v2** —— 渲染器作者的配置可以基本复用，
只需把 `.so` 重编成 `.dylib`。

### 5.5 四种 env 类型 → UI 控件

| type | 生成的控件 | 用途 |
|---|---|---|
| `NormalEnv` | 无（固定值） | 常量设置 |
| `ToggleableEnv` | **开关** | 可选的调试开关 |
| `SelectableEnv` | **单选列表** | 驱动/模式选择 |
| `CustomizableEnv` | **输入框** | 数值/路径 |

选中某个渲染器后，右侧出现**齿轮按钮** → 打开该渲染器的配置页
（对应 ZL2 的 `RendererV2ConfigDialog`）。

### 5.6 iOS 签名限制

| 环境 | 能否加载导入的 dylib |
|---|---|
| **TrollStore** | ✅ 导入即用 |
| **越狱** | ✅ 导入即用 |
| **正常签名** | ❌ `code signature invalid` |

**但构建时签名就没这个问题** —— 自己编译并签名的插件可以直接加载。

导入后我们会**实际 dlopen 探测**，把结果告诉用户：

```
✓ 可用
⚠ 代码签名无效。TrollStore/越狱环境可直接使用，其他环境需重新签名。
⚠ 这是 Android 的 .so 文件，iOS 不能加载（需要重新编译成 .dylib）
```

**不让用户面对静默失败。**

### 5.7 代码结构

| 文件 | 职责 |
|---|---|
| `Core/Renderer/A2RendererPlugin.{h,m}` | manifest 解析、三级校验 |
| `Core/Renderer/A2RendererImporter.{h,m}` | 解压 → 校验 → 原子安装 |
| `Core/Renderer/A2Renderer.{h,m}` | 内置渲染器注册表 |
| `UI/Screens/Settings/A2RendererPluginViewController.{h,m}` | 导入与管理页 |
| `UI/Screens/Settings/A2RendererSettings.{h,m}` | 渲染器选择（待接入） |

### 5.8 三级校验

导入时按顺序检查，**每一步失败都给出具体原因**：

```
① 文件存在性  → 缺库直接报「找不到 GL 库：libs/xxx.dylib」
② 架构检查    → 读 Mach-O 头，区分：
                  · ELF（Android 的 .so）→ "需要重新编译成 .dylib"
                  · 32 位 Mach-O        → "当前设备需要 64 位"
                  · 非 Mach-O           → "不是有效的动态库"
③ dlopen 实测 → 签名无效 / 缺依赖 / 其他错误，分别翻译成人话
```

---

## 六、构建与 CI

### CI

`.github/workflows/build.yml` —— macOS runner 上用 `xcodebuild` 编译，输出**未签名 IPA**。

**产物**：Actions → Artifacts → `Air2-IPA`

### 本地构建

```bash
python3 scripts/gen_xcodeproj.py   # 生成工程
make natives && make java && make package
```

**`Air2.xcodeproj/project.pbxproj` 是脚本生成的**，改了文件结构后重跑生成脚本，
不要手工编辑。

---

## 七、静态检查

因为开发环境无 macOS，用一套脚本做静态验证：

| 脚本 | 检查 |
|---|---|
| `lint_structure.sh` | 顶层目录白名单、禁用命名、分层依赖 |
| `lint_objc.py` | 只读属性赋值、属性归属、约束数组嵌套、变量声明顺序、block 循环引用、setter 命名 |
| `check_imports.py` | 头文件引用、声明/实现一致、属性修饰符跨文件、色板字段对齐、组件间依赖 |
| `verify_pbxproj.py` | 工程路径能否解析到真实文件 |

**每条规则都对应一次真实的 CI 失败。**

> **检查器的边界**：它只做「编译器不做的事」—— 分层约束、命名规范、色板对齐。
> 用正则模拟语言结构（方法解析、属性解析）的规则**不可靠**，误报比漏报更伤，
> 应交给编译器。

---

## 八、常见问题

### 为什么不用 SwiftUI？

Swift 的类型系统在与 ObjC 互操作时有额外开销，而这个项目的 UI 大量依赖
自绘组件（自定义圆角、动态色板、复杂动画），SwiftUI 反而绕远。所以全部用 ObjC。

### 为什么渲染器要"导入"而不是自动发现？

iOS 沙箱不允许 App 扫描已安装的其他应用。FCL 的「装个 APK 就出现」
在 iOS 上无对应 API。

### 导入的渲染器加载失败怎么办？

先看错误提示：
- **代码签名无效** → 需要与 Air2 使用相同签名（TrollStore 环境无此问题）
- **Android 的 .so** → 需要重新编译成 .dylib
- **缺依赖库** → 检查 `dlopenLibPaths`

### 为什么不用 CMake 构建整个项目？

原生层（渲染桥等）用 CMake；UI 与业务逻辑用 Xcode 工程。
这与 Air1 的做法一致 —— 两者各自适合不同的部分。

---

## 许可

GPL-3.0-or-later

Minecraft 是 Mojang Studios 的商标，本项目与其无隶属关系。

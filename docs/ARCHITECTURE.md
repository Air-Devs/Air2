# Air2 目录职责说明

本文件是 Air2 代码组织的**唯一权威定义**。新增目录前必须先在此登记，否则视为架构违规。

---

## 顶层

| 目录 | 职责 | 允许依赖 |
|---|---|---|
| `Air2/` | iOS 应用主体（ObjC） | Natives、Libraries |
| `Air2.xcodeproj/` | Xcode 工程定义（**由脚本生成，不手工编辑**） | — |
| `Natives/` | Objective-C / C 原生层 | Libraries |
| `JavaApp/` | Java 侧启动核心 | Libraries/Jars |
| `Libraries/` | 预编译二进制（不放源码） | — |
| `Assets/` | 静态资源、本地化 | — |
| `cmake/` | CMake 模块与工具链文件 | — |
| `scripts/` | 构建与辅助脚本 | — |
| `docs/` | 设计文档、决策记录、依赖清单 | — |
| `tests/` | 单元测试 | 被测层 |

---

## `Air2/` — 应用主体

### 依赖方向（严格单向）

```
App → UI → Player → Core → Bridge → (Natives)
                 ↘ Utils ↙
```

- 上层可依赖下层
- **下层禁止依赖上层**（Core 不得 import UI，Bridge 不得 import Core）
- Utils 是全层共用的叶子，不得反向依赖任何业务层

### 各目录职责

#### `App/`
应用生命周期与根装配。
- `Air2App.swift` —— SwiftUI 入口
- `AppDelegate.swift` —— UIKit 生命周期钩子（JIT、后台任务）
- `RootView.swift` —— 根导航容器
- `DependencyContainer.swift` —— 依赖注入装配点（唯一允许的"全局"）

**禁止**：业务逻辑、网络请求、直接引用具体 View。

#### `Bridge/`
Swift ↔ Objective-C ↔ JVM 的**唯一**跨界通道。
- 所有 `@_cdecl` / `extern "C"` 声明集中此处
- JNI 调用封装为 Swift 协议，UI 层只面对协议
- 桥接层**不含业务规则**，只做类型转换与生命周期转发

**禁止**：在 Bridge 里做判断业务状态的逻辑。

#### `Core/`
无 UI 的业务核心。**可单测，不依赖 UIKit。**

| 子目录 | 职责 |
|---|---|
| `Account/` | 账号模型、Microsoft OAuth 流程、离线账号、皮肤披风 |
| `Version/` | 版本 JSON 解析、安装、隔离目录、启动参数拼装 |
| `Download/` | 下载引擎：分片、断点续传、镜像回退、速度自适应 |
| `Addons/` | Mod / 资源包 / 光影 / 整合包的识别、依赖解析、安装 |
| `Renderer/` | 渲染后端抽象与注册表（Metal / kopper / VirGL / GL4ES…） |
| `Path/` | 沙盒路径规划，所有路径只在此处拼装 |
| `Settings/` | 设置项注册表、类型安全的读写、默认值、迁移 |

**禁止**：`import SwiftUI`、`import UIKit`。

#### `UI/`

| 子目录 | 职责 |
|---|---|
| `Screens/` | 页面级视图，一屏一文件 |
| `Components/` | 跨页面复用的小组件（按钮、卡片、弹窗） |
| `Control/` | 游戏内触控层（虚拟按键、摇杆、布局编辑） |
| `Theme/` | 配色、字体、间距、动效常量 |

**禁止**：在 View 里手写网络协议细节或拼接文件路径；发起请求与读写文件一律走 Core 服务（ViewController 只做调度，不内嵌实现）。

#### `Player/`
游戏会话运行时宿主。
- 启动流程编排（准备 → 解压 → 拉 JVM → present）
- 会话生命周期与异常兜底
- 游戏内菜单与悬浮层

#### `Utils/`
无业务语义的纯工具。**能放进这里的，必须与 Minecraft 无关。**
日期格式化、JSON 编解码扩展、字符串处理、数学工具等。

---

## `Natives/` — 原生层

| 子目录 | 职责 |
|---|---|
| `Context/` | JVM 创建/销毁、类加载器、线程组 |
| `Renderer/` | Metal 层管理、EGL/GL 桥、surface 生命周期 |
| `Input/` | 触摸、键盘、鼠标、手柄、陀螺仪的事件注入 |
| `Controls/` | 自定义控件的原生渲染与命中测试 |
| `Support/` | JIT 环境、签名处理、崩溃探针、诊断日志 |

**约束**：原生层不感知"版本""账号"等业务概念，只接收已解析好的参数。

---

## `JavaApp/` — Java 启动核心

| 路径 | 职责 |
|---|---|
| `src/launcher/` | 启动器 Java 代码（主类、参数拼装、类路径） |
| `src/lwjgl/` | LWJGL 补丁源码（GLFW 回调、输入桥、平台适配） |
| `libs/` | 预编译 Java 库（不修改的上游 jar） |

产物为 `lwjgl.jar`，由 Xcode 构建阶段复制进 app bundle。

---

## `Libraries/` — 预编译二进制

**只放二进制，不放源码。**

| 子目录 | 内容 |
|---|---|
| `Frameworks/` | `.framework` / `.xcframework` |
| `Jars/` | 预编译 `.jar` |
| `Renderers/` | 渲染后端 `.dylib`（Mesa / GL4ES / MobileGL…） |

每个二进制必须在 `docs/DEPENDENCIES.md` 登记来源、版本、许可。

---

## 命名规范总表

| 类型 | 规范 | 示例 |
|---|---|---|
| 目录 | UpperCamelCase，单数 | `Download/` 而非 `downloads/` |
| Swift 类型 | UpperCamelCase | `VersionInstaller` |
| Swift 协议 | 名词或 -able | `LauncherBridge`, `Downloadable` |
| 变量/函数 | lowerCamelCase | `resolveManifestURL()` |
| ObjC 类 | 前缀 `A2` | `A2SurfaceView` |
| C 函数 | 前缀 `a2_` | `a2_ctx_create()` |
| 常量 | lowerCamelCase（Swift） | `defaultTimeout` |

**禁用命名**：`Utils2`、`ManagerNew`、`Helper`、`Common`、`Base`（无信息量的后缀）。

---

## 文件规模

**不设行数上限。** 是否拆分由职责边界决定，不由行数决定。

原因：UIKit 的 Auto Layout 是声明式的，一条约束一行，一个稍复杂的
卡片 30~40 行约束很正常。按行数强制拆分会把完整的视图硬切成多份，
反而增加跨文件跳转成本（分类访问主类私有属性还要额外的内部头文件），
是为了满足指标而制造复杂度。

行数只作提示信号：`lint_structure.sh` 在文件超过 1000 行时给出提醒，
让人确认一下「是否承担了多个职责」，仅此而已。

判断标准是：**这个文件里是否存在两组不相干的关注点？**
有就拆，没有就不拆。

---

## 新增目录流程

1. 在本文档对应章节补充条目，写明职责与依赖方向
2. 确认不产生循环依赖
3. 提交时 PR 描述中引用本节改动

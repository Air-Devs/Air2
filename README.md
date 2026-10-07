# Air2

> 全新的 iOS 端 Minecraft: Java Edition 启动器
> 基于 pojav 系后端重新开发，目标平台 iOS 14.0+（arm64）

Air2 是 [Air-Devs](https://github.com/Air-Devs) 组织的下一代 iOS 启动器项目。
与 ZL2（Android / Kotlin / Compose）同源设计理念，但面向 iOS 原生技术栈重新实现：
SwiftUI/UIKit 负责界面与交互，Java 层复用 pojav 系的启动核心与 LWJGL 补丁，
原生层（Objective-C / C）负责渲染桥接、输入注入与 JIT 环境。

---

## 设计原则

**禁止石山代码。** 所有代码必须满足以下硬性约束：

1. **单一职责** —— 一个文件只做一件事。UI 文件不写下载逻辑，桥接文件不写业务规则。
2. **分层清晰，禁止跨层调用** —— UI → ViewModel → Domain → Data，逆向依赖一律通过协议（protocol）解耦。
3. **无循环依赖** —— 模块间依赖是有向无环图，新增依赖前先确认方向。
4. **显式优于隐式** —— 不使用全局可变单例承载状态；需要共享的东西走依赖注入。
5. **文件长度上限** —— 单文件超过 400 行必须拆分，超过 800 行视为阻塞性问题。
6. **命名即文档** —— 目录名、类型名必须能自解释，禁止 `Utils2`、`ManagerNew`、`Helper` 这类无信息量命名。
7. **不留死代码** —— 注释掉的代码、未使用的类、`TODO` 占位超过一个迭代周期的一律删除。
8. **可测试** —— Domain 层不依赖 UIKit / JVM 环境，纯逻辑必须能单测。

> 违反以上任一条的 PR 不予合并。

---

## 技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| UI | SwiftUI（主）+ UIKit（必要的宿主容器） | 面向 iOS 26 液态玻璃，向下兼容 |
| 宿主 | Objective-C++ | 承载 JVM 生命周期、Metal 层、输入注入 |
| 业务逻辑 | Swift | 账号、版本管理、下载、设置 |
| 启动核心 | Java（复用 pojav 系） | 类加载、参数拼装、LWJGL 补丁 |
| 图形 | Metal / MoltenVK / Mesa(kopper) | 渲染后端抽象，多渲染器可选 |
| 构建 | Xcode + Makefile + CMake | 产物为 `.ipa` |

### 后端来源

Air2 的 pojav 后端（LWJGL 补丁、Java 启动器、GLFW/SDL3 兼容层、Mesa 构建产物）
参考并复用以下上游工作：

- **[Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)**
  —— iOS 端 pojav 后端实现（`Natives/`、`JavaApp/`、`lwjgl-lib/`）
- **[PojavLauncher](https://github.com/PojavLauncherTeam/PojavLauncher)**
  —— 原始启动核心与 Boardwalk 思路
- **[ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2)**
  —— 架构分层与功能设计的参考基准

---

## 目录结构

```
Air2/
├── Air2.xcodeproj/              # Xcode 工程定义
├── Air2/                        # iOS 应用主体（Swift）
│   ├── App/                     # 应用入口、生命周期、根导航
│   ├── Bridge/                  # Swift ↔ ObjC ↔ JVM 三层桥接
│   ├── Core/                    # 无 UI 的业务核心
│   │   ├── Account/             # 账号体系（离线 / Microsoft / Yggdrasil）
│   │   ├── Version/             # 版本安装、隔离、启动参数
│   │   ├── Download/            # 下载引擎（分片、断点续传、镜像）
│   │   ├── Addons/              # Mod / 资源包 / 光影 / 整合包
│   │   ├── Renderer/            # 渲染后端注册与选择
│   │   ├── Path/                # 路径与沙盒布局
│   │   └── Settings/            # 设置注册表与持久化
│   ├── UI/                      # 全部界面
│   │   ├── Screens/             # 页面级视图
│   │   ├── Components/          # 可复用组件
│   │   ├── Control/             # 游戏内触控控件
│   │   └── Theme/               # 配色、字体、动效
│   ├── Player/                  # 游戏会话与运行时宿主
│   └── Utils/                   # 通用工具（无业务语义）
├── Natives/                     # Objective-C / C 原生层
│   ├── Context/                 # JVM 上下文与生命周期
│   ├── Renderer/                # 渲染桥接（Metal / GL / Vulkan）
│   ├── Input/                   # 键盘、鼠标、手柄、陀螺仪
│   ├── Controls/                # 自定义控件渲染
│   └── Support/                 # JIT、签名绕过、诊断探针
├── JavaApp/                     # Java 侧启动核心
│   ├── src/launcher/            # 启动器 Java 代码
│   ├── src/lwjgl/               # LWJGL 补丁源码
│   └── libs/                    # 预编译 Java 库
├── Libraries/                   # 预编译原生库（dylib / framework / jar）
├── Assets/                      # 静态资源与本地化
├── cmake/                       # CMake 模块与工具链
├── scripts/                     # 构建与辅助脚本
├── docs/                        # 设计文档与决策记录
└── .github/                     # CI 与 issue 模板
```

---

## 构建

```bash
# 环境要求：Xcode 26.x、iOS 26 SDK、CMake 3.20+、JDK 17
make bootstrap     # 拉取依赖与子模块
make natives       # 编译原生层
make java          # 编译 Java 启动核心
make package       # 打包 IPA → artifacts/
```

产物输出至 `artifacts/Air2.ipa`。

---

## 分支约定

| 分支 | 用途 |
|---|---|
| `main` | 稳定主线，随时可构建 |
| `dev` | 集成分支 |
| `feat/*` | 功能开发 |
| `fix/*` | 缺陷修复 |

---

## 许可

见 [LICENSE](LICENSE)。
上游依赖各自遵循其原始许可，详见 [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)。

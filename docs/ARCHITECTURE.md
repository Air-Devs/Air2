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
| `src/launcher/` | 启动核心 Java 代码（入口、启动计划消费、类路径追加、主类派发） |
| `src/lwjgl/` | LWJGL 补丁源码（GLFW 回调、输入桥、平台适配）★层 2，尚未落★ |
| `libs/` | 预编译 Java 库（不修改的上游 jar） |

产物为 `build/air2-launch.jar`（★旧文写的 `lwjgl.jar` 已作废：自研启动核心与 LWJGL 补丁
是两件事，前者已落、后者未落，共用一个名字会让「哪一半在包里」说不清★），
由 Xcode 的 `Build Java Launch Core` 脚本阶段（`scripts/gen_xcodeproj.py` 生成）
编出来并复制到 `Air2.app/Java/`。

### 自研启动核心（Java 侧）—— [OWN-JAVA]

**定位**：native 侧 `a2_launch`（R2/R3/R4/R7）已经把「建 VM、JVM 参数、classpath、资源路径」
这一整块自研掉了；Java 侧只保留**只有 Java 能做**的最小胶水，且**不承载任何业务**
（版本 JSON 语义、账号、下载、UI 都不在这里）。

| 文件 | 职责 |
|---|---|
| `dev/airdevs/air2/launch/A2Entry.java` | 入口：`a2_run_main` 的派发目标；四步顺序（load 符号宿主 → 落系统属性 → 追加类路径 → 派发主类） |
| `dev/airdevs/air2/launch/A2LaunchPlan.java` | 启动计划（JSON, schema=1）读取与校验 —— Java 侧唯一输入 |
| `dev/airdevs/air2/launch/A2Json.java` | 极简 JSON 读取器（自研，避免引入 gson 等第三方库） |
| `dev/airdevs/air2/launch/A2JvmProperties.java` | 系统属性落地（LWJGL/Vulkan/spvc/libffi/allocator 约定；须在类初始化前） |
| `dev/airdevs/air2/launch/A2NativeLibrary.java` | 「主可执行文件即 JNI 符号宿主」约定的落地（`System.load`） |
| `dev/airdevs/air2/launch/A2GameClasspath.java` | 计划里的类路径条目 → URL（**不做通配展开**：那是 R4 的唯一实现） |
| `dev/airdevs/air2/launch/A2GameClassLoader.java` | 运行期可追加类路径的系统类加载器（`JNI_CreateJavaVM` 之后唯一时机） |
| `dev/airdevs/air2/launch/A2MainDispatcher.java` | 主类派发（与 `a2_run_main` 同语义），解包 `InvocationTargetException` |
| `dev/airdevs/air2/launch/A2LaunchFailure.java` | 启动期失败类型（带可读原因，供 failbanner 分流） |

**分工边界（为什么只有这样切）**

- 计划里的 `arguments` **已完全替换占位符**：占位符取值要读账号与版本 JSON ⇒ 属业务 ⇒ 留 native。
- 计划里的 `classpath` 是**显式 jar 列表**，无 `*`：通配展开的唯一实现是
  `Natives/Context/a2_resourcepaths.m` 的 `a2_paths_expand_classpath_wildcards`。
- Java 侧**不解析版本 JSON**：`A2VersionInfo` 只解决「是哪版 + 有没有加载器」；
  MC 的 `mainClass` / `arguments` / `libraries` 由 native/Core 解析后写进启动计划。

**规格来源**：`D:\CTF\_AIR2_OWN_JAVA.md`。

**来源**：本单为净室实现（见 `docs/DEPENDENCIES.md`「Java 侧自研替换」一节）。


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

---

## 自研启动链(runtime chain)落地登记 —— [RT-CHAIN]

落位三处：`Natives/Context`、`Natives/Support`、`Air2/Player`。
依赖严格单向（App → UI → Player → Core → Bridge → Natives）；**Natives 只收已解析参数，不感知版本/账号**。

| 文件 | 层 | 职责 |
|---|---|---|
| `Natives/Context/a2_vmloader.[hm]` | Natives/Context | R2：`dlopen(libjvm)` + `JNI_CreateJavaVM`（★同进程，不经 libjli★） |
| `Natives/Context/a2_argbuilder.[hm]` | Natives/Context | R3：JVM 参数拼装（保序 / `-D` 按 key 去重 / classpath / 主类 / 程序参数） |
| `Natives/Context/a2_resourcepaths.[hm]` | Natives/Context | R4：资源与类路径注入 + classpath 通配展开（只依赖 Foundation） |
| `Natives/Context/A2JVMContext.[hm]` | Natives/Context | JVM 创建 / 销毁（ObjC 封装；`-Djava.home` 由上层给出） |
| `Natives/Support/a2_log.[hm]` | Natives/Support | R7：结构化日志 `[RT]` / `[LAUNCH-PROGRESS 阶段 n/8]` / `[RT-STRICT]`（★无状态★） |
| `Natives/Support/a2_failbanner.[hm]` | Natives/Support | 失败提示条（JIT / 启动阶段分流文案） |
| `Natives/Support/A2JITEnvironment.[hm]` | Natives/Support | JIT 环境与判据（`brk #0x69` 区域取证、真写+真执行自证、诊断日志） |
| `Air2/Player/A2LaunchChain.[hm]` | Player | 启动链顺序编排（发脚本 → 探测 JIT → 建 VM）；步骤由注入 block 提供 |
| `Natives/Context/a2_launch.[hm]` | Natives/Context | runtime 链 facade 编排：R3→R4→R2→R7，并 dispatch 主类 main；**全链唯一回退点** `a2_fallback_gate` |
| `Air2/Player/A2JIT*`（Provider/Facts/StrategySelector/StateMachine/Coordinator/LocalFactsSource + 四路 Provider） | Player | JIT 供给编排（纯逻辑，可单测；见 ADR-009 / `docs/JIT-PROVISIONING.md`） |
| `Air2/Player/A2PairingFile.[hm]` | Player | 配对文件解析与校验（纯 Foundation，可单测） |

### JIT 判据接线与取得路径真实现 —— [JIT-IMPL-2]

依赖严格单向（App → UI → Player → Core → Bridge → Natives）。★Natives 只收已解析参数、不感知版本/账号★；
★Bridge 是唯一与 Natives 相邻的层★，所以「跨到 Natives 取 JIT 判据」只能发生在 Bridge。

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Player/A2JITReadinessProbe.h` | Player | 判据注入缝（协议）+ `A2JITReadinessVerdict`（逐值镜像 Natives 的 `A2JITRegionVerdict`）|
| `Air2/Player/A2JITExternalToolLauncher.h` | Player | 外部工具拉起缝（协议）|
| `Air2/Player/A2JITVerdictGuidance.[hm]` | Player | 判据分流表：verdict → 失败原因 / 动作 / 本地化 key / 日志行 |
| `Air2/Player/A2JITStrings.[hm]` | Player | JIT 面板四语文案表（zh-Hans / zh-Hant / en / ja）|
| `Air2/Player/A2JITPairingFileStore.[hm]` | Player | 导入配对文件落盘与记录（容器约定位置；来源/时间/SHA-256/格式/设备标识）|
| `Air2/Bridge/A2JITEnvironmentProbe.[hm]` | **Bridge** | ★真调判据★：转发 `Natives/Support/A2JITEnvironment`（`ensureVerifiedWithinBudget:reason:` + 实时 verdict/取证）|
| `Air2/UI/Components/A2JITSystemToolLauncher.[hm]` | UI | 拉起缝真机实现（`UIApplication` URL scheme；白名单见 `Air2/Info.plist`）|

**来源**：`docs/JIT-PROVISIONING.md` §3.2；判据内核 `Natives/Support/A2JITEnvironment.[hm]`（ADR-007，本单不改其语义）。

**来源（上一节 [RT-CHAIN]）**：原 Amethyst 线 `Natives/runtime/*` 的 P1 实现 + P1 之后修复（G1–G7 `[VS-GAP]`、
`[RT-STRICT]` 严格回退门、`[RT-NOAGENT]` 切片），逐文件搬入并按 Air2 规范归位。

**启动链开关（Debug）**：设置 → 诊断 → 「运行环境 · 启动链」（写 `NSUserDefaults` key `debug.rt_p1_runtime`）。
ADR 见 `docs/DECISIONS.md` ADR-007 / ADR-008 / ADR-009。

### iOS 27+ 自动配对（自研 RPPairing）—— [JIT-AUTOPAIR-1]

依赖严格单向（App → UI → Player → Core → Bridge → Natives）；★Bridge 是唯一与 Natives 相邻的层★，
真 RPPairing（Bonjour / RSD / pair-verify / TLS-PSK）的落点只能在这里 → Natives。

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Player/A2JITAutoPairing.[hm]` | Player | 自动配对类型（前置条件 4 项 / 步骤 / 阻塞分类）+ `A2JITAutoPairingPreconditions`（三态值对象）+ `A2JITAutoPairingEngine` 注入缝 |
| `Air2/Player/A2JITAutoPairingGuidance.[hm]` | Player | 自动配对分流表：blocker → 现有 `A2JITFailureReason` / 本地化 key / 诊断名 / 日志行 |
| `Air2/Player/A2JITAutomaticPairingProvider.[hm]` | Player | ① 自动配对 Provider 真实现（能力 / 前置 / 新鲜度 / ★有界★生成调用点 / 真调判据复验） |
| `Air2/Bridge/A2JITAutoPairingEngineBridge.[hm]` | **Bridge** | RPPairing 引擎接线点骨架（本阶段如实报「未接入」；真实现见 `docs/JIT-PROVISIONING.md` §4.2） |

**来源**：`docs/JIT-PROVISIONING.md` §1.2 / §3.3；许可口径见 `docs/DEPENDENCIES.md`「JIT 自动配对」节
（★自研；只参考 SideInstaller 思路、未用其代码★）。

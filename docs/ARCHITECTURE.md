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
| `src/lwjgl/` | LWJGL 补丁源码（GLFW 回调、输入桥、平台适配）★层 2；[A2-GLFW-REUSE-1] 已复用老树 9 类 + 1 注解补丁★ |
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
| `Air2/Bridge/A2JITAutoPairingEngineBridge.[hm]` | **Bridge** | RPPairing 引擎接线点：★[JIT-AUTOPAIR-2] 起为真接线★（前置条件真读 + 真跑 `A2RPPairingPreflight` 并点名受阻步骤；仍如实报「未接入」） |
| `Natives/Support/a2_rppairing_crypto.[hm]` | **Natives** | 系统密码学原语薄封装：X25519（corecrypto `cccurve25519`）/ HKDF-SHA512 / SHA-512 / MD5 / CSPRNG / UUIDv3；Ed25519 / ChaCha20-Poly1305 的**可用性真自检**（★真跑签/验/加解 + 坏输入必须被拒★）
| `Natives/Support/a2_rppairing_chacha.[hm]` | **Natives** | **[JIT-AUTOPAIR-2] 自研** ChaCha20-Poly1305（RFC 8439）：ChaCha20 流 + Poly1305 + AEAD seal/open（常数时间认证）
| `Natives/Support/a2_rppairing_ed25519.[hm]` | **Natives** | **[JIT-AUTOPAIR-2] 自研** Ed25519（RFC 8032）：5×51 位肢体域运算 + 扩展坐标点运算 + mod L 标量运算（★非常数时间，一次性握手用★）
| `Natives/Support/a2_rppairing_verify.[hm]` | **Natives** | **[JIT-AUTOPAIR-2] pair-verify 握手本体**：Host/Device 双角色会话 + M1→M4 状态机 + `shared_secret`(=PSK) + HKDF 派生 + §10 主密钥；**进程内自握手自证** `A2RPPairVerifySelfTest`
| `Natives/Support/a2_rppairing_rsd.[hm]` | **Natives** | **[JIT-AUTOPAIR-2] 发现/连接层**：Bonjour 服务类型与传输路径映射、流式帧读取器、hostOptions/pairingData/createListener 信封、NWBrowser 发现 + NWConnection 连接 + 真跑 pair-verify、TLS-PSK 配置与**能力如实点名** |
| `Natives/Support/a2_rppairing.[hm]` | **Natives** | RPPairing 线上编解码（帧 / 信封）+ 配对文件（RpPairingFile）组装 + 握手完成度自检 `A2RPPairingPreflight` |

**来源**：`docs/JIT-PROVISIONING.md` §1.2 / §3.3 / §3.6；许可口径见 `docs/DEPENDENCIES.md`「JIT 自动配对」节
（★自研；只参考公开协议描述，未用任何第三方代码★）。

### DDI（Developer Disk Image）取得与三态判定 —— [JIT-DDI-1]

依赖严格单向（App → UI → Player → Core → Bridge → Natives）。★机制在 Bridge → Natives，
Player 只消费状态★：本地镜像的发现/校验/落盘与判定合成都在 Player（纯逻辑、可单测），
真正碰设备与网络的（设备侧查询、个性化请求、`image_mounter` 挂载）经 Bridge 注入。

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Player/A2JITDDI.[hm]` | Player | DDI 类型（来源 / 形态 / 5 态判定 / 三态对齐）+ 值对象（要求 / 镜像 / 判定结果）+ 纯逻辑（版本对齐、新鲜度、判定 → 前置条件三态）+ 设备侧查询协议 `A2JITDDIDeviceQuery` |
| `Air2/Player/A2JITDDIStore.[hm]` | Player | 本地镜像发现 / 校验（UDIF 尾标 `koly`）/ **手动导入**（与配对文件同机制）/ 落盘记录（来源 / 时间 / SHA-256 / 声明版本） |
| `Air2/Player/A2JITDDIProbe.[hm]` | Player | 判定合成（本地镜像 + 设备侧查询 ⇒ 三态），★唯一实现★；「联网取 / 挂载」调用点（如实转发） |
| `Air2/Player/A2JITDDIGuidance.[hm]` | Player | DDI 分流表（5 态 → 前置条件三态 / 本地化 key / 稳定诊断名 / 日志行） |
| `Air2/Bridge/A2JITDDIDeviceBridge.[hm]` | **Bridge** | 设备侧查询接线点骨架（设备侧判定回 `Unknown`、能力查询回 `NO`、联网取与挂载回 `NO` + 确切缺什么）|

**来源**：`docs/JIT-PROVISIONING.md` §1.2 / §3.4；许可口径见 `docs/DEPENDENCIES.md`「DDI 取得」节
（★自研；只按公开资料的行为描述实现，未搬运任何第三方代码★）。

### 运行时 / 渲染器随包登记 —— [RT-BUNDLE]

**分层**：`Libraries/` 是「预编译二进制」层（见 §顶层，**不放源码**）；启动链（`Natives/Context`）只**消费**它，
方向仍是 单向 `Natives → Libraries`。

| 路径 | 层 | 职责 | 随包目标 |
|---|---|---|---|
| `Libraries/Renderers/libmetallum.dylib` | Libraries | ★唯一主推渲染器★（自研 Metal，零第三方 dylib） | `<App>/Frameworks/libmetallum.dylib` |
| `Libraries/Frameworks/liblwjgl{,_opengl,_stb}.dylib`、`libjnidispatch.jnilib` | Libraries | LWJGL 3.4.1 iOS natives（`System.loadLibrary` 的目标） | `<App>/Frameworks/` |
| `Libraries/Jars/lwjgl-341/*.jar` | Libraries | LWJGL 3.4.1 jar 集（classpath 的 `<lwjglDir>/*` 尾项） | `<App>/libs/lwjgl-341/` |
| `Libraries/java_runtimes/java-25-openjdk/` | Libraries | JVM 运行时（★不入 git★；由 `scripts/stage_runtime.sh` 从本机 Amethyst 产物就位） | `<App>/java_runtimes/java-25-openjdk/` |

**加载者（谁读它）**：

| 随包目标 | 加载者 | 证据行号 |
|---|---|---|
| `<App>/java_runtimes/<ver>/lib/server/libjvm.dylib` | `Natives/Context/a2_vmloader.m` `a2_vm_resolve_libjvm()` → `dlopen` + `dlsym("JNI_CreateJavaVM")` | `a2_vmloader.m:15-27,36-39` |
| `<App>/Frameworks/*.dylib` | JVM 的 native 解析（`-Djava.library.path=<bundle>/Frameworks`） | `Natives/Context/a2_resourcepaths.m:100-117` |
| `<App>/libs/lwjgl-<ver>/*` | classpath 通配展开后并入 `-Djava.class.path` | `a2_resourcepaths.m:59-86`（`a2_argbuilder` 保序下发） |

**随包机制**：`scripts/gen_xcodeproj.py` 的 **「Stage Runtime Bundle」** 脚本阶段（`runtime_stage_script()`）。
★独立函数，不改 `collect_resources()` / `scan_sources()` 等公共段落★；★不手改 `project.pbxproj`★（脚本重生成）。
JRE 缺失时该阶段**只告警不失败**（同树多任务并行时不让别人的构建变红）；包内完整性由出包后的逐项断言兜底。

**开关**：无 —— 运行时随包是常态；「走不走自研启动链」仍只由 `debug.rt_p1_runtime` 决定。

### 启动计划产出方 + 自研链入口接线 —— [LAUNCH-PLAN]

**决策（两条归属）**：

1. ★**启动计划由 `Core` 产出**★，不由 native 自研链产出。理由：计划内容 = 版本 JSON 语义
   （`mainClass` / `arguments` / `libraries` / `assetIndex` / `inheritsFrom` 合并 / `rules` 求值）
   + 账号取值 ⇒ 是**业务**；而分层规范写明 `Natives`「只接收已解析好的参数，不感知版本/账号」，
   `a2_launch.h` / `A2JVMContext.h` 也把「javaHome 与启动选项由上层（Player → Core）解析后传入」
   写成契约 ⇒ native 链保持**纯消费者**。
2. ★**调用 `a2_launch_jvm_with_argv` 只能发生在 `Bridge`**★：Bridge 是唯一与 Natives 相邻的层
   （同 [JIT-IMPL-2] 的理由）。Player 与 UI 只见纯 ObjC 签名。

依赖方向不变：`UI → Player → Core → Bridge → Natives`；`Utils` 提供跨层契约常量（叶子层）。

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Utils/A2LaunchContract.[hm]` | Utils | 跨层契约常量：入口主类名 / `--plan` / 系统类加载器名 / 两个 jar 名 / plan schema |
| `Air2/Core/Version/A2LaunchPlan.[hm]` | Core | ★计划产出方★：版本 JSON（`inheritsFrom` 合并、`rules` 子集求值、`arguments` 占位符替换、`libraries` → 显式 jar 列表）+ 账号取值 → 计划对象与 JSON；另出 VM 级选项与程序参数 |
| `Air2/Bridge/A2LaunchRunner.[hm]` | **Bridge** | ★唯一调用 `a2_launch_jvm_with_argv` 的地方★：组 margv（`<java> [选项] -cp <cp> <A2Entry> --plan <json>`）、用 R4 单点拼 classpath、转发开关 `a2_launch_runtime_enabled` |
| `Air2/Player/A2LaunchSession.[hm]` | Player | 一次启动的编排：解析目录/账号（Core）→ 产出计划（Core）→ 组命令行（Bridge）→ 建 VM；★开关默认关★，关时零副作用 |

**与既有实现的边界**：本组**不新建任何启动语义** —— 主类名、classpath 形态、
资源注入、回退门、严格门、`[VS-GAP]` 校验一律沿用 `Natives/Context/a2_launch.[hm]` 的既有契约。
`classpath` 仍只由 `a2_resourcepaths.m` 的 `a2_paths_build_classpath` 一处拼装（Core 不 import Natives，
故由 Bridge 组 argv 时调用，并把同一份 `frontJar/librariesPath/lwjglDir` 传给 `A2LaunchInput`
—— 否则 `a2_launch` 的漂移校验会返回 `-9` 阻断启动）。

**开关**：`debug.rt_p1_runtime`（设置 → 诊断 → 运行环境 · 启动链）/ env `RT_P1_RUNTIME` /
标志文件 `$POJAV_HOME/rt_p1_runtime.enable`。默认关 ⇒ 首页「启动游戏」行为不变。

**来源**：`D:\CTF\_AIR2_LAUNCH_PATH.md`。

### LWJGL 补丁类归属 —— [LWJGL-PATCH]

**决策**：`org.lwjgl.*` 补丁类放 **Java 侧、独立 jar**（`air2-lwjgl-patch.jar`，源在
`JavaApp/src/lwjgl/`），在 classpath 上排**最前**（先于 `libs/lwjgl-<ver>/*`，同名类覆盖）。

理由：① 它们是 **Java 类**，MC 按**类名**引用 ⇒ 不可能放 Natives；② `Bridge` 依规范只是
「ObjC ↔ Natives 的类型转换与生命周期转发」通道，不是字节码容器 ⇒ 放 Bridge 会让它承担
「Java 类宿主」职责；③ 与自研启动核心（`air2-launch.jar`）是**两件事**，共用一个名字会让
「哪一半在包里」说不清（见 §JavaApp）。

| 路径 | 层 | 职责 | 随包目标 |
|---|---|---|---|
| `JavaApp/src/lwjgl/**` | JavaApp | LWJGL 补丁源码（层 2） | `build/air2-lwjgl-patch.jar` → `<App>/Java/` |
| `JavaApp/src/lwjgl/META-INF/air2-lwjgl-patch.list` | JavaApp | ★已落 / 剩余清单★（包内可判） | 同 jar 内 |

**现状（★[A2-GLFW-REUSE-1]：路线由「净室重写」改为「复用老树」★）**：已落 **10 个类** ——
复用老树（`D:\CTF\_510src\runtime_native`，GPL-3.0）的 9 个覆盖类
（`GLFW` / `Callbacks` / `GLFWNativeCocoa` / `GLFWNativeEGL` / `CallbackBridge` /
`GLFWWindowProperties` / `STBImageResize` / `Callback` / `CallbackI`）
+ 1 个 Air2 新增的编译期注解补丁（`javax/annotation/Nullable`，★A2-LWJGL-1★，理由见文件头）。
逐文件来源/许可/适配登记在 `docs/DEPENDENCIES.md`「自研替换 · 复用登记」；
包内清单 `META-INF/air2-lwjgl-patch.list` 记录「已落 + 未落及原因」。
未落 3 个（`GLFWVulkan` 缺 lwjgl-vulkan jar、`APIUtil` 签名属老树自带 jar、`InfdevMouse` 需 Caciocavallo）。
★仍需与 `Natives/Input` 的 native 符号一起落位才是完整通路★（见 `D:\CTF\_AIR2_GLFW.md` §①/§③）。

**构建**：`JavaApp/Makefile` 的 `lwjgl` / `verify-lwjgl` 目标；
随包由 `scripts/gen_xcodeproj.py` 的「Build Java Launch Core」脚本阶段完成（两个 jar 同一阶段）。

### 渲染后端「显式选择 + 加载」接线 —— [RENDER-WIRE]

**缺口（接线前）**：`Libraries/Renderers/libmetallum.dylib` 虽随包（见 [RT-BUNDLE]），
但启动链里**没有任何一步引用它** —— 出包后主二进制里扫不到这个渲染器名。

**接线**（★只新增，不改既有段落★）：

| 文件 | 层 | 职责 |
|---|---|---|
| `Natives/Renderer/a2_renderer.[hm]` | Natives | 单一职责：**选后端 + `dlopen`**。不解析版本/账号、不拼路径（frameworksPath 由上层按「路径只由一处拼装」传入）、不含 Metal 具体逻辑 |
| `Air2/Bridge/A2LaunchRunner.m` | Bridge | ★唯一调用点★：组 java 命令行**之前**调 `a2_renderer_load_metal(frameworksPath)`。理由同 [LAUNCH-PLAN] 决策 2 —— Bridge 是唯一与 Natives 相邻的层 |
| `scripts/gen_xcodeproj.py` | 构建 | `NATIVES_INCLUDE_DIRS` 增 `$(SRCROOT)/Natives/Renderer`（Bridge 以裸文件名 import 它，与 Natives/Context、Natives/Support 同款做法） |

**判据（机器可查，非推断）**：出包后主二进制内可扫到 `libmetallum.dylib`
（常量 `A2RendererMetalDylibName`）+ 运行期日志行
`[A2-RENDERER] 已显式选择并加载 Metal 后端：libmetallum.dylib <- …`。

**开关**：**无独立开关** —— 该调用只在自研启动链内发生，而链整体由 `debug.rt_p1_runtime`
（默认关）决定 ⇒ 开箱行为不变（同 [LAUNCH-PLAN]）。

**边界（本单未做）**：只做「选择 + 加载」这一步，**不含** Metal 后端与 JVM 侧的对接
（出画面不在本单范围）；`libmetallum.dylib` 本体仍是既存随包物，未改动字节。

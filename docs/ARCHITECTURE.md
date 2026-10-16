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
| `Natives/Support/a2_remotexpc_framing.[hm]` | **Natives** | **[A2-RXPC] RemoteXPC 编解码**（公开规格 §4）：HTTP/2 帧（前导/SETTINGS/WINDOW_UPDATE/HEADERS/DATA）+ HPACK（静态表 + 不索引字面量；★不做 Huffman/动态表★）+ XPC 消息与对象（Null/Bool/Int64/UInt64/Double/Date/Data/String/UUID/Dict/Array）；判据行出口 `A2RXPCLog` |
| `Natives/Support/a2_remotexpc_session.[hm]` | **Natives** | **[A2-RXPC] RemoteXPC 会话**：可注入字节通道 `A2RPByteStream` + 初始化握手（§4 七步）+ `exchangePairingData:kind:startNew:reason:`（发一条 pairingData TLV、同步取回下一条）+ 错误分类 `A2RemoteXPCErrorKind` + 内存字节通道（单测用） |
| `Natives/Support/a2_rppairing_pairsetup_transport.[hm]` | **Natives** | **[A2-RXPC] 传输实现**：NWConnection 字节通道（§2b 建连 / 被接受）+ 缝 `A2RPPairSetupMessageTransport` 在 RemoteXPC 之上的实现 `A2RPPairSetupRemoteXPCTransport`（同仓存在 `a2_rppairing_pairsetup.h` 时条件声明遵守）+ §2a 可用性如实回报 |
| `Natives/Support/a2_rppairing_pairable_host.[hm]` | **Natives** | **[A2-RXPC] iOS 27 设备发起配对**：`_remotepairing-pairable-host._tcp` 通告契约（SipHash-2-4 → `authTag`、TXT 记录、服务名截断、协议版本 26）+ NWListener 真广告/真接受 + 四类失败分类 + 整层判据行 `A2RXPCReportLayerReadiness` |
| `Natives/Support/a2_rppairing_pairsetup_accessory.[hm]` | **Natives** | **[JIT-AUTOPAIR-4] 设备发起配对的★最后一跳★**：把 pairable-host 广告与 pair-setup 的 **accessory/device 侧**会话接到一起 —— 新主机身份/altIRK → 广告 → 等连入 → 建传输 → ★先收后发★ 驱动 PS-Msg01..06 → 交出配对文件字节；阶段观察者（starting/advertising/connected/verifying/succeeded/failed/cancelled）+ 逐条判据行 `[A2-PAIRPIN]`；单测用假广告器 + 假传输在 macOS 上把整条链真跑（`tests/JIT/pairwire_tests.m`） |

**来源**：`docs/JIT-PROVISIONING.md` §1.2 / §3.3 / §3.6；许可口径见 `docs/DEPENDENCIES.md`「JIT 自动配对」节
（★自研；只参考公开协议描述，未用任何第三方代码★）。

**[JIT-AUTOPAIR-4] 的设备发起档接线（★改点清单，共 6 处★）**：`A2JITAutoPairingEngineBridge`
（★唯一驱动入口★ `startDeviceInitiatedPairingWithHostName:displayedCode:budget:stageHandler:reason:failureName:`
+ `cancelDeviceInitiatedPairing`）→ `a2_rppairing_pairsetup_accessory`（上表）→
`A2RPPairSetupSession.runAccessoryOverTransport:…`（★先收后发★的 accessory 侧驱动，落在
`a2_rppairing_pairsetup.[hm]`）→ 缝 `A2RPPairSetupMessageTransport` 的**两个可选原语**
（`receivePairingDataWithKind:timeout:reason:` / `sendPairingData:kind:startNew:reason:`；
★既有 `exchangePairingData:` 的语义一个字没改★）→ `A2RPPairSetupRemoteXPCTransport` 与
`A2RemoteXPCSession`（收/发两半，exchange = 发 + 收）→ 设置页 `Air2/UI/Screens/Settings/A2JITSettings.m`
的「开始配对 / 取消 / 状态」两行。①「生成 6 位码并交给已有 UI/持久化」仍由既有
`A2JITPairingCodeSession`（Player）承担 —— Bridge 不得反向依赖 Player（ADR-002），故驱动入口**消费**它显示的码。

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

#### 启动时运行时事实 → 两个 VM 级 `-D` —— [LAUNCH-PLAN-FACTS]

**要修的是什么**：复用线覆盖层 `GLFW.java` 读两个 JVM 系统属性，且读它们的地方是
`static { … }` **静态块**（`:538` `getProperty("glfw.windowSize").split("x")`、
`:557` `Integer.parseInt(getProperty("UIScreen.maximumFramesPerSecond"))`）——
`glfw.windowSize` 直接决定 MC 认到的帧缓冲尺寸（见 `_AIR2_GLFWNATIVE.md` §⑦-6）。
装 GLFW 类那一刻就跑 ⇒ 任何「晚于 VM 启动」的注入（如 `A2Entry` 落属性）都赶不上 ⇒
**只能由 VM 级 `-D` 落下**。此前全仓无人设置 ⇒ 真机装载 GLFW 类即 NPE。

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Utils/A2LaunchRuntimeFacts.[hm]` | Utils | ★运行时事实值对象★（屏幕像素尺寸 / 系统最大帧率）；`"<宽>x<高>"` 格式的**唯一实现处**；`0`/`nil` = 没取到。放 Utils 是因为它要跨 Bridge（产出）/Player（中转）/Core（消费）三层，而 Core 与 Bridge 互不可见（严格单向） |
| `Air2/Bridge/A2LaunchRunner.[hm]` | Bridge | ★真来源★：`+currentRuntimeFacts` 读宿主窗口像素尺寸（`bounds × screen.scale`，与老树 `SurfaceViewController::updateSavedResolution` 同口径）与 `UIScreen.mainScreen.maximumFramesPerSecond`；调用点唯一 = `A2LaunchSession` 的计划产出段 |
| `Air2/Core/Version/A2LaunchPlan.[hm]` | Core | `runtimeFacts` 字段 + `jvmOptionsWithMemoryMB:` 里落成 `-Dglfw.windowSize` / `-DUIScreen.maximumFramesPerSecond`（★取不到就不下发★，不填猜的值） |
| `Air2/Utils/A2LaunchContract.[hm]` | Utils | 两个系统属性名（ABI 级契约，与 `GLFW.java` 那两行的字面量逐字相同） |
| `scripts/verify_launch_planprops.py` | 构建 | 机器自证：消费端（Java）↔ 产出端（ObjC）的格式与字面量对齐、接线顺序、**阴性对照**（无「猜的默认值」兜底） |
| `tests/Plan/` | tests | ★真编译 + 真运行★的单测：把 `A2LaunchPlan` 与 `A2LaunchRuntimeFacts` 真的跑一遍，断言产出的两条 `-D` 字符串、以及★缺真值时一条都不产出★（入口 `run_plan_tests.py`） |

**为什么采集在 Bridge（而不是 UI/Core）**：`Core` 明文不得 import UIKit
（§Core「可单测，不依赖 UIKit」）；`Player` 也不感知 UIKit（同层 `A2JITLocalFactsSource`
把 UIKit 探测留给更上层）；Bridge 是启动链唯一与 Natives 相邻的跨层入口，
链上只有它读 UIKit 不越界。**取值来源是系统真实值，不是估算**。

**开关**：无独立开关 —— 只走 `debug.rt_p1_runtime` 那条自研链。

**未做/前提**：Air2 的游戏 surface 尚未落地（渲染器到「选 + 加载」为止，见 [RENDER-WIRE]；
「拿表面 + 建上下文」这一段见 [GL-BRIDGE]），
故现取「承载游戏的宿主窗口」的像素尺寸；专用 surface 落地后只需改
`+currentRuntimeFacts` 一处。详见 `D:\CTF\_AIR2_PLANPROPS.md` §⑦。

### JIT ↔ 建 VM 串联 —— [JIT-VM-WIRE]

**要接的是什么**：启动时按住「**① 下发 JIT 脚本 → ② 探 JIT 可用 → ③ 建 VM**」的顺序走；
★JIT 不可用 ⇒ 如实阻断并告知怎么开（不静默回退）★。此前 `A2LaunchSession` 直接调
`A2LaunchRunner`（**跳过**了 `A2LaunchChain` 的 ①②）⇒「建 VM 前没有 JIT 前置」。

依赖严格单向（App → UI → Player → Core → Bridge → Natives）；★Bridge 是唯一与 Natives 相邻的层★，
所以 ①（`a2_jit_send_script_safe`）与 ③（`a2_launch_jvm_with_argv`）的调用点都只在 Bridge。

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Player/A2LaunchChain.[hm]` | Player | ★顺序与状态的唯一真相源★：`stage` / `failureReason`；① 失败不拦路、② 失败拦路（绝不进 ③）。本单**零改动** |
| `Air2/Bridge/A2JITScriptDelivery.[hm]` | **Bridge** | ① ★唯一调用 `a2_jit_send_script_safe` 的地方★：定位随包 `AmethystJIT69.js` 并下发（失败不拦路）|
| `Air2/Bridge/A2JITEnvironmentProbe.[hm]` | **Bridge** | ② 真调判据（**已有**；本单不改其语义）|
| `Air2/Bridge/A2LaunchRunner.[hm]` | **Bridge** | ③ ★唯一调用 `a2_launch_jvm_with_argv` 的地方★（**已有**）|
| `Air2/Player/A2LaunchFailure.[hm]` | Player | ★失败分类唯一实现★：`chain.stage` ⇒ 4 类；② 的判据行 / 用户文案按 7 档 verdict 分流（复用 `A2JITVerdictGuidance` + `A2JITStrings`，不另造表）|
| `Air2/Player/A2LaunchSession.[hm]` | Player | 编排改动：开关两条判据行 + 组装并 `runWithError:` 上链（后台队列）|

**★单一真相源★**：「走到哪一步 / 为什么停」只由 `A2LaunchChain.stage` + `.failureReason` 一处持有；
JIT 是否可用只由 `A2JITEnvironment.lastRegionVerdict`（经 probe）一处给出。
★禁止★ 各路径用局部 BOOL 记 JIT 状态（历史误判形态）—— `tests/JIT/jit_logic_tests.m` §⑱ 有源码级回归断言。

**开关**：沿用 `debug.rt_p1_runtime`（**默认关** ⇒ 首页行为与旧版逐字相同）；开 / 关两条路都有判据行 `[A2-CHAIN] 开关=…`。

**来源**：`D:\CTF\_AIR2_JITVM.md`；设计口径见 `docs/JIT-PROVISIONING.md` §2.4（「先 JIT 后启 JVM」）。

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
★后续★：「拿表面 + 建出可用 GL 上下文」这一段见 [GL-BRIDGE]（本单在此之上）。

### 设置里的「渲染器 / Java 运行时」两张列表 + 接线到启动 —— [RENDER-SEL] / [JRE-SEL]

**用户口径**：「像 Air 一样做一个渲染器选择列表，先放一些必要的，然后再选 JRE 就能启动」
⇒ 三件事：① 渲染器列表 ② Java 运行时列表 ③ 选完就能启动（选中的值真的进启动链）。

**数据侧（Core，纯逻辑、可单测）**

| 文件 | 层 | 职责 |
|---|---|---|
| `Air2/Core/Renderer/A2RendererCatalog.[hm]` | Core | ★渲染器候选表 + 包内存在性★（标识 = dylib 文件名，与老线 `utils.h` 的 `RENDERER_NAME_*` 同一词汇表）；档位 主推 / 兼容底 / 实验；★未内置的候选也留在表里★（用户要看得见全表、选了要如实报）。登记进既有 `A2Renderers` 注册表（不另造解析） |
| `Air2/Core/Version/A2JavaRuntimeCatalog.[hm]` | Core | ★Java 运行时候选表（25/21/17/8）+ 可用性判据★；候选目录名与本机 Amethyst 产物同血统；可用 = `<javaHome>/lib/server/libjvm.dylib` 在（= `a2_vmloader` 的首选布局），**不是**「目录在」 |
| `Air2/Player/A2RuntimeStrings.[hm]` | Player | 四语（zh-Hans / zh-Hant / en / ja）文案表（同 `A2JITStrings` 的决策与形态：本仓无 i18n 基建，放纯逻辑件里可单测） |

**持久化（Air2 自己的 `NSUserDefaults`，★不是老线 `$POJAV_HOME` 下的 plist★）**

| 键 | 取值 | 写点（唯一） | 读点（唯一） |
|---|---|---|---|
| `A2SelectedRenderer`（`A2SelectedRendererPrefKey`） | 渲染器 dylib 文件名 | `A2RuntimeSettings.m` 渲染器行 | `A2LaunchSession.m` |
| `A2SelectedJavaRuntime`（`A2SelectedJavaRuntimePrefKey`） | `java_runtimes/<目录名>` 的目录名 | `A2RuntimeSettings.m` Java 运行时行 | `A2LaunchSession.m` |

两个键定义在 `Air2/Utils/A2LaunchContract.h`（跨层契约常量的家：UI 写、Player 读）。
缺键 = 未选择 ⇒ 用主推（`libmetallum.dylib` / `java-25-openjdk`）。

**UI**：`Air2/UI/Screens/Settings/A2RuntimeSettings.m`（新分组「运行环境」挂在「游戏」分类下，
由 `A2SettingsViewController.m` 的 `index == 0` 分支挂上）—— 两行各弹一个 `UIAlertController`
action sheet 列全部候选，**未内置的项照列但标「未内置」**（老线是直接隐藏；本单按用户口径改成可见）。

**接线到启动（选完就能启动）**

| 环节 | 文件 | 行为 |
|---|---|---|
| 渲染器 | `A2LaunchSession.m` → `A2LaunchRunner.m` → `Natives/Renderer/a2_renderer.m` | Player 读偏好 ⇒ 交给 Bridge ⇒ `a2_renderer_load_named(dylib, frameworksPath)` dlopen。★未内置 ⇒ 返回 -1，Bridge 返回 -10 **阻断启动**（不静默换一个渲染器）★ |
| Java 运行时 | `A2LaunchSession.m` → `A2LaunchRunner.javaHome:` → 启动计划 | 选中的目录名拼成 `javaHome` 交给启动链（与 `A2LaunchPlan` / `A2LaunchInput.javaHome` 对接）。★不可用 ⇒ 阻断★；另区分「整份 java_runtimes 没随包」（构建问题）与「只是选的那一档没内置」（选项问题） |
| 失败文案 | `Air2/Player/A2LaunchFailure.m` | `-10` / `-11` 的翻译（所选渲染器 / 所选 JRE 不可用） |

**判据行（真机 grep 锚点）**

```
[A2-RENDERER] chosen=libmetallum.dylib(源: 默认; source=default)
[A2-RENDERER] chosen=libgl4es_114.dylib(源: 用户选择; source=user)
[A2-JRE] chosen=java-25-openjdk(源: 默认; source=default)
[A2-JRE] chosen=java-21-openjdk(源: 用户选择; source=user)
[A2-RENDERER] ★阻断启动★：所选渲染器未内置（libnggl4es.dylib）—— 包内缺 Frameworks/…
[A2-JRE] ★阻断启动★：所选档未内置/不完整（java-21-openjdk）—— 期望 …/lib/server/libjvm.dylib
```

中文与稳定 tag（`source=user` / `source=default`）并存：真机换语言也能机器判据。

**随包**：`scripts/gen_xcodeproj.py` 的「Stage Runtime Bundle」阶段 —— ①渲染器 dylib +
①b ★`.framework` 依赖目录★（GL4ES 需要 ANGLE 的 `libEGL.framework` / `libGLESv2.framework`，
它们是**目录**，`[ -f ]` 的旧循环会跳过）+ ②LWJGL jar + ③JRE。★不手改 `project.pbxproj`★。

**测试**：`tests/Runtime/run_runtime_tests.py`（★真编译 + 真运行★）—— 候选表 / 默认项 /
包内存在性 / 可用性判据 / 四语齐全 / 接线自证（谁调它哪一行）+ 随包件存在性 + 阴性对照。

**来源**：老线 `runtime_native`（GPL-3.0，只读参考）：`Natives/utils.h`（`RENDERER_NAME_*`）、
`Natives/LauncherPreferences.m`（渲染器候选表 + `rendererLibraryExists` 过滤）、
`LauncherPreferences.m:351 getSelectedJavaHome`（JRE 分档选择）。★只拄口径，未搬运代码★。

### 渲染器 surface / GL 桥（缺口③）—— [GL-BRIDGE]

**缺口（接线前）**：`[RENDER-WIRE]`/`[RENDER-SEL]` 只做到「选 + `dlopen`」——
用户看得见列表、选得中，但选中的后端**拿不到 surface、也建不出 GL 上下文** ⇒ 出不了画面。

**本单补的**：把「宿主表面 → 已选后端」真的接上，并**建出一条可用的 GL 上下文**。

**接口（★与渲染器解耦★）**：`Natives/Renderer/a2_gl_bridge.h` 的 `A2GlHostSurface` ——
★只含五样★：原生窗口句柄 + 像素格式 + 尺寸（这三样**复用** `Natives/Input/a2_glfw_window.h`
的中立表面描述 `A2GlfwSurface`，★不另造平行结构★）+ 帧回调 + 已选渲染器名。
`a2_gl_bridge.m` 里 **不出现任何 Metal 专有 API**（`CAMetalLayer`/`MTLDevice`… 命中 = 0），
也不 import 任何图形后端头 —— 只按 Khronos 公开 ABI 自声明最小 EGL 类型。
机器判据：`tests/Natives/gl_bridge_tests.m` §⑤ 的解耦断言（带阴性对照组）。

| 文件 | 层 | 职责 |
|---|---|---|
| `Natives/Renderer/a2_gl_bridge.[hm]` | Natives | ★GL 桥★：按已选后端名从 `<App>/Frameworks/` 加载 EGL/GLES 兼容底 + 后端本体，建 EGL display/config/context/surface，取函数指针表，在**帧回调**里做一次 `glClear`（可判据动作） |
| `Air2/Bridge/A2LaunchRunner.m` | Bridge | ★唯一调用点★：`a2_renderer_load_named` 之后调 `a2_gl_bridge_attach`；宿主表面在主线程采集（同 `+currentRuntimeFacts` 的口径），帧回调交给桥 |
| `Air2/Player/A2LaunchFailure.m` | Player | `-12` 的用户文案翻译 |

**阻断口径（★不静默回退★）**：

| 情形 | 返回 | 行为 |
|---|---|---|
| 选中的后端**不是** EGL/GL 系（如主推 Metal） | `A2GlBridgeSkipped`(1) | **不阻断** —— 它的建面归它自己；本桥不假装能替它建面，也不换成别的后端 |
| 是 EGL/GL 系，但缺库 / 无表面 / EGL 建面失败 | 负值（-1/-2/-3/-4） | Bridge 返回 **-12 ⇒ 如实阻断启动**（缺什么由 `[A2-GLBRIDGE]` 判据行点名） |

**判据行（真机 grep 锚点）**：

```
[A2-GLBRIDGE] 后端判定：selected=libgl4es_114.dylib ⇒ EGL/GL 系，本桥负责建面
[A2-GLBRIDGE] 后端判定：selected=libmetallum.dylib ⇒ 非 EGL/GL 系，本桥不负责其建面（跳过…）
[A2-GLBRIDGE] 已加载兼容底：EGL=…/libEGL.framework/libEGL handle=…；GLESv2=… handle=…；后端=… handle=…
[A2-GLBRIDGE] EGL 就绪：display=… config=… context=… surface=…（1170x2532 像素；像素格式=0）
[A2-GLBRIDGE] 帧回调 #1 已执行 glClear（color=0,0,0,0；1170x2532 像素）glGetError=0x0 ⇒ GL 上下文可用
[A2-GLBRIDGE] ★阻断★：包内缺该后端所需的库 …（未内置）⇒ 不静默回退到默认渲染器
```

**开关**：**无独立开关** —— 该调用只在自研启动链内发生，链整体由 `debug.rt_p1_runtime`
（默认关）决定 ⇒ 开箱行为不变（同 [RENDER-WIRE]）。

**测试**：`tests/Natives/run_gl_bridge_tests.py`（★真编译 + 真运行★）—— 判据/常量、后端判定、
返回码契约、`attach` 四个分支（不归本桥 / 无表面 / 缺库 / 加载失败）、接线自证 + 解耦自证 + 阴性对照。
★真建面（EGL 成功）需 iOS 设备，属真机判定表项★。

**来源**：老线 `runtime_native/Natives/ctxbridges/gl_bridge.m`（GPL-3.0，★只读行为约定★：
`EGLNativeWindowType` 取 `layer` 的行为事实、`eglCreateWindowSurface` 带/不带尺寸属性的两种尝试）。
★未搬运任何代码★。

### 帧性能判据 + 分辨率缩放（与渲染器无关）—— [FRAME-PERF]

**要解决的是什么**：缺一套「**与后端无关**的帧性能判据」——不依赖任何具体渲染器，
就能在真机上回答「现在每秒多少帧、每帧多久、提交了多少绘制、纹理/帧缓冲占多少、
这一帧有没有新建着色器或管线、测量处于预览态还是真实态」；并且能**降内部分辨率**换帧率。

**① 判据行 `[FRAME]`（默认可见，每 N 帧一行，不是每帧一刷）**

```
[FRAME] 指标口径：★无真实 GPU 时间★ ⇒ cpu_fps/cpu_ms 为 CPU 帧时间…（一次性，附着前打）
[FRAME] frame=5 phase=preview cpu_fps=59.7 cpu_ms=16.74 draw=1 tex≈6512KB shaderNew=0 presented=1 scale=0.75 px=878x1899 clear=878x1899
[FRAME] frame=10 phase=preview …
[FRAME] frames=0 ⇒ ★无帧样本★…（帧生产者未产出帧时如实报，不补默认值）
```

- `cpu_fps` / `cpu_ms`：**CPU 帧时间**（相邻两帧记录之间的墙钟差及其倒数）。
  ★拿不到真实 GPU 时间 ⇒ 明确以 `cpu_` 前缀标注为代理指标，不冒充 GPU 时间★。
- `draw`：本帧提交的绘制/清屏命令数（★代理指标★；帧生产者只清屏 ⇒ 1）。
- `tex`：drawable 字节**估值**（宽 × 高 × 4，非真实纹理内存占用）。
- `shaderNew`：本帧是否新建着色器/管线（帧生产者不建 ⇒ 0；由上报方给值，不替它猜）。
- `phase`：`preview`（附着后的**基线帧**，不代表游戏负载）/ `real`（游戏/渲染器接管后）。
- `scale=… px=…x… clear=…x…`：渲染倍率、缩放后的 drawable 像素、本帧**实际清屏区域**
  （scissor 读回 ⇒ 「本帧真的按缩放尺寸清屏」有可核对证据）。

**② 分辨率缩放（render scale）**

| 键 | 取值 | 写点（唯一） | 读点（唯一） |
|---|---|---|---|
| `A2SelectedRenderScale`（`A2SelectedRenderScalePrefKey`） | 受支持倍率的十进制字符串（`0.50`/`0.75`/`1.00`） | `A2RuntimeSettings.m` 渲染分辨率行 | `A2LaunchSession.m` |

- 候选与归一化唯一实现在 `Air2/Core/Renderer/A2RenderScaleCatalog.[hm]`（起始三档 0.5/0.75/1.0，
  默认 1.0）；缺值/非数值/超范围 ⇒ 默认档，★不猜中间值★。
- 落到表面上的那一步唯一：`A2LaunchRunner.m` 把宿主的**表面像素**乘倍率后交给桥，
  ★`widthPoints`/`heightPoints`（逻辑尺寸）原样不动★ ⇒ 「逻辑尺寸不变、drawable 像素变小」。
- 帧侧证据：桥每帧把这些像素设进 `glViewport`/`glScissor` 再清屏，并**读回 scissor box**；
  该值与缩放后的 drawable 一致才叫「真的按缩放尺寸清屏/呈现」。

**③ 文件与调用点**

| 文件 | 层 | 职责 |
|---|---|---|
| `Natives/Renderer/a2_frame_perf.[hm]` | Natives | ★帧判据的唯一实现处★：只收**中立数值**（像素/毫秒/字节/0-1 标志），出 `[FRAME]` 一行。★不含任何后端名★ |
| `Natives/Renderer/a2_gl_bridge.[hm]` | Natives | 帧动作按缩放尺寸设 viewport/scissor → 清屏 → 读回 scissor box（证据）→ 呈现 → 记数；新增可重复调用的帧生产入口 `a2_gl_bridge_present_frame()` |
| `Air2/Bridge/A2LaunchRunner.m` | Bridge | 应用倍率（只改像素）→ 设帧判据环境/相位 → 附着 → 驱动一小段**基线帧**（预览态）→ 每 N 帧打一行；交给游戏前切 `real` 相位 |
| `Air2/Player/A2LaunchSession.m` | Player | 读倍率偏好 → Core 归一化 → 判据行 `[A2-RENDER] chosen=…` → 传给 Bridge |
| `Air2/UI/Screens/Settings/A2RuntimeSettings.m` | UI | 渲染分辨率行（三档 action sheet）＝ 倍率键的唯一写入点 |
| `scripts/verify_frame_perf_native.py` | 构建 | 机器自证：本层**后端专有名命中 = 0**（带阴性对照）+ 每个对外函数**有调用点**（禁石山）；挂进 `scripts/lint_structure.sh` §8 |
| `tests/Natives/`、`tests/Runtime/` | tests | ★真编译 + 真运行★：帧判据行字段/相位/缩放像素/CPU 时间、倍率候选表与归一化、接线自证 |

**边界（本单不做）**：不优化任何具体渲染器；不引入真实帧源（渲染器仍只到「选 + `dlopen`」），
故本包内 `[FRAME]` 只有 `phase=preview` 的基线帧 —— `real` 相位已接线但无帧样本。
★真 GPU 时间/真实 draw call/纹理占用需渲染器上报，未做★。

**开关**：无独立开关 —— 相关调用只在自研启动链内发生，链整体由 `debug.rt_p1_runtime`
（默认关）决定 ⇒ 开箱行为不变（同 [RENDER-WIRE]）。



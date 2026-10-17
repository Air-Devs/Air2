# Air2 JIT 供给：按系统分级策略 · 状态机 · Provider 设计

本文是 Air2 【JIT 取得】的权威设计文档，与 `docs/DECISIONS.md` ADR-009 配套。
分级表在本文件与 `Air2/Player/A2JITStrategySelector.m` **只有一处实现**（代码为实现、本文为口径），
改动必须两处同改，避免漂移。

范围：**只讲「怎么把 JIT 拿到手」**。「拿到之后怎么建 VM」见 ADR-007 / `A2LaunchChain`。

---

## 0. 结论速览

| 系统 | 策略（枚举） | 一句话 |
|---|---|---|
| iOS 26 | `A2JITStrategyBuiltInManual` 内置手动 | 导入配对文件 → 连 LocalDevVPN → **App 内**开启；★不开自动配对★ |
| iOS 27+ | `A2JITStrategyAutomatic` 自动 | **设备内自动配对**（自研 RPPairing），不导入、不用外部工具 |
| iOS 17 / 18（17.4+） | `A2JITStrategyImportedExternal` | 导入配对文件 + **外部工具**（StikDebug / SideStore…）开启 |
| iOS 16 及更早 / 越狱 / TrollStore | `A2JITStrategyKernel` 内核级 | 内核级 JIT，**不靠外部调试器、不需配对文件** |
| iOS 17.0–17.3（纯签名） | `A2JITStrategyUnavailable` | 无可用路径（远程调试式 JIT 需 17.4+） |

**决策来源**：用户拍板（2026-10-07）——
「iOS 26 的手动、iOS 27 的自动；17 / 18 还是走配对文件；16 及更早走内核级」。
分级依据的源码事实见 `D:\CTF\_AIR2_JIT_BUILTIN.md`（PocketJ / SideInstaller 解剖 + 许可核实）。

---

## 1. 分级策略表（逐档写全）

> 每档固定六栏：前置条件 / 取得路径 / 失败回退 / entitlement 与签名 / 状态分支 / 许可与合规。

### 1.1 iOS 26 —— 内置手动（`BuiltInManual`）

| 项 | 内容 |
|---|---|
| **前置条件** | ① 签名带 `get-task-allow`（免费/开发签名默认具备，AltStore/SideStore 即属此类）；② 已导入本机配对文件；③ LocalDevVPN 已装（提供 loopback 路由 `10.7.0.1:49152`）；④ 首次需联网下载 DDI |
| **取得路径** | **② 导入配对文件** →（连 VPN）→ **App 内开启 JIT**（内置 helper，**独立进程**+ExtensionKit `AppExtensionProcess`/XPC）→ 状态机 |
| **失败回退** | ② 无文件 / 导入失败 ⇒ ③ 外部工具（`stikdebug://` 等）⇒ 都不行 ⇒ `Unavailable`，提示条按 `A2JITFailureReason` 分流 |
| **entitlement / 签名** | host：`get-task-allow`（**必需**，因为要附加的是主 App 进程）、`extended-virtual-addressing`、`increased-memory-limit`（JVM 用）。helper 作为 App 内扩展**随主 App 一起签，不需额外证书** |
| **状态分支** | `WaitingPairing`（缺配对）→`Paired`→`WaitingActivation`→`Enabled`；Provider = `A2JITImportedPairingProvider` |
| **许可** | 第二阶段若 vendor StikJIT：**MPL-2.0**（文件级 copyleft，须保留许可/版权声明，改过的文件须开源该文件）；`idevice` **MIT**；★**不得**引入 PocketJ 的 `Natives/stikdebug/`（派生自 StikDebug **AGPL-3.0**）★ |

★ **"手动"的确切含义**：不自动生成配对文件（那是 iOS 27 的事），也不自动拉起外部工具——
由用户在设置页完成「导入 + 开启」，本类只负责状态机与判据。

### 1.2 iOS 27+ —— 自动（`Automatic`）

| 项 | 内容 |
|---|---|
| **前置条件** | ① Developer Mode 开启；② 本地网络权限（Bonjour 广告）；③ `get-task-allow`；④（首次）联网取 DDI ★[JIT-DDI-1] ④ 已升级为【真三态探测】：已就位 / 缺失 / 无法确认（见 §3.4）★ |
| **取得路径** | **① 设备内自动配对**（自研 RPPairing：RSD host + pair-verify + TLS-PSK 隧道）→ App 内开启 JIT |
| **失败回退** | ① 失败/未接入 ⇒ ② 导入 ⇒ ③ 外部工具 ⇒ `Unavailable` |
| **entitlement / 签名** | 同 1.1，另加 Info.plist `NSLocalNetworkUsageDescription` + `NSBonjourServices`（**不需** multicast entitlement） |
| **状态分支** | 同 1.1，但 Provider 优先 `A2JITAutomaticPairingProvider` |
| **许可** | 自研；底层用 `idevice`(**MIT**)。**必须避开 SideInstaller 代码**（自定义许可：非商业 + 禁止再分发构建，只可参考协议思路） |

★ 设备内自动配对**只对 iOS 27 有效**：18–26.7 仍需配对文件 + PC（SideInstaller `README.md:81-85`）。

### 1.3 iOS 17 / 18（17.4–25）—— 导入 + 外部（`ImportedExternal`）

| 项 | 内容 |
|---|---|
| **前置条件** | ① 已装外部工具（URL scheme 可打开）；② `get-task-allow`（外部工具要 attach 主 App） |
| **取得路径** | **② 导入配对文件** + **③ 外部工具**开启（`stikdebug://` / `stikjit://` / `sidestore://`） |
| **失败回退** | 无外部工具 ⇒ `Unavailable` + 文案「安装 StikDebug / SideStore…」 |
| **entitlement / 签名** | `get-task-allow`（必需）；scheme 探测需 `LSApplicationQueriesSchemes` 白名单（★[JIT-IMPL-2] 已落地★：stikdebug / stikjit / sidestore / stosdebug，见 `Air2/Info.plist`） |
| **状态分支** | `WaitingPairing`→`Paired`→`WaitingActivation`→`Enabled`；Provider 优先 `A2JITImportedPairingProvider`，开启逐级回退到 `A2JITExternalToolProvider` |
| **许可** | **零 vendor**：只走外部 App 的 URL scheme，不派生其代码 |

### 1.4 iOS 16 及更早 / 越狱 / TrollStore —— 内核级（`Kernel`）

| 项 | 内容 |
|---|---|
| **前置条件** | 越狱（且用户为本 App 打开了 JIT / `Allow JIT`）**或** TrollStore（其 JIT 能力）**或** 签名带 `dynamic-codesigning` |
| **取得路径** | 内核级 JIT 直启 —— **不靠外部调试器、不需配对文件、不需隧道** |
| **失败回退** | 环境不具备 ⇒ `Unavailable`（原因 `KernelJITUnavailable`），文案指向「去越狱设置打开 JIT / 用 TrollStore」 |
| **entitlement / 签名** | 越狱：`get-task-allow` / `platform-application`（依越狱而异）；TrollStore：`no-sandbox` + `get-task-allow` + 磁盘标记 `jb.pmap_cs.custom_trust` |
| **状态分支** | `isPairingReady = 内核环境具备` ⇒ **直接 `Paired`**（不经 `WaitingPairing`）→ `WaitingActivation` → `Enabled`；Provider = `A2JITKernelJITProvider` |
| **许可** | 零 vendor |

★ **铁律（见 ADR-007 / `A2JITEnvironment`）**：**"环境能提供 JIT" ≠ "本进程现在能用 JIT"**。
越狱/巨魔识别**只用于选路径**；就绪判据必须是**真实能力**（发一次 `brk #0x69` 拿到真映射，
或匿名页执行式自证）。第二阶段接线时必须复用 `Natives/Support/A2JITEnvironment`。

★ **纯签名 iOS 16 及更早**：无远程调试式 JIT（需 17.4+）、又无内核环境 ⇒ 落 `Kernel` 策略但其
Provider 自报不可用 ⇒ 最终 `Unavailable`。这是**如实口径**，不要用文案假装有解。

### 1.5 不存在的档：iOS 17.0–17.3（纯签名）

`A2JITStrategyUnavailable`；原因 `SystemTooOld`。

---

## 2. 状态机与 Provider 设计

### 2.1 状态机（`A2JITState` + `A2JITFailureReason`）

```
                    ┌──────────────────────────────────────────┐
                    │            A2JITStateUnavailable          │
                    │  （带 A2JITFailureReason 原因枚举）        │
                    └──────────────────────────────────────────┘
                                     ▲
   refreshState / acquirePairing     │ 无可用路径 / 系统过低 / 开启失败
                    ┌────────────────┴────────────────┐
                    │                                 │
        ┌───────────┴───────────┐          ┌──────────┴──────────┐
        │ A2JITStateWaitingPairing│──取配对─▶│   A2JITStatePaired   │
        │      （等待配对）        │          │      （已配对）       │
        └───────────────────────┘          └──────────┬──────────┘
                                                        │ enableJIT
                                             ┌──────────▼──────────┐
                                             │ A2JITStateWaitingActivation│
                                             │     （等待开启）      │
                                             └──────────┬──────────┘
                                                        │ 开启成功
                                             ┌──────────▼──────────┐
                                             │  A2JITStateEnabled   │  ★终态，不再复位★
                                             └─────────────────────┘
```

原因枚举 `A2JITFailureReason`（失败提示条**按此分流**，严禁一句万能文案）：
`SystemTooOld` / `NoProvider` / `PairingMissing` / `AutoPairingNotBuilt` / `ExternalToolMissing` /
`TunnelUnreachable` / `ActivationFailed` / `KernelJITUnavailable`。

- **`refreshState`** 是纯评估：先按 `A2JITFacts` 选**策略**，再在策略内取**第一条可用 Provider**；
  **不触发开启**。`Enabled` 是终态，一次探测抖动不复位。
- **`acquirePairingWithError:`**：按策略内优先级**逐条尝试** `preparePairingWithError:`，
  任一成功即重评估；全失败报**最后一条**的原因。
- **`enableJITWithError:`**：只对 `isPairingReady` 的 Provider **逐条尝试** `activateJITWithError:`；
  全失败则**停留在 `WaitingActivation`**（配对材料仍在，不回退到未配对）并回填 `ActivationFailed`。

### 2.2 四路可插拔 Provider（协议 `A2JITProvider`）

```
                 ┌──────────────────────────────────────────┐
                 │           <A2JITProvider>                 │
                 │  kind / displayName / isAvailable /       │
                 │  isPairingReady / userActionHint?         │
                 │  preparePairingWithError: / activateJIT…  │
                 └───────┬────────┬────────┬────────┬────────┘
        ┌────────────────┘        │        │        └────────────────┐
        ▼                         ▼        ▼                         ▼
 AutomaticPairing          ImportedPairing  ExternalTool          Kernel
 （① 自动，27+）            （② 导入，17.4+） （③ 外部工具）        （④ 内核级）
```

| Provider | `isAvailable` | `isPairingReady` | 适用策略 |
|---|---|---|---|
| `A2JITAutomaticPairingProvider` | `supportsAutomaticPairing`（≥27） | ★[JIT-AUTOPAIR-1] 真探测★：容器里有一份【新鲜】的可用配对文件 ⇒ YES；否则 NO（`preparePairing` 会先查前置条件、再（有界）尝试生成） | `Automatic` |
| `A2JITImportedPairingProvider` | `supportsRemoteDebugJIT`（≥17.4） | ★真探测★ `A2JITPairingFileStore.hasUsablePairingFile`（容器约定位置找 + 解析） | `BuiltInManual` / `Automatic` / `ImportedExternal` |
| `A2JITExternalToolProvider` | ★`supportsRemoteDebugJIT && hasExternalEnablerInstalled`★（未安装 ⇒ 不可用，编排层不选、设置页置灰写「未安装」） | `hasExternalEnablerInstalled` | `BuiltInManual` / `Automatic` / `ImportedExternal` |
| `A2JITKernelJITProvider` | `hasKernelJITEnvironment` | = `isAvailable`（无需配对） | `Kernel` |

★ **[JIT-IMPL-2] 开启一律以「真能力」为准**：②③④ 三条路径的 `activateJITWithError:` 都经
注入的 `A2JITReadinessProbe`（真机 = `Bridge/A2JITEnvironmentProbe` → `Natives/Support/A2JITEnvironment`）
复验，按 `A2JITRegionVerdict` 如实判成败；★未注入判据内核时如实失败，不假装成功★。

策略 → 尝试顺序（`A2JITStrategySelector.orderedProviderKindsForStrategy:`）：

| 策略 | 顺序 |
|---|---|
| `Automatic`（27+） | 自动 → 导入 → 外部 |
| `BuiltInManual`（26） | 导入 → 外部（★**不含自动**★） |
| `ImportedExternal`（17/18） | 导入 → 外部 |
| `Kernel`（16-/越狱/巨魔） | 内核 |
| `Unavailable` | — |

★ **四路都是"插件"**：编排层只认协议。第二阶段的真实机制（RPPairing、XPC helper、隧道、
`canOpenURL`、`brk` 复验）**不改编排层**，只把对应 Provider 的占位方法替换为经 Bridge 落到
`Natives/Support` 的实现。

### 2.3 环境事实（`A2JITFacts`）—— 为什么要有这一层

Player 只编排、不跨界（ADR-002）。版本号、越狱/巨魔形态、配对文件是否存在、外部工具是否可拉起、
签名能力（`get-task-allow` / `dynamic-codesigning`）这些**平台事实**由 **App 装配处**从
`Natives/Support` 取好后构造 `A2JITFacts` 注入 ⇒ Player 侧全是**纯逻辑**（可单测）。

★ 事实变化（用户导入配对文件、装好外部工具、App 回前台重探）→ 由 App **重建 `A2JITFacts` 与
Provider**（本单不做热更新；后续可给 Coordinator 加 `updateFacts:`）。

### 2.4 与 `A2LaunchChain` 的接线（只接一个钩子）

```
UI（启动按钮）
   └─▶ A2JITCoordinator.prepareJITThenRunLaunchChain:error:
            ├─ JIT 未启用 ⇒ enableJITWithError:   … 仍不就绪 ⇒ ★不运行启动链★（返回 NO）
            └─ JIT 已启用 ⇒ A2LaunchChain.runWithError:  （① 发脚本 → ② 探测 → ③ 建 VM）
```

★ **不改 `A2LaunchChain` 的任何公开行为**（本单对 `A2LaunchChain.h/.m` 零改动）；
两者不互相 import（Coordinator 的 `.m` 单向引用 `A2LaunchChain.h`）。
★ 未就绪时**绝不带病建 VM**（否则首帧 JIT 取指 SIGBUS）。

---

## 3. 本单落的代码（见文末提交 sha）

| 文件 | 说明 |
|---|---|
| `Air2/Player/A2JITProvider.h/.m` | 协议 `A2JITProvider` + `A2JITStrategy`/`A2JITProviderKind` 枚举 + 统一错误构造 |
| `Air2/Player/A2JITFacts.h/.m` | 本机环境事实（不可变值对象）+ 版本能力判定 |
| `Air2/Player/A2JITStrategySelector.h/.m` | ★分级表唯一实现★：事实 → 策略 → Provider 顺序 |
| `Air2/Player/A2JIT{AutomaticPairing,ImportedPairing,ExternalTool,KernelJIT}Provider.h/.m` | 四路 Provider（**占位 + 能力检测**） |
| `Air2/Player/A2JITCoordinator.h/.m` | 状态机 + 逐级回退 + 「先 JIT 后启 JVM」钩子 |

**本单边界**：四路 Provider 的 `preparePairingWithError:` / `activateJITWithError:` 一律为占位
（返回 NO + 可读原因），因此本单**不会真正开启 JIT**；带来的是：**分级策略可判定、状态机可跑、
回退顺序可观测、UI 文案可按原因分流**。
（★[JIT-IMPL-2] 已把 ②导入 / ③外部 / ④内核 三条路径改为真实现，见 §3.2；
★[JIT-AUTOPAIR-1] 已把 ① 自动配对 从「占位」改为【真能力探测 + 前置条件检查 + 配对文件新鲜度】，
见 §3.3 —— 但真正的 RPPairing 握手（RSD + pair-verify + TLS-PSK）仍是【骨架】，如实报未接入★。）

### 3.1【JIT-IMPL】纯逻辑件实现 + 单测（后续一轮）

在上述骨架上把四件「纯逻辑」做成**真能跑、可单测**的实现（★不新增第三方、不碰真实机制★）：

| 文件 | 变更 |
|---|---|
| `Air2/Player/A2JITFacts.h/.m` | 新增探测接缝 `A2JITFactsSource`（协议）+ `factsWithSource:` ⇒ 事实可注入假数据单测 |
| `Air2/Player/A2JITStrategySelector.h/.m` | 新增 `decisionForFacts:`（策略 + 失败原因）；分级表仍唯一在此 |
| `Air2/Player/A2JITStateMachine.h/.m` | **新增**：纯状态机（`A2JITState`/`A2JITFailureReason` 定义处 + 合法迁移表） |
| `Air2/Player/A2PairingFile.h/.m` | **新增**：配对文件解析/校验（RemotePairing + lockdown PairRecord，兼容 base64） |
| `Air2/Player/A2JITLocalFactsSource.h/.m` | **新增**：本机事实薄探测适配器（Foundation-only） |
| `Air2/Player/A2JITCoordinator.h/.m` | 状态迁移改为委托 `A2JITStateMachine`（非法迁移被拒） |
| `Air2/UI/Screens/Settings/A2JITSettings.m` | **新增**：设置「运行环境 · JIT」面板（状态 + 导入 + 开启，按策略启停） |
| `Air2/UI/Components/A2SettingsRow.h/.m` | 新增 `enabled`（禁用态整行变暗且不响应） |
| `tests/JIT/jit_logic_tests.m` + `run_jit_tests.py` | **新增**：★编译被测真实实现★的单元测试（分级/配对/状态机/事实探测） |

★单测直接 `clang` 链接 `Air2/Player` 下真实 `.m` 运行（非 Python 镜像）★：
`python3 tests/JIT/run_jit_tests.py` ⇒ 每例 PASS/FAIL 与计数。
★仍未做★：真实 XPC / RPPairing 隧道 / 自动配对 / 越狱·巨魔·entitlement 的真机取证
（属 §4 第二阶段）。

### 3.2【JIT-IMPL-2】iOS 26 主线打通（判据接线 + 导入 + 外部工具 + 面板/四语/单测）

在 §3.1 的纯逻辑之上，把「判据内核」真正接到四路 Provider 上（★仍不 vendor 任何第三方★）：

| 文件 | 层 | 变更 |
|---|---|---|
| `Air2/Player/A2JITReadinessProbe.h` | Player | **新增**：判据注入缝（协议）+ `A2JITReadinessVerdict`（逐值镜像 `A2JITRegionVerdict`）|
| `Air2/Player/A2JITExternalToolLauncher.h` | Player | **新增**：外部工具拉起缝（协议；真机实现用 UIApplication）|
| `Air2/Player/A2JITVerdictGuidance.h/.m` | Player | **新增**：★判据分流表★（verdict → 失败原因 / 下一步动作 / 本地化 key / 日志行）|
| `Air2/Player/A2JITStrings.h/.m` | Player | **新增**：面板四语文案表（zh-Hans / zh-Hant / en / ja；key 稳定，便于日后迁 `.lproj`）|
| `Air2/Player/A2JITPairingFileStore.h/.m` | Player | **新增**：导入落盘（约定位置 `Library/Application Support/Pairing/pairingFile.plist`）+ 元数据（来源 / 时间 / SHA-256 / 格式 / 设备标识）|
| `Air2/Bridge/A2JITEnvironmentProbe.h/.m` | **Bridge** | **新增**：★真调判据的那一层★——逐字转发 `A2JITEnvironment.ensureVerifiedWithinBudget:reason:`，实时读 `lastRegionVerdict` / `regionEvidence`；带 `_Static_assert` 镜像防线 |
| `Air2/UI/Components/A2JITSystemToolLauncher.h/.m` | UI | **新增**：`UIApplication` 拉起 `stikdebug://enable-jit` 等 |
| `Air2/Player/A2JITImportedPairingProvider.h/.m` | Player | 占位 → 真实现：就绪=真探测文件；开启=真调判据；失败文案按 verdict 分流 |
| `Air2/Player/A2JITExternalToolProvider.h/.m` | Player | 占位 → 真实现：未安装即不可用；拉起 + ★有界等待★（轮询判据，超时即失败）|
| `Air2/Player/A2JITKernelJITProvider.h/.m` | Player | 占位 → 真调判据【复验】（★不做内核级启用★）|
| `Air2/Player/A2JITCoordinator.h/.m` | Player | 新增装配工厂 `providersWithFacts:probe:launcher:pairingFileStore:`；评估时输出「选中路径」日志 |
| `Air2/UI/Screens/Settings/A2JITSettings.m` | UI | 面板重做：状态 / 档位 / 下一步动作 / 判据取证（★按 verdict 分流★）/ 导入（`UIDocumentPicker`）/ 外部工具（未安装置灰）/ 开启（后台队列）|
| `Air2/Info.plist` | — | 新增 `LSApplicationQueriesSchemes`（stikdebug / stikjit / sidestore / stosdebug）|
| `tests/JIT/*` | tests | 新增 ⑥–⑪ 共 ~158 例（判据分流 / 四语齐全 / 落盘记录 / 外部工具有界等待 / 真调判据 / 接线不变量）|

★ **仍未做（本单明确不做）★**：iOS 27 设备内自动配对（§4.2）、iOS 26 内置 helper
（ExtensionKit XPC，§4.1）、内核级 JIT 的真实启用、TrollStore 自开 JIT，
以及 `A2JITEnvironment` 判据语义的任何改动。

### 3.3【JIT-AUTOPAIR-1】iOS 27+ 自动配对（自研 RPPairing）—— 第一阶段

把 ① 自动配对 从「占位」做成【真能力探测 + 前置条件检查 + 配对文件新鲜度 + 有界生成调用点】。
★本阶段**不做**真正的 RPPairing 握手★（Bonjour 广告 / RSD / pair-verify / TLS-PSK 属 §4.2，下一阶段）；
引擎在仓内以【Bridge 骨架】如实报「未接入」，★绝不假成功★。

| 文件 | 层 | 变更 |
|---|---|---|
| `Air2/Player/A2JITAutoPairing.h/.m` | Player | **新增**：类型（前置条件 4 项 / 步骤 6 步 / 阻塞分类 14 档）+ `A2JITAutoPairingPreconditions`（三态值对象）+ `A2JITAutoPairingEngine` 协议（注入缝）|
| `Air2/Player/A2JITAutoPairingGuidance.h/.m` | Player | **新增**：自动配对分流表（blocker → 现有 `A2JITFailureReason` / 本地化 key / 稳定诊断名 / 日志行）|
| `Air2/Player/A2JITAutomaticPairingProvider.h/.m` | Player | **占位 → 真实现**：能力检测（≥27）/ 就绪真探测（新鲜文件）/ 前置条件精确报缺哪项 / ★有界★生成调用点 / 开启时真调判据复验 |
| `Air2/Bridge/A2JITAutoPairingEngineBridge.h/.m` | **Bridge** | **新增**：RPPairing 引擎的【接线点骨架】——`isEngineAvailable=NO`、`readPreconditions` 全 Unknown、`generate` 返回 `EngineUnavailable`（如实报未接入）|
| `Air2/Player/A2JITCoordinator.h/.m` | Player | 新增装配工厂 `providersWithFacts:preconditions:engine:probe:launcher:pairingFileStore:`（旧签名等价于 preconditions/engine 传 nil）|
| `Air2/Player/A2JITStrings.m` | Player | 新增 **44 个 key × 4 语**（自动配对行 / 前置条件名与判定态 / 14 档 blocker 的原因与动作 / 提示）|
| `Air2/UI/Screens/Settings/A2JITSettings.m` | UI | 新增「自动配对（推荐）」行 + **一键开展**（后台队列）+ 失败按 blocker 分流（四语）|
| `tests/JIT/*` | tests | 新增 ⑫⑬ 两组（~70 例）：能力/前置/新鲜度/有界生成/★不谎报★/分流表四语/接线不变量 |

★ **「不谎报」的三条硬判据（真机可核对）★**：
1. 前置条件三态：**Unknown（无法确认）≠ Satisfied（已满足）** —— 探测未接入时报「无法确认」，绝不当作满足；
2. 引擎未接入 ⇒ 用 `A2JITProviderNotImplementedError`（code=1），与「真实执行失败」（code=2）分开；
3. 引擎报成功但容器里没有可解析的配对文件 ⇒ **不视为成功**（报 `WriteFailed`）。

★ **仍未做（属 §4.2 下一阶段）★**：Bonjour 广告与设备发现、RSD 连接、pair-verify、
TLS-PSK 隧道、DDI 的真取用（联网个性化请求与 image_mounter 挂载）、
`readPreconditions` 其余三项的真读实现（Developer Mode / 本地网络 / get-task-allow）。

### 3.4【JIT-DDI-1】DDI（Developer Disk Image）—— 本地优先的取得与三态判定

把 ① 自动配对前置条件里的 **④ DDI** 从「一律 Unknown（探测未接线）」做成 **真三态**
（**已就位 / 缺失 / 无法确认**）。★本单只做到【本地优先 + 如实阻断】★：
真正的【联网个性化请求】与【image_mounter 挂载】属 §4.2 下一阶段，
在仓内以 **Bridge 骨架**如实报「未接入 / 缺什么」，★绝不假成功★。

| 文件 | 层 | 变更 |
|---|---|---|
| `Air2/Player/A2JITDDI.h/.m` | Player | **新增**：类型（来源 / 形态 / 5 态判定 / 三态对齐）+ `A2JITDDIRequirement`、`A2JITDDIImage`、`A2JITDDIStatus` 值对象 + 纯逻辑（版本对齐、新鲜度、判定 → 前置条件三态）+ 设备侧查询协议 `A2JITDDIDeviceQuery` |
| `Air2/Player/A2JITDDIStore.h/.m` | Player | **新增**：本地镜像的发现 / 校验（UDIF 尾标 `koly`）/ **手动导入**（与配对文件同机制）/ 落盘记录（来源 / 时间 / SHA-256 / 声明版本） |
| `Air2/Player/A2JITDDIProbe.h/.m` | Player | **新增**：判定合成（本地镜像 + 设备侧查询 ⇒ 三态），★唯一实现★；另有「联网取 / 挂载」的调用点（如实转发） |
| `Air2/Player/A2JITDDIGuidance.h/.m` | Player | **新增**：DDI 分流表（5 态 → 前置条件三态 / 本地化 key / 稳定诊断名 / 日志行） |
| `Air2/Bridge/A2JITDDIDeviceBridge.h/.m` | **Bridge** | **新增**：设备侧查询的【接线点骨架】——设备侧判定回 `Unknown`、能力查询回 `NO`、联网取与挂载回 `NO` + 确切缺什么（如实报未接入） |
| `Air2/Player/A2JITAutomaticPairingProvider.h/.m` | Player | 新增 `ddiProbe:` 注入；**生效前置条件** = 注入值 +（有探测时）以探测结果覆盖 DDI 那一项 |
| `Air2/Player/A2JITCoordinator.h/.m` | Player | 新增装配工厂 `providersWithFacts:preconditions:engine:ddiProbe:probe:launcher:pairingFileStore:`（旧签名等价于 ddiProbe 传 nil） |
| `Air2/Player/A2JITStrings.m` | Player | 新增 **约 37 个 key × 4 语**（DDI 行 / 开关行 / 5 态状态·原因·动作 / 下一步动作 / 机制阻塞 / 提示） |
| `Air2/UI/Screens/Settings/A2JITSettings.m` | UI | 新增「DDI」状态行、「导入 DDI 镜像」行、「**联网取 DDI**」行（★[PAIRFIX] 起改为「未实现」如实态行 —— 原来那个只写偏好的开关是摆设★）+ 失败分流文案 |
| `tests/JIT/*` | tests | 新增 ⑭⑮ 两组 + 接线不变量 ⑩（DDI 纯逻辑 / 本地存储 / 判定合成 / 四语 / Provider 接线 / 分层纪律）|

★ **「不谎报」的三条硬判据（真机可核对）★**：
1. **版本对齐是三态**：镜像未声明版本/构建号、或系统构建号取不到 ⇒ 一律 **不匹配「无法确认」**，
   绝不猜成匹配（单测覆盖六个分支）；
2. **判定 Unknown ≠ Missing**：`A2JITDDIVerdictUnknown` 只映射到前置条件 `Unknown`；
   探测未接线 / 目录不可读 / 元数据不足时一律 **Unknown**，★不许升成「已满足」，也不许降成「缺失」★；
3. **机制未接入就如实阻断**：联网获取与镜像挂载都返回 `NO` 并**点名缺什么**，★不假成功★。

★ **「联网取 DDI」的边界（★[PAIRFIX] 起：无开关，UI 如实标「未实现」★）★**：
★机制未接线★（Bridge 骨架如实回 `NO` + 点名缺什么）⇒ 不给用户「能下」的期待。
行仍可点，点了走真机制调用点并如实报缺什么；原先那个「开关只写偏好」的写法已删 —— ★那是摆设★。
★完全离线也能用★：本地发现 + 手动导入两条路都在，不依赖联网。

★ **流程口径（以公开实现的行为为准，见 §3.4 末「与 StikDebug 对照」）★**：
公开实现（StikDebug）的 DDI 获取**不是**向 Apple 的个性化（TSS）端点申请，而是
**按系统版本选一种镜像形态**（iOS ≥ 26.4 走 cryptex、否则 personalized）→
**从固定 HTTPS 直链下载一小撮文件**（BuildManifest.plist / Image.dmg / Image.dmg.trustcache，
cryptex 另加 cryptex_info 与 root_hash）→ **经 RPPairing 隧道调用设备的 image_mounter 挂载**。
★它不需要设备标识参与取件★。本仓采用同一套**结构**（选形态 → 取文件集 → 校验 → 挂载），
但**只把「本地优先」这一段做真**；联网取与挂载是**调用点 + 如实阻断**。

★ **DDI 的判定口径★**：本项判定 = 「本机（App 视角）是否具备一份与系统匹配的可用 DDI 镜像」；
**设备侧已挂载**属加分项（可查时才算证据；查不到不影响本地结论，且在取证里写明「设备侧不可查」）。
公开实现同样把挂载状态做成三态（已挂载 / 未挂载 / **不可达**），与本仓的
「已就位 / 缺失 / **无法确认**」是一一对应的口径。

### 3.5「与 StikDebug 的对照」（★只参考行为，未采用其代码★）

| 环节 | StikDebug（AGPL-3.0，**只读参考**） | Air2（本单） | 是否采用 |
|---|---|---|---|
| 镜像形态选择 | 按系统版本：>26 或 26.x(≥4) ⇒ `cryptex`；否则 `personalized` | ★未做★（不选形态，只做本地镜像的三态判定） | ✗ 未采用（需隧道才谈得上挂载） |
| 取件来源 | 固定 HTTPS 直链，指向**第三方 GitHub 镜像仓**的 Apple DDI 文件集 | ★未做★（**来源选型未拍板**：第三方镜像 vs Apple 分发） | ✗ 未采用（合规待定） |
| 取件清单 | `BuildManifest.plist` / `Image.dmg` / `Image.dmg.trustcache`（cryptex 另加 `Image.dmg.cryptex_info`、`Image.dmg.root_hash`） | 本地发现面 = 约定目录 + `Documents/DDI`+`Documents`；写入面 = 单个约定名 | ✓ 结构同形（探测面宽、写入面窄） |
| 落盘位置 | App `Documents/DDI/`，并写一个 `MountMethod` 标记 | App `Library/Application Support/DDI/` + `ddi.meta.plist`（来源/时间/SHA-256/声明版本） | ✓ 结构同形 |
| 挂载 | 经 idevice FFI：RPPairing 隧道 + RSD + `image_mounter`（cryptex / personal 两条路） | **调用点**（`mountCurrentImageWithReason:` → Bridge）；★未接线，如实报缺什么★ | ✗ 未采用（机制未落地） |
| 挂载状态 | 三态：mounted / notMounted / **unreachable** | 三态：已就位 / 缺失 / **无法确认** | ✓ 口径同形 |
| 设备标识（UDID/芯片 ID） | ★取件与挂载都**不需要**它参与★ | 已按此**移除** `uniqueChipID`（不留无调用方的字段） | ✓ 已对齐 |

★ **红线★**：StikDebug 为 **AGPL-3.0**，本单**只读其公开源码以确认「行为/流程」**，
**未拷贝任何代码/常量/文件**，也**未引入其依赖**（`libidevice_ffi.a` 未入仓）。
上表里「结构同形」指的是**独立自研的同一种做法**（探测面宽 / 写入面窄 / 三态口径），不是代码复用。

---

### 3.6【JIT-AUTOPAIR-2】RPPairing **真握手本体**（pair-verify 消息机 + 自研密码学，RFC 向量自证）

本阶段把 §4.2-a 的「**握手本体**」做成真实现：**pair-verify 消息机（M1→M4）+ 密钥交换 + TLV8 +
Bonjour 发现/连接 + 线上 JSON 信封**，并把上一阶段卡住的两个密码学原语**自研落地**。
★协议事实来源★ = 公开协议描述（RPPairing 规格 §1–§12：帧/信封/TLV8/配对文件/pair-verify/隧道），
**不采用任何项目源码**（StikPair / StikDebug / idevice 一行未抄）。

| 文件 | 层 | 变更 |
|---|---|---|
| `Natives/Support/a2_rppairing_chacha.h/.m` | **Natives** | **新增（自研）**：ChaCha20-Poly1305（RFC 8439）—— 含 ChaCha20 流、Poly1305（5×26 位肢体）、AEAD seal/open（常数时间认证校验） |
| `Natives/Support/a2_rppairing_ed25519.h/.m` | **Natives** | **新增（自研）**：Ed25519（RFC 8032 §5.1）—— 5×51 位肢体域运算、扩展坐标点运算、mod L 标量运算；★非常数时间★（一次性握手用，已在头文件声明） |
| `Natives/Support/a2_rppairing_crypto.h/.m` | **Natives** | X25519/HKDF-SHA512/摘要/UUIDv3 之外，**Ed25519 与 ChaCha20-Poly1305 改为真自检**（随机种子派生→签→验→**坏签名必须被拒**；seal→open + **坏 tag 必须被拒**） |
| `Natives/Support/a2_rppairing.h/.m` | **Natives** | 新增 **TLV8 编解码**（>255 自动分片 + 解码并回 + 截断报错）、**身份**（`A2RPPairingIdentity`：Ed25519 密钥对 + `uuid_v3(NAMESPACE_DNS, hostname)`；配对文件往返；★私钥派不出公钥就拒绝★）、自检升级为**含 pair-verify 自握手** |
| `Natives/Support/a2_rppairing_verify.h/.m` | **Natives** | **新增**：★pair-verify 握手本体★ —— Host/Device 双角色会话、M1/M2/M3/M4 状态机、`shared_secret = X25519(...)`（= TLS-PSK 的 PSK）、`HKDF-SHA512("Pair-Verify-Encrypt-Salt"/"…Info")`、ChaCha20-Poly1305 信封（nonce `\0\0\0\0PV-Msg02`/`PV-Msg03`）、Ed25519 签名/验签、§10 主密钥派生；**★进程内自握手自证★**（双方 PSK/主密钥一致 + 篡改必须被拒） |
| `Natives/Support/a2_rppairing_rsd.h/.m` | **Natives** | **新增**：Bonjour 服务类型与传输路径映射（§2）、流式帧读取器、hostOptions/pairingData/createListener 信封、**NWBrowser 发现 + NWConnection 连接 + 真跑 pair-verify**、TLS-PSK 配置构造与**能力如实点名** |
| `Air2/Bridge/A2JITAutoPairingEngineBridge.h/.m` | **Bridge** | **真跑**：自检 → Bonjour 发现 → 连接 → hostOptions → pair-verify → 新身份 → **写入注入的配对文件存储**；失败按语义分类（DiscoveryFailed / PairVerifyFailed / WriteFailed / EngineUnavailable）并点名步骤；★没落盘就不返回成功★ |
| `Air2/UI/Screens/Settings/A2JITSettings.m` | UI | 装配处**一行注入**：把 `A2JITPairingFileStore` 交给引擎（新增代码有生产调用点） |
| `Air2/Info.plist` | 配置 | 新增 **`NSBonjourServices`**（`_remotepairing._tcp` / `_remoted._tcp` / `_remotepairing-pairable-host._tcp`）+ 本地网络用途文案补充（★未登记则 NWBrowser 一无所获★） |
| `tests/JIT/*` | tests | ⑯ 改为「真落地」口径；**新增 ⑰**（78 例）：RFC 8032/8439 向量、TLV8、身份与配对文件（含篡改拒绝）、pair-verify 自握手与负例、RSD 层、TLS-PSK 如实口径、plist 防漂移 |

★ **本阶段【已落地并自证】（有运行期证据）★**：
1. **ChaCha20-Poly1305**：RFC 8439 §2.4.2（ChaCha20 密钥流）与 **§2.8.2（AEAD 密文+标签）逐位相同**；
   另有 24 条 `cryptography`(OpenSSL) 随机向量逐位核对，且篡改 tag/密文/AAD 一律拒绝；
2. **Ed25519**：**RFC 8032 §7.1 TEST 1/2/3 的公钥与签名逐位相同**；另有 24 条 PyNaCl(libsodium)
   随机向量逐位核对；篡改签名/公钥/消息、以及 **S ≥ L** 一律拒绝；
3. **TLV8**（公开规格 §5）：编码/解码往返、>255 分片与并回、截断报错（不静默）；
4. **pair-verify 握手本体**：进程内 Host↔Device **真跑完 M1→M4**，双方 **PSK 一致**、
   **client/server 主密钥一致且两名互不相同**、**篡改 M2 的 AEAD 标签被拒**；
   负例：身份对不上（验签失败）、消息流顺序错、非 TLV 垃圾、对端 `ErrorResponse` 全部被拒；
5. **线上编解码 + 发现层**：帧（magic/长度/JSON 信封）往返、base64 pairingData 往返、
   `createListener` 端口按字符串解析（规格 §15）、Bonjour 服务类型与传输路径映射（未知类型 ⇒ Unknown）；
6. **配对文件链路**：pair-verify 成功后产出的新身份 → 配对文件字节 → **`A2PairingFile` 校验通过**
   → **`A2JITPairingFileStore` 落盘**（与既有 ②导入 同一约定位置）。

★ **本阶段【仍未落地】（如实点名，绝不假成功）★**：
1. **pair-setup（SRP-3072）**：★这是真正的「首次自配对」★——设备不认识本机时只有它能建立配对记录。
   本单没做（SRP-3072 + PS-Msg01..06 是独立一单的量级），因此**「设备内自配对」在真机上尚不能首配**；
   pair-verify 只能在**设备已经认识本机（已有配对记录）**的前提下建立会话；
2. **TLS-PSK 隧道（规格 §12）**：**公开 TLS API 给不出设备要求的套件** —— 实测 iPhoneOS26.2 SDK 的
   `SecProtocolOptions.h` 里 `tls_ciphersuite_PSK*` **一项都没有**（设备要 `0x00AF`/`0x008C`）；
   `sec_protocol_options_add_pre_shared_key` 虽在，但无法把那两套套件放进 ClientHello。
   要打通只有按 §12 **手写 TLS 1.2 PSK**（PRF/HMAC/AES-CBC/Finished）——★这是需要拍板的架构点★；
3. **RemoteXPC 连接路径（§2a/§2b）**：本单只做 §2c（裸 RPPairing socket，且规格明确它**只支持 pair-verify**）；
   §2a（USB/CoreDeviceProxy）与 §2b（`_remoted._tcp` 的 HTTP/2 + XPC 帧）未做；
4. **真机联调**：本会话**没有真机**，所以「与 iOS 27 真设备互操作」未验证 —— 自握手证的是
   **本仓实现自洽且密码学正确**，不等于对端接受（对端还要看身份/协议细节）。

★ **决策点（D1 已自行解决，D2 需拍板）★**：
- **D1（已解决）**：上一阶段的「Ed25519/ChaCha20-Poly1305 走私有符号桥 vs 引入 Swift/CryptoKit」——
  本单改为**第三条路：按 RFC 自研**（有 RFC 向量 + 独立库随机向量双重自证），
  既不动工程结构（不引 Swift），也不依赖私有 ABI；X25519 仍走系统 `cccurve25519`（已验证可用）；
- **D2（需拍板）**：TLS-PSK 隧道要么**手写 TLS 1.2 PSK**（严格照 §12，~一单工作量），
  要么换一条不依赖 PSK 套件的隧道形态（需重新核对设备侧行为）。

---

### 3.7【A2-RXPC】传输层：RemoteXPC（§2a/§2b）+ 设备发起配对（pairable host）

§3.6 把「握手本体」做真之后，还剩两个缺口：**pair-setup 在真机上走哪条传输**，以及 **iOS 27 的设备发起配对长什么样**。
本节只做【传输层】——SRP/PS-Msg 本体属 [JIT-AUTOPAIR-3]（另一单），本层给它留缝。

| 文件 | 层 | 变更 |
|---|---|---|
| `Natives/Support/a2_remotexpc_framing.[hm]` | **Natives** | **新增**：RemoteXPC（公开规格 §4）编解码 —— HTTP/2 帧 + HPACK（静态表/不索引字面量）+ XPC 消息与对象 |
| `Natives/Support/a2_remotexpc_session.[hm]` | **Natives** | **新增**：RemoteXPC 会话（初始化握手 + pairingData 交换 + 错误分类 + 超时；字节通道可注入） |
| `Natives/Support/a2_rppairing_pairsetup_transport.[hm]` | **Natives** | **新增**：真网络字节通道（NWConnection）+ 缝 `A2RPPairSetupMessageTransport` 的实现 + §2a 如实回报 |
| `Natives/Support/a2_rppairing_pairable_host.[hm]` | **Natives** | **新增**：`_remotepairing-pairable-host._tcp` 通告契约（authTag/TXT）+ NWListener 真广告/真接受 + 四类失败分类 |
| `docs/ARCHITECTURE.md` / `docs/JIT-PROVISIONING.md` | docs | 登记与本节 |
| `tests/JIT/remotexpc_tests.m` + `run_remotexpc_tests.py` | tests | **新增**：60+ 例（帧/HPACK/XPC/会话/传输缝/pairable-host 契约） |

★ **哪条路支持 pair-setup（公开规格 §2 原文口径）★**：
| 路径 | 传输 | 支持 pair-setup？ |
|---|---|---|
| §2a `com.apple.internal.devicecompute.CoreDeviceProxy`（USB） | RemoteXPC（经 CDTunnel + 用户态 TCP + RSD） | 是（但★本仓在 iOS App 内做不到★，见下） |
| §2b `_remoted._tcp` | RemoteXPC（HTTP/2 + XPC；需设备侧 ncm） | 是 |
| §2c `_remotepairing._tcp` | 裸 RPPairing socket（JSON 帧） | ★否★（规格原文：需既有配对文件，只支持 pair-verify） |
| `_remotepairing-pairable-host._tcp`（iOS 27 设备发起） | 裸 RPPairing socket（设备当 host、本机当 accessory） | 是（★这是 iOS 27 在设备内自配对的主路★） |

★ **§2a 为什么不做（如实）★**：链路要求「宿主电脑」角色（USB → usbmuxd → lockdownd → CoreDeviceProxy）；
iOS App 没有 USB 主机权限、拿不到 usbmuxd/lockdownd 的进程通道；而本仓目标是**设备内回环自配对**，
USB 前提根本不存在 ⇒ `A2RPPairSetupUSBPathAvailable()` 如实回 `NO` 并点名原因。

★ **仍未做 / 需拍板（如实点名）★**：
1. **与 iOS 27 真设备互操作未验证**（本会话无真机）—— 本层只证「按公开规格自洽」（帧/HPACK/XPC 往返、
   authTag 用公开测试向量）。
2. **HPACK 不做 Huffman 与动态表** —— 解码遇 Huffman / 动态表索引一律如实报错（不猜）；编码从不产出
   Huffman。若真机头块用了 Huffman，需补这一块。
3. **`.pairing.session` 后台保活**（用户进设置期间保活）属 **App 层接线**（需 Info.plist 的
   `BGTaskSchedulerPermittedIdentifiers` + UIApplication 的 background task）；本层只做超时中止与
   「被挂起」的可观察分类，★不假装自己保活了★。
4. **pairable-host 的会话方向与缝相反**：该路径上【设备】是 rppairing 的 host（发 `originatedBy: "host"`）、
   本机是 accessory ⇒ 驱动的是 **device 侧**（收先发后），而缝 `A2RPPairSetupMessageTransport` 是
   **host 侧**语义（发先收后）。本层把「发一条 TLV / 收下一条」做真并暴露双向能力；**由 [JIT-AUTOPAIR-3]
   的 device 侧会话驱动**（`deviceSessionWithIdentity:pin:` 那一路）。这一处是两单的**接口接缝**，需对齐。

★ **许可★**：零 vendor。只读公开规格与公开实现的**行为/接口/常量**（服务类型、TXT 键、authTag 算法、
协议版本号），未搬运任何代码。

---

## 4. 第二阶段工作拆分与工作量估算（★本单不实现★）

> 估算单位＝**人日**（含真机调试，不含外部等待/审核）。★每项标注许可红线★。

### 4.1 ② iOS 26 内置 helper（独立进程 + XPC）

| 子项 | 内容 | 人日 | 许可 |
|---|---|---|---|
| a | vendor **StikJIT 源码**（11 个 Swift 文件）进 `Libraries/` 或 `Vendor/`；保留其 **MPL-2.0** LICENSE 与版权声明；★改过的 StikJIT 文件须开源该文件★ | 1.0 | MPL-2.0（可 vendor） |
| b | `idevice`(**MIT**) 交叉编译为 iOS 静态库/`xcframework`（★不要直接搬 PocketJ 的 `libidevice_ffi.a`，约 90 MB★；走源码 + CI 构建） | 2.0–3.0 | MIT |
| c | helper 进程（ExtensionKit `app extension`）+ 主 App 侧 `AppExtensionProcess`/XPC 握手 | 2.0–3.0 | 自研 |
| d | 实现 `A2JITImportedPairingProvider.activateJITWithError:`（经 Bridge → `Natives/Support`） | 1.0 | 自研 |
| e | 真机验证（免费签名 / SideStore / TrollStore 三种渠道各一） | 1.5 | — |
| **小计** | | **7.5–9.5** | |

★ 红线：**不得**引入 PocketJ 的 `Natives/stikdebug/`（派生自 StikDebug **AGPL-3.0**，整件作品被传染）。

### 4.2 ① iOS 27 设备内自动配对（自研）

| 子项 | 内容 | 人日 | 许可 |
|---|---|---|---|
| a | RPPairing host（`pair-setup`/`pair-verify`）+ TLS-PSK 隧道，基于 `idevice`(**MIT**) crate | 4.0–7.0 | MIT |
| b | Bonjour 广告 + 本地网络权限 + Developer Mode 检测 | 1.0–2.0 | 自研 |
| c | 配对文件落盘与多候选路径探测（探测面宽、返回值窄） | 1.0 | 自研 |
| d | 实现 `A2JITAutomaticPairingProvider`（含 DDI 获取与缓存） | 2.0–3.0 | 自研 |
| e | 真机验证（仅 iOS 27 可用） | 2.0 | — |
| **小计** | | **10.0–15.0** | |

★★ **必须避开 SideInstaller 代码**（自定义许可：非商业 + 禁止再分发官方构建）——
只可参考「协议与思路」，**不得抄任何代码/常量**。

★ **进度（[JIT-AUTOPAIR-1]，§3.3）**：本节的**前置条件 + 能力探测 + 配对文件新鲜度 +
有界生成调用点**已落第一阶段（引擎以 Bridge 骨架如实报「未接入」）；
**尚未做**的是 4.2-a（RSD/TLS-PSK 握手）、4.2-b 的真读（Developer Mode / 本地网络 / DDI）与 4.2-d/e。
★ **进度（[JIT-DDI-1]，§3.4）**：4.2-d 的 **DDI 本地优先取得（发现 / 校验 / 手动导入）+ 三态判定 +
版本匹配与新鲜度** 已落；4.2-b 的 **DDI 一项** 已真读（不再是 Unknown 占位）。
★ **进度（[JIT-AUTOPAIR-2]，§3.6）**：4.2-a 的 **握手密码学内核 + 线上编解码** 已落并自证
（X25519 / HKDF-SHA512 / 帧 / 信封 / 配对文件组装）；4.2-b 的 **Developer Mode** 已真读
（get-task-allow / 本地网络仍如实 Unknown —— 均因 iOS 无公开 API）。★仍未做★：**Ed25519 / ChaCha20-Poly1305 原语**（卡点见 §3.6）、
**pair-setup(SRP-3072) / pair-verify 消息机**、**TLS-PSK 隧道**、**Bonjour 发现与 RSD 连接**。
★仍未做★：**联网个性化请求（Apple personalization / TSS）与 image_mounter 挂载**
（属 4.2-a 的一部分；需设备标识、网络与特权，仓内以 Bridge 骨架如实报未接入）。
★本节不动分级口径：iOS 27+ 仍 = `A2JITStrategyAutomatic`（与 `Air2/Player/A2JITStrategySelector.m` 同改）★。

### 4.3 ③ iOS 17 / 18 导入 UI + 外部工具拉起

| 子项 | 内容 | 人日 | 许可 |
|---|---|---|---|
| a | `UIDocumentPicker` 导入 `.plist` / `.mobiledevicepairing` + 校验入库 | 1.0 | 自研 |
| b | 外部工具探测：`LSApplicationQueriesSchemes` 白名单 + `canOpenURL:`（★探测面宽：`stikdebug` / `stikjit` / `sidestore` / `stosdebug`…） | 0.5 | 自研 |
| c | scheme 拉起 + **有界等待** + **真实能力复验**（复用 `A2JITEnvironment`），失败文案按原因分流 | 1.5–2.5 | 自研 |
| d | 与 `LocalDevVPN` 的交互（隧道就绪判定、`TunnelUnreachable` 分流） | 1.0 | 外部 App（用户自装） |
| **小计** | | **4.0–5.0** | |

★ 追外部工具**只走 URL scheme**，零 vendor。

### 4.4 ④ 接线与真机矩阵（跨档）

| 子项 | 内容 | 人日 |
|---|---|---|
| a | App 装配处（`DependencyContainer`）构造 `A2JITFacts` + 四路 Provider + Coordinator；`Natives/Support` 提供事实采集实现（版本/越狱/巨魔/文件/`canOpenURL`/entitlement） | 2.0–3.0 |
| b | `A2JITEnvironment`（真实能力复验）接进 `activateJITWithError:` 的统一出口 | 1.0 |
| c | 真机矩阵：iOS 16(越狱) / 17.4–18 / 26 / 27 × {TrollStore, SideStore 免费签名} | 3.0–5.0 |
| **小计** | | **6.0–9.0** |

### 4.5 合计

| 阶段 | 人日 |
|---|---|
| ② iOS 26 内置 helper | 7.5–9.5 |
| ① iOS 27 自动配对 | 10.0–15.0 |
| ③ 17/18 导入 + 外部 | 4.0–5.0 |
| ④ 接线 + 真机矩阵 | 6.0–9.0 |
| **总计** | **27.5–38.5** |

**建议顺序**：④-a（事实采集）+ ③（成本最低、覆盖 17.4+ 绝大多数设备）→ ②（iOS 26 覆盖）→ ①（等 iOS 27 铺开再立项）。

---

## 5. 风险 / 依赖

| # | 风险 / 依赖 | 影响 | 处置 |
|---|---|---|---|
| 1 | **iOS 26 ExtensionKit 在免费签名/侧载下未实测** | 内置 helper 可能不可用 | 第二阶段先做真机验证；不可用则 26 也回退外部工具 |
| 2 | **主进程不能自 attach**（PocketJ `StikDebugEngine.m:175-261` 整段 `#if 0`） | 决定了**必须有独立进程** | 架构上固定为 helper / 外部 App，不做进程内 attach |
| 3 | 免费账号 **7 天重签** | 配对/DDI 缓存需重走 | 文案提示「重签后重开 JIT」；缓存失效判定 |
| 4 | **DDI 首次需联网** | 无网环境失败 | 按上游 trick（蜂窝 + 飞行模式）给出指引 |
| 5 | **LiveContainer 下内置 helper 不可用** | 该形态无内置路 | 回退外部工具；文案区分 |
| 6 | `libidevice_ffi.a` 约 **90 MB** | 包体暴涨 | 走**源码 + CI 构建**，不搬预编译 |
| 7 | **许可红线** | 合规 | StikJIT=MPL-2.0（保留声明）、idevice/isideload=MIT、★StikDebug=AGPL-3.0 只可当外部 App★、★SideInstaller 禁抄禁再分发★ |
| 8 | **分支基线旧** | 无法直接 PR | 基线 `091db7a` 系；远程 `main` 已前进 ⇒ 先 rebase |
| 9 | `Air2JIT69.js` 与 StikJIT 脚本兼容性未验证 | 内置路可能需换脚本 | 第二阶段做脚本并存测试 |
| 10 | 越狱 JIT 需用户自己打开（`Allow JIT`） | 误判 | 就绪判据只用真实能力（ADR-007） |

---

## 6. 要用户再拍板的点

1. **StikJIT = MPL-2.0 是否接受 vendor 进仓**（文件级 copyleft：须保留声明、改过的文件须开源该文件）？
   —— 影响 4.1 的 ② 能否开工。
2. **iOS 27 自动配对（①）现在立项还是等铺开**？（仅 27 可用；10–15 人日；须自研、不得抄 SideInstaller）
3. **分发渠道**（TrollStore / SideStore+免费 ID / 自签 7 天）—— 决定 helper 与 entitlement 能否稳定工作。
4. **iOS 16 纯签名（无越狱/无巨魔）** 确认归为 `Unavailable` 并给出如实文案？（技术上无解）

---

## 7. 脚本侧真机回归：`Skipping: instruction was not a brk` 与 `Failed to extract registers: tid=null…`

真机（StikDebug 跑 `Air2JIT69.js`）稳定复现过这一段：

```
Skipping: instruction was not a brk (was 0xa9bf7bfd)
Continuing with signal 0x0a
…
Failed to extract registers: tid=null, pc=null, x16=null
Script failed:
```

两条真因都在**脚本侧**（本脚本血统 = 上游 `UniversalJIT26.js`，这两处上游同样有）：

1. **`vCont;S<sig>:<tid>` 是「单步」，不是「继续」。**
   debugserver `RNBRemote.cpp`：`case 'S'` ⇒ `eStateStepping`（L4072–L4083），
   `case 'C'` ⇒ `eStateRunning`（L4059–L4069）。⇒ 每次非 brk 停止，脚本只让进程前进**一条指令**，
   于是 pc 落在函数序言 `stp x29,x30,[sp,#-16]!`（`0xa9bf7bfd`）、`ret`（`0xd65f03c0`）这类任意指令上，
   判「不是 brk」，周而复始；App 永远走不到下一次 `brk #0x69`，`0x69` 真交付器一次都没被调用。
   且 vCont 只恢复被点名的那一个线程、其余线程按 `eStateStopped` 处理（多线程 App 等于被冻住）。
   **改法**：发 `C<sig>`（两位 hex，如 `C0a`）。★不能写成 `C<sig>;thread:<tid>`★ ——
   `HandlePacket_C` 会把信号之后的 `;` 当成 **PC 地址**解析。
2. **`tid=null, pc=null, x16=null` 不是「正则写错」，而是那一条回复根本不是停止回复。**
   寄存器来自 `c` 的停止回复 `T<sig>thread:<tid>;…;20:<pc>;…`（每寄存器 16 hex、小端字节序）。
   当回复是 `W<status>` / `X<sig>`（进程已退出）或 `E<nn>`（包错误）时，`T` 正则必然全不匹配 ⇒ 三个 null。
   base 此时 `continue` 空转（在同一个死进程上反复 `c`），直到宿主按 `Script failed:` 把脚本收掉。
   **改法**：`ameJITParseStopReply()` 分类（`stop`/`exited`/`error`/`empty`/`unknown`）+ **有界收尾**（连续 8 次），
   日志带上 `kind` 与回复原文前 160 字符。

顺带修掉三处「原地打转 / 整脚本抛异常」的路径：未注册的 `brk #imm` 之前不推进 PC（同一条 brk 无限重停）；
`m` 读失败时 `littleEndianHexToU32` 抛 `TypeError`（→ 宿主 `Script failed:`）；同一 pc 反复 SIGTRAP。

单测：`node tests/JIT/jit_script_tests.js` —— 98 例，用假 debugserver 直接断言**脚本发出的包**。
真机复测判据（★需用户在 StikDebug 上做，本仓库未验证★）：出现
`[AMETHYST-JIT69] hit #1: brk #0x69 BreakGetJITMapping(size=0x…) @pc=0x…`；
不再刷 `Skipping: instruction was not a brk`；`Continuing with signal … (packet 'C0a')` 只在真信号时出现。

---

## 相关文档

- `docs/DECISIONS.md` —— **ADR-009**（本文的决策条目）、ADR-007（传统 `brk #0x69` 回退）、ADR-008（内置 JIT 工作流首版）
- `docs/DEPENDENCIES.md` —— JIT 供给候选依赖与许可（★均未引入★）
- `docs/ARCHITECTURE.md` —— Player / Natives 分层与文件登记
- `D:\CTF\_AIR2_JIT_BUILTIN.md` —— PocketJ / SideInstaller 链路解剖与许可核实（本文的事实来源）
- `D:\CTF\_AIR2_JIT_PLAN.md` —— 本单交付计划与验收记录

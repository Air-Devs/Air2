# Air2 JIT 供给：按系统分级策略 · 状态机 · Provider 设计

本文是 Air2 【JIT 取得】的权威设计文档，与 `docs/DECISIONS.md` ADR-008 配套。
分级表在本文件与 `Air2/Player/A2JITStrategySelector.m` **只有一处实现**（代码为实现、本文为口径），
改动必须两处同改，避免漂移。

范围：**只讲「怎么把 JIT 拿到手」**。「拿到之后怎么建 VM」见 ADR-006 / `A2LaunchChain`。

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
| **前置条件** | ① Developer Mode 开启；② 本地网络权限（Bonjour 广告）；③ `get-task-allow`；④（首次）联网取 DDI |
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
| **entitlement / 签名** | `get-task-allow`（必需）；scheme 探测需 `LSApplicationQueriesSchemes` 白名单（第二阶段加） |
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

★ **铁律（见 ADR-006 / `A2JITEnvironment`）**：**"环境能提供 JIT" ≠ "本进程现在能用 JIT"**。
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
| `A2JITAutomaticPairingProvider` | `supportsAutomaticPairing`（≥27） | 占位 NO（自动生成未接） | `Automatic` |
| `A2JITImportedPairingProvider` | `supportsRemoteDebugJIT`（≥17.4） | `hasImportedPairingFile` | `BuiltInManual` / `Automatic` / `ImportedExternal` |
| `A2JITExternalToolProvider` | `supportsRemoteDebugJIT`（≥17.4） | `hasExternalEnablerInstalled` | `BuiltInManual` / `Automatic` / `ImportedExternal` |
| `A2JITKernelJITProvider` | `hasKernelJITEnvironment` | = `isAvailable`（无需配对） | `Kernel` |

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

**本单边界**：四路 Provider 的 `preparePairingWithError:` / `activateJITWithError:` **一律为占位**
（返回 NO + 可读原因），因此本单**不会真正开启 JIT**；带来的是：**分级策略可判定、状态机可跑、
回退顺序可观测、UI 文案可按原因分流**。

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
| 9 | `AmethystJIT69.js` 与 StikJIT 脚本兼容性未验证 | 内置路可能需换脚本 | 第二阶段做脚本并存测试 |
| 10 | 越狱 JIT 需用户自己打开（`Allow JIT`） | 误判 | 就绪判据只用真实能力（ADR-006） |

---

## 6. 要用户再拍板的点

1. **StikJIT = MPL-2.0 是否接受 vendor 进仓**（文件级 copyleft：须保留声明、改过的文件须开源该文件）？
   —— 影响 4.1 的 ② 能否开工。
2. **iOS 27 自动配对（①）现在立项还是等铺开**？（仅 27 可用；10–15 人日；须自研、不得抄 SideInstaller）
3. **分发渠道**（TrollStore / SideStore+免费 ID / 自签 7 天）—— 决定 helper 与 entitlement 能否稳定工作。
4. **iOS 16 纯签名（无越狱/无巨魔）** 确认归为 `Unavailable` 并给出如实文案？（技术上无解）

---

## 相关文档

- `docs/DECISIONS.md` —— **ADR-008**（本文的决策条目）、ADR-006（传统 `brk #0x69` 回退）、ADR-007（内置 JIT 工作流首版）
- `docs/DEPENDENCIES.md` —— JIT 供给候选依赖与许可（★均未引入★）
- `docs/ARCHITECTURE.md` —— Player / Natives 分层与文件登记
- `D:\CTF\_AIR2_JIT_BUILTIN.md` —— PocketJ / SideInstaller 链路解剖与许可核实（本文的事实来源）
- `D:\CTF\_AIR2_JIT_PLAN.md` —— 本单交付计划与验收记录

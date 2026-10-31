# 架构决策记录（ADR）

每条决策一经确立不得静默推翻。需要变更时追加新条目，并标注取代关系。

格式：`ADR-编号` / 状态 / 日期 / 背景 / 决策 / 理由

---

## ADR-001：技术栈选用 SwiftUI + 原生层 ObjC/C

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：项目目标为 iOS 端启动器，同时要复用 pojav 系后端。参考对象 ZL2 是 Android/Kotlin/Compose 工程，技术栈无法直接移植。
- **决策**：UI 层用 SwiftUI（宿主容器必要的部分用 UIKit），原生桥接层用 Objective-C/C，业务核心用 Swift，Java 层只承载启动核心与 LWJGL 补丁。
- **理由**：
  - iOS 上 Kotlin/Compose 无可用运行时，Gradle 工程无法产出 IPA
  - SwiftUI 在 iOS 26 上原生支持液态玻璃，向下兼容，符合目标体验
  - ObjC 是唯一能同时对接 JNI 与 Metal/UIKit 的语言，桥接层用它最省事

---

## ADR-002：严格单向分层，Core 不依赖 UI

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：启动器类项目容易把下载、账号、版本解析等逻辑写进 ViewController，后续无法测试也无法复用。
- **决策**：依赖方向固定为 `App → UI → Player → Core → Bridge`，Utils 为共用叶子。Core 层禁止 `import SwiftUI/UIKit`。
- **理由**：
  - Core 可脱离模拟器单测，反馈快
  - UI 改版不牵动业务逻辑
  - CI 可用 `scripts/lint_structure.sh` 机器化拦截违规，不靠人自觉

---

## ADR-003：用脚本强制规范，而非文档强制

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：项目明确要求"禁止石山代码"。仅靠文档约定无法阻止劣化，必须有机器的强制关卡。
- **决策**：`scripts/lint_structure.sh` 作为 CI 的第一个 job，检查顶层目录白名单、文件规模上限、禁用命名、跨层依赖。任一项失败即阻塞构建。
- **理由**：
  - 机器的记忆比人可靠
  - 把"要不要拆文件"这种争论变成客观阈值
  - 新增目录必须更新 `docs/ARCHITECTURE.md`，架构变更留下痕迹

---

## ADR-004：后端以源码复制而非 submodule 引入

- **状态**：待定
- **日期**：2026-10-07
- **背景**：pojav 后端可来自 Amethyst-iOS-MyRemastered。两种引入方式各有代价。
- **决策**：待定，需在首个后端集成 PR 前确定。
- **备选**：
  - **submodule**：来源清晰，同步方便；但改动上游代码需要 fork 并维护补丁分支
  - **源码复制**：可直接改，编译链可控；但上游更新需手工合并，容易脱节
  - **折中**：submodule 引入 + `patches/` 目录存放本地补丁，构建时自动应用

---

## ADR-005：目录命名统一 UpperCamelCase 单数

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：混合命名（`download` / `Downloads` / `downloads`）在大型项目中会造成认知负担。
- **决策**：目录一律 UpperCamelCase 且用单数：`Download/`、`Version/`、`Account/`。
- **理由**：与 Swift/ObjC 类型命名一致，导入路径与类型名视觉统一；单数避免"目录里到底装一个还是多个"的歧义。

## ADR-006：禁止系统输入弹窗，文本输入一律走自研 MD3 组件

- **状态**：已接受
- **日期**：2026-10-09
- **背景**：资源下载链路（如 CurseForge API Key 输入，`A2CurseForgeKeyPrompt.m`）
  使用 `UIAlertController` + `addTextFieldWithConfigurationHandler:` 收集文本。
  系统弹窗不跟随主题（亮暗 / 材料包均无法控制），横屏下样式割裂，
  也无法承载 MD3 语义色、圆角与弹簧动效，与「界面元素可被主题统一控制」的既定目标冲突。
- **决策**：**任何地方**需要用户输入文本时，禁止使用系统输入弹窗；一律使用自研的
  MD3 输入弹窗 / 内联输入视图（语义色 + 8/12/16/20/28 圆角 + 弹簧动效 + 空/错误校验态）。
  **存量弹窗按此一并替换**，不区分新老页面。
- **理由**：规范性（可主题化）、一致性（与其余 MD3 界面统一）、可控性（校验与触觉反馈）。
- **取代关系**：此前无对应 ADR，属新增约束；与既有「UI 默认 MD3」条目同源，不推翻任何旧条目。
- **落地**：见 `docs/UI-DESIGN.md` 第七节。

---

## ADR-007：JIT 采用「传统 0x69 + 自包含脚本 + 区域取证判据」

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：iOS 26+（TXM/硬化运行时）上，JVM 的 code cache 需要一块「可写 + 可执行」内存。无 `dynamic-codesigning` / `allow-jit` entitlement 的机器上，JVM 自行 `mmap(RW)+mprotect(RX)` 建 code cache 会在首帧取指时 `KERN_PROTECTION_FAILURE`/SIGBUS。可行的机制是借外部调试器（StikDebug 等）服务传统 `brk #0x69`（BreakGetJITMapping）代映射。但上游 base 脚本 `UniversalJIT26.js` 对 `brk #0x69` 只回 legacy 哨兵 `0xE0000069`（"请改用 Universal 脚本"），真正建区实现被拆在 `UniversalJIT26Extension.js` 里，且下发时机晚于门禁探测 ⇒ 死锁（门禁等真区域 → 真区域要先覆盖 0x69 → 覆盖要先下发 → 下发在门禁之后）。
- **决策**：
  - **纳入自包含脚本** `Assets/Air2JIT69.js`（派生自 `UniversalJIT26.js`，接管 `brk #0x69` 真建区），随包交付，供调试器「指派脚本」选用；
  - JIT 可用性判据**不接受「能力声明」**（CS_DEBUGGED / entitlement / TrollStore 装机），只认**真的试一次**：拿到 `brk #0x69` 交付的区域并核验 `vm_region_64` 的 `mapped=1 + size>0 + max_protection 含 EXECUTE`；
  - `brk` 一律在**专用后台线程 + 有界预算**内发出（调试器在岗却不服务时会永不返回），失败即「优雅失败」，**绝不带病创建 JVM**；
  - 落层：JIT 环境与判据在 `Natives/Support/A2JITEnvironment`，JVM 创建/销毁在 `Natives/Context/a2_vmloader`，顺序编排在 `Player/A2LaunchChain`（先发脚本 → 再探测 → 再建 VM）。
- **理由**：
  - 自包含脚本消除 base+Extension 的时序死锁，脚本可被用户一次指派、路径最短；
  - 区域取证（`max_protection` 含 X）是**设备无关**的硬证据；而「真写入+真执行」自证在 iOS 26+ 上会因 RW→RX 撤销调试器对该页的可执行祝福而恒为 inconclusive ⇒ 只能当日志、不能当判据；
  - 有界探测把「主线程永久挂起」的旧缺陷变成有界失败，UI 不受影响；
  - 分层遵守 `App → UI → Player → Core → Bridge → Natives`，Natives 只收已解析参数、不感知版本/账号。
- **来源**：`docs/_RT_P0.md`、`_RT_P0_2.md`、`_JIT_ORDER.md`（工作树 `feat/runtime-native`）。

---

## ADR-008：新启动器采用【内置 JIT 工作流】（配对 → 开启），取代「要求外部 StikDebug 指派脚本」

- **状态**：已接受（骨架已落，真机实现待接入）
- **日期**：2026-10-07
- **背景**：
  - 现状（ADR-007）走**传统 `brk #0x69` + 自包含脚本**，但脚本需由**外部 StikDebug 手动指派**；用户必须「Assign Script → 杀 App 重开」，TrollStore 场景还要单独放宽判据 —— 操作链路长且易错。
  - PocketJ Launcher（`EricoEC/PocketJLauncher`，GPL-3.0，派生自 Amethyst-iOS）已实现**内置** JIT 工作流（源码核实）：host 侧导入本机配对文件 → 起 LocalDevVPN → 在设置页开启；iOS 26+ 走内置 Helper（`PocketJJITCoordinator`/`PocketJJITHelper` 经 ExtensionKit XPC 调 vendored `StikJIT` 的 `enableJIT`，附加/分离调试器；`StikJIT` 由 `StikDebug/StikJIT` 提供，**MPL-2.0**；其依赖 `jkcoxson/idevice` **MIT**）；iOS < 26 回退到外部 `stikdebug://enable-jit`。
  - 配对文件此前必须「插电脑 / 用外部工具生成」。`FrizzleM/SideInstaller`（**自定义许可，禁止再分发**）证明可在**设备内**生成配对文件：其 `rust-core` 用 `idevice` crate 的 `remote_pairing`（RPPairing host + pair-verify + TLS-PSK 隧道）复刻 StikPair，Swift 侧仅做 Bonjour 广告（需本地网络权限 + Developer Mode，不需 multicast entitlement）。
- **决策**：
  1. 新启动器采用【**内置 JIT 工作流**】作为**主路**：在启动器内完成「配对 → 开启 JIT」，不再要求用户手动指派脚本。
  2. 引入 `Player/A2JITCoordinator`（协议 `A2JITProvisioning` + 状态机 `A2JITState`）作为**编排层**（本次仅落接口/状态机，**不 vendor 任何第三方源码/二进制**）。
  3. 配对文件的取得**优先级**：① 设备内自动生成（参考 SideInstaller 思路，**自研实现**，适用 iOS 27+）→ ② 用户导入文件（照 PocketJ，适用 iOS 17.4+）→ ③ 外部工具（StikDebug / SideStore / iLoader…，兜底）。
  4. **ADR-007 的传统 `brk #0x69` + 外部脚本路径保留为回退**：旧设备（iOS 16 / 17 早期）与 TrollStore 场景走回退；两条路的取舍见 `D:\CTF\_AIR2_JIT_BUILTIN.md`。
- **理由**：
  - 内置工作流把「指派脚本 + 杀 App 重开」两步收敛为「设置页开启」，路径最短、可诊断（状态机可见）；
  - 编排层与实现分离：配对/开启/RPPairing 都会演进，接口稳定后实现可替换，符合 ADR-002 单向分层；
  - 合规上**分两步走**：先只留接口与依赖登记，待许可证逐项核实并拍板后再 vendor（StikJIT MPL-2.0 属**文件级弱 copyleft**，vendor 需保留其文件与许可声明；idevice/isideload 为 MIT；StikDebug 为 AGPL-3.0；SideInstaller **不可 vendor**）。
- **来源**：`EricoEC/PocketJLauncher` @ `53eac78d`（`JITIntegration/**`、`Vendor/StikJIT/**`、`Natives/JavaLauncher.m`）、`FrizzleM/SideInstaller` @ `7df7d54b`（`rust-core/src/pairing.rs`、`rust-core/Cargo.toml`）。

---

## ADR-009：JIT 供给【按系统分级】，并把取得路径拆成四路可插拔 Provider

- **状态**：已接受（分级策略 + 状态机 + 四路 Provider 骨架已落；纯逻辑件 + 单测已落
  【见 `D:\CTF\_AIR2_JIT_IMPL.md`】；真实机制待接入）
- **日期**：2026-10-07
- **背景**：
  - ADR-008 确立了「内置 JIT 工作流」为**主路**，但只给了一条**单一后端**协议
    （`A2JITProvisioning`）与「① 自动 → ② 导入 → ③ 外部」的**跨系统统一优先级**；
    源码核实后发现三档系统的**可行路径差别很大**：
    · 内置 helper（ExtensionKit `AppExtensionProcess`）**只在 iOS 26+** 存在
      （`PocketJJITCoordinator.swift:5` `@available(iOS 26.0)`）；
    · **设备内自动配对**（RPPairing）**只在 iOS 27** 可行（SideInstaller `README.md:81-85`：18–26.7 仍需配对文件 + PC）；
    · iOS 17.4–25 只能「导入配对文件 + 外部工具」；
    · iOS 16 及更早 / 越狱 / TrollStore 走**内核级 JIT**（不靠外部调试器）。
  - 用户拍板（2026-10-07）：「**iOS 26 的手动、iOS 27 的自动；17/18 还是走配对文件；16 及更早走内核级**」。
- **决策**：
  1. JIT 取得策略**按系统分级**（分级表见 `docs/JIT-PROVISIONING.md`，实现唯一落在
     `Air2/Player/A2JITStrategySelector.m`）：
     · iOS 26 = `BuiltInManual` 内置手动（导入配对 → 连 LocalDevVPN → **App 内**开启；**不开自动配对**）；
     · iOS 27+ = `Automatic` 设备内自动配对；
     · iOS 17/18（17.4–25）= `ImportedExternal` 导入配对文件 + 外部工具；
     · iOS 16- / 越狱 / TrollStore = `Kernel` 内核级 JIT（不靠外部调试器、不需配对文件）。
  2. 把 ADR-008 的**单一后端**细化成**四条可插拔取得路径**，统一在协议 `A2JITProvider` 下：
     `A2JITAutomaticPairingProvider` / `A2JITImportedPairingProvider` /
     `A2JITExternalToolProvider` / `A2JITKernelJITProvider`。
     策略决定**尝试顺序**，编排层在失败时**逐级回退**（顺序见 `JIT-PROVISIONING.md` §2.2）。
  3. 本机环境事实（版本、越狱/巨魔形态、配对文件、外部工具、签名能力）抽成**不可变值对象
     `A2JITFacts`**，由 App 装配处从 `Natives/Support` 取好后注入 ⇒ Player 侧全部是纯逻辑，
     保持 ADR-002 单向分层（Player 只编排、不跨界）。
  4. 状态机保持 ADR-008 的五态，但**失败态带原因枚举** `A2JITFailureReason`（失败提示条按原因分流，
     不得用一句万能文案）。
  5. 与启动链**只接一个钩子** `A2JITCoordinator.prepareJITThenRunLaunchChain:error:`：
     **先确保 JIT 已启用，未就绪则不运行启动链**；★不修改 `A2LaunchChain` 的任何公开行为★。
  6. 本单**不 vendor 任何第三方代码/二进制**；四路 Provider 的机制方法一律为**占位**
     （返回 NO + 可读原因），真实实现 Phase 2 经 Bridge 落到 `Natives/Support`。
  7. **ADR-008 的决策 3（跨系统统一优先级）由本 ADR 取代**，其余条目继续有效；
     `A2JITProvisioning` 协议由 `A2JITProvider` ×4 取代。
- **理由**：
  - 分档后每档的**前置条件 / 回退 / entitlement / 文案**都能各写各的，不会把「26 的可行路」误用到「17 不可行」上；
  - Provider 化让「机制演进」与「编排稳定」解耦：换实现不动状态机，符合 ADR-002；
  - 事实注入让策略可脱离真机单测（`A2JITFacts` 是纯数据）；
  - 合规上仍分两步：先只留协议与占位，待许可拍板后再 vendor（StikJIT **MPL-2.0**、`idevice`/`isideload` **MIT**、
    ★StikDebug **AGPL-3.0** 只可当外部 App★、★SideInstaller 自定义许可，禁抄禁再分发★）。
- **来源**：`docs/JIT-PROVISIONING.md`（本项目）、`D:\CTF\_AIR2_JIT_BUILTIN.md`（PocketJ / SideInstaller 源码核实）、
  `D:\CTF\_AIR2_JIT_PLAN.md`（本单交付计划）。


---

## ADR-010：二级界面改 Material Design 3、去玻璃；一级页面保留玻璃

- **状态**：已接受（实现已落；真机观感验收见 `D:\CTF\_AIR2_MD3_SECONDARY.md` 的逐页判定表）
- **日期**：2026-10-16
- **背景**：
  - 用户最新口径（原话）：「你这个 ui，就是点进去二级选择界面用 metrial design 3，不用玻璃」。
    即：一级页面（启动器主页）现有观感不动；**从一级点进去的二级选择界面改用 MD3、不要玻璃**。
  - 此前 `A2BaseViewController`（二级页面基类，类注释自述「所有二级页面继承它」）在**每个二级页面**
    都挂了一张 `A2BackgroundView`：壁纸 + 用户设定的模糊材质（`UIVisualEffectView`）。
    同时 `A2GlassCard` 在**有自定义壁纸时**把填充做成半透明（亮 0.76 / 暗 0.68）。
    两者叠加 = 二级页面上「毛玻璃卡片浮在糊掉的壁纸上」，正是用户点名的玻璃观感。
- **决策**：
  1. **二级页面底板 = MD3 不透明 `surface`**：`A2BaseViewController` 不再挂 `A2BackgroundView`，
     直接 `self.view.backgroundColor = scheme.cSurface`。二级页面不放壁纸、也没有模糊层。
  2. **玻璃改成显式 opt-in**：`A2GlassCard` 新增**玻璃总开关** `glassEnabled`，
     ★默认 NO★ ⇒ 默认输出不透明的 MD3 表面（elevation 对应的 `surfaceContainer` 不透明填充
     + `outlineVariant` 描边 + 阴影）。原半透明填充与模糊只在 `glassEnabled == YES` 时生效。
  3. **一级页面是玻璃的唯一用武之地**：`A2LauncherViewController`（启动器主页）保留自己的
     `A2BackgroundView`，并在主卡/最近游玩卡上显式 `glassEnabled = YES` ⇒ 一级观感**逐像素不变**。
  4. **机器判据**：新增 `scripts/check_no_glass.py`，接入 `scripts/lint_structure.sh` 第 8 节与 CI 的 lint job：
     ① 白名单之外任何文件命中玻璃 API = 失败；② 阴性对照（一级文件命中必须 > 0，防假通过）；
     ③ ★二级清单（由 `@interface X : A2BaseViewController` 推导）命中必须 = 0★；
     ④ `A2GlassCard` 的默认值必须是 `_glassEnabled = NO`。
  5. **组件复用优先**：不新建「MD3 卡片」组件 —— `A2GlassCard` 本身就是 MD3 卡片容器
     （其头注释即写「用 surfaceContainer 的五档层级表达深度，而不是玻璃模糊」），
     玻璃只是它的一项可选能力。类名里的 “Glass” 属历史命名，本单**不改名**（改名会波及全部调用点）。
  6. **选择器也去系统玻璃**：二级界面里 9 处单选/菜单选择器原先是
     `UIAlertController` 的 **ActionSheet**（外观是系统半透明材质、不跟主题，
     且 iPad 上必须锚 popover 否则抛异常）⇒ 统一换成自研 `A2OptionSheet`
     （MD3 实心 surfaceContainerHigh 卡片 + 0.45 遮罩 + 选项行复用 A2SettingsSection/A2SettingsRow
     + 语义色 error 标注破坏性项 + 弹簧入场，居中自绘 ⇒ 不再需要 popover 锚点）。
     危险操作**确认**仍用 `UIAlertControllerStyleAlert`（air2-ui 组件规范允许），本单不动那 5 处。
     当前项标记由行上的 MD3 选中勾承担，不再往标题里塞「✓ 」前缀。
- **理由**：
  - MD3 的页面底板语义就是 `surface`；壁纸穿透 + 模糊本身就是「玻璃层」的载体，留着它就等于二级页面仍有玻璃。
  - 把玻璃收成**一个默认关闭的开关**，才能让「二级不许有玻璃」成为可被机器断言的强不变量：
    将来任何人给新二级页面加玻璃，`make lint` 直接红。
  - 一级/二级分层与「用户个性化只出现在一级」一致：个性化在主页，功能页求清晰与一致。
  - 不新建组件、不改名 ⇒ 不产生并行实现（石山），也不顺手重构。
- **影响 / 边界**：
  - 二级页面**不再显示用户壁纸**（这是本决策的可见后果，且是「不用玻璃」的必然推论：
    壁纸层就是玻璃的载体）。若后续要求「二级留壁纸但卡片不透明」，那是一条**新 ADR**，
    改动集中在 `A2BaseViewController` 一处（3 行）。
  - `A2InputDialog` / `A2ColorThemeDialog` 本来就是 MD3（`surfaceContainerHigh` + 0.45 遮罩），
    本单未改；它们由同一条断言覆盖（玻璃命中 = 0）。
- **来源**：本仓 `Air2/UI/Screens/A2BaseViewController.m`、`Air2/UI/Components/A2GlassCard.[hm]`、
  `Air2/UI/Screens/Home/A2LauncherViewController.m`、`scripts/check_no_glass.py`。

---

## ADR-011：原版下载走「国内镜像候选链 + 失败自动切源」，并发默认提到 6

- **状态**：★已退役（2026-10-17 上游同步）★ —— 用户口径「下载要留上游的」：
  上游 `origin/main` 的下载链（`A2GameInstaller` / `A2ContentSource` / `A2APIModDownloader` /
  `A2ModPackInstaller` / `A2RemoteVersions`）一律照上游实现，本 ADR 的「Mojang 域名 → bmclapi2
  候选展开」「安装并发默认 6」不再接线到任何下载器；`A2MirrorResolver` 改为上游自带的
  MCIM（Modrinth / CurseForge CDN）版本。详见 `D:\CTF\_AIR2_SYNC.md`。以下为实现当时的原始记录。
- **日期**：2026-10-17
- **背景**：
  - 用户真机反馈：原版游戏资源（版本清单 / 依赖库 / 资源）下载**慢**。
  - 对照证据（★只读老线 Air 1 的行为与参数约定★）：
    `runtime_native/Natives/AI/AiAssetTools.m:1168-1170` 版本清单默认走 BMCLAPI、失败切官方；
    `:1282-1286` 版本 JSON 的官方域名失败后替换成 `bmclapi2.bangbang93.com` 重试；
    `Natives/PLMirrorCenter.m:40-77` 给出完整前缀映射表（库 → `/maven`、资源 → `/assets`）；
    `Natives/DownloadTaskManager.m:13` 并发上限 = 3。
  - 本仓现状：`A2MirrorResolver` 的映射表**只覆盖资源站**（MCIM），Mojang 三个域名一个都没覆盖；
    `A2GameInstaller` 的下载候选只吃 manifest 原始 URL（`req.candidateURLs` 仅一条）；
    版本清单写死一个官方 URL；并发默认 3。
- **决策**：
  1. **映射表扩容**：`A2MirrorResolver` 的「官方前缀 → 镜像前缀」表补上 Mojang 原版分发
     （`piston-meta` / `piston-data` / `launchermeta` / `launcher.mojang.com` → BMCLAPI 根；
     `libraries.minecraft.net` → `/maven`；`resources.download.minecraft.net` → `/assets`，
     http / https 都认）。**前缀须后跟 `/` 才命中**，避免同前缀异主机被误改写。
  2. **候选链 + 自动切源**：候选顺序 = 镜像优先 → 官方兜底（`mirrorPriority` 默认由官方优先
     ★改为镜像优先★：镜像只在「官方先失败」后才用上，对提速没有意义）；
     失败切源复用下载引擎既有的候选遍历（退避重试耗尽 ⇒ 下一个候选），并新增 `failover` 判据行。
  3. **默认只在判定为大陆时启用**：判据 = 系统时区（`Asia/Shanghai` 等），
     与老线 `PLMirrorIsChinaMainland` 同口径；判错只影响快慢，不影响功能。
  4. **一键关闭**：设置页「使用国内镜像加速」开关（key `A2MirrorEnabled`，存 `Documents/config.json`）。
  5. **并发 3 → 6**：上限仍 8，`air2.install.concurrency` 覆盖仍有效。
  6. **判据行**：前缀 `[A2-MIRROR]`，默认可见、可 grep（开关 + 依据 + 每阶段实际源 + 失败切源）。
- **理由**：
  - 只镜像版本清单对总耗时几乎没有改善 —— 安装阶段的耗时大头是**资源（上万文件）与依赖库**，
    官方域名在国内的单连接吞吐才是瓶颈。
  - 做成候选链而不是硬替换，是为了「镜像坏了也不至于装不上」：官方源永远在链上，
    且用户可一键关掉。★镜像链不是把用户绑到第三方镜像上★。
  - 老线是「配置项 + 域名替换 + 失败重试」这套已验证的行为，本单只对齐行为与参数约定，实现自写。
- **风险与合规（必须写明）**：
  - BMCLAPI（作者 bangbang93）与 MCIM（`mod.mcimirror.top`）都是**第三方公益镜像**，
    与 Mojang / 本仓无隶属关系，**不提供 SLA**，也可能随时下线或限速；
    它们分发的文件未经本仓校验，成品的完整性仍由下载引擎的校验把关。
  - 因此：可一键关闭、官方源恒在候选链上、UI 文案里写明出处与风险。
- **影响 / 边界**：
  - 老线对 `resources.download.minecraft.net` 有「即使镜像优先也官方优先」的减压例外，
    本单★未沿用★ —— 资源正是最慢的一段，沿用等于不提速；减压改由档位承担。
  - 未做源级熔断：镜像整体不可用时，每个文件仍会各付一次退避重试（1s+2s+4s）。
  - ★未在真机实测网速 / 耗时改进★；本单的判据只覆盖 URL 改写、候选链顺序、开关、并发常量。
- **来源**：本仓 `Air2/Core/Addons/A2MirrorResolver.[hm]`、`Air2/Core/Version/A2GameInstaller.m`、
  `Air2/Core/Download/A2DownloadEngine.m`、`Air2/Core/Settings/A2Settings.[hm]`、
  `Air2/UI/Screens/Settings/A2AppearanceSettings.m`、`tests/Mirror/`、`tests/Core/test_install_concurrency.py`。

---

## ADR-012：JIT 就绪判据改为【放行优先】（entitlement / CS_DEBUGGED / verifiedRegion / exec-probe 任一即放行）

- **状态**：已接受（取代 ADR-007 决策第 2 条「只认真实测一次」的**排他性**部分）
- **日期**：2026-10-25
- **背景**：ADR-007 把「拿到 `brk #0x69` 交付的区域」当成**唯一**就绪判据。真机（StikDebug
  里开完 JIT 后启动不再往下走）证明这是**死锁**：iOS 26+ 的 JIT 区是**建 VM 时 libjvm
  自己发的那一发 `brk #0x69`** 才由调试器交付的 ⇒ 建 VM 之前本进程**永远**没有
  `verifiedRegion` ⇒ 判据永远否 ⇒ 永不放行。判据与它要保护的动作之间存在循环依赖。
- **决策**：就绪判据改为**放行优先**，下面四条**任一成立**即放行建 VM：
  1. 内核级 entitlement（`dynamic-codesigning` / `com.apple.private.cs.debugger`，TrollStore / 越狱）；
  2. `CS_DEBUGGED`（有位调试器 attach 着本进程 ⇒ 它会应答 `brk #0x69`，含 libjvm 那一发）；
  3. `verifiedRegion != NULL`（本进程此前真拿到过调试器交付的、`mapped=1 + size>0 + max` 含 X 的区）；
  4. 非镜像设备（< iOS 26）的匿名页执行式探针**真的跑过**（mmap → 写指令 → RX → 真 call）。
  **四条都不成立**才拒绝，并给可读原因（不闪退）。判据只落 `Natives/Support` 一处
  （`A2JITEnabler` 的 `a2jit_ready_now`；`A2JITEnvironment ensureVerifiedWithinBudget:`
  同一口径，供启动链 ② 使用）。
- **保留的约束**：
  - 「凭 CS_DEBUGGED 放行」**不等于**「区域已验证」：判据行必须写清依据
    （`[A2-JIT-ENABLER] 判据 ready=1(原因: debugger-attached)（ppid=…）`），不许把 ② 写成 ③；
  - `getppid()≠1`（被使能器重拉）**仍然不算就绪**，只用于防死循环（不再跳第二次）；
  - `SetDetachAfterFirstBr(1)` **只在确实拿到 `size >= expected`（默认 64MB）的区**之后才发；
  - 区域验收行 `[A2JIT] region=… size=… (X MB) expected=… enough=0|1` 保留，并在建 VM 前 /
    建 VM 返回后各打一次（`tag=before-vm` / `tag=after-vm`）；拿不到区**不崩溃**，
    由 libjvm 自己报错（它的 rc 才是结论）。
- **理由**：把「我们提前能不能取到区」从判据降为**证据之一** —— 真正决定建 VM 成败的是
  libjvm 那一发 `brk #0x69` 有没有人应答，而「有调试器 attach」正是这件事的现场证据；
  提前探一发拿不到区是**常态**（脚本可能只对 JVM 的请求建区），不构成阻断理由。
- **风险 / 边界**：调试器 attach 着而 JIT 实际不可用（例如脚本未指派）时，会走到建 VM 才失败 ——
  这是**有意接受**的取舍：失败点从「永远不启动」变成「libjvm 报可读错误」。
- **落地**：`Natives/Support/A2JITEnabler.[hm]`、`Natives/Support/A2JITEnvironment.[hm]`
  （新增 `a2_jit_is_debugged()`）、`Air2/Player/A2LaunchSession.m`（建 VM 前后区域快照）。

---

## ADR-013：JIT 闸门判据定为【握手完成】（哨兵 + Extension + brk 被服务），不再要求本进程先有 64MB 真区

- **状态**：已接受（修正 ADR-012 与本条之前的实现口径；ADR-007 的「区域取证」降为**日志**，不再是闸门判据）
- **日期**：2026-10-25
- **背景**：把闸门判据从「调试器应答了」收紧成「本进程先拿到 `size ≥ A2JITRegionMB(默认 64MB)` 且可写的真区」之后，
  真机日志（`lastlog.old-6`）出现固定失败链：`Extension 已下发 ⇒ 立刻重试 brk #0x69（期望 size≥67108864）`
  ⇒ `重试 2 次后仍未拿到真区：最后一发=失败（size 小于期望）⇒ JIT 未就绪 ⇒ 失败页`。
  **根因是判据错，不是 JIT 没开**：闸门自己发的那发 `brk #0x69` 用固定小页长度（老 Air 的
  `JIT26CreateRegionLegacySafe(getpagesize())`），而 64MB 的 code cache 是 libjvm 建 VM 时按
  `-XX:ReservedCodeCacheSize` **自己**发 `brk #0x69` 才向调试器要的 ⇒ 用「探测 brk 的返回值」去要求 64MB，
  逻辑上永远不成立。
- **决策**：镜像设备（iOS 26+）上的闸门判据 = **握手完成**，条件按此顺序：
  1. entitlement（`dynamic-codesigning`）—— 只进日志与原因文案，**不单独放行**；
  2. 调试器在岗（`ppid≠1` / `P_TRACED` / 任务级 BREAKPOINT·SOFTWARE 异常端口 任一）；
  3. 哨兵已识别（`0x690000E0` / `0xcccccccc690000e0` / 一页且不可写）⇒ 下发 `UniversalJIT26Extension.js` 且**下发成功**；
  4. 至少一发 `brk #0x69` 被调试器服务（返回值非 NULL）⇒ 放行建 VM。
  `region` 的 `size` / 期望值 / 保护位**只打日志**（「仅供参考，不参与判定」）；真正的建区与尺寸由
  libjvm 建 VM 时自己发 brk 完成，拿不到时由 libjvm 自己报错，闸门不替它验收、也不拦。
- **仍然保留**：`brk` 一律在 SIGTRAP 安全网内发出；`SetDetachAfterFirstBr` + 清 `EXC_MASK_BAD_ACCESS`
  只在握手完成后做；非镜像设备（< iOS 26）整块闸门跳过（与老 Air 逐字一致）。
- **不退回**「只看 `CS_DEBUGGED` 就放行」：那只会证明「有调试器 attach」，不证明脚本已指派、Extension 已生效。
- **落地**：`Natives/Support/A2LegacyJITGate.[hm]`（`a2gate_handshake` 取代 `a2gate_obtain_real_region`；
  `A2AMEJITVerifyWritableJITRegion` → `A2AMEJITVerifyJITHandshake`）、`Natives/Support/A2JITEnabler.m`（回前台复查判据行文案）。

---

## ADR-014：技术栈确认为 ObjC（+C），取代 ADR-001 的 SwiftUI / Swift 选型

- **状态**：已接受（**取代 ADR-001** 中「UI 用 SwiftUI、业务核心用 Swift」的技术选型；ADR-001 的「原生层 ObjC/C」「Java 层只承载启动核心与 LWJGL 补丁」保留）
- **日期**：2026-10-31
- **背景**：ADR-001 写于项目立项（2026-10-07），当时的设想是「SwiftUI 上 iOS 26 原生支持液态玻璃」。
  三个多月的实现已经走到与文档相反的方向：仓库里 `Air2/`、`Natives/` 下 **231 个 `.m`、0 个 `.swift`**；
  UI 是手写的 MD3（ADR-010 之后二级界面去玻璃、一级页面保留玻璃），构建链是
  Xcode 工程 + CMake + Makefile，启动链要直接调 JNI、ARM 异常端口、`brk #0x69` 与 Metal/EAGL。
  这些点上 Swift 只带来多一层桥接与两套内存/异常语义。插件系统（本次）又要往 UI 里注入 slot、
  跑 JSCore、并在 P5 提供 C ABI 原生面 —— 语言选型必须先落定，否则后续 ADR 全部悬空。
- **决策**：正式确认 **ObjC（+C）为全仓唯一应用层语言**。
  - 新代码一律 `.m` / `.h` / `.c`；不允许新增 `.swift`（确有必要须单独 ADR，并说明桥接头边界）。
  - UI 规范按 `docs/UI-DESIGN.md` 用 ObjC 实现；「MD3 + 液态玻璃」是**外观契约**，与语言无关。
  - 插件系统的宿主侧（安装器、注册表、权限、JSCore 绑定）全部 ObjC；P5 原生模块面用 **C ABI**，
    不用 Swift 模块。
- **后果**：
  - 好处：文档与代码一致（新人和 review 不再被 ADR-001 误导）；免掉 Swift/ObjC 双向桥；
    JNI、异常端口、C ABI 三处都在同一语言语义下，插件原生面可以只暴露 `air2_plugin_abi_v1`。
  - 代价：失去 SwiftUI 的声明式写法与部分系统控件便利；UI 代码量更大 —— 这一代价在 ADR-010
    （二级界面改 MD3、手写组件）时其实已经付过，本 ADR 只是把事实写进决策记录。
  - 约束：`scripts/lint_structure.sh` 增加「禁止新增 `.swift`」检查（实现见 P1 任务，不在本文档范围）。
  - 回退成本：若将来真要引入 Swift，必须新开 ADR 并把 `docs/ARCHITECTURE.md` 的分层表一起改。

---

## ADR-015：插件执行模型定为「单进程 JSCore + 能力注入」

- **状态**：已接受
- **日期**：2026-10-31
- **背景**：插件要能改 UI、改启动参数、写游戏目录文件。可选三条路：
  ① **独立进程**（XPC / 子进程）隔离最好，但 iOS 上启动器与游戏共用大量进行中状态
  （下载任务、实例选中、JIT 供给、渲染上下文），IPC 面会大到等于把宿主重写一遍；
  ② **同进程 JSCore** 无进程隔离，但有 JS 沙箱，且能直接读写宿主对象；
  ③ **自有字节码解释器** 可控性最高，但要自己实现语言、标准库、调试器 —— 不是 P0/P1 能承担的。
  另一条独立的轴是「越权怎么处理」：运行时拒绝（`throw permission denied`）还是加载期不注入。
- **决策**：
  1. 执行模型 = **单进程、JSCore 上下文**（P3 落地；P2 只有纯 JSON 声明，没有代码执行）。
  2. 越权处理 = **能力注入**：未授权的 API 在 `air2` 对象上**不存在**（`typeof === "undefined"`、
     `"x" in air2 === false`），注入发生在上下文创建时、之后**不再变化**。
  3. 硬禁（不是权限）：`eval` / `new Function` / `Function.constructor` / `WebAssembly` 不注入；
     无 `require` / `import` / `fetch` / DOM。
  4. 回调一律在主线程执行 + 时间预算（`onLoad` ≤ 50 ms，其余单次 ≤ 16 ms，超预算记诊断而非杀进程）。
- **后果**：
  - 好处：插件可以在 `onLoad` 第一行就判定「我有没有这个能力」，失败前移、可测；
    宿主实现里不需要到处塞权限检查（少一类遗漏）；错误信息不会泄露权限目录。
  - 代价：**运行期不能加权限** —— 用户改授权必须重载插件（卸载再加载），上下文内能力面恒定。
    这是有意的取舍：能力面变化会让插件的分支逻辑在运行中失效，比「重载一次」危险得多。
  - 残余风险（明确接受）：JSCore 自身的越界漏洞挡不住。缓解：禁 RCE 构造、原生面推迟到 P5 且设门槛
    （ADR-020）、日志脱敏（形似 token 的串一律 `<redacted>`）。**不声称**这是安全沙箱。
  - 落地约束：所有 API 对象必须由同一个「能力表」驱动生成，禁止在实现里写 `if (hasPermission)`
    式的运行时判断 —— 否则「不存在」这条契约会被局部悄悄破坏。

---

## ADR-016：权限模型 = 分级目录 + 信任等级 + 组合判定，签名覆盖「manifest + 文件哈希清单」

- **状态**：已接受
- **日期**：2026-10-31
- **背景**：插件能改启动参数，就等于能改游戏行为（`-javaagent` 可注入任意 Java 代码）；
  能写 `mods/*.jar`，就等于能换掉任意 mod 的代码。另一方面，绝大多数插件只需要「改个徽标、
  加个镜像源」，如果所有插件都要走同一套 critical 授权，用户会习惯性点「同意」——
  授权疲劳会让这套模型失效。所以需要**分级**，而不是一个开关。
- **决策**：
  1. **权限目录三级**：低（展示）/ 中（有副作用、边界清晰）/ critical（影响进程、代码执行或数据可信度）。
     critical 项：`launch.args`、`launch.env.code`、`launch.classpath`、`launch.libraryPath`、
     `java.agent`、`files.game.write.content`、`version.patch`、`native.module`、`ui.web`。
  2. **launch 面硬边界**：`-Dminecraft.api.*.host` 直接禁止（不给权限也不许）；
     `--gameDir` / `--assetsDir` / `--version` / `--username` / `--uuid` / `--accessToken`
     插件不可写，宿主在插件参数**之后**统一追加；`-javaagent` 类另需 `java.agent`，
     `-Xbootclasspath*` / `--patch-module` / `-cp` 另需 `launch.classpath`，
     `-Djava.library.path` 另需 `launch.libraryPath`。
  3. **文件面按用途拆**：`files.game.write.config`（中）与 `files.game.write.content`（critical）
     分成两个 id —— 否则「只想改 `options.txt`」的插件被迫申请能换 mod jar 的权限。
  4. **版本面按影响拆**：`version.decorate`（低，只改展示）/ `version.patch`（critical，改内容）。
  5. **信任等级**：T0（无签名/签名无效/指纹不在白名单）只能拿低/中；
     **T1 = 签名有效 且 签名者指纹在白名单**；T2 = 官方密钥 + 官方仓库 + 指纹一致。
     签名「有效」与「被信任」是两件事：任何人都能自签一个密码学上有效的包。
  6. **T0 授权一次性绑定 `(pluginId, packageHash)`**：包哈希变了就重新授权，
     让「同一个 id 悄悄换了内容」必须被用户看见一次。
  7. **组合判定**：`launch.args` + `java.agent`（args 可自带 `-javaagent`，绕过 jar 白名单）、
     `launch.args` + `launch.classpath`、`launch.args` + `launch.env.code`、
     `native.module` + 任一参数面、`ui.web` + `native.module`、`version.patch` + `download.source`
     → **直接拒装**；单项 critical → **红色二次确认**（逐条列出将授予的具体后果）。
  8. **签名范围 = manifest 规范化字节 + 文件哈希清单**，**不签整个 zip**；Ed25519，公钥内置 keyring，
     不从网络取；`AIR2SIG.json` 结构损坏 → 降 T0（不报「包损坏」）。
- **后果**：
  - 好处：critical 权限**只可能**来自已知签名者（T0 下安装器直接不列出 critical 项）；
    组合判定堵住了「用 A 权限绕过 B 权限校验」这一整类问题；签名覆盖语义内容 ⇒ 换打包工具、
    重新压缩都不破坏签名，研究者能解开包看内容同时验签。
  - 代价：未签名插件功能上限很低（这是有意的）；白名单需要维护流程（P2 静态内置，P5 才允许追加/吊销）；
    组合表会让少数「确实需要全权」的插件装不上 —— 接受，因为那种插件等于宿主的一部分，应该走官方集成。
  - 约束：**权限 id 永不改名**（改名 = 让所有已授权插件静默失权）；`plugin.schema.json` 的
    permissions enum、`docs/PLUGIN-SECURITY.md` 第二节目录、注册表 `permissionsGranted` 三处必须同步改。
  - 遗留：`launch.env` 与 `launch.env.code` 写同名变量的冲突在安装期不可知 ⇒ 运行时以 `code` 为准
    并记诊断（不做拒装，否则会拒掉合法的「default + 覆盖」写法）。

---

## ADR-017：包格式 `.air2plugin`（zip / formatVersion 2）与原子安装

- **状态**：已接受
- **日期**：2026-10-31
- **背景**：安装插件的过程会被中断（磁盘满、用户杀进程、崩溃），而 iOS 上用户在文件 App 里
  也能看到 `Documents`。需要一个「任何时刻中断都不留半成品」的安装模型，以及一个
  「用户改不了」的存放位置。
- **决策**：
  1. 包 = **zip**，后缀 `.air2plugin`，`manifest.json` 必须在包根，UTF-8 文件名标志位置位；
     `formatVersion = 2` 为当前唯一受支持值。
  2. 硬上限：包 64 MB / 解压 256 MB / 4096 文件 / 单文件 32 MB / 路径 255 字节 / 深度 8 / 压缩比 100:1；
     路径拒 `..`、绝对路径、反斜杠、符号链接与硬链接。
  3. **`manifest.files` 与「包内实际文件（除 manifest / AIR2SIG）」双向严格相等**：多一个即夹带、少一个即说谎。
  4. 安装七步：导入 → 结构校验 → schema + 语义 → 全量哈希 → 授权 → 同卷 `rename` 换目录 → 注册表原子替换。
     任一步失败删除 staging，注册表不动。
  5. **注册表是唯一事实来源**，目录不是；启动时清理 staging 与孤儿目录，注册表损坏则改名重建
     （不猜、不修）。
  6. **保留上一版**（每插件最多 1 份），清理发生在「下次成功启动到 `stable`」之后，
     这样「新版本一启动就崩」时用户还能回退。
  7. 目录固定在 `Library/Application Support/Air2/Plugins/`，**不用 `Documents`**，并排除 iCloud 备份。
- **后果**：
  - 好处：安装对系统其余部分是瞬时的（要么旧状态、要么新状态）；用户无法手改插件目录
    （否则哈希/签名只剩「拒载或信任篡改」两个坏选项）；注册表可回放、可诊断（`seq` + `lastBootStage`）。
  - 代价：用户不能「把 zip 解压到目录里」当安装 —— 必须走导入（文件选择器/分享）；
    旧版本占磁盘（最多一份，可接受）。
  - 约束：`formatVersion` 只在**新增必填字段 / 改语义 / 新增 type 枚举值**时升版；
    新增可选字段不升版（否则每个小功能都要全体重打包）。宿主接受 `formatVersion ∈ [2, 自身最大值]`。

---

## ADR-018：UI Schema 用「slot + 语义组件 + 语义图标 + 主题 token」

- **状态**：已接受
- **日期**：2026-10-31
- **背景**：插件要能改界面，但若允许插件直接指定平台控件（`UIButton`）或图片路径，
  后果是：① UI 改版会打断所有插件；② 多端契约不可能成立（Android 没有 UIKit）；
  ③ 插件可以指定任意图片路径 ⇒ 与 `air2.paths` 的路径抽象冲突（ADR-015 / `PLUGIN-COMPAT.md` 第三节）。
- **决策**：
  1. 插件只描述**语义**：`slot`（放哪儿）+ `component`（放什么语义组件）+ `icon`（语义图标 ID）+ `theme.tokens`。
  2. `slot` / `component` / 常用 `icon` 都是 **schema 枚举**；写平台控件名或图片路径一律 schema 拒。
  3. 层级（L0/L1/L2）由**申请的能力**推导，不由作者填写 —— 避免「自称 L0、实际做 L2 的事」。
  4. 加载顺序 `(priority, layer, pluginId)` 三元组全升序，保证同注册表每次启动顺序一致。
  5. 未知图标 ID / 未知 token → 宿主降级 + 诊断，**不拒载**（宿主加图标不应让旧包失效）。
  6. L2 独占 slot（整页替换）同 slot 只允许一个插件，冲突在**安装期**拒装。
- **后果**：
  - 好处：宿主换 UI 实现不破坏插件；同一 manifest 在 Android/桌面可映射到各自设计语言；
    插件没有路径能力也就没有路径泄露面。
  - 代价：表现力受限 —— 复杂自定义界面要等 P3 的整页替换 / `ui.web`（P5）；
    宿主词表成为**兼容性资产**：加项容易，改项/删项必须走弃用流程（ADR-019）。
  - 约束：`plugin.schema.json` 的 slot/component 枚举是契约的一部分，任何增删都要同时改
    `PLUGIN-COMPAT.md` 2.2/2.3 与本条 ADR 的落地说明。

---

## ADR-019：版本兼容分三套号（包格式 / API / 注册表），平台与语言按显式回退链

- **状态**：已接受
- **日期**：2026-10-31
- **背景**：插件系统里同时存在「包结构在变」「API 在长」「注册表在迁移」三件不同的事，
  用一个版本号表达任意两件都会出错；多端与本地化也需要明确「缺了怎么办」，否则每个插件作者
  都会自己发明一套回退。
- **决策**：
  1. **三个独立版本号**：`formatVersion`（包结构，manifest 内）/ `air2.host.apiVersion`（API 主版本）/
     注册表自身的 `formatVersion`。三者在文档里必须互相索引。
  2. `manifest.air2.host` 是**声明**（我要什么宿主），运行时 `air2.host` 是**只读视图**（我面对什么宿主），
     字段集不同，同名不共义。
  3. 平台：`platforms` 不含当前平台 → **拒装**，不静默降级；`assets/<platform>/` 逐文件覆盖
     `assets/common/`，都不存在才用宿主默认。
  4. 语言：BCP-47 回退链 `精确 → 去 REGION → 去 Script → 语言主标签 → 宿主下一语言 → en → key 本身`；
     **不做**简体↔繁体自动转换。
  5. UI 能力用 `uiCapabilities` 协商（`color.glass` / `motion.spring` / `haptics` / `grid.columns` /
     `minTapTarget` …），与权限正交：能力管「画不画得出」，权限管「准不准做」。
  6. 宿主接受 `formatVersion ∈ [2, 自身支持的最大值]`；新必填字段才升版。
- **后果**：
  - 好处：破坏性变更的爆炸半径最小（升 API 主版本不影响包格式，反之亦然）；
    作者不必猜「宿主能不能画玻璃」，读 `uiCapabilities` 即可。
  - 代价：三套版本号增加理解成本 —— 缓解手段是 `PLUGIN-AUTHORING.md` 第三节的字段表
    与本节的三号对照表；不允许再引入第四套号。
  - 约束：`type: js` 的包在只支持声明面的宿主（P2）上**拒装**（它完全无法工作，装上只会误导）；
    `type: json` 的包在 P2 宿主上正常装。平台不匹配一律拒装，不做「尽力而为」。

---

## ADR-020：原生模块门槛 —— 仅官方签名（T2）、仅 v3 包格式、仅 C ABI

- **状态**：已接受
- **日期**：2026-10-31
- **背景**：有些需求（自定义渲染路径、深度输入、性能探针）只有原生代码能满足，
  P5 要开这个面；但原生 dylib 与宿主同进程、同地址空间，一旦允许就等于把「插件审核」
  退化成「代码审计 + 祈祷」。同时 P0～P4 必须先把签名与信任等级建起来（ADR-016），
  否则原生面会是第一个被滥用的面。
- **决策**：
  1. **信任门槛**：`native.module` **只能授予 T2**（官方发布密钥 + 官方仓库来源 + 指纹一致）。
     T0/T1 申请该权限 → 安装期拒装，不是「拒绝授予」。
  2. **格式门槛**：`native/` 目录只在 `formatVersion ≥ 3` 的包里合法；v2 包出现 `native/` 一律拒装
     （失败方向是「旧宿主装不上」，不是「静默忽略 dylib」）。
  3. **接口门槛**：dylib 只能链接宿主导出的 `air2_plugin_abi_v1` 符号表；ABI 版本不匹配 → 拒绝装载，
     不做「尽力加载」。
  4. **组合门槛**：`native.module` 不得与 `launch.args` / `launch.classpath` / `launch.libraryPath` /
     `launch.env.code` 任一共存（拒装）；`ui.web` + `native.module` 也拒装。
  5. **同行开放的两个面**（P5）：`ui.web`（禁 `file://`、独立进程或强隔离、页面与插件 JS 不直连）、
     Java agent 自挂载（沿用 `java.agent` 权限 id，新增 `agentFiles` 清单，宿主校验哈希后写 `-javaagent=`）。
- **后果**：
  - 好处：原生面必然可追溯到官方审核过的代码；「原生 + 任意启动参数」这条最危险的组合被结构性排除；
    插件生态的上限（纯 JSON → JS → 原生）与信任成本正相关，用户能理解。
  - 代价：生态小（只有官方或官方合作方能出原生插件）；需要官方审核流程与签名基础设施，
    而这两样必须在 **P2 就建好**（这也是「签名提前到 P2」的直接原因）。
  - 约束：`air2_plugin_abi_v1` 一旦发布**不能改函数签名**，只能新增 `v2` 符号表并同时导出，直到 v1 退役；
    ABI 变更必须新开 ADR。

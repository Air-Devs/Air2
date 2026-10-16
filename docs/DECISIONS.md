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
  - **纳入自包含脚本** `Assets/AmethystJIT69.js`（派生自 `UniversalJIT26.js`，接管 `brk #0x69` 真建区），随包交付，供调试器「指派脚本」选用；
  - JIT 可用性判据**不接受「能力声明」**（CS_DEBUGGED / entitlement / TrollStore 装机），只认**真的试一次**：拿到 `brk #0x69` 交付的区域并核验 `vm_region_64` 的 `mapped=1 + size>0 + max_protection 含 EXECUTE`；
  - `brk` 一律在**专用后台线程 + 有界预算**内发出（调试器在岗却不服务时会永不返回），失败即「优雅失败」，**绝不带病创建 JVM**；
  - 落层：JIT 环境与判据在 `Natives/Support/A2JITEnvironment`，JVM 创建/销毁在 `Natives/Context/A2JVMContext`，顺序编排在 `Player/A2LaunchChain`（先发脚本 → 再探测 → 再建 VM）。
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

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

---

## ADR-006：JIT 采用「传统 0x69 + 自包含脚本 + 区域取证判据」

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

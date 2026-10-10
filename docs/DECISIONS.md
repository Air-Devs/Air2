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

## ADR-006：UI 层由 Objective-C 迁移到 SwiftUI，Core / 原生层保持 ObjC

- **状态**：已接受
- **日期**：2026-10-10
- **背景**：HANDOVER 第二章 2.1「技术栈（已定，不要改）」把 UI 与 Core 都钉死为 Objective-C
  （"不是 Swift！不是 SwiftUI！"），与本仓 ADR-001「UI 层用 SwiftUI」直接冲突。工程实际已按
  ADR-001 把 `App/` 与 `UI/` 整体用 Swift 重写完毕（分支 `feat/swift-frontend`），Core 的
  24 个 `.m`、Utils 的 2 个 `.m` 原样保留。
- **决策**：
  - `App/` 与 `UI/` 的语言改为 **Swift**（UI 以 SwiftUI 为主，宿主容器等必要处用 UIKit）。
  - `Core/`、`Utils/`、`Natives/` **继续用 Objective-C 不动**；Swift 侧经
    `Air2-Bridging-Header.h` 调用 Core，桥接头只允许 import `Core/`、`Utils/`。
  - 分层与依赖方向沿用 ADR-002：Core 仍**禁止** `import SwiftUI / UIKit`，CI 的
    `scripts/lint_structure.sh` 继续机器化拦截违规。
- **取代关系**：本条取代 **HANDOVER.md 第二章 2.1** 的语言表及其「Swift 仅保留为极少量衔接点 /
  工程里一个 Swift 文件都没有」的表述；ADR-001 的技术栈指向由此正式落地。HANDOVER 第一～九章为
  交接原文，不回头改写，改动一律以本条 + HANDOVER 第十章的新条目为准。
- **理由**：
  - Objective-C 手写 UIKit 布局成本高，SwiftUI 的结构化视图与语义色更利于材料包式主题化；
  - Core 保持 ObjC 避免一次性大爆炸重写，Swift ↔ ObjC 的边界收敛在唯一 bridging header，风险可控；
  - 与 ADR-002 单向分层一致，迁移不放松任何既有硬约束。

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

## ADR-006：整合包四格式解析统一归入 `Core/Addons/Modpack/`

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：整合包来源格式互不兼容 —— Modrinth（`modrinth.index.json`）、CurseForge（`manifest.json`）、MultiMC（`mmc-pack.json` + `instance.cfg`）、MCBBS（`mcbbs.packmeta`）。若每种格式都往 UI 或下载引擎里塞分支，会把「来源差异」扩散到整条链路。
- **决策**：四种格式各自一个解析器，统一产出 `A2ModpackInfo` 模型；由 `A2ModpackParser` 按 CF → MR → MultiMC → MCBBS 顺序命中即止。上层（安装编排、UI）只面对统一模型，不感知来源格式。
- **理由**：
  - 来源差异收敛在一处，新增格式只加解析器
  - 解析器纯逻辑、可单测，符合 Core 不依赖 UIKit 的约束
  - 错误域 `A2ModpackParserErrorDomain` 统一对外，UI 报错文案无需分格式

---

## ADR-007：只读 zip 解析器放在 `Utils/` 而非 `Core/`

- **状态**：已接受
- **日期**：2026-10-07
- **背景**：整合包安装需要读取 zip 内的清单与解压文件。iOS 无公开的同步 zip 读取 API，需自行解析中央目录并用 zlib 做 raw inflate。
- **决策**：`A2ZipReader`（只读条目、按名取数据）与 `A2ZipExtractor`（按前缀解压到目录）放在 `Utils/`，不进 Core；解压用 zlib，链接参数由 `scripts/gen_xcodeproj.py` 生成 `OTHER_LDFLAGS = ("-lz")`。
- **理由**：
  - zip 是通用容器格式，与 Minecraft 无关，符合 Utils「能放这里的必须与 MC 无关」的界定
  - Core 只依赖「按条目名取数据」的抽象，不关心压缩算法
  - 避免把 zlib 依赖绑到业务层

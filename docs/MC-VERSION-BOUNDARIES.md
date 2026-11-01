# MC 版本分界线 —— Air2 最小测试边界

> 目的：1.7.10 ~ 26.x 全量测不现实。本文找出**启动链 / 渲染管线真的变了**的版本，
> 只测这些点；中间小版本给出「不必重复测」的区间。
>
> 证据口径：**A 级 = Mojang 官方版本元数据机器校验**（`version_manifest_v2.json` → 每个版本的
> `javaVersion.majorVersion` 与 `libraries` 清单，103 个正式版逐个抓取，2026-10-25）；
> **B 级 = minecraft.wiki 版本页/Pack_format**；**C 级 = 加载器官方元数据**（Forge promotions、
> Fabric meta）。每条结论都标了级别与版本号，没有一条是拍脑袋。
>
> 与 Air2 现状的对应见 §5（只引用本仓已有文档，不改代码）。

---

## 0. 一页结论

1. Java 下限只有 4 个台阶：**1.17→16、1.18→17、1.20.5→21、26.1→25**（1.12 起为 8）。四档 JRE（8/17/21/25）正好可与之一一对应，中间版本不需要第五档。
2. 图形栈只有 4 个真断点：**1.13（LWJGL2→3）、1.17（GL3.2 core + 全 shader）、26.2（Vulkan 后端）、26.3（GLFW→SDL3）**。
3. 渲染/资源侧断点集中在 1.21.2 之后：**1.21.2 / 1.21.4 / 1.21.5 / 1.21.6 / 1.21.9 / 1.21.11 / 26.1 / 26.2 / 26.3**，每处都有 pack_format 跳号可对账。
4. 加载器：Fabric 从 **1.14** 起；Forge 1.13+ 从 **1.13.2** 起有构建、1.20.5 **无构建**（1.20.4→1.20.6 直接跳过）；NeoForge 从 **1.20.1** 起、1.20.2 起与 Forge 分家。
5. 最小测试矩阵 **11 行**覆盖 1.7.10 ~ 26.3；快照、预发布、26.4 一律不测。

---

## 1. 分界版本总表

级别：**P0 = 必测**（换 Java / 换图形栈 / 换窗口栈），**P1 = 抽测**（渲染或数据格式大改，故障面大），**P2 = 只记录不测**（仅库小版本漂移）。

| 分界版本 | 变了什么 | 为什么需要单独测 | 级别 | 证据 |
|---|---|---|---|---|
| **1.7.10** | LWJGL **2.9.1** + launchwrapper + GL 2.1 固定管线 | 旧管线唯一有生态价值的基线（Forge legacy 主力）；gl4es 唯一能覆盖的段 | P0 | A：1.7.10 libraries 含 `org.lwjgl.lwjgl:lwjgl:2.9.1`；B：[Java Edition 1.7.10](https://minecraft.wiki/w/Java_Edition_1.7.10) |
| **1.12.2** | LWJGL **2.9.2/2.9.4**，Java 8，1.12 线终点 | 与 1.7.10 同栈但库/注册表/Forge 世代不同；是「最后一版 LWJGL2」 | P0 | A：1.12.2 libraries 含 `org.lwjgl.lwjgl:lwjgl:2.9.4-nightly-20150209` |
| **1.13** | 首个 LWJGL3：`org.lwjgl:lwjgl:3.1.6`，`lwjgl-glfw` 首次出现；**扁平化**（方块/物品 id 全改，pack_format 4）；`textures/blocks`→`block` | 启动链（GLFW 窗口 + LWJGL3 native 符号）与资源结构同时换代；此前的 GL 桥/输入桥在这里第一次被真正调用 | P0 | A：1.13 libraries 首个 3.1.6；B：[Java Edition 1.13](https://minecraft.wiki/w/Java_Edition_1.13)（"Game library updated to LWJGL 3"）、[Pack_format](https://minecraft.wiki/w/Pack_format)（format 4） |
| **1.14** | **Blaze3D** 落地：`Use VBOs` 开关移除、VBO 强制，不再支持 GL 1.5 以下；LWJGL 3.2.1 | 渲染抽象层换代（RenderSystem 风格），此后所有渲染 mod/agent 的注入点都变了 | P1 | B：1.14「Changes→General」VBO 条目与 cite 9（Searge "JustBlaze3DThings"）；A：3.2.1 |
| **1.17** | **OpenGL 3.2 core profile 强制**，全部固定管线渲染改为 shader；**Java 16**；pack 7 | 本文最重要的一条：GL 2.1 兼容路径在这里被砍掉，任何只到 GL 2.x 的渲染器（gl4es 家族）在此彻底失效；shader 编译链第一次成为启动阻塞点 | P0 | B：[Java Edition 1.17](https://minecraft.wiki/w/Java_Edition_1.17)（"Rendering is now using OpenGL 3.2 core profile… All fixed-function rendering has been replaced with shader-based rendering"）；A：java=16 |
| **1.18** | **Java 17** 起 | JRE 档位台阶（17 档从这一版开始） | P0 | A：1.18 `javaVersion.majorVersion=17` |
| 1.19 | LWJGL 3.3.1 | 仅库小版本；无管线变化 | P2 | A |
| 1.20.2 | LWJGL 3.3.2；数据包 18（function 宏、overlay 目录） | 加载器/数据包结构变化，渲染无关 | P2 | A；B：Pack_format（data 18） |
| **1.20.5** | **Java 21** 起；**物品组件化**（非结构化 NBT → 结构化 components，pack 41）；LWJGL 3.3.3 | JRE 档位台阶 + 物品数据格式换代（影响 mod 与物品渲染路径） | P0 | A：java=21；B：Pack_format（format 41 条目列出 components 替代 NBT） |
| **1.21.2** | shader/post 定义改 JSON：`defines` 预处理器、`vertex`/`fragment` 改为命名空间 id；新增 `lightmap` shader；`ChunkOffset`→`ModelOffset`；pack 42 / data 57 | 核心 shader 配置格式第一次大改，agent 注入的 shader/管线假设在这里全废 | P1 | B：[Java Edition 1.21.2 §Shaders](https://minecraft.wiki/w/Java_Edition_1.21.2)、Pack_format 42 |
| **1.21.4** | **数据驱动物品模型**（`items/*.json` 新格式）；方块实体方块补渲染普通模型；pack 46 | 物品渲染入口换代，物品相关渲染 patch 必须重写 | P1 | B：Pack_format 46 |
| **1.21.5** | **移除核心 shader / 后处理的 JSON program 定义**，物品渲染更新；pack 55 | 旧 shader 资源包与依赖它的渲染方案直接不加载 | P1 | B：Pack_format 55（"removed shader program definitions for core shaders and post-processing effects as JSON files, and updated item rendering"） |
| **1.21.6** | 核心 shader uniform 全部改为 **uniform block**；`FOG_IS_SKY` 移除；pack 63 | uniform 布局换代，任何按名取 uniform 的代码会静默拿到错误值 | P1 | B：Pack_format 63 |
| **1.21.9** | pack format 引入 **minor 版本**（`min_format`/`max_format` 取代 `pack_format`）；后处理顶点 shader 合并、改用三角形绘制；pack 69.0 | 资源包声明与后处理几何都变了；同时是 Copper Age 之后的第一个断点 | P1 | B：Pack_format 正文（"Since 25w31a, the pack format has been changed to work with `min_format` and `max_format`"）+ 69.0 条目；[Java Edition 1.21.9](https://minecraft.wiki/w/Java_Edition_1.21.9) |
| **1.21.11** | 1.21 线终点（Mounts of Mayhem，2025-12-09）；pack 75.0；LWJGL 3.3.3 | 最后一个 Java 21 版本 = metallum agent `classes12111` 的覆盖上限 | P0 | A；B：[Java Edition 1.21.11](https://minecraft.wiki/w/Java_Edition_1.21.11)；本仓 `docs/COMPAT-MATRIX.md` §1 类集台账 |
| **26.1** | **Java 25** 起；LWJGL **3.4.1**；物品渲染从 `core/entity` 拆出 `core/item`；lightmap shader 重写（`AmbientLightFactor` 移除等）；pack **84.0** | 新版号体系元年 + JRE 25 档起点 + 物品渲染再拆一层 | P0 | A：java=25、lwjgl 3.4.1；B：[Java Edition 26.1](https://minecraft.wiki/w/Java_Edition_26.1)、Pack_format 84.0 |
| **26.2** | **Vulkan 后端**（实验、可 opt-in）；libraries 首次出现 `lwjgl-shaderc` + `lwjgl-vulkan`；`core/text` 系列替代 6 个 text shader（pack 88.0） | 图形 API 分叉：iOS 无原生 Vulkan，必须保证走 OpenGL 后端；shader 编译链换 ShaderC | P0 | A：26.2 libraries 新增 shaderc/vulkan；B：Pack_format 88.0；C：[Fabric for Minecraft 26.2](https://fabricmc.net/2026/06/15/262.html)（"26.2 introduces the ability for the backend to be changed between the default OpenGL backend and an experimental Vulkan backend"）；[26.2 Snapshot 8](https://www.minecraft.net/sv-se/article/minecraft-26-2-snapshot-8)（OpenGL 改回默认） |
| **26.3** | **GLFW → SDL3**（`lwjgl-glfw` 消失、`lwjgl-sdl` 出现）；OpenGL 后端也改用 **ShaderC** 编译；`terrain.vsh/.fsh` 支持 multi-draw；pack 97.1 | 窗口/输入/平台集成换代 ⇒ 宿主表面与输入桥全改；这是 Air2 已知的「上下文建得出来但画面在黑层」风险点 | P0 | A：26.3 libraries 无 glfw、含 `lwjgl-sdl:3.4.3`；B：[Java Edition 26.3 §Game window and input backend](https://minecraft.wiki/w/Java_Edition_26.3)（"Minecraft now uses SDL3 instead of GLFW for window management, input and platform integration"）；本仓 `docs/COMPAT-MATRIX.md` §0-6 |
| 26.4 | 未发布（最新仅 `26.4-snapshot-5`） | 不测 | — | A：manifest `latest.snapshot=26.4-snapshot-5` |

### 1.1 版本号对应关系（旧 → 新）

| 旧 | 新（2026 起） | 名称 / 日期 | 依据 |
|---|---|---|---|
| 1.21.5 | 25.1 | Spring to Life, 2025-03-25 | [Minecraft's new version numbering system](https://www.minecraft.net/es-mx/article/minecraft-new-version-numbering-system)（2025-12-02，正文已核）：编号改为 `<年>.<drop>.<hotfix>`；官方举例 25w41a = `25.4-snapshot-1`，并列出 2025 年四个 drop 的顺序（Spring to Life / Chase the Skies / The Copper Age / Mounts of Mayhem）|
| 1.21.6 – 1.21.8 | 25.2 | Chase the Skies, 2025-06-17 | 同上 |
| 1.21.9 / 1.21.10 | 25.3 | The Copper Age, 2025-09-30 | 同上 |
| 1.21.11 | 25.4 | Mounts of Mayhem, 2025-12-09 | 1.21 线最后一个版本（[Java Edition 1.21.11](https://minecraft.wiki/w/Java_Edition_1.21.11)） |
| — | **26.1**（= 1.22） | Tiny Takeover, 2026-03-24 | [Java Edition 26.1](https://minecraft.wiki/w/Java_Edition_26.1) |
| — | **26.2**（= 1.23） | Chaos Cubed, 2026-06-16 | [Java Edition 26.2](https://minecraft.wiki/w/Java_Edition_26.2) |
| — | **26.3**（= 1.24） | Wilderness Bound, 2026-09-15 | [Java Edition 26.3](https://minecraft.wiki/w/Java_Edition_26.3) |
| — | 26.4（= 1.25） | Fourth Drop 2026，未发布 | manifest |

> 口径提醒：`26.1 ≠ 1.21.1`。版本画像里凡是拿字符串做前缀匹配的地方，`26.` 与 `1.21.` 必须分开分支。

---

## 2. 最小测试矩阵（11 行）

渲染器列按**包内现有能力**给（依据 `docs/COMPAT-MATRIX.md`：`gl4es_114`/`libnggl4es` 上限 GL 2.x；`metallum_agent.jar` 的类集只有 `classes12111` / `classes261` / `classes262` / `classes263`，即只覆盖 1.21.11 与 26.x）。

| # | 分组（覆盖区间） | 代表版本 | JRE | 渲染器 | 必测理由 / 备注 |
|---|---|---|---|---|---|
| G1 | 1.7.10 – 1.8.9 | **1.7.10** | 8 | `libgl4es_114` | LWJGL2 + launchwrapper；gl4es 唯一稳的段 |
| G2 | 1.9 – 1.12.2 | **1.12.2** | 8 | `libgl4es_114` | 最后一版 LWJGL2；与 G1 库版本不同（2.9.4 vs 2.9.1） |
| G3 | 1.13 – 1.16.5 | **1.13** + **1.16.5** | 8（备 17） | `libmobileglues` | 首个 LWJGL3 + 扁平化（1.13）；1.16.5 是该段终点，验证 8/17 都能起 |
| G4 | 1.17 – 1.17.1 | **1.17.1** | 17 | `libmobileglues` | 唯一 Java16 线 + GL3.2 core 起点；17 档向下兼容 16 |
| G5 | 1.18 – 1.20.4 | **1.20.1**（+ 抽 1.19.4） | 17 | `libmobileglues` | Mod 生态主力段；1.19.4 只在出现数据包相关故障时加测 |
| G6 | 1.20.5 – 1.21.1 | **1.21.1** | 21 | `libmobileglues` | Java21 起点 + 物品组件化 |
| G7 | 1.21.2 – 1.21.8 | **1.21.5** + **1.21.8** | 21 | `libmobileglues` | 1.21.2/1.21.5/1.21.6 三处 shader 格式连改，取改动最狠的 1.21.5 与段终点 1.21.8 |
| G8 | 1.21.9 – 1.21.11 | **1.21.11** | 21 | `metallum`（classes12111）／`libmobileglues` 对照 | pack minor 制 + metallum 类集上限；两渲染器各跑一次以区分「agent 不支持」与「GL 桥不支持」 |
| G9 | 26.1 – 26.1.2 | **26.1.2** | 25 | `metallum`（classes261） | Java25 起点；agent 类集主版本 69，只能上 25 |
| G10 | 26.2 | **26.2** | 25 | `metallum`（classes262） | Vulkan 分叉：必须确认走 OpenGL 后端、且 `lwjgl-shaderc` 路径不参与 GL 初始化 |
| G11 | 26.3 | **26.3** | 25 | `metallum`（classes263） | SDL3 窗口 + GL 侧 ShaderC；已知宿主表面/黑屏风险，须单独过 |

行数：**11 行**（P0 全覆盖；P1 的 1.21.2/1.21.4/1.21.6 折叠进 G7 的代表版本，不再单列）。

---

## 3. 明确「不需要重复测」的区间

| 区间 | 为什么可以不测 |
|---|---|
| 1.13.1 – 1.13.2、1.14.x、1.15.x、1.16.1 – 1.16.5 | 同一 LWJGL3 + 同一 GL 路径（1.14 起 Blaze3D 已定型），只抽 1.13 与 1.16.5 |
| 1.18.1 – 1.18.2、1.19 – 1.19.4、1.20 – 1.20.4 | 同为 Java 17、同 GL3.2 core 管线；LWJGL 3.3.x 之间的差异不触达 Air2（native 由包内提供）。抽 1.20.1 即可；1.19.4 仅在有数据包/加载器故障时加测 |
| 1.20.2 – 1.20.4 | 只有 LWJGL 3.3.2 与数据包 18，无渲染变化 |
| 1.21 – 1.21.1 | 与 1.20.5 同一渲染结构（仅 data pack 48 的 enchantment/painting 数据化），抽 1.21.1 |
| 1.21.3 | 与 1.21.2 完全同 pack（42）；无独立价值 |
| 1.21.7 – 1.21.8 | 与 1.21.6 同 pack 63/64，仅资源微调 |
| 26.1 – 26.1.1 | 与 26.1.2 同 pack 84.0/101.1，只取段终点 |
| 1.12.2 → 1.13 之间 | 没有中间正式版，不存在漏测缝隙 |
| 26.4、所有快照 / 预发布 / RC | 未发布或不面向用户；`version_manifest_v2` 里 `type=snapshot` 一律排除 |

---

## 4. 什么情况下**打破**上面的分界（加测触发条件）

任一条命中，就把对应版本从「不必测」升级为「必测」，并回溯它所在的整个 pack_format 区间：

1. 启动日志出现 `UnsupportedClassVersionError` 或 metallum 报「类集缺失 / 版本不支持」 ⇒ 说明越过了 agent 类集边界（1.21.11 / 26.1 / 26.2 / 26.3）。
2. 崩溃日志出现 shader 编译错误、`RenderPipeline`、`ShaderC`、uniform block 相关字样 ⇒ 按 Pack_format 跳号定位到 1.21.2 / 1.21.5 / 1.21.6 / 26.1 / 26.2 / 26.3。
3. 画面正常但**输入无响应**或窗口层级异常 ⇒ 优先怀疑 26.3 的 SDL3 路径。
4. 黑屏但 GL 上下文创建成功 ⇒ 先看 26.3 的窗口后端，再看 Vulkan 是否被误选（26.2+ 必须锁 OpenGL）。
5. Mojang 宣布新的后端/API 切换（OpenGL 退役、Vulkan 转正）或出现 `27.x` ⇒ 重新做一遍本文。

---

## 5. 与 Air2 现状的三条硬约束（不改代码，只登记冲突）

1. **包内只有 `java-25-openjdk`**（`docs/COMPAT-MATRIX.md` §0-1）⇒ G1–G8 全部在 JRE 闸门被阻断，测试矩阵里 8/17/21 三档必须先补齐运行时才有意义。
2. **metallum 类集只覆盖 1.21.11 / 26.1 / 26.2 / 26.3**（§1 台账：`classes12111`=65、`classes261/262/263`=**69**）⇒ G1–G7 只能用 `libmobileglues`；21.11 与 26.x 才有 metallum 可选。
3. **包内 LWJGL native 是 3.4.1 一套**（§1 清单），而 26.3 的版本元数据要求 **3.4.3** 且改用 `lwjgl-sdl` ⇒ 26.3 上 native 与 API 两侧都需要单独确认（这正是 G11 必须单列的原因）。

---

## 6. 证据可复现

```bash
# A 级证据：直接读 Mojang 元数据（无需第三方）
curl -s https://launchermeta.mojang.com/mc/game/version_manifest_v2.json > vm.json
# 对任一版本：取其 url → javaVersion.majorVersion + libraries 里 org.lwjgl:lwjgl:<ver>
# 关键实测结果（2026-10-25，103 个 release 顺序扫描，仅列变化点）：
#   1.7.10  java 8   org.lwjgl.lwjgl:lwjgl:2.9.1
#   1.12.2  java 8   org.lwjgl.lwjgl:lwjgl:2.9.4-nightly-20150209
#   1.13    java 8   org.lwjgl:lwjgl:3.1.6      ← LWJGL3 + lwjgl-glfw 首次出现
#   1.14    java 8   3.2.1
#   1.17    java 16  3.2.1
#   1.18    java 17  3.2.1
#   1.19    java 17  3.3.1
#   1.20.2  java 17  3.3.2
#   1.20.5  java 21  3.3.3
#   26.1    java 25  3.4.1
#   26.2    java 25  3.4.1 + lwjgl-shaderc + lwjgl-vulkan
#   26.3    java 25  3.4.3，lwjgl-glfw 消失、lwjgl-sdl 出现
```

```bash
# C 级证据：加载器
curl -s https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json
#   → 有构建的 MC 版本 77 个；1.13 线最早 1.13.2；1.20.5 缺失（1.20.4 → 1.20.6）；最新到 26.3
curl -s https://meta.fabricmc.net/v2/versions/game
#   → stable 列表最早 1.14，最新 26.3；无 1.13 及更早
```

NeoForge：官方 maven（`maven.neoforged.net`）与 `neoforged.net` 在本次抓取时不可达，
故 NeoForge 边界（1.20.1 起始、1.20.2 起与 Forge 分家、支持到 26.3）标为**二手证据**：
[mcmod NeoForge 支持版本列表](https://www.mcmod.cn/class/diff/0-308908.html)、
[NeoForge 说明](https://space-node.net/blog/neoforge-explained-what-is-it-2026)。**待网络可达时用 maven-metadata.xml 复核。**

---

## 7. 来源清单

- Mojang 版本元数据：<https://launchermeta.mojang.com/mc/game/version_manifest_v2.json>（A 级，本文所有 java/LWJGL 结论的原始出处）
- 版本号新制：<https://www.minecraft.net/es-mx/article/minecraft-new-version-numbering-system>（2025-12-02）
- wiki 版本页：[/w/Java_Edition_1.13](https://minecraft.wiki/w/Java_Edition_1.13)、[/1.14](https://minecraft.wiki/w/Java_Edition_1.14)、[/1.17](https://minecraft.wiki/w/Java_Edition_1.17)、[/1.20.5](https://minecraft.wiki/w/Java_Edition_1.20.5)、[/1.21.2](https://minecraft.wiki/w/Java_Edition_1.21.2)、[/1.21.9](https://minecraft.wiki/w/Java_Edition_1.21.9)、[/1.21.11](https://minecraft.wiki/w/Java_Edition_1.21.11)、[/26.1](https://minecraft.wiki/w/Java_Edition_26.1)、[/26.2](https://minecraft.wiki/w/Java_Edition_26.2)、[/26.3](https://minecraft.wiki/w/Java_Edition_26.3)
- 资源/数据包格式总表：<https://minecraft.wiki/w/Pack_format>（format 4/7/18/41/42/46/55/63/69.0/75.0/84.0/88.0/97.1 均出自此页）
- 加载器：<https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json>、<https://meta.fabricmc.net/v2/versions/game>、<https://fabricmc.net/2026/06/15/262.html>（26.2 的 OpenGL/Vulkan 后端说明）
- 26.2 Vulkan 快照公告：<https://www.minecraft.net/sv-se/article/minecraft-26-2-snapshot-8>（OpenGL 恢复默认、Vulkan 转实验）
- 本仓既有台账：`docs/COMPAT-MATRIX.md`（JRE 档位、metallum 类集主版本、gl4es GL2.x 上限、26.3 SDL 黑屏）

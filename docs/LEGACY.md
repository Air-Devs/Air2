# 远古版本（1.0–1.6.4 / Alpha / Beta）启动

本文记录 **1.0–1.6.4 这一代（含 rd-/c0./inf-/indev-/a1./b1. 与 old_alpha/old_beta）**
在 Air2 上启动所需的全部条件，以及每条条件的判定/实现落点。

> 只读结论：这一代与现代版本（1.13+）的差异不是「参数不同」，而是
> **三处硬性的 API/资源/渲染语义断层**。任何一处不满足都必然启动失败或进游戏即静音。

---

## 1. 判定口径（唯一判定处：`Air2/Core/Version/A2LegacyProfile.m`）

判定只看**版本 JSON 自身**，不猜、不看 UI：

| 依据 | 规则 | 结论 |
|---|---|---|
| `type` | `old_alpha` / `old_beta` | classic 世代 |
| `id` 形态 | `rd-` `c0.` `inf-` `indev-` `in-` `a1.` `b1.` 前缀 | classic 世代 |
| `id` 数值 | `1.x` 且 `minor ≤ 6` | classic 世代 |
| `assets` / `assetIndex.id` | `pre-1.6` 或 `legacy` | classic 世代 |
| `id` 数值 | `1.x` 且 `minor ≤ 12` | **需要 LWJGL 2 的 API 面** |
| — | 上述任一为真 | **只能用 Java 8**（`maxJavaMajor = 8`） |

`A2LegacyProfile` 同时给出：
- `requiresLWJGL2Compat`（1.12.2 及更早恒为 YES）
- `maxJavaMajor`（0 = 不限）
- `heapCapMB`（classic 世代 192 MB）
- `jvmCompatOptions`（classic 追加 `-Xms64M` / `CodeCache 16m+2m`）
- `+ rendererSupportsFixedPipeline:`（只有 gl4es 家族返回 YES）

---

## 2. 三个闸门（`Air2/Player/A2LaunchSession.m`，`[A2-LEGACY]` 段）

三个闸门都在**产出 VM 参数之前**，任一不过就直接 `finish(NO, …)` 阻断，
**不静默替换用户的选择**：

1. **JRE 档位** —— `acceptsJavaMajorVersion:`。
   用户选了 Java 17/21/25 启动 1.6.4 ⇒ 阻断，提示改选 `java-8-openjdk`。
2. **LWJGL 2 兼容层** —— `<bundle>/libs/lwjgl-<ver>/lwjgl-lwjglx.jar` 必须存在。
   缺少 ⇒ 阻断（否则必然 `NoClassDefFoundError: org/lwjgl/opengl/Display`）。
3. **渲染器语义** —— `rendererSupportsFixedPipeline:`。
   1.0–1.6 是 GL 1.x 固定管线：只有 **gl4es 家族**（`libgl4es_114` / `libnggl4es`）能接；
   `libmetallum`（Metal 直通）、`libmobileglues`、`libtinygl4angle`、`libMoltenVK` 都不行。

通过后：`-Xmx` 钳到 `heapCapMB`，并把 `jvmCompatOptions` 追加到计划的 VM 选项之后
（计划那份 `jvmOptionsWithMemoryMB:javaMajorVersion:` 仍是唯一产处，本项目不重排它）。

---

## 3. 资源映射（`Air2/Core/Version/A2LegacyAssetsMapper.m`）

1.7.3 起客户端自己按 `assets/indexes/<id>.json` 去 `assets/objects/<hh>/<hash>` 取文件；
**更早的客户端不认识 objects 布局**，两种索引字段决定了必须怎么摆：

| 索引 | 字段（Mojang 原始 JSON） | 客户端读取位置 | 本类做什么 |
|---|---|---|---|
| `pre-1.6`（1.0–1.5.2） | `"map_to_resources": true` | `<gameDir>/resources/<原始路径>` | 把对象映射到实例 `resources/` |
| `legacy`（1.6.x） | `"virtual": true` | `<assetsDir>/virtual/legacy/<原始路径>` | 把对象映射到 `assets/virtual/legacy/` |

实现要点：
- **硬链接优先**（同卷零成本），跨卷回落复制；幂等（目标存在即跳过）。
- 索引键含 `..` 或绝对路径一律拒绝（索引来自网络，不当作可信路径）。
- 调用点：`A2LaunchSession.m` 的后台段（建 VM 之前）。
  放在这里而不是安装阶段的原因：`<gameDir>` 是实例路径，只有到启动时才最终确定。
- 映射失败/对象缺失**不拦路**（表现为无音效/英文界面），只打判据行。

---

## 4. 打包前置（缺一不可）

| 依赖 | 落点 | 说明 |
|---|---|---|
| `java-8-openjdk` | `Libraries/java_runtimes/java-8-openjdk/` | `scripts/stage_runtime.sh` 目前只 stage `java-25-openjdk`，需要补 8；否则第 1 个闸门永远过不去 |
| `lwjgl-lwjglx.jar` | `Libraries/Jars/lwjgl-341/` | 打包阶段（gen_xcodeproj.py 的 Stage Runtime Bundle）会把它复制到 `<App>/libs/lwjgl-341/` |
| `libgl4es_114.dylib` | `Libraries/Renderers/` | 已在仓内；随包进 `Frameworks/`，选「兼容底」渲染器即可 |

`lwjgl-lwjglx.jar` 是 LWJGL 2 API 在 LWJGL 3 之上的纯 Java 实现
（`org.lwjgl.opengl.Display` / `org.lwjgl.input.*` / `org.lwjgl.util.glu.*` / `org.lwjgl.util.vector.*`，
见其 jar 内容清单）。**必须从上游源码自行构建**（BSD-3-Clause），不要从别人的构建产物里抄。

---

## 5. 安装侧：为什么跳过 `org.lwjgl.*`

`A2GameInstaller.m` 的装库循环里，`requiresLWJGL2Compat` 为真时跳过一切 `org.lwjgl.*`：

1. 这些坐标里的 `*-platform` / `*-natives-*` 只有 win/linux/osx 原生库，iOS 用不了；
2. 更致命的是 classpath 顺序：`a2_paths_build_classpath()` 把 `libraries/*.jar` 排在
   `libs/lwjgl-<ver>/*` **之前** ⇒ 一旦 lwjgl2 的 jar 落进 `libraries/`，
   它会把 `org.lwjgl.*` 抢先占掉，包内的 `lwjgl-lwjglx.jar` 完全失效。

---

## 6. 已知缺口（未在本单实现，需要后续单开）

1. **AWT / caciocavallo**：1.0–1.5 的崩溃对话框走 Swing；Air2 无 cacio jar，
   目前依赖「不触发崩溃界面」这一默认路径。真机若出现 `HeadlessException`，
   需要按 Java 档位引入 cacio（Java 8 用 `-Xbootclasspath/p`，17+ 用 `/a`）。
2. **jinput**：1.6.x 的控制器代码引用 `net.java.jinput`；其原生库在 iOS 上不可用。
   若启动期抛 `UnsatisfiedLinkError`，需要把它从装库清单剔除（或在加载器侧兜底）。
3. **1.7–1.12**：同一个 `requiresLWJGL2Compat` 判定也覆盖它们（Java 8 + lwjglx + gl4es），
   但资源映射用不上（1.7.3+ 自己读 objects），需要单独验证 Forge 那一层的 tweaker 参数。

# 版本 × 渲染器 × JRE —— 静态崩溃风险矩阵

> **性质**：只读静态分析（分支 `feat/ondevice-pair` @ `cc34bc0`）。本文不做真机验证，
> 每条结论都标了证据等级：`[静态-代码]` = 代码里可直接读出的因果链；
> `[静态-能力]` = 依赖「某个二进制/上游库的能力上限」这一已知事实（代码只看得到名字）；
> `[待真机]` = 只能靠真机日志定论。
>
> **判据口径**：本仓的「阻断」（`finish(NO,…)` 出可读失败页）与「崩溃」（闪退 / 黑屏 /
> 卡住）是两件事。矩阵里的 ❌ 包含两者，但每格都写清是哪种 —— 因为「必崩」要修代码，
> 「必阻断」只要补一个包内件或放开一个闸门。

---

## 0. 一页结论

1. **包内只有一份 JRE（`java-25-openjdk`）**（`Libraries/java_runtimes/` 实测）。
   ⇒ 选择 java-8 / 17 / 21 一律在 JRE 闸门被挡（`A2LaunchSession.m:383-404`），不崩、但启动不了。
2. **`≤1.12` 是死结**：版本画像要求 `maxJavaMajor = 8`（`A2LegacyProfile.m:99-102`），
   而包内只有 25 ⇒ 默认档被阻断；改选 `java-8-openjdk` 又「未内置」被阻断。
   **即使把 java-8 塞进包**，`A2LaunchPlan.m:490` 无条件下发 `-Xlog:init=debug:stderr`（Java 9+ 选项）
   ⇒ `JNI_CreateJavaVM` 直接失败。这是本文唯一「补包也救不回来」的组合。
3. **`libMoltenVK` 作渲染器 = 结构性必崩**：代码把它当 **OpenGL** 库下发
   （`A2LaunchSession.m:611-621`，`-Dorg.lwjgl.opengl.libname=MoltenVK`），
   而 GL 桥的 EGL 白名单明确不含它（`a2_gl_bridge.m:326-336`）⇒ 既没有 GL 上下文、也没有 `gl*` 符号。
4. **metallum 的 JRE 下限被写死在二进制里**：`metallum_agent.jar` 的
   `classes261 / classes262 / classes263` 主版本 = **69（Java 25）**，`classes12111` 与 agent 本体 = **65（Java 21）**。
   ⇒ 26.x + java-21 会「agent 起得来但一个类也 define 不上」（黑屏）；+ java-17 连 premain 都加载不了（建 VM 失败）。
   **当前没有任何 JRE × 渲染器闸门**，这个组合不会被拦。
5. `gl4es` 家族（`libgl4es_114` / `libnggl4es`）能力上限是 GL 2.x ⇒ 接不了 1.13+
   （`docs/DEPENDENCIES.md:277` 写的「≤1.16 兜底」与 GL 版本能力不符，见 §5-⑥）。
6. **26.3 的 SDL 窗口栈**：控件覆盖层已经单独处理（`A2LaunchSession.m:631-635`），
   但 GL 桥的宿主表面仍取「key window 的 rootViewController.view」
   （`A2LaunchRunner.m:36-76`）—— 26.3 的可见窗口是 SDL 后建的另一个 `UIWindow`
   （`Natives/Input/a2_glfw_window.m:677-681` 的注释即为此现象）
   ⇒ 所有走 EGL 建面的渲染器在 26.3 上是**上下文建得出来、画面在被遮住的层上** = 黑屏。

---

## 1. 包内实物清单（矩阵的地基，全部实测）

| 包内落点 | 内容 | 证据 |
|---|---|---|
| `<App>/Frameworks/` | 6 个渲染器 dylib **全部都会进包**（`Renderers/*.dylib` 通配拷贝）：`libmetallum` / `libgl4es_114` / `libmobileglues` / `libnggl4es` / `libMoltenVK` / `libtinygl4angle`，另加 `libglapi.0` / `libglslang*` / `libshaderc*` / `libspirv-cross*` / `libmithril` | `scripts/gen_xcodeproj.py:159-162` |
| `<App>/Frameworks/` | ANGLE 兼容底 `libEGL.framework` / `libGLESv2.framework`（目录，单独一段 `cp -R`） | `gen_xcodeproj.py:167-171` |
| `<App>/Frameworks/` | LWJGL native **只有 3.4.1 一套**：`liblwjgl.dylib`、`liblwjgl_opengl`、`liblwjgl_stb`、`liblwjgl_nanovg`、`liblwjgl_spng`、`liblwjgl_tinyfd`、`liblwjgl_vma`、`libopenal`、`libSDL3.dylib`、`libvulkan.1.dylib`、`libfreetype`、`libjnidispatch.jnilib` | 实测 `Libraries/Frameworks/` |
| `<App>/libs/lwjgl-341/` | `lwjgl.jar`（major 52 = Java 8 目标）+ `lwjgl-lwjglx.jar`（LWJGL2 API 的纯 Java 实现，含 `org.lwjgl.opengl.Display` / `input.*` / `util.glu.*`） | `gen_xcodeproj.py:183-187`；`docs/LEGACY.md:78-80` |
| `<App>/libs/` | `metallum_agent.jar`、`patchjna_agent.jar`（`-javaagent` 的落点） | `gen_xcodeproj.py:189-194` |
| `<App>/java_runtimes/` | **只有 `java-25-openjdk`**（`stage_runtime.sh` 主推只 stage 25；8/17/21 需 `A2_JRE_EXTRA` 手工补） | 实测；`scripts/stage_runtime.sh:6-27,69-87` |
| JIT 脚本 | `UniversalJIT26.js` / `universal.js` / **`UniversalJIT26Extension.js`**（闰门必需） | `gen_xcodeproj.py:175-180`；`Assets/Air2JIT69.js`、`Air2JIT69Ext.js` 均在 |

**关键台账（metallum_agent.jar 类集，`unzip -l` + class header 实测）**

| 类集 | 覆盖版本 | class 主版本 | 最高可用 JRE |
|---|---|---|---|
| `classes12111_1_21_11` | 1.21.11 | `0x41` = 65 | 需 ≥ 21 |
| `classes261` | 26.1 | `0x45` = **69** | 需 **25** |
| `classes262` / `classes262iris` | 26.2 | `0x45` = **69** | 需 **25** |
| `classes263` | 26.3 | `0x45` = **69** | 需 **25** |
| `com/metallum/agent/MetallumAgent`（premain） | — | `0x41` = 65 | 需 ≥ 21 |

> 没有 `classes1_20` / `classes1_21_5` / `classes1_16` 之类的类集 ⇒
> **metallum 在 1.20.x / 1.21.0–1.21.10 / 1.13–1.19 上无可注入内容**。

---

## 2. 主矩阵：版本 × 渲染器（JRE 取包内默认 `java-25-openjdk`）

图例：✅ 预期可用 ｜ ⚠️ 条件可用（条件写在格内）｜ ❌ 静态可判必失败/必崩（原因 + 行号）

| 版本档位 | metallum | mobileglues | gl4es_114 | nggl4es | MoltenVK | tinygl4angle |
|---|---|---|---|---|---|---|
| **26.3** | ✅ 默认档；类集 `classes263`(69) 与包内 java-25 匹配。⚠️ 控件走 SDL 覆盖层（`A2LaunchSession.m:631-635`），**控件位置/可见性待真机** | ❌ **黑屏**：SDL 后建窗口盖住 GL 桥的宿主表面（`A2LaunchRunner.m:36-76` vs `a2_glfw_window.m:677-681`） | ❌ 双重：①黑屏同左 ②GL 能力不足（MC 26 要 GL 4.x，gl4es 到 2.1） | ❌ ①黑屏同左 ②GL 能力不足 | ❌ 见 §5-①（`libname=MoltenVK`，桥白名单不含它） | ❌ ①黑屏同左 ②ANGLE 只报 ES 语义 |
| **26.2** | ✅ 唯一真机验证过的组合（`docs/DEPENDENCIES.md:276` 主推） | ⚠️ 已知 `glGetError` SIGBUS（真机 `libmobileglues.dylib+0x3e4e4`）：曾用「把 `glGetError` 改写为 `return 0`」的 shim 绕，真机证明**无效**（改写后 SIGBUS 仍落在同一地址，且还原页保护失败 `errno=13`）⇒ 该 shim 已整条移除，**目前无兜底** | ❌ **GL 版本不足**：MC 26 要求 GL 3.2+/4.x，gl4es 报 GL 2.1 ⇒ `GL.createCapabilities` 抛 "Unsupported GL version" → 失败页 | ⚠️ 条件：nggl4es 实测报 GL ≥ 3.2 才能接（`[待真机]`） | ❌ §5-① | ❌ ES 语义（同上） |
| **26.1** | ⚠️ 类集 `classes261` **存在**（69，需 java-25 ✓），但 `A2LaunchSession.m:556` 只把 26.2/26.3 当「支持」，26.1 会打「未验证」告警后仍注入 ⇒ 真机结论未知 | ✅ 默认档（`A2LaunchSession.m:83-86`） | ❌ GL 版本不足 | ⚠️ 同 26.2 | ❌ §5-① | ❌ ES 语义 |
| **1.21.x** | ❌ 除 **1.21.11**（`classes12111`，需 JRE≥21）外**无类集** ⇒ agent 一个类都 define 不上（`A2LaunchPlan.m:529-531` 注释里的真机形态：有声音没画面）→ 回落 `GlDevice` → 黑屏/闪退 | ✅ 默认档；GL 4.x 能力足够 | ❌ GL 版本不足（1.21 要 3.2 core） | ⚠️ 同 26.2 | ❌ §5-① | ❌ ES 语义 |
| **1.20.x** | ❌ 无类集（同上） | ✅ | ❌ | ⚠️ | ❌ | ❌ |
| **1.17–1.19** | ❌ 无类集（同上） | ✅ | ❌ | ⚠️ | ❌ | ❌ |
| **1.13–1.16** | ❌ 无类集 | ⚠️ 条件：**LWJGL 版本必须对齐**——classpath 里 `libraries/*.jar`（该版本自带的 3.1/3.2）排在 `libs/lwjgl-341/*` 之前（`a2_resourcepaths.m:64-96`），而 native 只有 3.4.1 一套（§1）⇒ Java 侧 3.1.6 + native 3.4.1，`[待真机]` | ❌ 同 1.21（GL 2.1 < 3.2）；`docs/DEPENDENCIES.md:277` 称「≤1.16 兜底」与能力不符 | ⚠️ 同 1.21 | ❌ | ❌ |
| **≤1.12** | ❌ **闸门阻断**（非崩）：`rendererSupportsFixedPipeline:` 只放 gl4es 家族（`A2LegacyProfile.m:181-196`、`A2LaunchSession.m:564-572`） | ❌ 闸门阻断（同上；MG 的 glslang 不认 GLSL 120 固定管线） | ⚠️ 闸门放行，但**卡在 JRE 死结**（§5-②）：`maxJavaMajor=8` 而包内只有 25 ⇒ 启动不了 | ⚠️ 同 gl4es（放行 + JRE 死结） | ❌ 闸门阻断 | ❌ 闸门阻断 |
| **≤1.6（classic/Alpha/Beta）** | ❌ 闸门阻断 | ❌ 闸门阻断 | ⚠️ 放行但 JRE 死结（§5-②③）；另 `heapCap=192MB`（`A2LegacyProfile.m:32,103`） | ⚠️ 同 gl4es | ❌ 闸门阻断 | ❌ 闸门阻断 |

> 读法提醒：`≤1.12` 那一行的 ❌/⚠️ 已经**不重要**了 —— 这一档的所有组合都先撞 JRE 死结，
> 与选哪个渲染器无关。这一档要修的是 JRE，不是渲染器。

---

## 3. JRE 维度矩阵（版本 × JRE）

### 3.1 按当前包（`java_runtimes/` 只有 `java-25-openjdk`）

| 版本档位 | java-8 | java-17 | java-21 | java-25 |
|---|---|---|---|---|
| 26.3 / 26.2 / 26.1 | ❌ 未内置（`A2LaunchSession.m:383-404`） | ❌ 未内置 | ❌ 未内置 | ✅ 默认档 |
| 1.21.x | ❌ 未内置 | ❌ 未内置 | ❌ 未内置 | ✅ |
| 1.20.x | ❌ 未内置 | ❌ 未内置 | ❌ 未内置 | ⚠️ 需真机（1.20.5+ 官方要 21；25 未验证） |
| 1.17–1.19 | ❌ 未内置 | ❌ 未内置 | ❌ 未内置 | ⚠️ 同上 |
| 1.13–1.16 | ❌ 未内置 | ❌ 未内置 | ❌ 未内置 | ⚠️ 字节码 52 可加载，但 LWJGL/第三方库在 25 上未验证 |
| ≤1.12 | ❌ 未内置 | ❌ **双重阻断**（未内置 + `maxJavaMajor=8`，`A2LaunchSession.m:529-537`） | ❌ 双重阻断 | ❌ **死结**：闸门要求 8，包内只有 25 |
| ≤1.6 | 同上 | 同上 | 同上 | ❌ 同上 |

### 3.2 假设手工补齐 8/17/21（`A2_JRE_EXTRA="8 17 21"`）之后

| 版本档位 | java-8 | java-17 | java-21 | java-25 |
|---|---|---|---|---|
| 26.x | ❌ ① `-Xlog` 崩（§5-③）② 类集 69 无法加载 | ❌ agent 本体 65 ⇒ premain 加载失败 ⇒ **建 VM 失败**（§5-④） | ❌ agent 起得来、`classes262/263`(69) define 不上 ⇒ **黑屏**（§5-④） | ✅ |
| 1.21.11 | ⚠️ 类集 65 可加载，但 MC 1.21 自身要 21 ⇒ `UnsupportedClassVersionError` | ⚠️ 同左 | ✅ | ✅ |
| 1.21.0–1.21.10 | ❌ 同 1.21.11（MC 需 21） | ❌ | ✅ | ✅ |
| 1.17–1.19 | ❌ MC 要 17+ | ✅ | ✅ | ⚠️ |
| 1.13–1.16 | ❌ `-Xlog`(§5-③) | ⚠️ 官方要 8；17 未验证 | ⚠️ 未验证 | ⚠️ 未验证 |
| ≤1.12 / ≤1.6 | ❌ ① `-Xlog`(§5-③) ② `isUsableJavaHome` 只认 `lib/server/libjvm.dylib`，标准 Java 8 布局是 `jre/lib/server/…`（§5-⑤） | ❌ 闸门 `maxJavaMajor=8` | ❌ 同左 | ❌ 同左 |

### 3.3 渲染器 × JRE（metallum 的硬下限）

| 渲染器 | java-8 | java-17 | java-21 | java-25 | 依据 |
|---|---|---|---|---|---|
| metallum @ 26.2/26.3 | ❌ | ❌（agent 本体 65） | ❌（类集 69） | ✅ | 类集主版本实测 §1 |
| metallum @ 26.1 | ❌ | ❌ | ❌ | ⚠️ | `classes261` = 69 |
| metallum @ 1.21.11 | ❌ | ❌ | ⚠️ | ⚠️ | `classes12111` = 65 |
| mobileglues / gl4es / nggl4es / angle | 与 JRE 无关（纯 native + LWJGL）：只看 MC 自身的最小 JRE | | | | — |
| MoltenVK | 与 JRE 无关（本来就崩，§5-①） | | | | — |

---

## 4. ❌ 清单（逐条：触发 / 形态 / 代码 / 修法）

### ① `MoltenVK` 作渲染器 —— 全版本结构性必崩 `[静态-代码]`

- **触发**：设置里选「MoltenVK」，任意 MC 版本。
- **形态**：**闪退**。LWJGL 把 `libMoltenVK.dylib` 当 OpenGL 库加载，首次 `glXxx` 调用
  取不到符号 ⇒ `UnsatisfiedLinkError`；即便侥幸不崩，MC 侧也会抛
  `IllegalStateException: There is no OpenGL context current in the current thread`
  （GL 桥对它返回 `Skipped`，压根没建上下文）。
- **代码**：
  - `A2LaunchSession.m:611-621`：非 metallum 一律 `-Dorg.lwjgl.opengl.libname=<dylib 去前缀>` ⇒ MoltenVK 被写成 **GL** 库；
  - `a2_gl_bridge.m:326-336`：EGL 白名单 5 项，**明确把 Vulkan 直通类排除**（注释写着「只把 Vulkan 直通类（MoltenVK）排除在外」）⇒ `attach` 返回 `A2GlBridgeSkipped`，`A2LaunchRunner.m:254-261` 不阻断但也不建面；
  - 同时 `A2LaunchPlan.m:558` 已经正确下发了 `-Dorg.lwjgl.vulkan.libname=MoltenVK` —— 也就是说 MoltenVK 的**唯一正确身份是 Vulkan ICD**，不是 GL 后端。
- **为什么会进到这条路径**：`A2RendererCatalog.m:46-49` 把 MoltenVK 登记成候选（`experimental`），
  `+isBundled:` 只看包内文件在不在（`A2RendererCatalog.m:106-115`），而打包脚本把
  `Renderers/*.dylib` 全拷（`gen_xcodeproj.py:159-162`）⇒ **`docs/DEPENDENCIES.md:294`
  写的「MoltenVK 未入包、设置页标未内置」与实物不一致**，于是它一路通过闸门走到崩。
- **修法**（任一，建议 1+2）：
  1. `A2RendererCatalog` 给每个候选加 `glCapable` 元数据，MoltenVK 置 `NO`，`A2LaunchSession.m:595-622`
     对非 GL 后端**不下发** `org.lwjgl.opengl.libname`；
  2. 打包只拷白名单（`Renderers/{libmetallum,libgl4es_114,libmobileglues,libnggl4es,libtinygl4angle}.dylib`
     以及各自依赖），让 `isBundled` 如实返回 `NO` ⇒ 走已有的「未内置 ⇒ 阻断」路径；
  3. 同步修 `DEPENDENCIES.md:287-294` 的台账。

### ② `≤1.12`（含 ≤1.6）× 任意渲染器 —— JRE 死结 `[静态-代码]`

- **触发**：启动任何 1.12.2 及更早版本（含 Alpha/Beta/1.0–1.6）。
- **形态**：**必然停启动**（不是闪退，是可读失败页）：
  - 默认档 java-25 ⇒ `A2LaunchSession.m:529-537`：「该版本只能用 Java 8 启动（当前选的是 Java 25）」；
  - 按提示改选 `java-8-openjdk` ⇒ `A2LaunchSession.m:383-404`：「所选档未内置/不完整」；
  - 两条路都堵死，**这一档在当前包里 0 个可启动组合**。
- **代码**：`A2LegacyProfile.m:99-102`（`requiresLWJGL2Compat ⇒ maxJavaMajor = 8`）、
  `A2JavaRuntimeCatalog.m:22-25`（四档候选名）、`scripts/stage_runtime.sh:27`（只 stage 25）。
  `docs/LEGACY.md:74` 自己就写明了这个缺口。
- **修法**：`A2_JRE_EXTRA="8" bash scripts/stage_runtime.sh` 补 java-8 —— **但补完仍会撞 ③ 与 ⑤**，
  必须三条一起修才算「这一档真的能启动」。

### ③ `java-8` × 任意版本 —— VM 建不起来（`-Xlog` 是 Java 9+ 选项）`[静态-代码]`

- **触发**：JRE 选 `java-8-openjdk`（③ 之前要先过 ⑤ 的布局闸门，或把 ⑤ 一起修掉）。
- **形态**：**建 VM 失败**（失败页 rc≠0）。JVM 打 `Unrecognized option: -Xlog:init=debug:stderr`
  → `Could not create the Java Virtual Machine` → `JNI_CreateJavaVM` 返回错误。
- **代码**：`A2LaunchPlan.m:490` —— `-Xlog:init=debug:stderr` **无条件**加入
  （注释自称「临时诊断」，实际在默认路径上）；`A2LaunchPlan.m:501-512` 的
  `A2VMDiagAll`（默认 **YES**）又追加 4 条 `-Xlog:*`、`-XX:+PrintFlagsFinal`。
  同文件里其它 Java 版本相关的开关都已经正确门控了（`482` 的 `>=17`、`534` 的 `>=9`、`433` 的 G1 `>=17`），
  **只有 `-Xlog` 这一组漏了门控** —— 这是典型的「单点漏判」。
- **修法**：把 `-Xlog:init=…` 与 `A2VMDiagAll` 整块收进 `if (javaMajorVersion >= 9) { … }`，
  并对 java-8 走 `-Xloggc:` / `-XX:+PrintGCDetails` 那一套（或干脆静默）。
  **顺带**：这几条本来就写着「定位完必须删」，属于应该下线的诊断代码。

### ④ metallum × JRE < 25（26.x）/ < 21（1.21.11）—— 黑屏或建 VM 失败 `[静态-代码 + 二进制]`

- **触发**：手工补齐 17/21 后，选 metallum 启动 26.2/26.3（或选 17 启动 1.21.11）。
- **形态**：
  - java-**17** × 26.x：`-javaagent` 的 premain 类 `MetallumAgent` 是 **major 65** ⇒
    `UnsupportedClassVersionError` ⇒ agent 初始化失败 ⇒ **建 VM 失败**；
  - java-**21** × 26.x：agent 能加载，但 `classes262/263` 是 **major 69** ⇒
    `defineClass` 抛 `UnsupportedClassVersionError` ⇒ 一个类都没定义上 ⇒
    **没有 Metal 后端 ⇒ 回落 `GlDevice` ⇒ 黑屏 / "no OpenGL context current"**（形态与
    `A2LaunchPlan.m:529-531` 记录的真机日志同型）。
- **代码**：`A2LaunchSession.m:595-610`（注入 agent，**不检查 JRE**）、
  `A2LaunchSession.m:550-562`（唯一的兼容性判断，且**只打日志不拦**，判据还漏了 26.1/1.21.11）。
- **修法**：在 `[A2-COMPAT]` 段把「日志告警」升级成「闸门」，判据用数据而不是字面量：
  - 最短路径：`A2LaunchSession.m:556` 的 `agentSupports` 改成
    `rendererNeedsJREMajor(metallum) = 25`（1.21.11 用 21），`jreMajor < 需求 ⇒ finish(NO,…)`；
  - 正解：`A2RendererCatalog` 增加 `minJavaMajor` / `supportedVersionPatterns` 字段，
    由一处给出「渲染器 × 版本 × JRE」三元判据，`A2LaunchSession` 只消费结果。

### ⑤ `java-8` 的包内判定与 `a2_vmloader` 的布局不一致 —— 补了包也判「未内置」`[静态-代码]`

- **触发**：把官方/Amethyst 的 `java-8-openjdk` 原样放进 `Libraries/java_runtimes/`。
- **形态**：**阻断**（「所选档未内置/不完整」），日志说「期望 …/lib/server/libjvm.dylib」。
- **代码**：`A2JavaRuntimeCatalog.m:60-70` 只认 `<home>/lib/server/libjvm.dylib`；
  而 `Natives/Context/a2_vmloader.m:24-26` 认三种布局（含 `jre/lib/server/libjvm.dylib`、
  `lib/hotspot/libjvm.dylib`）。**判据与消费者不是同一份口径** —— java-8 恰好是第一种布局之外的那档。
- **修法**：`isUsableJavaHome:` 改为调用 vmloader 的同一份相对路径表（把三个 rel 提到共享常量），
  一处定义、两处使用。

### ⑥ `gl4es` / `nggl4es` × 1.13+ —— GL 版本不足 `[静态-能力]`

- **触发**：1.13 及以上版本选 gl4es 家族（**默认不会**：1.13+ 缺省是 mobileglues，`A2LaunchSession.m:87`）。
- **形态**：**闪退 / 失败页**。MC 1.13+ 在 `GL.createCapabilities` 里检查 `GL_VERSION ≥ 3.2`
  （1.17+ 之后还要 core profile 语义），gl4es 家族对外报 GL 2.x ⇒ 抛
  `IllegalStateException: Unsupported GL version` ⇒ 主类异常退出（`a2_launch.m:186-191` 返回 -7）。
- **代码**：`A2LaunchSession.m:297-324` 只判「包内有没有这个 dylib」，**不判能力**；
  `A2LegacyProfile.m:181-196` 的 `rendererSupportsFixedPipeline:` 也只覆盖 classic 世代。
  `docs/DEPENDENCIES.md:277` 声称 gl4es 是「≤1.16 兜底」，与 GL 2.1 的能力上限冲突 ——
  这条文档结论要么过时、要么需要在真机上核实（见 §6）。
- **修法**：`A2RendererCatalog` 给每个渲染器标 `maxGLVersion`（gl4es/nggl4es = 2.1、
  mobileglues = 4.5、angle = ES 3.2），`A2LaunchSession` 在选渲染器之后、建 VM 之前做一次
  「版本档位 × maxGLVersion」判据；不满足就**阻断并解释**（不静默换后端）。

### ⑦ 26.3 × 所有 EGL 系渲染器 —— 黑屏（表面绑错窗口）`[静态-代码 + 待真机]`

- **触发**：26.3 选 mobileglues / gl4es / nggl4es / angle。
- **形态**：**黑屏**（不崩）：桥报「EGL 就绪 + 帧回调已清屏」，但画面落在被 SDL 窗口盖住的层上。
- **代码**：`A2LaunchRunner.m:36-76` 的宿主表面 = **key window 的 `rootViewController.view`**；
  而 26.3 走 SDL 窗口栈，MC 会**另建一个 `UIWindow`**（`a2_glfw_window.m:677-681` 的注释正是这个现象，
  已有的对策是「抬宿主窗口 + 1.5s/4s 再抬两次」，那是给 GLFW 宿主窗口用的）。
  `A2LaunchSession.m:631-635` 只为 **控件覆盖层**补了 SDL 分支，**GL 桥没有同类补偿**。
- **修法**：把「取宿主表面」抽成一处（与控件覆盖层同一处取窗口：
  `a2_controls_overlay.m:33-56` 已有「当前最顶层可见窗口」的实现），
  26.3 起改为在该处解析 SDL 窗口；或给桥加「SDL 相位」延迟 attach（等 SDL 窗口出现后再建面）。

---

## 5. 高风险清单（按严重度排序）

| # | 风险 | 影响面 | 等级 | 为什么排这个位置 | 修法 |
|---|---|---|---|---|---|
| 1 | **≤1.12 整档无法启动**（JRE 死结 ②③⑤ 三连） | 一整代版本（1.0–1.12.2，含 Alpha/Beta） | **Blocker** | 用户可见的「这一代全都不能玩」，且是三条独立缺陷叠加，修一条不够 | 补 java-8 + 门控 `-Xlog` + 对齐 libjvm 布局 |
| 2 | **metallum × JRE 无闸门**（④） | 26.x（主推渲染器）在非 25 的 JRE 上黑屏/建 VM 失败；1.21.11 同理 | **Blocker**（一旦补 JRE 就必然踩到） | 现在被「只有 25」掩盖；补 JRE 的那一天立刻变成真机黑屏 | `[A2-COMPAT]` 升级为闸门 + catalog 元数据 |
| 3 | **MoltenVK 结构性必崩**（①） | 全部版本 × 1 个渲染器选项；且 `DEPENDENCIES.md` 与实物不一致 | **High** | 100% 可复现、100% 静态可判，但只影响主动选它的人 | 白名单打包 + 不下发 `opengl.libname` |
| 4 | **`-Xlog` 无门控**（③） | 任何 java-8 启动（未来所有远古支持的前提） | **High** | 一行代码废掉整条 java-8 路线；且它自称「临时诊断」 | `if (jre >= 9)` |
| 5 | **gl4es × 1.13+ GL 版本不足**（⑥） | 1.13–1.21 全部版本 × 2 个渲染器；文档口径冲突 | **Medium** | 默认档不会命中（默认 mobileglues），但用户主动选就崩，且无任何提示 | catalog 加 `maxGLVersion` |
| 6 | **26.3 × EGL 系黑屏**（⑦） | 26.3 最新档 × 4 个渲染器 | **Medium** | 26.3 默认走 metallum（不受影响）；但「最新版本能不能用别的后端」是硬伤 | 宿主表面单一取法 + SDL 相位 |
| 7 | `[A2-COMPAT]` 判据漏 26.1 / 1.21.11（`A2LaunchSession.m:556`） | 日志误导（把可用的档报「未验证」，把不可用的档也一样只报一行） | **Low** | 不影响行为，但会让人在真机排查时走错方向 | 判据改成读 catalog 元数据 |
| 8 | `readme`/`DEPENDENCIES` 与实物台账漂移（MoltenVK「未入包」、gl4es「≤1.16」） | 决策误导 | **Low** | 本次矩阵就有两处结论必须标注「与文档冲突」 | 修文档 |

---

## 6. 静态推断 vs 需要真机验证（重要）

**A. 静态可判（代码/二进制本身就能定论，不需要上机）**

- 包内只有 `java-25-openjdk`（目录实测）⇒ 选 8/17/21 必被 `A2LaunchSession.m:383-404` 阻断；
- `≤1.12` 的 `maxJavaMajor = 8` 与默认 25 冲突 ⇒ 必阻断（`A2LegacyProfile.m:102` + `A2LaunchSession.m:529-537`）；
- `-Xlog:*` 无条件下发 ⇒ java-8 必 `Unrecognized option`（`A2LaunchPlan.m:490,505-510`）；
- `isUsableJavaHome:` 只认 `lib/server` ⇒ 标准 Java 8 布局必被误判（`A2JavaRuntimeCatalog.m:60-70` vs `a2_vmloader.m:24-26`）；
- metallum 类集主版本 69 / agent 65 ⇒ java-17 必 premain 失败、java-21 必 `defineClass` 失败（`unzip -l` + class header 实测）；
- 无 `classes1_20*` / `classes1_21_5*` 类集 ⇒ metallum 在那些版本上无可注入内容；
- `libMoltenVK` 不在 EGL 白名单（`a2_gl_bridge.m:326-336`）且被写成 `opengl.libname`（`A2LaunchSession.m:619`）⇒ 既无上下文也无 `gl*` 符号；
- `gl4es` 家族仅被 `rendererSupportsFixedPipeline:` 放行（classic），1.13+ 无任何能力判据；
- 打包脚本 `Renderers/*.dylib` 全量拷贝 ⇒ MoltenVK/tinygl4angle 的 `isBundled` 必为 `YES`（与 `DEPENDENCIES.md:294` 冲突）。

**B. 静态推断，但依赖「某个二进制的已知能力上限」（代码里只出现名字）**

- gl4es / nggl4es 的 GL 版本上限（2.1 / 3.x）—— 本文按上游能力判定，未在 iOS 上复核；
- `libtinygl4angle` 只提供 ES 语义（ANGLE 的性质）⇒ 桌面 GL 3.2 语义缺失；
- MobileGlues 支持 GL 4.5（所以 1.13+ ✅ 的承重点是它）。

**C. 必须真机才能定论（本文只标 ⚠️，不下结论）**

- **26.1 / 1.21.11 到底能不能出画面**：类集存在，但 `A2LaunchSession.m:556` 的判据不认它们，
  agent 对该版本 id 的匹配逻辑在 jar 内（无源码），`[待真机]`；
- **1.13–1.16 + mobileglues**：Java 侧 LWJGL 3.1/3.2 与 native 3.4.1 混用是否报
  `version mismatch` / `UnsatisfiedLinkError` —— 取决于 LWJGL 运行期是否做版本断言；
- **1.20.x / 1.17–1.19 + java-25**：字节码/库层面没有硬冲突，但 MC 老版本在 JDK 25 上的
  反射/Unsafe/模块行为没有任何验证过；
- **26.3 × metallum 的控件可见性**：SDL 覆盖层是新路径（`A2LaunchSession.m:631-635`），
  控件位置只做了「2 秒重挂」（`a2_controls_overlay.m:72`），实际是否跟手未验证；
- **26.3 × EGL 系的黑屏**：因果链（表面绑到被遮窗口）是静态读出来的，但「是否真的黑」
  要以 `[A2-GLBRIDGE] EGL 就绪` + `[FRAME] clear=` 行与截图对照确认；
- **MobileGlues 的 `glGetError` SIGBUS 根因未明**：曾经的「二进制改写为 `return 0`」shim 已在真机证伪
  （改写后同一地址仍崩、页保护还原 `errno=13`）并整条移除 ⇒ 现在**没有任何兜底**；要么查清
  `libmobileglues.dylib` 里那一下的根因，要么换后端/换版本。

---

## 7. 建议的落地顺序（如果要把这张矩阵变成「能启动的面」）

1. **一行就能救**：`A2LaunchPlan.m:490` 的 `-Xlog:init=debug:stderr` 收进 `javaMajorVersion >= 9`
   （并顺手把 `A2VMDiagAll` 默认改回 NO —— 模型注释自己说「定位完默认关」，现在默认还是 YES）。
2. **一处判据**：`A2RendererCatalog` 增加 `minJavaMajor` / `maxGLVersion` / `glCapable` 三个字段，
   把 `A2LaunchSession.m:550-562` 的「只告警」升级为「先判后拦」，一次解决 ②（部分）/④/⑥/① 的入口。
3. **一处口径**：libjvm 相对路径表（`lib/server` / `jre/lib/server` / `lib/hotspot`）从 `a2_vmloader.m`
   提成共享常量，`A2JavaRuntimeCatalog.isUsableJavaHome:` 复用它 —— 否则 java-8 永远「未内置」。
4. **一处取面**：宿主表面解析与控件覆盖层解析窗口合成一处（`a2_controls_overlay.m:33-56` 已有实现），
   26.3 起改走 SDL 窗口 ⇒ 解决 ⑦。
5. **打包白名单**：`gen_xcodeproj.py:159-162` 从通配改为显式清单（含 ANGLE/glslang/shaderc/spirv-cross 依赖），
   让「未内置」这条既有闸门重新有意义 ⇒ 从根上关掉 ①。

> 本文只读，未改动任何业务代码；没有提交。

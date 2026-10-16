# Air2 依赖清单

所有外部依赖必须在此登记。**未登记的依赖不得进入构建。**

登记字段：名称 / 版本 / 来源 / 许可 / 用途 / 引入方式

---

## 启动核心后端

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| Amethyst-iOS-MyRemastered | — | https://github.com/herbrine8403/Amethyst-iOS-MyRemastered | 见上游 | iOS 端 pojav 后端**行为/接口参考**（★不随包、不引用其代码★） |
| PojavLauncher | — | https://github.com/PojavLauncherTeam/PojavLauncher | GPL-3.0 | ★**设计参考**（启动核心分层、Boardwalk 思路）；★Java 侧见下节：本轮改为**逐文件复用**老树 overlay，不再净室重写★ |
| ZalithLauncher2 | — | https://github.com/ZalithLauncher/ZalithLauncher2 | GPL-3.0 | 架构分层与功能设计参考 |

---

## 启动核心后端 · 自研替换 —— 复用登记 ★[A2-GLFW-REUSE-1]★

> **背景（用户拍板）**：本项目本身是 **GPL-3.0**（见 `LICENSE` / `COPYING`），
> 老树（`D:\CTF\_510src\runtime_native`，Amethyst-iOS / PojavLauncher 系，同 GPL-3.0）
> 的 GLFW/输入栈**可以合法复用**。故本轮**废弃「净室重写」路线**，改为逐文件复用；
> 评估重点转为**可维护性**（见 `D:\CTF\_AIR2_GLFW.md` §①）。
> 之前的「Java 侧已换成自研，不再拷其类」口径自本单起**作废**。

**许可义务（已履行）**：复用文件逐个保留上游版权/许可头；另在文件头加一段来源标注
（`★复用自【老树】…★`，含源路径、许可、落位、Air2 适配清单）。GPL-3.0 要求的分发即开源、
保留声明、同许可，均满足；无宽松许可片段被并入。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| Amethyst overlay · Java LWJGL 层（9 类） | 老树 `runtime_native`（只读） | `JavaApp/src/lwjgl/org/lwjgl/**`（同 GPL-3.0 家族） | **GPL-3.0-or-later**（随本仓 `LICENSE`） | MC 侧 GLFW/回调/STB 覆盖类（首帧必需） | ★已引入★ 落位 `Air2/JavaApp/src/lwjgl/`，产出 `air2-lwjgl-patch.jar` |

**逐文件来源与 Air2 适配**（★可追溯到文件:行★）：

| Air2 落位 | 老树源路径 | 改动标记 |
|---|---|---|
| `JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java` | 同路径（1440 行） | ★A2-LWJGL-2★ 5 点：删 `android.util.*`（ArrayMap→HashMap/LinkedHashMap，4 处）、保留 `javax.annotation.*`（由随包声明提供）、删死 import `Tools`、system.load 段改写、`UIKit.updateMCGuiScale` 待回填 |
| `JavaApp/src/lwjgl/org/lwjgl/glfw/GLFWWindowProperties.java` | 同路径（22 行） | ★A2-LWJGL-3★ 删死 import `net.kdt.pojavlaunch.Tools` |
| `JavaApp/src/lwjgl/org/lwjgl/glfw/{CallbackBridge,Callbacks,GLFWNativeCocoa,GLFWNativeEGL}.java` | 同路径 | 逐字节（仅加来源头） |
| `JavaApp/src/lwjgl/org/lwjgl/stb/STBImageResize.java` | 同路径（290 行） | 逐字节（仅加来源头） |
| `JavaApp/src/lwjgl/org/lwjgl/system/{Callback,CallbackI}.java` | 同路径 | 逐字节（仅加来源头） |
| `JavaApp/src/lwjgl/javax/annotation/Nullable.java` | ★Air2 新增（非拷自老树）★ | ★A2-LWJGL-1★ JSR-305 最小声明；老树 overlay 用 50 处，本仓 LWJGL jar 未随 |

**未引入（含原因，非待办空话）**：`GLFWVulkan.java`（需官方 org.lwjgl.vulkan，本仓 lwjgl-341 未随）、
`APIUtil.java`（第 180 行 `MemoryUtil.wrap(Class,long,int)` 仅老树自带 jar 有）、
`InfdevMouse.java`（需 Caciocavallo `net.java.openjdk.cacio.ctc`）。
清单与判据同时写进包内 `air2-lwjgl-patch.list`（出包可核）。

**native 侧（`input_bridge_v3.m` / `egl_bridge.m` / `KeyboardInput.m` / `glfw_keycodes.h`）**：
本轮**未引入**。逐点耦合与「为什么整搬=两套并行维护」见 `D:\CTF\_AIR2_GLFW.md` §①/§②。

## Java 运行时

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| OpenJDK (iOS build) | 17 / 21 | https://github.com/herbrine8403/OpenJDK-iOS-FullVersion | GPL-2.0 + CE | 内嵌 JVM |

## 图形

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| Mesa | — | https://gitlab.freedesktop.org/mesa/mesa | MIT | GL 实现（kopper / zink / OSMesa） |
| MoltenVK | — | https://github.com/KhronosGroup/MoltenVK | Apache-2.0 | Vulkan → Metal 转译 |
| GL4ES | — | 上游 | MIT | GL 1.x/2.x → GL ES 转换 |
| MobileGL | — | https://github.com/MobileGL-Dev/MobileGL | — | 移动端 GL 驱动 |

## Java 库

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| LWJGL | 3.3.3 / 3.4.1 | https://www.lwjgl.org | BSD-3 | 窗口、输入、GL 绑定 |

---

## 登记模板

```markdown
| 名称 | 版本 | 来源 URL | 许可 | 一句话用途 |
```

> 提交新依赖时同步更新本文件，CI 会检查 `Libraries/` 下每个二进制是否已登记。


## JIT 脚本

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| AmethystJIT69.js | —（md5 `0201f14d3a59354a1c636a3d1e8c6b24`，16228 B） | 自研；逐字派生自 Amethyst 包内 `UniversalJIT26.js`（`Natives/resources/`，last updated 2025-10-10），三处改动见脚本头部 `★[改-*]★` | 随上游 Amethyst / PojavLauncher 系（见上「启动核心后端」） | 接管传统 `brk #0x69`（BreakGetJITMapping），在目标进程内真分配一块 W+X 内存并回填地址（不再回 legacy 哨兵 `0xE0000069`）。落地于 `Assets/AmethystJIT69.js` |

---

## JIT 供给（候选 —— ★尚未引入，许可证待核实 / 待拍板★）

> 本节是 **预登记**：仅记录候选与已知许可，**仓内当前未 vendor 任何一项**（无源码、无二进制）。
> 引入方式一栏为空 = 未引入。引进前须逐项核实许可并更新本表（见 ADR-008）。

| 名称 | 版本 | 来源 | 许可（待核实） | 用途 | 引入方式 |
|---|---|---|---|---|---|
| StikJIT | — | https://github.com/StikDebug/StikJIT | **MPL-2.0**（弱 copyleft，文件级） | iOS 26+ 内置 JIT 引擎（`enableJIT`：DDI 准备 + 脚本/附加） | 未引入 |
| idevice (rust) | — | https://github.com/jkcoxson/idevice | **MIT** | RSD/TLS-PSK 隧道、lockdown、RPPairing（`tunnel_create_rppairing` 等） | 未引入 |
| isideload | — | https://github.com/nab138/isideload | **MIT** | Apple ID 登录 + 设备内签名（自动配对路径可能需要） | 未引入 |
| StikDebug | — | https://github.com/StikDebug/StikDebug | **AGPL-3.0**（强 copyleft） | 外部 JIT 工具（`stikdebug://enable-jit`）；其隧道/调试代理实现 | 未引入 |
| SideInstaller | 1.3.0 | https://github.com/FrizzleM/SideInstaller | **自定义 / 非 OSI**（非商业 + 禁止再分发官方构建；源码可参考不得直接用） | ★仅作【设备内配对】思路参考★，**禁止 vendor / 禁止抄代码** | 不引入 |
| LocalDevVPN | — | App Store `id6755608044` | 专有（第三方 App） | 提供本机 Loopback 路由（10.7.0.1） | 外部依赖（用户自装） |

**许可口径备忘**（核实于 2026-10-07，源码/仓内 LICENSE 为准）：
- MPL-2.0 = **文件级** copyleft：可并入更大作品，但**修改过的 StikJIT 文件**须开源该文件，且必须保留其许可与版权声明。
- AGPL-3.0 = 强 copyleft：与 GPL 系可并存（AGPL 吸收 GPL，反向不行），但整件作品受其约束。
- SideInstaller 自定义许可**与 GPL/AGPL 兼容性不明**且**禁止再分发构建** ⇒ 一律**只参考、不入仓**。

**第二阶段工具链前置**（★尚未引入，仅登记★）：设备内自动配对 / 内置 helper 需要
`idevice`(MIT) 的 **Rust → iOS 静态库**构建（`aarch64-apple-ios` target + `cargo-lipo`/`xcframework`）。
★不要直接搬 PocketJ 的预编译 `libidevice_ffi.a`（约 90 MB）★——按 ADR-009 / `docs/JIT-PROVISIONING.md` §4
走「源码 + CI 构建」。iOS 27 自动配对另需 Info.plist 的 `NSLocalNetworkUsageDescription` 与
`NSBonjourServices`（本单未改 Info.plist）。

### [JIT-IMPL-2] 外部工具（★仍零 vendor★）

本单**没有引入任何第三方代码/二进制**。②导入 / ③外部 / ④内核 三条取得路径的实现全部自研，
外部使能器只经 **URL scheme** 触达（外部 App，用户自装）：

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| StikDebug（外部 App） | — | https://github.com/StikDebug/StikDebug | AGPL-3.0（★只可当外部 App★） | `stikdebug://enable-jit` 拉起 | 外部依赖（用户自装，**不 vendor**） |
| SideStore（外部 App） | — | https://github.com/SideStore/SideStore | 见上游 | `sidestore://` 拉起 | 外部依赖（用户自装，**不 vendor**） |

上游依赖已由 ②/④ 带入 registry：`stikdebug` / `stikjit` / `sidestore` / `stosdebug`
（见 `Air2/Info.plist` 的 `LSApplicationQueriesSchemes`；★清单唯一真相源★ =
`A2JITExternalToolProvider.registeredToolSchemes`，`tests/JIT` 会逐项比对防漂移）。

**判据内核**：`Natives/Support/A2JITEnvironment`（★仓内自研★，搬运自 `feat/runtime-native`，
许可随本项目 GPL-3.0-or-later，见 `LICENSE`）——本单只接线，不改其语义。
**合规复核**：本单**未**引入 StikJIT(MPL-2.0) / idevice(MIT) / SideInstaller(禁抄) 的任何代码。

## 运行时(启动链)

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| libjvm.dylib | JDK 8/17/21/25 | 包内 `java_runtimes/*-openjdk`(OpenJDK 官方构建) | GPL-2.0+CE | JVM 本体 | app_bundle 内随包 |
| AmethystJIT69.js | 1.0 | 自研(基于上游 UniversalJIT26 的 base+Extension 合并) | 跟随上游 | 服务传统 brk #0x69 交付可执行区 | `Assets/` 静态资源 |

---

## JIT 自动配对（自研 RPPairing）—— [JIT-AUTOPAIR-1]

> iOS 27+ 的「设备内自动配对」= **自研 RPPairing**（RSD + pair-verify + TLS-PSK），
> ★**本仓零新增第三方依赖、零 vendor**★：本阶段只落【能力探测 + 前置条件 + 配对文件新鲜度 +
> 有界生成调用点】，真正的握手在下一阶段（`docs/JIT-PROVISIONING.md` §4.2）。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| （无） | — | — | — | 本阶段无任何新依赖 | **未引入** |

**合规口径（★必须写清★）**：
- **自研 RPPairing**：本仓不 vendor 任何第三方 JIT 隧道库；`A2JITAutoPairing` /
  `A2JITAutoPairingGuidance` / `A2JITAutomaticPairingProvider` / `A2JITAutoPairingEngineBridge`
  全部为仓内自研，许可随本项目 GPL-3.0-or-later（见 `LICENSE`）。
- **SideInstaller 只参考思路、未用其代码**：仅参考其「设备内 RPPairing」的**协议思路**
  （设备发现 → RSD → pair-verify → TLS-PSK → 落配对文件）。
  ★**未拷贝、未搬运其任何代码/常量/文件**★——其许可为**自定义（非 OSI：非商业 + 禁止再分发官方构建）**，
  与 GPL/AGPL 兼容性不明，故一律「只参考、不入仓」（见上一节 SideInstaller 行）。
- 下一阶段若引入 `idevice`(**MIT**) 做 RSD/TLS-PSK，须**先登记本表**再落码，并走「源码 + CI 构建」
  （★不要搬 PocketJ 的预编译 `libidevice_ffi.a`，约 90 MB★）。
- **本阶段复核**：未引入 StikJIT(MPL-2.0) / StikDebug(AGPL-3.0) / SideInstaller(禁抄) 的任何代码；
  未改 `Natives/Support/A2JITEnvironment` 的判据语义。

**★[JIT-AUTOPAIR-2] 补充（阶段 2a）★**：
- **仍然零新增第三方依赖、零 vendor**。新增的 `Natives/Support/a2_rppairing*` 分两类：
  · **系统库**：X25519（corecrypto `cccurve25519`）、HKDF-SHA512 / SHA-512 / MD5（CommonCrypto）、
    CSPRNG（Security `SecRandomCopyBytes`）、Bonjour/连接（Network.framework）、TLS 选项（Security `SecProtocolOptions`）；
  · **本仓自研（GPL-3.0-or-later）**：`a2_rppairing_ed25519.[hm]`（RFC 8032）与 `a2_rppairing_chacha.[hm]`（RFC 8439）——
    两者**按公开标准自写**（未采用任何项目源码），并由 RFC 官方向量 + PyNaCl/cryptography 随机向量逐位自证；
    自研理由（该两个原语在 iOS 侧**无公开 API**，私有符号不可驱动）见 `docs/JIT-PROVISIONING.md` §3.6。
  CommonCrypto（`CCHmac` / `CC_SHA512` / `CC_MD5`）、`SecRandomCopyBytes`、以及
  ★系统 corecrypto 的 **私有导出符号** `cccurve25519`（libSystem 导出，无公开头文件）★。
- **★必须登记的合规点★**：`cccurve25519` 是 **Apple 私有 API**（CryptoKit 底层同一实现），
  仅供本仓**非 App Store 分发**（自签名 / SideStore / TrollStore 侧载）使用；
  ★若将来上架 App Store，此调用须替换为公开 API（如引入 Swift + CryptoKit）或移除★。
  签名经 **RFC 7748 向量实测**确认（见 `tests/JIT/jit_logic_tests.m` §⑯），若系统改签名测试立刻变红。
- **StikPair 关系声明**：只参考其**公开行为与协议描述**（设备内生成配对文件；
  jkcoxson 的 RPPairing 协议说明）——★**未拷贝、未改写其任何代码/常量/文件**★；
  其仓库 **LICENSE = NOASSERTION（未声明许可，默认保留所有权利）**，故一律「只参考协议事实、不入仓」。
- 下一阶段若引入 `idevice`(**MIT**) 或 Swift/CryptoKit，须**先登记本表**再落码。

---

## DDI（Developer Disk Image）取得 —— [JIT-DDI-1]

> 把自动配对前置条件 ④（DDI）从「一律 Unknown」做成【真三态：已就位 / 缺失 / 无法确认】。
> ★**本仓零新增第三方依赖、零 vendor**★：本单只落【本地镜像发现 / 校验 / 手动导入 +
> 版本匹配与新鲜度 + 判定合成 + 如实阻断】；真正的【联网个性化请求】与【image_mounter 挂载】
> 属下一阶段（`docs/JIT-PROVISIONING.md` §4.2）。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| （无） | — | — | — | 本阶段无任何新依赖 | **未引入** |

**材料来源（★只用公开资料★）**：
- **公开文档 / 公开实现的行为描述**：公开 JIT 使能器（StikDebug，AGPL-3.0）的 DDI 获取行为 ——
  ★只读其公开源码确认「流程/行为」★：按系统版本选镜像形态（cryptex / personalized）→
  从**固定 HTTPS 直链**下载一小撮文件（`BuildManifest.plist` / `Image.dmg` / `Image.dmg.trustcache`，
  cryptex 另加 `Image.dmg.cryptex_info` / `Image.dmg.root_hash`）→ 经 **RPPairing 隧道 + 设备的
  `image_mounter`** 挂载；★其取件与挂载都不需要设备标识参与★。
- 另有公开的磁盘映像格式事实：UDIF（`.dmg`）**尾标块魔数 `koly`** 与「大小是 512 的整数倍」——
  本单的本地校验就只用这两条公开事实。
- ★**未拷贝、未搬运任何第三方代码/常量/文件**★：StikDebug(AGPL-3.0) / StikJIT(MPL-2.0) /
  PocketJ / SideInstaller（自定义许可：非商业 + 禁再分发构建）一律**未引用**；
  仓内 `A2JITDDI*` / `A2JITDDIDeviceBridge` 全为**独立自研**（判定逻辑原创；校验只用公开格式事实）。

**合规口径（★必须写清★）**：
- 仓内新增件 `A2JITDDI` / `A2JITDDIStore` / `A2JITDDIProbe` / `A2JITDDIGuidance` /
  `A2JITDDIDeviceBridge` 全部**自研**，许可随本项目 **GPL-3.0-or-later**（见 `LICENSE`）。
- **「联网取 DDI」的边界**：★默认关★（偏好键 `debug.jit_ddi_fetch`）。
  ★本单未实现该请求★（Bridge 骨架如实报未接入）；且**取件来源尚未拍板** ——
  公开实现指向的是**第三方镜像仓**（重分发 Apple 的 DDI 文件），
  与「直接从 Apple 分发获取」在**来源合规**上不是一回事，★须先定来源再落码★。
- **完全离线可用**：本地发现 + 手动导入两条路都在，不依赖联网。
- **挂载的边界**：经 `image_mounter` 挂载需要 **RPPairing 隧道**（与自动配对同一套，本仓尚未落地）；
  ★当前不具备时如实阻断并点名缺什么★，绝不假成功（`A2JITDDIDeviceBridge`）。
- **本阶段复核**：未引入任何第三方代码/二进制（★`libidevice_ffi.a` 未入仓★）；
  未改 `Natives/Support/A2JITEnvironment` 判据语义。

---

## Java 侧自研替换（★替掉 Pojav 传承的 Java 类★）—— [OWN-JAVA]

**变更**：启动核心的 **Java 侧整块换成自研**。原 `runtime_native`（Amethyst/Pojav 线）的
`JavaApp/src/launcher/net/kdt/pojavlaunch/**`（43 个 .java 中 25 个在此包）与
`JavaApp/src/lwjgl/org/lwjgl/**`（LWJGL 补丁）**一律不随本仓交付**；
本仓 `JavaApp/src/launcher/dev/airdevs/air2/launch/**` 为**本单新写**的 9 个类
（见 `docs/ARCHITECTURE.md` §JavaApp §[OWN-JAVA]、规格 `D:\CTF\_AIR2_OWN_JAVA.md`）。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| Air2 Java 启动核心（`air2-launch.jar`） | 1.0 | **本仓自研**（`JavaApp/src/launcher/dev/airdevs/air2/launch/**`） | 随本仓 `LICENSE`（GPL-3.0-or-later） | 入口 / 启动计划消费 / 类路径追加 / 主类派发 | Xcode 脚本阶段编入 `Air2.app/Java/`，不 vendor 第三方 |

**净室口径（★必须如实读★）**

- 新增的 9 个类**没有**逐行搬运 Pojav 的类：包名、类名、文件组织、公开接口全部是新的；
  它们**没有**实现 Pojav 的业务（版本 JSON 语义、账号、下载、UI）—— 那些留在 native/Core。
- 但**这不构成法律意义上的「净室」**：实现者（本单）在写之前**读过**老树的
  `net/kdt/pojavlaunch/**` 以取得**行为/接口约定**（这是任务明确允许的），
  没有「写规格的人」与「写代码的人」分离，因此**同源代码风险不能被排除**。
  ⇒ 结论按 GPL 走，不按「重新开发」免罪：本仓整体仍是 **GPL-3.0-or-later**（`LICENSE`/`COPYING`），
  PojavLauncher 的 GPL-3.0 义务**继续被遵守**，不主张任何额外豁免。

**转换后的剩余 GPL 来源**（本单**未**消除，也不打算在本单消除）

| 来源 | 许可 | 现状 |
|---|---|---|
| 本仓整体（含 `Air2/`、`Natives/` 自研代码） | GPL-3.0-or-later | 随包，`LICENSE`/`COPYING` 已随仓 |
| OpenJDK iOS 构建（`libjvm.dylib`） | GPL-2.0 + Classpath Exception | 随包（层 1 运行时），CE 使「非 GPL 应用」可用 |
| PojavLauncher / Boardwalk **设计** | GPL-3.0 | ★仅参考，仓内不含其代码★；`Air2/UI/Screens/About/A2LicenseViewController.m` 仍保留对 PojavLauncher 的**署名**（署名不是代码引用） |
| LWJGL | BSD-3 | 层 2，尚未随包 |
| Amethyst-iOS-MyRemastered | 见上游 | 仅行为参考，不 vendor |

**未引入**：本单**没有**新增任何第三方库、二进制或源码；`JavaApp/` 无 `libs/`。
**零 Pojav 判据**：`JavaApp/Makefile` 的 `verify` 目标用 `jar tf` 扫
`net/kdt/pojavlaunch|Boardwalk`，命中非 0 即构建失败；Xcode 脚本阶段会连带跑它。

---

## 运行时随包（启动必需 + 必要渲染器）—— [RT-BUNDLE]

> 按「★防石山★」只引入**启动链必需**的运行时与**一个**主推渲染器：
> JVM 运行时**只选一个版本**、渲染器**只选一个主推**、LWJGL **只收启动必需那几件**。
> 落地位置与加载者见 `docs/ARCHITECTURE.md` 的「[RT-BUNDLE]」节；随包由
> `scripts/gen_xcodeproj.py` 的 **「Stage Runtime Bundle」** 脚本阶段完成。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| OpenJDK (iOS, aarch64) | **25.0.4**（`release` 内 `JAVA_VERSION=25.0.4` / `OS_NAME=Darwin` / `OS_ARCH=aarch64`） | **本地随包**：Amethyst 构建产物 `java_runtimes/java-25-openjdk`（上游 `herbrine8403/OpenJDK-iOS-FullVersion` = 官方 OpenJDK 25 + iOS 补丁） | **GPL-2.0 + Classpath Exception** | JVM 本体（`lib/server/libjvm.dylib` + `lib/modules`）；`a2_vmloader.m` 以 `dlopen` + `JNI_CreateJavaVM` 使用 | ★**不入 git**★（119 MB，「防石山」）：`scripts/stage_runtime.sh` 从**本机本地路径**就位到 `Libraries/java_runtimes/java-25-openjdk/`；★不上云、不下载★ |
| **libmetallum.dylib**（Metallum 自研 Metal 渲染器） | 与 Amethyst b12 包内一致（md5 `7d6b022aa2564c422f71325314a771ab`，221,856 B） | **本地随包**：`Air-5.1.1-b12-jitorder2.ipa` 内 `Frameworks/libmetallum.dylib`（= Mac `b12/artifacts/Payload/…/Frameworks/`，逐字节相同） | 自研（Metallum/Amethyst 线），随上游 `LICENSE` = **GPL-3.0**；引入本仓后随本仓 `LICENSE`（GPL-3.0-or-later） | ★**唯一主推渲染器**★。`otool -L` 实测**只依赖系统框架**（Metal/UIKit/Foundation/CoreGraphics/QuartzCore/libSystem/swift 运行时），零第三方 dylib | **随仓** `Libraries/Renderers/libmetallum.dylib` → 随包 `<App>/Frameworks/`（= `-Djava.library.path`） |
| **libgl4es_114.dylib**（GL4ES —— ★兼容底渲染器★） | 与老线 `runtime_native/Natives/resources/Frameworks/libgl4es_114.dylib` 同源；入仓已 ad-hoc 签名（md5 `882141648165eb677188f52c94c4acc1`，5,680,592 B） | **本地随包**：老线树 `D:\CTF\_510src\runtime_native\Natives\resources\Frameworks\`（= 老线素材库，GPL 系树内素材）；上游 = `ptitSeb/gl4es` 家族（老线 `ThirdParty/gl4es_extra_extra`，其 `LICENSE` = **MIT**） | **MIT**（gl4es 上游；本仓不再许可） | ★**兼容底**★：GL 1.x/2.x → GL ES 转译，旧版 MC（≤1.16）的兜底后端。**依赖** ANGLE 的 `libEGL` / `libGLESv2`（`otool -L` 实测 `@rpath/libEGL.framework/libEGL` + `@rpath/libGLESv2.framework/libGLESv2`，由主二进制的 `@executable_path/Frameworks` rpath 解析）⇒ 三件必须一起在包内 | **随仓** `Libraries/Renderers/libgl4es_114.dylib` → 随包 `<App>/Frameworks/` |
| **libEGL.framework / libGLESv2.framework**（ANGLE，GL4ES 的 EGL/GLES 运行依赖） | `libEGL` md5 `5ae505f76087081ea9529fdd4f899c4c`（363,600 B）/ `libGLESv2` md5 `932bdecd50fc1989b1acfcb5618a7a3a`（6,212,752 B）；两者 `Info.plist` 报 `MinimumOSVersion=16.0`、`CFBundleIdentifier=org.chromium.ost.lib{EGL,GLESv2}` | **本地随包**：老线树同目录的 `libEGL.framework/` `libGLESv2.framework/`（= 老线 app 包内那两份）；上游 = `google/angle` | **BSD-3-Clause**（ANGLE） | GL4ES 的 EGL/GLES 提供方（Krypton/WebKit 风格 `org.chromium.ost.*` 标识）。★iOS ≥16（`MinimumOSVersion=16.0`）★ | **随仓** `Libraries/Frameworks/lib{EGL,GLESv2}.framework/` → 随包 `<App>/Frameworks/`（`.framework` 是**目录**，由随包阶段 ①b 段 `cp -R`） |
| LWJGL（核心 / 窗口 / GL / 贴图） | **3.4.1**（`lwjgl.jar` md5 `ab79e80355127103a864944c2923aa9b`；`lwjgl-glfw.jar` `7ebd0017934278aed913a6e6bc28784a`；`lwjgl-opengl.jar` `0c84a2d43c42d5bef2006da4f18f2e37`；`lwjgl-stb.jar` `7f99535811019cce530fc26451a16089`） | **本地随包**：Amethyst 构建树 `JavaApp/libs/lwjgl-341/`；上游 = lwjgl.org 官方 **3.4.1** | **BSD-3-Clause** | classpath 的 `<lwjglDir>/*` 尾项（`a2_resourcepaths.m:59-86`）；`lwjgl-glfw` 对应真机 `NoClassDefFoundError: org/lwjgl/glfw/GLFWErrorCallbackI` 那处根因 | **随仓** `Libraries/Jars/lwjgl-341/*.jar` → 随包 `<App>/libs/lwjgl-341/` |
| LWJGL iOS natives + JNI 分发器 | 3.4.1（随 `Air-5.1.1-b12-jitorder2.ipa`） | **本地随包**：同 IPA 的 `Frameworks/{liblwjgl,liblwjgl_opengl,liblwjgl_stb}.dylib` + `libjnidispatch.jnilib`；上游 = lwjgl.org 官方 iOS/aarch64 | **BSD-3-Clause** | LWJGL Java 层 `System.loadLibrary(...)` 的目标；落 `<App>/Frameworks/` 才能被 `java.library.path` 解析 | **随仓** `Libraries/Frameworks/*` → 随包 `<App>/Frameworks/` |

**「不上云」自查**：本单**未**引入任何云服务 / 远端清单 / 自建后台；**未**新增任何下载步骤；
`stage_runtime.sh` 只做本机文件复制，找不到源就**报错退出**（不兜底去网上取）。

**被本单明确排除的大件**（防石山口径，逐项理由见 `D:\CTF\_AIR2_RUNTIME_DEPS.md` §0）：
另三个 JRE（`java-8/-17/-21-openjdk`，100 / 103 / 120 MB）、`libMobileGL{,-gles}.dylib`（85.8 MB ×2）、
`libOSMesa.8.dylib`（17.8 MB）、`libmithril.dylib`（9.3 MB）、`libMoltenVK.dylib`、
`libs/lwjgl-333/lwjgl.jar`（10.4 MB，与 3.4.1 重复）、着色器编译链（`libglslang*` / `libshaderc*` /
`libspirv-cross*` / `libspvc`）等。

> **[RENDER-SEL] 后续修订（本仓当前状态）**：按用户口径「渲染器要先放一个兼容底」，
> 上面**未被排除**的 `libgl4es_114.dylib` 连同它的 ANGLE 依赖（`lib{EGL,GLESv2}.framework`）
> **已入仓**（合计 ≈11.6 MB）；上面那张「排除清单」里的大件**仍然排除**（JRE 三档 / MobileGL /
> OSMesa / mithril / MoltenVK 一律未入包，在设置页里如实标「未内置」）。

---

## 启动计划与自研链入口接线 —— [LAUNCH-PLAN]（登记）

**登记内容**：新增 8 个 ObjC 文件 / 2 个 Java 文件（均**本单新写**，无第三方依赖），
以及「Java 侧多出一个 jar」这一交付形态变化。落位与加载者见 `docs/ARCHITECTURE.md` 的
「[LAUNCH-PLAN]」「[LWJGL-PATCH]」两节。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| `Air2/Utils/A2LaunchContract.[hm]` | — | 本单新写 | 随本仓 GPL-3.0-or-later | 跨层契约常量（入口主类名 / `--plan` / 类加载器名 / jar 名 / plan schema） | 随仓（源码） |
| `Air2/Core/Version/A2LaunchPlan.[hm]` | — | 本单新写（净室） | 同上 | 启动计划产出（版本 JSON 合并/rules/占位符/库表 + 账号取值） | 随仓（源码） |
| `Air2/Bridge/A2LaunchRunner.[hm]` | — | 本单新写（净室） | 同上 | 组 margv 并调 `a2_launch_jvm_with_argv`；转发开关 | 随仓（源码） |
| `Air2/Player/A2LaunchSession.[hm]` | — | 本单新写（净室） | 同上 | 一次启动的编排（默认关 ⇒ 零副作用） | 随仓（源码） |
| `Air2/Bridge/A2JITScriptDelivery.[hm]` | — | [JIT-VM-WIRE] 本单新写（净室） | 随本仓 GPL-3.0-or-later | ① 唯一调用 `a2_jit_send_script_safe` 的地方（下发随包 `AmethystJIT69.js`，失败不拦路） | 随仓（源码） |
| `Air2/Player/A2LaunchFailure.[hm]` | — | [JIT-VM-WIRE] 本单新写（净室） | 同上 | 启动链失败分类 + 判据行 + 用户文案（复用 `A2JITVerdictGuidance` / `A2JITStrings`） | 随仓（源码） |
| `air2-lwjgl-patch.jar`（源 `JavaApp/src/lwjgl/**`） | 随本仓 | 本单新写（净室）；`org.lwjgl.glfw.CallbackBridge` / `GLFWWindowProperties` 为**非官方同名**类 | 随本仓 GPL-3.0-or-later（LWJGL 本体仍是 BSD-3，见上表） | `org.lwjgl.*` 补丁类容器（层 2，逐片落位） | 随仓（源码）→ 构建产物 `<App>/Java/` |

**未引入**：本组**没有**新增任何第三方库 / 二进制 / 下载步骤；`JavaApp/` 下仍无 `libs/`。

**净室口径（★不许当免罪符★）**：`JavaApp/src/lwjgl/` 下两个类的**接口形状**（常量值、native 方法签名）
取自老树 `src/lwjgl/` 的既有约定（任务明确允许「读老树取行为/接口约定」），实现为本单新写、
不 import 任何 `net.kdt` / `Boardwalk` 包。同源代码风险不可排除 ⇒ 结论按 GPL 走：
本仓整体仍为 **GPL-3.0-or-later**，PojavLauncher 的 GPL-3.0 义务**继续被遵守**，不主张额外豁免。

**机器判据**：`JavaApp/Makefile` 的 `verify` 与 `verify-lwjgl` 目标（`jar tf` 扫
`net/kdt/pojavlaunch|Boardwalk`，命中非 0 即构建失败）；两个 jar 由同一脚本阶段随包。


---

## 第三方依赖引入：mbedTLS（TLS-PSK 隧道后端）—— [A2-INTEGRATION]

**登记内容**：本单（集成分支）为「TLS-PSK 隧道」引入**唯一一项第三方依赖** —— mbedTLS。
按用户拍板：★TLS-PSK 走第三方（mbedTLS 优先：Apache-2.0、~500KB、PSK 成熟），不手写 TLS★。

| 名称 | 版本 | 来源 | 许可 | 用途 | 引入方式 |
|---|---|---|---|---|---|
| Mbed TLS（mbedTLS） | 3.6.2（LTS） | 上游 `Mbed-TLS/mbedtls` 标签 `v3.6.2` 源码 tarball | **Apache-2.0**（上游双许可 Apache-2.0 OR GPL-2.0-or-later，本仓选 Apache-2.0） | 仅用于 §12 的 TLS-PSK 隧道（TLS 1.2 / 静态 PSK / 套件 0x00AF,0x008C） | 随仓预编译 iOS arm64 静态库 `Libraries/ThirdParty/mbedtls/{lib,include,LICENSE,NOTICE.md}`；配方 `scripts/build_mbedtls_ios.sh`（★离线★） |

**接口与开关（★可替换 / 默认关 / 不谎报 / 不上云★）**
- 门面：`Natives/Support/a2_tlspsk_tunnel.[hm]` —— 只暴露「建连 / 发帧 / 收帧 / 关」；
  `+registerBackend:` 是唯一可替换入口 ⇒ **日后换自写实现不动任何调用方**。
- 后端：`Natives/Support/a2_tlspsk_mbedtls.[hm]` —— 唯二调用点：
  ① 生产 `Air2/Bridge/A2JITAutoPairingEngineBridge.m`（TLS-PSK 诊断块）；
  ② 自证 `tests/JIT/jit_logic_tests.m`。
- 默认关：`A2TLSPskTunnel.enabled` 默认 **NO**；未开时 `connect…` 一律如实拒绝并点名。
- 不谎报：无后端 / 未开 / 地址被拒 / 握手失败 ⇒ 一律 `NO` + 具体 reason，绝不静默成功。
- 不上云：默认主机准入策略 `A2TLSPskDefaultHostPolicy` 只放行
  **本机 / 私有网段 / 链路本地 / `.local`**；任何公网地址一律拒绝。**不接任何云服务。**

**未引入**：不使用 mbedTLS 的 x509 信任链（PSK 模式 `VERIFY_NONE`）；不引入 OpenSSL / BoringSSL / 任何包管理器；
不新增任何联网取依赖的构建步骤（tarball 由运维离线提供，见 `NOTICE.md`）。

**机器判据（可逐条核）**：`lipo -info Libraries/ThirdParty/mbedtls/lib/libmbedtls.a` = arm64；
`nm -gU …libmbedtls.a | grep _mbedtls_ssl_conf_psk` 命中；包内 `nm` 有 `_mbedtls_ssl_conf_psk`（链接真的进去了）；
`natives` 自证见 `tests/JIT/jit_logic_tests.m` 的 [A2-INTEGRATION] 例。

---

## 加载器品牌图标（IMG_0094 批注）—— ★本轮未引入，许可未决★

**背景**：版本详情页（`A2LoaderCard`）的加载器列表原用 iOS 自带 SF Symbols 占位
（`A2LoaderSymbol()`：puzzlepiece.extension.fill / square.grid.3x3.fill / …）。用户批注
「这些不要用 iOS 自带的图标，上网找对应的真图标」，要求换成 Fabric / Quilt / Forge /
NeoForge / Legacy Fabric / OptiFine / 原版的**官方或可再分发**品牌图标。

**本轮结论：没有找到可合法随包分发的素材，故一个都没引入，等用户拍板。**
（铁律③：图标只接受官方品牌资源或可商用/可再分发素材；拿不到就如实标注并停下问，
★不得用无关图标充数★。）

**逐项取证（截至本轮，来源为各项目官网/仓库）：**

| 加载器 | 官方站点 | 许可取证 | 可否随 GPL-3.0 包分发 |
|---|---|---|---|
| Fabric | fabricmc.net | 站点声明「本站内容除非另有注明，按 **CC BY-NC-SA 4.0** 授权」（`fabricmc.net/use` 页脚）。NC 禁止商业使用、SA 附加相同方式共享 —— 与 GPL-3.0 分发条款不兼容 | ★否★（需上游书面许可） |
| Quilt | quiltmc.org | 未检索到对 logo 的授权声明；商标权归 QuiltMC | ★未获授权★ |
| Forge | minecraftforge.net | 仓库许可（LGPL-2.1）覆盖**代码**，未覆盖品牌 logo | ★未获授权★ |
| NeoForge | neoforged.net | logo 位于 `neoforged/NeoForge` 仓库 `docs/assets`，随项目 LGPL-2.1；是否覆盖 logo 无明确说明 | ★待澄清★ |
| Legacy Fabric | legacyfabric.net | 未检索到对 logo 的授权声明 | ★未获授权★ |
| OptiFine | optifine.net | `optifine.net/copyright` 明确「**It may not be placed on any web site or otherwise (re)distributed**」 | ★否，明令禁止再分发★ |
| 原版（草方块） | — | 草方块贴图是 Mojang 的美术资源，受 Minecraft 品牌/版权约束 | ★未获授权★ |

**已排查但未采用的来源**：simple-icons（CC0）—— 已核 `fabric` / `quilt` / `forge` /
`minecraftforge` / `neoforge` / `optifine` / `legacyfabric` 均 **404 / 无该品牌**，取自其 CDN 核实。

**仓库内既有同名资源的处置说明（★未采用、也未删除★）**：
`Assets/Images.xcassets/` 下另有 `ModLoaderFabric/Forge/NeoForge/OptiFine/Quilt.imageset`
及 `VanillaIcon.imageset`，由 `A2Icon +loaderIconForIdentifier:` 使用（首页「最近游玩」小卡）。
经逐张查图核对：`ModLoaderFabric` 实为一张**像素风火石（flint）贴图、并非 Fabric logo**，
`ModLoaderForge` 为深色铁砧像素材质图，`ModLoaderOptiFine` 为黄字 OF 圆标，
`VanillaIcon` 为草方块；四者在本文档**均无登记**（不在依赖清单内）。
本轮**未改动**它们的用法（不在本单范围内），仅记录该事实供用户决定是否清理。
⇒ 因为既无来源/许可登记、`ModLoaderFabric` 又与 Fabric 品牌无关，
**不能**把它们搬去充当版本详情页的「真图标」。

**待用户拍板的三条路**：
1. 由用户提供/授权 6 家的官方图标（含 OptiFine 需 sp614x 书面许可）；
2. 维持 SF Symbols，但改用**中性自绘徽标**（如首字母色块），不冒充品牌；
3. 只对已获授权的项目换真图标，其余保持现状（会不一致，需接受）。


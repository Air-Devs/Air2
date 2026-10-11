# Air2 依赖清单

所有外部依赖必须在此登记。**未登记的依赖不得进入构建。**

登记字段：名称 / 版本 / 来源 / 许可 / 用途 / 引入方式

---

## 启动核心后端

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| Amethyst-iOS-MyRemastered | — | https://github.com/herbrine8403/Amethyst-iOS-MyRemastered | 见上游 | iOS 端 pojav 后端**行为/接口参考**（★不随包、不引用其代码★） |
| PojavLauncher | — | https://github.com/PojavLauncherTeam/PojavLauncher | GPL-3.0 | ★**设计参考**（启动核心分层、Boardwalk 思路）；**Java 侧已换成自研，不再拷其类**★ |
| ZalithLauncher2 | — | https://github.com/ZalithLauncher/ZalithLauncher2 | GPL-3.0 | 架构分层与功能设计参考 |

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
| LWJGL（核心 / 窗口 / GL / 贴图） | **3.4.1**（`lwjgl.jar` md5 `ab79e80355127103a864944c2923aa9b`；`lwjgl-glfw.jar` `7ebd0017934278aed913a6e6bc28784a`；`lwjgl-opengl.jar` `0c84a2d43c42d5bef2006da4f18f2e37`；`lwjgl-stb.jar` `7f99535811019cce530fc26451a16089`） | **本地随包**：Amethyst 构建树 `JavaApp/libs/lwjgl-341/`；上游 = lwjgl.org 官方 **3.4.1** | **BSD-3-Clause** | classpath 的 `<lwjglDir>/*` 尾项（`a2_resourcepaths.m:59-86`）；`lwjgl-glfw` 对应真机 `NoClassDefFoundError: org/lwjgl/glfw/GLFWErrorCallbackI` 那处根因 | **随仓** `Libraries/Jars/lwjgl-341/*.jar` → 随包 `<App>/libs/lwjgl-341/` |
| LWJGL iOS natives + JNI 分发器 | 3.4.1（随 `Air-5.1.1-b12-jitorder2.ipa`） | **本地随包**：同 IPA 的 `Frameworks/{liblwjgl,liblwjgl_opengl,liblwjgl_stb}.dylib` + `libjnidispatch.jnilib`；上游 = lwjgl.org 官方 iOS/aarch64 | **BSD-3-Clause** | LWJGL Java 层 `System.loadLibrary(...)` 的目标；落 `<App>/Frameworks/` 才能被 `java.library.path` 解析 | **随仓** `Libraries/Frameworks/*` → 随包 `<App>/Frameworks/` |

**「不上云」自查**：本单**未**引入任何云服务 / 远端清单 / 自建后台；**未**新增任何下载步骤；
`stage_runtime.sh` 只做本机文件复制，找不到源就**报错退出**（不兜底去网上取）。

**被本单明确排除的大件**（防石山口径，逐项理由见 `D:\CTF\_AIR2_RUNTIME_DEPS.md` §0）：
另三个 JRE（`java-8/-17/-21-openjdk`，100 / 103 / 120 MB）、`libMobileGL{,-gles}.dylib`（85.8 MB ×2）、
`libOSMesa.8.dylib`（17.8 MB）、`libmithril.dylib`（9.3 MB）、`libMoltenVK.dylib`、
`libs/lwjgl-333/lwjgl.jar`（10.4 MB，与 3.4.1 重复）、着色器编译链（`libglslang*` / `libshaderc*` /
`libspirv-cross*` / `libspvc`）等。


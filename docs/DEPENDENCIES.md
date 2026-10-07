# Air2 依赖清单

所有外部依赖必须在此登记。**未登记的依赖不得进入构建。**

登记字段：名称 / 版本 / 来源 / 许可 / 用途 / 引入方式

---

## 启动核心后端

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| Amethyst-iOS-MyRemastered | — | https://github.com/herbrine8403/Amethyst-iOS-MyRemastered | 见上游 | iOS 端 pojav 后端实现参考与复用 |
| PojavLauncher | — | https://github.com/PojavLauncherTeam/PojavLauncher | GPL-3.0 | 原始启动核心与 Boardwalk 设计 |
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

## JIT 脚本

| 名称 | 版本 | 来源 | 许可 | 用途 |
|---|---|---|---|---|
| AmethystJIT69.js | —（md5 `0201f14d3a59354a1c636a3d1e8c6b24`，16228 B） | 自研；逐字派生自 Amethyst 包内 `UniversalJIT26.js`（`Natives/resources/`，last updated 2025-10-10），三处改动见脚本头部 `★[改-*]★` | 随上游 Amethyst / PojavLauncher 系（见上「启动核心后端」） | 接管传统 `brk #0x69`（BreakGetJITMapping），在目标进程内真分配一块 W+X 内存并回填地址（不再回 legacy 哨兵 `0xE0000069`）。落地于 `Assets/AmethystJIT69.js` |

---

## JIT 供给（候选 —— ★尚未引入，许可证待核实 / 待拍板★）

> 本节是 **预登记**：仅记录候选与已知许可，**仓内当前未 vendor 任何一项**（无源码、无二进制）。
> 引入方式一栏为空 = 未引入。引进前须逐项核实许可并更新本表（见 ADR-007）。

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

---

## 登记模板

```markdown
| 名称 | 版本 | 来源 URL | 许可 | 一句话用途 |
```

> 提交新依赖时同步更新本文件，CI 会检查 `Libraries/` 下每个二进制是否已登记。

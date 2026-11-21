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

---

## 登记模板

```markdown
| 名称 | 版本 | 来源 URL | 许可 | 一句话用途 |
```

> 提交新依赖时同步更新本文件，CI 会检查 `Libraries/` 下每个二进制是否已登记。

# tests/Mirror —— 国内镜像链单测

覆盖 `Air2/Core/Addons/A2MirrorResolver`、`Air2/Core/Settings/A2Settings`
（★编译并运行**真实实现**，非 Python 镜像★）：

- **URL 重写表**（逐域名 / 逐路径）：
  - Mojang 版本清单 / 版本 JSON：`piston-meta` `piston-data` `launchermeta` `launcher.mojang.com`
    → `bmclapi2.bangbang93.com`（路径原样保留）；
  - 依赖库 `libraries.minecraft.net` → `bmclapi2.bangbang93.com/maven/…`；
  - 资源对象 `resources.download.minecraft.net`（http / https）→ `bmclapi2.bangbang93.com/assets/…`；
  - Modrinth / CurseForge 文件 CDN → `mod.mcimirror.top`（★既有行为：只换主机★）。
- **不改写的反例**：同前缀异主机（`cdn.modrinth.com.evil.example`、
  `libraries.minecraft.network`、`resources.download.minecraft.net.evil`）、
  前缀后没有 `/` 的裸主机、已是镜像的地址（幂等）、空串、未登记域名（Forge 官方站 / Modrinth API）。
- **中国大陆判定**：★同一个二进制用不同 `TZ` 跑 8 轮★（Asia/Shanghai、Asia/Urumqi、
  Asia/Chongqing、Asia/Harbin ⇒ 大陆；America/Los_Angeles、Europe/London、Asia/Tokyo、UTC ⇒ 非大陆）——
  真判定，不复刻逻辑。
- **开关与优先级四组合**（纯函数缝 `candidateURLsForURL:enabled:priority:chinaMainland:`）：
  开+镜像优先 ⇒ `[镜像, 官方]`；开+官方优先 ⇒ `[官方, 镜像]`；关掉 ⇒ 单源官方；非大陆 ⇒ 单源官方。
- **源标签**（判据行字段）：`mirror(bmclapi)` / `mirror(mcim)` / `official` / `(空)`。
- **接线判据**：`[A2-MIRROR]` 判据串、候选展开的唯一入口、版本清单的逐源尝试、
  并发默认 6 / 上限 8 / 覆盖键、★除 `A2MirrorResolver` 外没有第二处写镜像主机名或库域名★，
  以及阴性对照（不存在的判据串扫不到）。

## 运行（macOS：需 Xcode 命令行工具的 clang）

```sh
python3 tests/Mirror/run_mirror_tests.py
```

输出每例一行 `PASS` / `FAIL`，末尾给跨轮汇总：

```
TOTAL pass=<N> fail=0
[runner] 全部通过 ✓
```

退出码：`0` = 全通过；`1` = 有 `FAIL`（或编译/工具链失败）。

> 计数是**单调不回退**的门禁：新增映射 / 新增接线只许加例。
> 为什么是真编译：URL 改写的正确性取决于**字符串变换与候选顺序**这个行为，
> 源码扫描只能证明「文字在文件里」，证明不了「镜像在前、官方在后」。
>
> 时区为什么要多轮：`isChinaMainland` 读的是**系统时区**，同一进程内改不了；
> runner 用 `TZ` 环境变量把同一个二进制跑多次，被测代码每条路径都真走。

## 与 `tests/Core/test_install_concurrency.py` 的分工

安装期的并发度解析（默认 ← 偏好覆盖 → 夹到 `[1, 8]`）在
`Air2/Core/Version/A2GameInstaller.m` 的 `static` C 函数里，所在翻译单元会把整条
安装器依赖图拉进来 ⇒ 无法单独编译。故那部分走 `tests/Core/test_install_concurrency.py`
（**源码断言 + 规则镜像**，常量一漂移就红），与这里的真编译用例互补：
**常量与解析规则**在 Core 侧，**域名映射与候选顺序**在 Mirror 侧。

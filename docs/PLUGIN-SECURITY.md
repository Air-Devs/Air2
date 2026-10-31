# Air2 插件安全模型

> **状态**：P0 契约。本文是**权限目录、逐项授权、哈希完整性、崩溃归因、存储隔离**的唯一权威定义，
> 与 `plugin.schema.json` 的枚举必须逐项一致（改一处必须同时改另一处）。
> **前提**：插件运行在宿主进程内（JSCore），不是独立进程 —— 所以安全边界靠
> 「能力注入 + 安装期逐项授权 + 完整性校验」三层，**不靠运行时沙箱**。
>
> **v2 变更（2026-10-31）**：取消官方签名与信任等级（T0/T1/T2）。
> Air2 **不验证作者身份**，改为安装时向用户逐项申请权限；critical 权限必须连续通过
> **三次提示框、每次等待 5 秒**才可授权。决策见 `DECISIONS.md` ADR-021。

---

## 一、威胁模型

| 威胁 | 是不是要防 | 手段 |
|---|---|---|
| 插件作者上传一个「声明无害、实际越权」的包 | 是 | 权限由宿主判定与授予，作者声明只是申请；API 面按授权注入 |
| 用户在文件 App 里手改插件目录（iOS 侧载场景） | 是 | 目录不在 `Documents`；每类关键文件加载前验哈希 |
| 下载 / 传输过程中包被替换或损坏 | 是 | 安装期全量 SHA-256 + `packageHash` 展示；用户可见「本次安装的包哈希」 |
| 恶意插件通过参数面拿账号 token | 是 | `-Dminecraft.api.*.host` 直接禁止；`accessToken` 类参数插件不可写 |
| 插件借崩溃把启动器搞成砖 | 是 | 崩溃安全模式（第六节）：stage marker + 逐级禁用 |
| 插件读别的插件的数据 | 是 | 每插件独立存储命名空间；无跨插件 API |
| 插件读宿主私有状态（账号、JIT 状态、调试端口） | 是 | API 面里不存在这些对象 |
| 恶意作者在插件里跑任意原生代码 | **v1 不接受**（P5 才开，且仅 TrollStore / 越狱设备） | `formatVersion 2` 的包出现 `native/` 即拒装；P5 仍走三次确认 |
| 用户被钓鱼装了「官方外观」的仿冒插件 | **不防**（明确接受） | 安装页显示「Air2 不验证作者身份」+ 来源 + 包哈希；不提供「官方/已验证」徽标 |
| 拥有设备写权限的攻击者改 registry / 替换已装文件 | 部分防 | 加载期关键文件哈希；`tampered` 标记；但能改 registry 的攻击者可以绕过授权记录 |

### 1.1 明确承认的残余风险

1. **无法验证作者身份**。任何人都能做一个 `id`、`name`、图标都像官方的插件。
   Air2 不再提供「官方签名」「信任等级」「作者 / 发布者白名单」，因此**没有任何徽标能证明作者是谁**。
   安装页只展示「作者自述」、来源与包哈希，用户必须自己判断包从哪来。
2. **哈希不是签名**。SHA-256 能发现「包被改过 / 下错了」，但**不能**证明「这个包是谁做的」。
   能同时改写 `registry.json` 与插件目录的攻击者可以绕过本文的大部分校验。
3. **JS 与宿主同进程**。JSCore 自身若出现可被 `entry.js` 利用的越界漏洞，能力注入挡不住。
   这也是为什么 JS 运行时（P3）必须在 `eval` / `Function.constructor` / `WebAssembly` 三处封死，
   且原生面推迟到 P5。
4. **用户会习惯性点「允许」**。三次 5 秒确认只能降低误触，不能把不看文案的用户变谨慎。
   所以权限目录必须**少而清晰**，组合风险必须硬拒装，不能靠文案解决。

---

## 二、权限目录

风险级：**低**（只有展示影响）/ **中**（有副作用，边界清晰）/ **critical**（可影响进程、
代码执行、或数据可信度）。

「平台」列只有 `ios` 是当前实现；`android` / `desktop` 为契约占位，宿主未实现即视为**不可用**。
标记「P3a / P3b / P4 / P5」的是生效里程碑，未到里程碑的权限在安装页显示为「当前版本不可用」，
不会授予。

### 2.1 启动类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `launch.tuning` | 中 | ios | P3a | 结构化调优：内存上下限、GC 选择、渲染开关 | 只能取宿主枚举内的键值；`-Xmx` 上限受设备物理内存约束（宿主 clamp） |
| `launch.properties` | 中 | ios | P3a | `-D<name>=<value>` | `name` 必须命中前缀白名单：`fml.` / `forge.` / `neoforge.` / `mixin.` / `fabric.` / `quilt.` / `iris.` / `sodium.`；白名单外**只能**走 `launch.args` |
| `launch.args` | **critical** | ios | P3a | 追加裸 JVM 参数，逐条展示 | 受保护参数与 `-Dminecraft.api.*.host` 仍然禁止（见 `PLUGIN-API.md` 5.2）；`-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` 另需 `java.agent`；`-Xbootclasspath*` / `--patch-module` / `-cp` 另需 `launch.classpath`；`-Djava.library.path` 需 `launch.libraryPath` |
| `launch.env` | 中 | ios | P3a | 设置进程环境变量（静态值，manifest 内声明） | 名字不能是宿主保留变量（`HOME` / `TMPDIR` / `JAVA_HOME` / `DYLD_*` / `JAVA_TOOL_OPTIONS` / `_JAVA_OPTIONS` / `JDK_JAVA_OPTIONS`）；值长度 ≤ 4 KB |
| `launch.env.code` | **critical** | ios | P3a | 启动时由插件代码计算环境变量 | 每次启动重新计算 → 每次启动都写一条诊断日志（值脱敏后前 64 字节）；保留变量同样禁止 |
| `launch.classpath` | **critical** | ios | P3a | `-cp` 追加条目（插件自带 jar 或游戏目录内已存在文件） | 条目必须落在插件目录或游戏目录内；不允许绝对路径指向沙箱外 |
| `launch.libraryPath` | **critical** | ios | P3a | 改 `-Djava.library.path` | 只能**追加**，不能替换宿主设置的原生库路径；插入顺序受控（插件段在宿主段之后、用户段之前） |
| `launch.gameArgs` | **critical** | ios | P3a | 追加**游戏主类之后**的参数（如 `--server`、`--width`） | 不能注入 JVM 参数（位置在主类之后，宿主还会复核前缀）；`--accessToken` / `--uuid` / `--username` 等受保护参数不可写；单条 ≤ 2 KB，总数 ≤ 64 条 |
| `java.agent` | **critical** | ios | P3a（P5 扩展到自带 jar） | `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` | 路径必须在插件目录或游戏目录内；jar 需在 `manifest.files` 清单内并被哈希校验；`-Xrunjdwp` 允许（调试用途），但会在授权页额外提示「可能被任意调试器接管」 |

> `launch.gameArgs` 与 `launch.args` 是两条不同的面：前者在主类之后（游戏参数），
> 后者在主类之前（JVM 参数）。**不允许**用 `launch.gameArgs` 的字符串去模拟 JVM 参数——
> 宿主在拼命令行时按位置分段，插件无法跨段注入。

### 2.2 文件类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `files.game.read` | 中 | ios | P4 | 读游戏目录内的**数据类**文件：`options.txt`、`config/**`、`logs/**`、`mods/**`（含 jar 内容）、`resourcepacks/**`、`shaderpacks/**`、`saves/**`、`schematics/**` | 只读；不得读 `libraries/` 下的 `.jar` 本体；不得读账号/token 文件（这些文件不在游戏目录内，也不在 token 表里）；单次 ≤ 8 MB，单文件 ≤ 32 MB；返回值只给内容或 token，不给绝对路径 |
| `files.game.write.config` | 中 | ios | P3a | 写游戏目录内的**配置类**文件：`options.txt`、`config/**`、`mods/**/*.toml`、`servers.dat` | 目标路径必须命中配置白名单；单次 ≤ 4 MB；写入走临时文件 + rename |
| `files.game.write.content` | **critical** | ios | P3a | 写游戏目录内**内容类**文件：`mods/*.jar`、`resourcepacks/**`、`shaderpacks/**`、`saves/**`、`schematics/**` | 目标必须在游戏目录内且不在 `libraries/`；不得覆盖 `.jar` 的哈希记录；写入前把被覆盖文件复制到宿主备份区（可回滚） |
| `files.export` | 中 | ios | P4 | 把插件可访问的文件交给系统分享面板导出（整合包、日志、配置） | 只能导出「插件已能读」的 token；导出必须经过系统分享面板，插件不能指定任意落盘路径；单次 ≤ 512 MB；导出前展示文件清单与大小 |

> 拆成 `files.game.write.config` / `.content` 两个 id：因为「改配置」和「换 mod jar」是两种完全不同的
> 信任诉求 —— 前者坏了一个 mod 设置，后者可以换掉任意 mod 的代码。合并成一个 id 会让
> 「只改配置」的插件被迫申请 critical 权限，用户只能全给或全不给。
>
> `files.game.read` 与 `files.export` 分开：读只是把内容交给插件，导出是把内容交给**系统分享面板**。
> 前者可以被插件静默使用，后者一定会出现用户可见的分享界面，所以风险不同。

### 2.3 版本类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `version.decorate` | 低 | ios | P2 | 改**显示**：版本列表的标题/副标题/徽标/图标 | 只影响展示层，不落盘；宿主另存「真实名」，详情页可切换查看 |
| `version.patch` | **critical** | ios | P3a | 改**内容**：向版本目录写入/替换 jar 之外的补丁文件、改 `version.json` 的本地副本 | 不得改 `.jar` 本体与 `libraries/`；每次 patch 记录到 `patches.log`；补丁在版本详情页常驻「已被插件修改」徽标 |
| `version.filter` | 低 | ios | P4 | 按规则隐藏/置灰版本 | 只影响展示与选择，不删文件；隐藏项可在设置里一键显示 |

### 2.4 网络与下载

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `network.http` | 中 | ios | P4 | 出站 GET/POST 到 manifest 声明的域名 | 域名预声明（安装时列出）；禁 `file://` / 内网段；响应 ≤ 8 MB；重定向只能落在同域或预声明域 |
| `download.source` | 中 | ios | P4 | 追加下载源候选（镜像 URL 模板） | 只能**追加**候选，不能改引擎顺序；不参与官方文件的完整性校验 |
| `download.fetch` | 中 | ios | P4 | 由插件发起一次下载，落到插件缓存 token | 域名仍受 `network.http` 的预声明约束（申请 `download.fetch` 必须同时申请 `network.http`）；单文件 ≤ 512 MB；插件缓存不进入备份 |

### 2.5 界面类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `ui.contribute` | 低 | ios | P2（slot / 主题）/ P3b（页面） | 往宿主 slot 放语义组件、覆盖主题 token、注册插件页面 | 只能用宿主词表里的 slot / component / icon；未知项降级 + 诊断，不拒载；页面 chrome 由宿主绘制 |
| `ui.override` | 中 | ios | P3b | `hide` / `override` 宿主界面、整页替换、`launch.overlay` 内容替换（只能 `replace`） | 不得隐藏「插件管理」「安全模式横幅」「插件页面横幅」「取消启动」「启动失败页」；同 slot 只允许一个 L2 占位；安全模式优先禁用本权限的插件 |

> `ui.override` 不是 critical：它不能执行代码、不能碰数据，但能让界面「看起来不对」。
> 真正的兜底是崩溃安全模式与「插件管理页永远可进」，不是授权弹窗。

### 2.6 实例类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `instance.guard` | 中 | ios | P4 | 在打开 / 编辑实例前做检查，返回「允许 / 拒绝 + 原因」；可调用 `air2.ui.confirm` / `promptSecret` 与用户交互 | **只能否决，不能改实例数据**；不得读取账号；拒绝原因必须本地化；单次交互最长 60 秒，超时视为「允许」并记诊断 |

### 2.7 P5 才可用

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `native.module` | **critical** | ios（仅 TrollStore / 越狱） | P5 | 装载插件自带 dylib | 仅当 `air2.host.nativePluginsSupported == true` 时可申请；三次确认 + 额外一页「这是未审核的原生代码」；ABI 版本必须匹配；只能调用 `air2_plugin_abi_v1` 导出符号 |
| `ui.web` | **critical** | ios | P5 | 内嵌 WebView 承载插件页面 | 禁 `file://`；独立进程或强隔离；页面与插件 JS 之间不直连；只能在插件页面内使用，不能覆盖宿主关键界面 |

> P5 的原生面**没有**「官方签名 / T2」门槛了。取而代之的是：设备能力门槛
>（非 TrollStore / 越狱设备直接不列出）+ 三次确认 + 第四页原生代码警告 + 安全模式。
> 这不是更强的保证，而是**诚实地把风险交给用户**。

### 2.8 一律不可授予（不存在于目录）

| 能力 | 原因 |
|---|---|
| 读账号 token / 写账号状态 | API 面里没有 `air2.account`；账号文件不在任何 token 下 |
| 任意绝对路径读写 | `air2.paths` 只发不透明 token |
| 执行任意代码（`eval` 类） | JSCore 上下文不注入，非权限问题 |
| 改宿主下载引擎选择逻辑 | 非目标（`PLUGIN-SYSTEM.md` 1.2） |
| 游戏内 UI hook | v1 非目标 |
| 访问其它插件的数据 | 存储命名空间隔离 |
| 读取宿主调试端口 / JIT 状态 | API 面里不存在 |
| 关闭崩溃安全模式 / 隐藏插件管理入口 | 宿主保留能力，不是权限 |

### 2.9 账号与 token 的绝对边界

这条不依赖任何权限，属于**实现约束**：

1. `air2` 对象上**不存在** `account` / `auth` / `token` / `session` 任何命名空间。
2. `launch.*` 的受保护参数（`--accessToken` / `--uuid` / `--username`）由宿主在插件参数**之后**
   统一追加；插件写入的同名参数一律丢弃并记 `plugin-forbidden-arg`。
3. `-Dminecraft.api.auth.host` / `-Dminecraft.api.session.host` / `-Dminecraft.api.services.host`
   一律禁止，不降级为「需要权限」。
4. `air2.files.*` 的 token 表里没有账号目录；`files.game.read` 的根是游戏目录，不是 App 容器根。
5. 日志脱敏：任何长度 ≥ 32 的 base64 / hex 串一律替换为 `<redacted>`。

---

## 三、逐项授权模型

### 3.1 三种默认状态

| 风险 | 安装页默认 | 用户操作 | 跨版本 |
|---|---|---|---|
| 低 | **开启** | 可逐项关掉 | 沿用（按 `pluginId + permissionId`） |
| 中 | **开启** | 可逐项关掉 | 沿用（按 `pluginId + permissionId`） |
| **critical** | **关闭** | 必须逐项点「授权」并走三次 5 秒确认 | **不沿用**：绑定 `(pluginId, packageHash, permissionId)`，包哈希变一次就重新确认一次 |

「默认开启」不等于「静默授予」：安装页会把低/中权限逐条列出，用户必须看到并可以关掉。
「默认关闭」也不等于「安装失败」：用户可以不授权任何 critical 权限，插件照常安装，
只是对应 API 在运行时不存在，管理页标「功能受限」。

### 3.2 安装详情页（授权之前）

导入包并完成结构 / schema / 哈希校验后，安装器必须先展示一页**不可跳过**的详情：

```
┌──────────────────────────────────────────────┐
│  [插件图标]  Hello 下载器                     │
│  top.example.downloader · 1.2.0              │
│  作者（自述）：示例作者                        │
│  来源：从文件导入 · hello.air2plugin           │
│  包哈希：a3f1…9c2e（完整值可展开）             │
│                                              │
│  ⚠ Air2 不验证作者身份。请确认这个包来自你      │
│    信任的地方。哈希只能证明「包没变」，不能     │
│    证明「是谁做的」。                          │
│                                              │
│  申请的权限（5）                               │
│  [✓] 版本显示装饰        低 · 只影响展示        │
│  [✓] 游戏配置写入        中 · 可改 options.txt  │
│  [ ] 追加 JVM 参数        高危 · 未授权          │
│      └ 授权（需 3 步确认）                      │
│  [ ] 写入 mods/*.jar      高危 · 未授权          │
│      └ 授权（需 3 步确认）                      │
│  [ ] 读取游戏文件        中 · 未授权             │
│                                              │
│  组合风险：无                                  │
│                                              │
│  [ 取消 ]                    [ 安装 ]         │
└──────────────────────────────────────────────┘
```

规则：

1. `author.name` / `author.url` 是**作者自述**，必须带「自述」标签，不得显示成「官方」。
2. 包哈希显示前 8 位 + 后 4 位，点击可看完整 64 位；复制按钮复制完整值。
3. 每个权限必须有一句**人话说明**（不是权限 id），并标注风险级与生效阶段。
4. 未到当前宿主里程碑的权限显示「当前版本不可用」，开关禁用。
5. 「安装」按钮在 critical 未授权时仍可点；文案变为「安装（2 项高危未授权）」。
6. 组合风险命中硬拒装时，这一页直接变成失败页，列出两个权限 id 与原因（见第四节）。

### 3.3 critical 权限的三次确认

**每个 critical 权限独立走三次确认**，不是把多个权限打包成一次。
第 1、2、3 次提示框都必须是**独立的全屏页 / 大号模态**，不允许用一个小号 ActionSheet 代替。

#### 第 1 次：这个权限能做什么

- 标题：`高危权限：<人话名称>`
- 正文：
  - 权限 id 与一句话定义；
  - 允许的具体操作（逐条，最多 5 条）；
  - 明确写出「这个权限**不能**做什么」（硬边界）；
  - 风险级与生效阶段。
- 底部按钮：`取消`（始终可点）、`继续`（**5 秒倒计时结束前禁用**）。
- 倒计时文案：`请阅读以上说明，5 秒后可继续`；剩余秒数可见；按钮禁用态不能通过连点、回车、辅助功能绕过。

#### 第 2 次：允许之后可能造成的危害

- 标题：`再确认：<人话名称>可能造成什么`
- 正文：至少 **2 个具体危害场景**，必须是用户能理解的行为，不是抽象形容词。例：
  - `launch.args`：「插件可以往 JVM 追加调试端口，让同一网络内的调试器接管游戏进程。」
  - `files.game.write.content`：「插件可以把任意 mod 的 jar 换成自己的代码；下次启动游戏时这些代码会运行。」
  - `version.patch`：「插件可以改版本元数据，让启动器显示的和实际运行的不是同一个版本。」
  - `java.agent`：「插件可以向游戏进程注入任意 Java 代码，等同于把游戏进程交给它。」
- 额外一行：`如果你不确定这个插件为什么需要它，请取消。`
- 底部按钮同上：`取消` / `继续`（5 秒倒计时）。

#### 第 3 次：最终确认

- 标题：`最后确认：授予 <人话名称>？`
- 正文：
  - 复述权限 id、插件名、包哈希前 8 位；
  - 列出本次**已经授权**的全部 critical 权限（如果有多个，逐个列出）；
  - 明确写出：`授权后，插件可以在你不知情的情况下执行上述操作。`
  - 明确写出：`包一旦变化（更新 / 重装 / 改内容），这项授权会自动失效并要求重新确认。`
- 底部按钮：`不授权`（主按钮，默认高亮）、`我已知晓，授权`（次要按钮，5 秒倒计时结束后才可点）。
- 第 3 次确认后才写入 registry 的 `criticalGrants`。

#### 计时与交互的硬规则

| 规则 | 要求 |
|---|---|
| 计时源 | `mach_absolute_time` / `CACurrentMediaTime`，不用 wall clock；系统时间变化不影响 |
| 后台 | App 进入后台 → 倒计时暂停；回前台重新计满 5 秒（不允许「后台等 5 秒再回来点」） |
| 旋转 / 分屏 | 不重置倒计时，但按钮位置必须保持可达 |
| 辅助功能 | VoiceOver 必须朗读完整正文与倒计时；「减弱动态效果」不影响倒计时；动态字体放大后正文可滚动 |
| 自动化 | 不接受 URL Scheme / 快捷键 / 辅助功能 API 直接触发「授权」；没有 release 版绕过开关 |
| 取消 | 任意一步取消 → 该权限不授予；已完成的其它权限不受影响；安装继续 |
| 重复 | 同一 `(pluginId, packageHash, permissionId)` 已授权 → 不再弹三次；包哈希变化 → 重新弹 |
| 记录 | 每次授权写 `grantedAt` / `method:"three-step"` / `packageHash` / `hostVersion`，管理页可查 |

### 3.4 授权绑定与失效

| 风险 | 绑定键 | 何时失效 |
|---|---|---|
| 低 / 中 | `(pluginId, permissionId)` | 用户手动关闭；manifest 不再申请该权限（自动移除）；插件卸载 |
| **critical** | `(pluginId, packageHash, permissionId)` | 用户手动关闭；`packageHash` 变化（升级 / 重装 / 改内容）；manifest 不再申请；插件卸载 |

补充规则：

1. **同包重装幂等**：`packageHash` 完全相同 → 直接成功，不重新弹授权。
2. **同版本不同内容 → 拒装**（见 `PLUGIN-SYSTEM.md` 4.5），不进入授权流程。
3. **升级时新增 critical**：只为新增项走三次确认；已授权且 `packageHash` 已变的旧 critical 项
   **全部重新确认**（因为绑定键变了）。
4. **升级时新增低/中**：在更新页列出并默认开启，用户可关掉；不额外弹窗。
5. **降级**：默认拒绝（见 `PLUGIN-SYSTEM.md` 4.5）。开发者模式例外；降级后 critical 仍需重新确认。
6. **用户手动改授权**：`grantRevision + 1`，插件在下次加载时拿到新的能力面；运行中的上下文不热改。

### 3.5 管理页必须显示什么

- 插件名、id、版本、作者（自述）、来源、安装时间、包哈希短串；
- 已授予权限（按风险分组）；critical 项显示「授权于 <时间> · 绑定包 <hash8>」；
- 未授予但申请的权限，标「未授权」；当前宿主不支持的，标「当前版本不可用」；
- 「重新审查权限」按钮 → 重新打开安装详情页（只读 + 可调整低/中；critical 变更走三次确认）；
- 「撤销全部授权」按钮 → 二次确认后清空 `permissionsGranted` / `criticalGrants`，插件重载后能力面为空；
- **不显示**「官方」「已验证」「信任等级」「签名者」任何徽标或字段。

### 3.6 为什么取消签名

| 原方案 | 问题 |
|---|---|
| 官方签名 + 白名单 + T0/T1/T2 | 需要官方维护密钥、审核流程、白名单、吊销链；个人开发者几乎不可能进 T1，复杂插件生态起不来 |
| 自签名「密码学有效」 | 任何攻击者都能自签，白名单才是信任来源；没有白名单时，签名只提供「未被篡改」的错觉 |
| 「官方」徽标 | 一旦被仿冒，用户会以为签名等于安全；取消后反而没有这个误导 |

取消签名后，Air2 的承诺变小了，但更诚实：**哈希防误改，权限防越权，作者身份由用户判断**。
这也是 ADR-021 的核心取舍。

---

## 四、组合风险判定

单项权限的风险已经在上表；但真正危险的是**组合**。判定发生在安装第 ⑤ 步（授权页之前），
结果只有两种：**通过（可能带组合提示）** / **拒装**。

### 4.1 直接拒装（硬失败，不能通过任何确认放行）

| 组合 | 为什么拒 |
|---|---|
| `launch.args` + `java.agent` | `args` 可以自己再塞一条 `-javaagent=`，让 `java.agent` 的路径白名单与 jar 哈希校验形同虚设 —— 拿到 agent 权限的插件再要 `args` 等于要全权，没有可审计的边界。 |
| `launch.args` + `launch.classpath` | 同理：`-cp` 可以直接写在 args 里，`classpath` 的「条目必须落在插件/游戏目录内」这条约束被绕过。 |
| `launch.args` + `launch.env.code` | 任意参数 + 任意代码路径 = 审计面消失（谁都可以把等价能力搬到另一个面上）。 |
| `launch.gameArgs` + `launch.args` | 两段参数面同时开放时，插件可以把「游戏参数」伪装成「JVM 参数」的等价能力（例如通过游戏参数触发调试/代理），宿主无法给出有意义的边界。 |
| `native.module` + 任一（`launch.args` / `launch.classpath` / `launch.libraryPath` / `launch.env.code` / `launch.gameArgs`） | 原生模块已经能改宿主进程符号面，再叠加任意启动参数或库路径 ⇒ 无法给出有意义的授权边界，也无法在崩溃时归因。 |
| `ui.web` + `native.module` | 不可信页面内容 + 原生代码，两个信任域直接打通。 |
| `version.patch` + `download.source` | 下载源可投递伪造文件，`version.patch` 再改版本元数据 ⇒ 「这个版本到底是什么」不可信，等于把冒充做成一条流水线。 |

拒装的文案要求：必须写出**具体冲突的两个权限 id** 与一句话原因，不许只说「权限组合不被允许」。

### 4.2 组合提示（可放行，但必须在授权页额外展示）

| 情形 | 额外提示 |
|---|---|
| `files.game.read` + `network.http` | 「该插件可以读取游戏配置 / 日志 / 存档 / mods，并把内容发送到它声明的域名。请确认域名可信。」 |
| `files.game.read` + `files.export` | 「该插件可以把游戏文件交给你选择的 App / 云盘。」 |
| `launch.classpath` + `launch.libraryPath` | 「该插件可以替换原生库解析路径，并追加 classpath 条目。」 |
| `files.game.write.content` + `version.patch` | 「该插件既能换 mod 文件，也能改版本元数据；版本详情页会常驻『已被插件修改』徽标。」 |
| `ui.web` + `network.http` | 「插件页面可以加载远端内容。」 |
| `java.agent` | 「可向游戏进程注入任意 Java 代码。」 |
| `native.module` | 额外一页（第 4 页）：「这是未审核的原生代码，可以读写宿主进程内存。」 |

组合提示不改变授权步骤：critical 仍然逐项三次确认；中风险组合只在安装页显示一行警告。

### 4.3 不算冲突但必须记日志

| 情形 | 处理 |
|---|---|
| `launch.env` 与 `launch.env.code` 写同名变量 | 不拒装（名字冲突在安装期不可知）：运行时以 `code` 为准并打一条 `plugin-env-override` 诊断 |
| 两个插件写同一 `-D` 属性 | 后加载者覆盖（按 `PLUGIN-SYSTEM.md` 5.2 排序），诊断页显示最终值与来源插件 |
| 两个插件改同一版本元数据 | 同上，L0 层按排序键后者胜；详情页显示「由 N 个插件修改」 |
| 两个插件都注册 `launch.overlay` | 按排序键叠加；`ui.override` 的独占规则见 `PLUGIN-COMPAT.md` 2.2 |

---

## 五、哈希与完整性

### 5.1 三个摘要

| 名字 | 计算方式 | 用途 |
|---|---|---|
| `fileDigest` | 单文件字节的 `SHA-256`，hex 小写 | `manifest.files[].sha256` |
| `filesDigest` | 对 `manifest.files` 按 `path` 字典序排列后的规范化清单（`path\0sha256\0size\n` 逐条拼接）再 `SHA-256` | 完整性检查、包哈希组成部分 |
| `packageHash` | `SHA-256("AIR2-PKG-V1\n" + manifestDigest + "\n" + filesDigest)`，其中 `manifestDigest` = `manifest.json` 规范化（RFC 8785 JCS）后的 `SHA-256` | 授权绑定、注册表记录、重装幂等判定、安装页展示 |

`packageHash` 与 zip 的字节无关：同一份内容用不同压缩工具重打包，`packageHash` 不变。
这是刻意的：用户看到的是「内容哈希」，不是「某个压缩工具的产物哈希」。

### 5.2 何时校验什么

| 时机 | 范围 | 失败处理 |
|---|---|---|
| **安装（全量）** | `manifest.files` 里**每一个**文件的 `fileDigest`；并检查「包内除 `manifest.json` 外的文件集合 == 清单集合」（双向相等，多一个即夹带） | 拒装，删除 staging |
| **每次加载（关键子集）** | `manifest.json`、`entry`（`entry.js`）、`ui/**`、`pages/**`、`native/**` —— 即**所有会被解释执行或被当作声明读取的文件** | 不加载该插件，registry 置 `tampered=true`，管理页红色条目 + 「重新安装」按钮 |
| 显式「完整性检查」（管理页） | 全量 | 同上 |
| 宿主大版本升级后首次启动 | 全量 | 同上（逐个插件标记，不影响启动） |
| 运行中 | 不校验 | —— |

**为什么加载不做全量**：`manifest.files` 可能覆盖 200+ MB 资源，在启动关键路径上做全量哈希
会把冷启动拖长数百毫秒；而资源文件（图片、语言包）不被解释执行，篡改后的后果是「显示异常」，
不是「代码执行」。真正需要每次验的是被当作代码或声明解释的那几类。

### 5.3 哈希能证明什么，不能证明什么

| 能证明 | 不能证明 |
|---|---|
| 包在安装时与 `manifest.files` 一致 | 包是谁做的（没有作者身份） |
| 安装后关键文件没被改动（加载期子集） | 拥有设备写权限、能同时改 registry 的攻击者没动过 |
| 同 `id` 同 `version` 的内容是否变过 | 包里的 JS 是善意的 |
| 用户看到的 `packageHash` 与实际安装内容一致 | 下载源没有在传输中替换（只能发现「内容变了」，不能发现「第一次就下到假包」） |

因此：**哈希是完整性工具，不是信任工具**。安装页必须把这句话写给用户看。

### 5.4 不再有签名块

- 包根**不允许**出现 `AIR2SIG.json`。出现即拒装，错误码 `E_LEGACY_SIGNATURE`，
  文案：「此包使用了已移除的签名格式，请重新导出」。
- 宿主没有 keyring、公钥、作者白名单、吊销列表、`signerFingerprint`、`trustLevel`。
- registry 不记录任何签名相关字段。
- 旧文档 / 旧工具生成的签名块不再有特殊含义；把它当普通文件列进 `manifest.files` 也不能恢复信任。

### 5.5 存储保护

| 项 | 规则 |
|---|---|
| 位置 | `Library/Application Support/Air2/Plugins/`，不在 `Documents` |
| 文件保护 | `NSFileProtectionCompleteUntilFirstUserAuthentication`（设备首次解锁后可读，锁屏后台任务仍可加载） |
| 备份 | 插件目录与 `registry.json` 设 `NSURLIsExcludedFromBackupKey`；插件可由包重新安装，不占 iCloud 配额 |
| 目录权限 | 仅宿主进程可写；不暴露给文件 App / 分享面板 |
| registry | `write-temp → fsync(file) → rename → fsync(dir)`；读失败改名 `.corrupt-<ts>` 重建，不猜不修 |
| 插件私有数据 | `Plugins/<pluginId>/data/`，单键 ≤ 64 KB，总量 ≤ 1 MB；卸载时可选保留 |

---

## 六、崩溃安全模式

目标：**插件把启动搞挂之后，启动器一定要能起来**，且用户能看出是哪个插件。

### 6.1 stage marker

文件：`Plugins/.bootstate.json`（宿主写，原子替换）。

```json
{
  "bootId": "3f2a…",
  "enabledFingerprint": "sha256:…",
  "userSeq": 41,
  "stage": "boot",
  "updatedAt": "2026-10-31T10:00:00Z"
}
```

- `enabledFingerprint` = 对「启用集」排序后逐条 `id@version@packageHash:grantRevision` 拼接再 `SHA-256`，
  用于诊断与崩溃报告（「是哪一组插件 + 哪一组授权」）。
- `userSeq` = **用户配置序号**：用户每次安装 / 卸载 / 开关插件 / 改授权，registry 的 `userSeq` +1。
  归因比较的是它，**不是**指纹 —— 因为宿主自动禁用插件也会改指纹，若拿指纹比较，
  「2 次禁一个 → 集合变了 → 计数归零」就永远到不了第 3 次的「3 次进安全模式」。
  自动禁用**不**改 `userSeq`。
- `stage` 三档：
  1. `boot` —— Phase A 完成（注册表读完、启用集算完），**UI 还没画**；
  2. `ui` —— 首帧已出；
  3. `stable` —— 首帧后**稳定 5 秒**。走到 `stable` 才**清除** marker 并把
     `suspectCount` 归零（同时触发旧版本目录清理）。

marker 在**启动最早**写入 `stage:"boot"`，此后只往前走，不回头。

### 6.2 归因规则

下次启动读 marker，只有同时满足两条才算「插件相关的可疑失败」：

1. `marker.stage` **早于首帧**（即等于 `boot`）；
2. `marker.userSeq` == 本次 `userSeq`（用户没动过插件配置、也没有新装/卸载）。

于是：

| 情况 | 是否计入 |
|---|---|
| 上次死在 `boot`（UI 都没出来），用户没动配置 | **计入**（`suspectCount += 1`） |
| 上次死在 `boot`，但用户装/卸/开关过插件或改过授权（`userSeq` 变了） | 不计入，`suspectCount` 归零 |
| 上次死在 `ui` 之后（首帧已出，例如进游戏时崩 / 用户强杀） | **不计入** |
| 上次走到 `stable` | 不计入（marker 已清） |
| 用户主动强杀一次（marker 停在 `boot`） | 计入 1 次，但**不触发任何动作**（阈值 2） |

### 6.3 升级路径

| `suspectCount` | 动作 |
|---|---|
| 1 | 只记录，不改配置。单次强杀不触发任何禁用。 |
| **2** | **禁用「最近启用的插件」**（registry 中 `lastEnabledChangeAt` 最新的一个），管理页提示「已因启动失败禁用 <id>」。**计数器不清零**（自动禁用不动 `userSeq`，计数继续累计，才能晋级到第 3 次）。 |
| **3** | **进入安全模式**：本次启动禁用全部 **L2**（覆盖层：`hide` / `override` / 整页替换 / `launch.overlay`）插件；仍失败（计数继续 +1）则下一次再禁用全部 **L1**（slot / 主题 / 页面入口），只保留 L0（纯数据）与纯 JSON 声明。 |
| 成功到 `stable` | `suspectCount = 0`，退出安全模式，恢复被**自动**禁用的插件（用户手动禁用的不动）。 |

安全模式期间 UI 必须有：常驻横幅（「插件安全模式：已临时禁用 N 个插件」）+
「插件诊断」页（逐插件显示：层级、最近一次 stage、是否被自动禁用、原因）+
「逐个恢复」入口（恢复一个 → 重启 → 若再失败则回到安全模式并保留该插件为禁用）。

### 6.4 P1 的实现范围（重要）

P1 **只做**：

1. 启动最早写 `stage:"boot"`；首帧写 `stage:"ui"`；稳定 5 秒写 `stage:"stable"` 并清除；
2. 下次启动按 6.2 计算 `suspectCount` 并写回 registry；
3. 管理页显示 `suspectCount` 与最近 stage。

P1 **不做**自动禁用、不做安全模式。原因：P1 还没有插件运行时代码，自动禁用没有对象；
提前实现会让「崩溃计数」与「真实插件生命周期」脱节。自动禁用从 **P2（有 slot 渲染）** 开始生效。

### 6.5 与宿主自身崩溃的区分

- `A2CrashGuard` 已有的崩溃记录与 stage marker **互不替代**：
  CrashGuard 记的是「崩了」，stage marker 记的是「崩在插件生命周期的哪一段」。
- 插件只能影响 `boot → ui` 这一段（Phase B 的 `onLoad`/`onBoot`）。所以判定一律以
  「stage 是否早于首帧」为准，不看崩溃信号的类型 —— 类型会误导（同一插件可能以不同信号崩）。

---

## 七、存储与隔离

| 项 | 规则 |
|---|---|
| 插件私有存储 | `air2.storage`，物理位置 `Plugins/<pluginId>/data/`，宿主维护索引；单键 ≤ 64 KB，总量 ≤ 1 MB |
| 插件缓存 | `Plugins/<pluginId>/cache/`，可被系统清理；不进入备份；不保证持久 |
| 跨插件读取 | 不存在任何 API；文件系统层面也不给路径 |
| 日志 | 全部经宿主格式化，带 `[PLUGIN:<id>]` 前缀；**任何看起来像 token 的串（长度 ≥ 32 的 base64/hex）一律替换为 `<redacted>`** |
| 崩溃日志 | 记插件 id 与当前 stage，不记插件变量内容 |
| 删除插件 | 同时删 `data/` 与 `cache/`（除非用户在卸载提示里选「保留数据」） |
| 备份 | 插件目录、registry、插件数据全部排除 iCloud 备份 |

---

## 八、安全相关的验收清单（P1/P2 实现时必须逐条可测）

### 8.1 授权

1. critical 权限默认关闭；安装不授权也能成功；装完后对应 API 在 `air2` 上**不存在**。
2. 每个 critical 权限独立弹三次；第 1、2、3 次「继续 / 授权」按钮在 5 秒内均不可点。
3. 第 1 次取消 → 该权限不授予；安装继续；其它已授权项不受影响。
4. 第 2 次取消 → 同上；第 3 次点「不授权」→ 同上。
5. 第 3 次确认后 → registry 出现 `criticalGrants` 条目，含 `packageHash` / `grantedAt` / `method:"three-step"`。
6. 同 `(pluginId, packageHash, permissionId)` 二次安装 → 幂等成功，不再弹三次。
7. 同 `pluginId` 装**新版本**（`packageHash` 变化）→ 所有 critical 权限重新弹三次；低/中沿用。
8. 同 `version` 但内容不同 → **拒装**（`E_SAME_VERSION_DIFFERENT_CONTENT`），不进入授权。
9. 低/中权限在安装页默认开启，可逐项关掉；关掉后 API 不存在。
10. 升级新增低/中权限 → 更新页列出且默认开启，可关；新增 critical → 只对新增项弹三次。
11. 用户撤销全部授权 → 重载后只剩无权限基础面（`host` / `log` / `i18n` / `storage` / `crypto` /
    `paths` / `ui` / `files` / `instance`）；`launch` / `page` / `net` / `download` 以及
    `files.writeGame` / `ui.register` / `paths.gameDir` 等受控入口**都不存在**。

### 8.2 包与完整性

12. 包内多一个未在 `manifest.files` 里的文件 → 拒装（`E_FILE_SET_MISMATCH`）。
13. `manifest.files` 少一个实际存在的文件 → 拒装。
14. 解压后手工改 `entry.js` → 下次加载拒绝，`tampered=true`。
15. 包根出现 `AIR2SIG.json` → 拒装（`E_LEGACY_SIGNATURE`）。
16. 同内容用不同 zip 工具重打包 → `packageHash` 相同；用户看到的哈希不变。

### 8.3 组合与参数

17. 组合 `launch.args` + `java.agent` → 拒装，文案含两个 id。
18. 组合 `launch.gameArgs` + `launch.args` → 拒装。
19. `-Dminecraft.api.auth.host=...` 出现在插件参数里 → 该条被丢弃并记 `plugin-forbidden-arg`。
20. `--accessToken` 出现在插件参数 / 游戏参数里 → 丢弃；最终命令行里仍只有宿主追加的那一份。
21. `launch.env` 写 `JAVA_TOOL_OPTIONS` / `_JAVA_OPTIONS` / `JDK_JAVA_OPTIONS` → 拒绝该条并记诊断。
22. `files.game.read` 尝试读账号目录 token → `E_FORBIDDEN_ARG`；日志不出现绝对路径。
23. `files.export` 只能通过系统分享面板；插件无法指定落盘路径。

### 8.4 崩溃与界面

24. 连崩两次（stage 停在 `boot`）→ P2 起最近启用的插件被禁用；P1 只记录，不自动禁用。
25. 连崩三次 → P2 起进安全模式，L2 全禁，横幅可见。
26. 首帧后 5 秒内用户强杀 → 不算失败，`suspectCount` 不变。
27. `ui.override` 插件试图隐藏「插件管理」入口 → 宿主拒绝该 override 并记诊断。
28. 插件页面顶部必须显示插件名 + 「插件页面」横幅；插件无法通过任何组件隐藏它。
29. 页面 schema 里没有密码框组件；`air2.ui.promptSecret` 必须使用宿主自绘的安全输入页。
30. 插件页面尝试渲染 HTML / 远程图片 → schema 拒装或运行时拒绝该节点，不加载远端资源。

# Air2 插件安全模型

> **状态**：P0 契约。本文是权限、信任、哈希、签名、崩溃归因的**唯一权威定义**，
> 与 `plugin.schema.json` 的枚举必须逐项一致（改一处必须同时改另一处）。
> **前提**：插件运行在宿主进程内（JSCore），不是独立进程 —— 所以安全边界靠
> 「能力注入 + 安装期判定 + 完整性校验」三层，**不靠运行时沙箱**。

---

## 一、威胁模型

| 威胁 | 是不是要防 | 手段 |
|---|---|---|
| 插件作者上传一个「声明无害、实际越权」的包 | 是 | 权限由宿主判定与授予，作者声明只是申请；API 面按授权注入 |
| 用户在文件 App 里手改插件目录（iOS 侧载场景） | 是 | 目录不在 `Documents`；每类关键文件加载前验哈希 |
| 中间人替换下载到的插件包 | 是 | 签名（Ed25519）+ 白名单指纹；未签名包走 T0 一次性授权 |
| 恶意插件通过参数面拿账号 token | 是 | `-Dminecraft.api.*.host` 直接禁止；`accessToken` 类参数插件不可写 |
| 插件借崩溃把启动器搞成砖 | 是 | 崩溃安全模式（第六节）：stage marker + 逐级禁用 |
| 插件读别的插件的数据 | 是 | 每插件独立存储命名空间；无跨插件 API |
| 插件读宿主私有状态（账号、JIT 状态、调试端口） | 是 | API 面里不存在这些对象 |
| 恶意作者在插件里跑任意原生代码 | **v1 不接受**（P5 才开，且门槛见 ADR-020） | `formatVersion 2` 的包出现 `native/` 即拒装 |
| 用户被钓鱼装了「官方外观」的仿冒插件 | 部分防 | 管理页常驻签名/信任徽标（T0 显式标「未验证」） |

**明确承认的残余风险**：JS 插件在宿主进程内运行，一旦 JSCore 层出现可被 `entry.js`
利用的越界（JSCore 自身漏洞），能力注入挡不住。这也是为什么 JS 运行时（P3）必须
在 `eval` / `Function.constructor` / `WebAssembly` 三处封死，且原生面推迟到 P5。

---

## 二、权限目录

风险级：**低**（只有展示影响）/ **中**（有副作用，边界清晰）/ **critical**（可影响进程、
代码执行、或数据可信度）。

「平台」列只有 `ios` 是当前实现；`android` / `desktop` 为契约占位，宿主未实现即视为**不可用**。

### 2.1 启动类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `launch.tuning` | 中 | ios | P3 | 结构化调优：内存上下限、GC 选择、渲染开关 | 只能取宿主枚举内的键值；`-Xmx` 上限受设备物理内存约束（宿主 clamp） |
| `launch.properties` | 中 | ios | P3 | `-D<name>=<value>` | `name` 必须命中前缀白名单：`fml.` / `forge.` / `neoforge.` / `mixin.` / `fabric.` / `quilt.` / `iris.` / `sodium.`；白名单外**只能**走 `launch.args` |
| `launch.args` | **critical** | ios | P3 | 追加裸 JVM 参数，逐条展示 | 受保护参数与 `-Dminecraft.api.*.host` 仍然禁止（见 `PLUGIN-API.md` 5.2）；`-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` 另需 `java.agent`；`-Xbootclasspath*` / `--patch-module` / `-cp` 另需 `launch.classpath`；`-Djava.library.path` 需 `launch.libraryPath` |
| `launch.env` | 中 | ios | P3 | 设置进程环境变量（静态值，manifest 内声明） | 名字不能是宿主保留变量（`HOME` / `TMPDIR` / `JAVA_HOME` / `DYLD_*`）；值长度 ≤ 4 KB |
| `launch.env.code` | **critical** | ios | P3 | 启动时由插件代码计算环境变量 | 每次启动重新计算 → 每次启动都写一条诊断日志（值脱敏后前 64 字节） |
| `launch.classpath` | **critical** | ios | P3 | `-cp` 追加条目（插件自带 jar 或游戏目录内已存在文件） | 条目必须落在插件目录或游戏目录内；不允许绝对路径指向沙箱外 |
| `launch.libraryPath` | **critical** | ios | P3 | 改 `-Djava.library.path` | 只能**追加**，不能替换宿主设置的原生库路径；插入顺序受控（插件段在宿主段之后、用户段之前） |
| `java.agent` | **critical** | ios | P3（P5 扩展到自带 jar） | `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` | 路径必须在插件目录或游戏目录内；jar 需在 `manifest.files` 清单内并被哈希校验；`-Xrunjdwp` 允许（调试用途），但会额外提示「可能被任意调试器接管」 |

### 2.2 文件类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `files.game.write.config` | 中 | ios | P3 | 写游戏目录内的**配置类**文件：`options.txt`、`config/**`、`mods/**/*.toml`、`servers.dat` | 目标路径必须命中配置白名单；单次 ≤ 4 MB；写入走临时文件 + rename |
| `files.game.write.content` | **critical** | ios | P3 | 写游戏目录内**内容类**文件：`mods/*.jar`、`resourcepacks/**`、`shaderpacks/**`、`saves/**` | 目标必须在游戏目录内且不在 `libraries/`；不得覆盖 `.jar` 的签名-哈希记录；写入前把被覆盖文件复制到宿主备份区（可回滚） |

> 拆成两个 id 而不是一个 `files.game.write`：因为「改配置」和「换 mod jar」是两种完全不同的
> 信任诉求 —— 前者坏了一个 mod 设置，后者可以换掉任意 mod 的代码。合并成一个 id 会让
> 「只改配置」的插件被迫申请 critical 权限，用户只能全给或全不给。

### 2.3 版本类

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `version.decorate` | 低 | ios | P2 | 改**显示**：版本列表的标题/副标题/徽标/图标 | 只影响展示层，不落盘；宿主另存「真实名」，详情页可切换查看 |
| `version.patch` | **critical** | ios | P3 | 改**内容**：向版本目录写入/替换 jar 之外的补丁文件、改 `version.json` 的本地副本 | 不得改 `.jar` 本体与 `libraries/`；每次 patch 记录到 `patches.log`；补丁在版本详情页常驻「已被插件修改」徽标 |

### 2.4 网络与下载（P4）

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `network.http` | 中 | ios | P4 | 出站 GET/POST 到 manifest 声明的域名 | 域名预声明（安装时列出）；禁 `file://` / 内网段；响应 ≤ 8 MB |
| `download.source` | 中 | ios | P4 | 追加下载源候选（镜像 URL 模板） | 只能**追加**候选，不能改引擎顺序；不参与官方文件的签名校验 |
| `version.filter` | 低 | ios | P4 | 按规则隐藏/置灰版本 | 只影响展示与选择，不删文件；隐藏项可在设置里一键显示 |

### 2.5 P5 才可用

| id | 风险 | 平台 | 生效 | 允许做什么 | 硬边界 |
|---|---|---|---|---|---|
| `native.module` | **critical** | ios | P5 | 装载插件自带 dylib | 仅 T2 可授予；签名白名单；ABI 版本必须匹配；只能调用 `air2_plugin_abi_v1` 导出符号 |
| `ui.web` | **critical** | ios | P5 | 内嵌 WebView 承载插件页面 | 禁 `file://`；独立进程或强隔离；页面与插件 JS 之间不直连 |

### 2.6 一律不可授予（不存在于目录）

| 能力 | 原因 |
|---|---|
| 读账号 token / 写账号状态 | API 面里没有 `air2.account` |
| 任意绝对路径读写 | `air2.paths` 只发不透明 token |
| 执行任意代码（`eval` 类） | JSCore 上下文不注入，非权限问题 |
| 改宿主下载引擎选择逻辑 | 非目标（`PLUGIN-SYSTEM.md` 1.2） |
| 游戏内 UI hook | v1 非目标 |
| 访问其它插件的数据 | 存储命名空间隔离 |

---

## 三、信任等级

| 等级 | 判定条件 | 可授予的权限 | 授权绑定 | UI 徽标 |
|---|---|---|---|---|
| **T0** | 无签名，或签名无法验证（公钥未知 / 校验失败 / 未被支持） | 仅**低 / 中**风险权限。critical 一律不授予（安装器直接不列出） | **一次性**：按 `(pluginId, packageHash)` 绑定，包哈希变化即失效，需重新授权 | 橙色「未验证」 |
| **T1** | 签名**有效**（Ed25519 校验通过、`keyId` 已知、未吊销）**且** 签名者指纹在宿主的**白名单**内 | 全部权限（含 critical），critical 走红色二次确认 | 记 `pluginId` + `packageHash`；同 id 新版本若权限集**不扩大**则沿用，扩大则只对新增项重新确认（critical 仍走红色页） | 蓝色「已验证」+ 指纹短串 |
| **T2** | 官方发布密钥（`keyId` ∈ 宿主内置官方 key 集合）+ **签名者指纹与官方一致** + 来源为官方仓库 | 全部权限（含 P5 的 `native.module` / `ui.web`） | 同上；官方自动更新不重复弹窗（权限集不变时） | 绿色「官方」 |

关键定义：

- **`signerFingerprint` = `"sha256:" + hex(SHA-256(Ed25519 公钥原始 32 字节))`**。指纹针对**公钥**，不是证书、不是包。
- **T1 的两个条件是与关系**：签名有效但指纹不在白名单 → **仍是 T0**。
  这一条是刻意的：自签名的包在密码学上「有效」，但在信任上「无意义」——
  任何攻击者都能自己生成一对密钥签一个包。白名单是信任的唯一来源。
- 白名单在 P2 是**宿主内置静态列表**（随 App 更新下发）；P5 允许从官方仓库拉更新，
  但**永远只能追加/吊销、不能替换整个集合**（防止一次远端失陷把信任根换掉）。
- T0 的「一次性」含义：`packageHash` 变了就重新弹授权页，**即使用户之前授权过同名同版本**。
  目的是让「同一个 id 悄悄换了内容」这件事必须被用户看见一次。

---

## 四、组合风险判定

单项权限的风险已经在上表；但真正危险的是**组合**。判定发生在安装第 ⑤ 步（授权前），
结果只有三种：**通过** / **红色二次确认** / **拒装**。

### 4.1 直接拒装（硬失败，不能通过任何确认放行）

| 组合 | 为什么拒 |
|---|---|
| `launch.args` + `java.agent` | `args` 可以自己再塞一条 `-javaagent=`，让 `java.agent` 的路径白名单与 jar 哈希校验形同虚设 —— 拿到 agent 权限的插件再要 `args` 等于要全权，没有可审计的边界。 |
| `launch.args` + `launch.classpath` | 同理：`-cp` 可以直接写在 args 里，`classpath` 的「条目必须落在插件/游戏目录内」这条约束被绕过。 |
| `launch.args` + `launch.env.code` | 任意参数 + 任意代码路径 = 审计面消失（谁都可以把等价能力搬到另一个面上）。 |
| `native.module` + 任一（`launch.args` / `launch.classpath` / `launch.libraryPath` / `launch.env.code`） | 原生模块已经能改宿主进程符号面，再叠加任意启动参数或库路径 ⇒ 无法给出有意义的授权边界，也无法在崩溃时归因。 |
| `ui.web` + `native.module` | 不可信页面内容 + 原生代码，两个信任域直接打通。 |
| `version.patch` + `download.source` | 下载源可投递伪造文件，`version.patch` 再改版本元数据 ⇒ 「这个版本到底是什么」不可信，等于把冒充做成一条流水线。 |

拒装的文案要求：必须写出**具体冲突的两个权限 id** 与一句话原因，不许只说「权限组合不被允许」。

### 4.2 红色二次确认（可放行，但必须走红色警告页）

红色页 = 全屏警示、红底标题、逐条列出将要授予的具体条款（不是权限 id 列表）、
底部两个按钮（「返回」为主按钮、「我了解风险，继续」为次要按钮，不做默认高亮）。
**不允许**用普通确认弹窗代替。

| 情形 | 额外要求 |
|---|---|
| 申请任一 critical 单项（`launch.args` / `launch.env.code` / `launch.classpath` / `launch.libraryPath` / `java.agent` / `files.game.write.content` / `version.patch`） | 逐条展示该权限将造成的具体后果（例：「允许向 JVM 追加任意参数，包括调试端口」） |
| `launch.classpath` + `launch.libraryPath` 同时申请 | 额外一行说明：可替换原生库解析路径 |
| `files.game.write.content` + `version.patch` | 额外要求：该插件在版本详情页常驻「来源可能不可信」徽标 |
| `ui.web` + `network.http` | 额外一行说明：页面可加载远端内容 |
| `java.agent` | 额外一行说明：可注入任意 Java 代码到游戏进程 |

### 4.3 不算冲突但必须记日志

| 情形 | 处理 |
|---|---|
| `launch.env` 与 `launch.env.code` 写同名变量 | 不拒装（名字冲突在安装期不可知）：运行时以 `code` 为准并打一条 `plugin-env-override` 诊断 |
| 两个插件写同一 `-D` 属性 | 后加载者覆盖（按 `PLUGIN-SYSTEM.md` 5.2 排序），诊断页显示最终值与来源插件 |
| 两个插件改同一版本元数据 | 同上，L0 层按排序键后者胜；详情页显示「由 N 个插件修改」 |

---

## 五、哈希与完整性

### 5.1 三个摘要

| 名字 | 计算方式 | 用途 |
|---|---|---|
| `fileDigest` | 单文件字节的 `SHA-256`，hex 小写 | `manifest.files[].sha256` |
| `filesDigest` | 对 `manifest.files` 按 `path` 字典序排列后的规范化清单（`path\0sha256\0size\n` 逐条拼接）再 `SHA-256` | 签名覆盖、完整性检查 |
| `packageHash` | `SHA-256("AIR2-PKG-V1\n" + manifestDigest + "\n" + filesDigest)`，其中 `manifestDigest` = `manifest.json` 规范化（RFC 8785 JCS）后的 `SHA-256` | T0 授权绑定、注册表记录、重装幂等判定 |

`packageHash` 与 zip 的字节无关：同一份内容用不同压缩工具重打包，`packageHash` 不变。
这是刻意的（见 5.3）。

### 5.2 何时校验什么

| 时机 | 范围 | 失败处理 |
|---|---|---|
| **安装（全量）** | `manifest.files` 里**每一个**文件的 `fileDigest`；并检查「包内除 `manifest.json` / `AIR2SIG.json` 外的文件集合 == 清单集合」（双向相等，多一个即夹带） | 拒装，删除 staging |
| **每次加载（关键子集）** | `manifest.json`、`entry`（`entry.js`）、`ui/**`、`native/**` 四类 —— 即**所有会被解释执行或被当作声明读取的文件** | 不加载该插件，registry 置 `tampered=true`，管理页红色条目 + 「重新安装」按钮 |
| 显式「完整性检查」（管理页） | 全量 | 同上 |
| 宿主大版本升级后首次启动 | 全量 | 同上（逐个插件标记，不影响启动） |
| 运行中 | 不校验 | —— |

**为什么加载不做全量**：`manifest.files` 可能覆盖 200+ MB 资源，在启动关键路径上做全量哈希
会把冷启动拖长数百毫秒；而资源文件（图片、语言包）不被解释执行，篡改后的后果是「显示异常」，
不是「代码执行」。真正需要每次验的是被当作代码或声明解释的那四类。

### 5.3 签名范围

**签的是「manifest + 文件哈希清单」，不是整个 zip。**

签名消息：

```
signedMessage = "AIR2PLUGIN-SIG-V1\n" + manifestDigest + "\n" + filesDigest
signature     = base64(Ed25519_sign(私钥, signedMessage))
```

`AIR2SIG.json`（包根，可选存在）：

```json
{
  "version": 1,
  "algorithm": "ed25519",
  "keyId": "air2-official-2026",
  "signerFingerprint": "sha256:3f9a…e17c",
  "manifestDigest": "sha256:…",
  "filesDigest": "sha256:…",
  "signature": "base64…"
}
```

为什么不签整个 zip：

| 不签 zip 的理由 | 说明 |
|---|---|
| zip 不是规范化格式 | 条目顺序、时间戳、压缩级别、extra field、注释都会变。同一个内容用 macOS `zip` 与 Windows 资源管理器打包出来的字节不同，签名就全废 —— 作者会被迫固定一个「打包脚本版本」，而不是固定内容。 |
| 交换与审查 | 安全研究者需要能解开包看内容，同时仍能验证「内容与签名一致」。签语义内容而不是字节，让「重新打包」不等于「破坏签名」。 |
| 与实际校验点对齐 | 运行期校验的是文件哈希，签名覆盖的正是这张表 —— 签名与校验用同一份数据，不会出现「签名通过但文件被换」的缝隙。 |
| 夹带可控 | 清单外文件一律拒装（5.2），所以「不签 zip」不会打开夹带口子：夹带的东西没有哈希、不在清单里、装不进去。 |

`AIR2SIG.json` 自身不被签名（它是签名容器）。它被**严格校验结构**：字段缺失/多余、
`manifestDigest` 与实算不符、`algorithm` 未知、`keyId` 未收录 → 视为「签名无法验证」
（→ T0，不报「损坏」）。

### 5.4 公钥与吊销

- 宿主内置 **keyring**：`keyId → Ed25519 公钥(32B) + 用途标记(official/whitelist) + 有效期`。
  公钥随 App 二进制走，**不从网络取**（避免首用时信任 TOFU 被劫持）。
- 白名单 = T1 可用的指纹集合。P2 静态内置；P5 允许随官方仓库更新，但只能追加/吊销。
- 吊销：`keyId` 或指纹进吊销列表 → 已装插件下次加载时降为 T0（不卸载，但不给它 critical 权限，
  并在管理页提示「签名者已被吊销」）。
- 轮换：新增 `keyId` 并行生效，旧 key 保留 ≥ 1 年用于验旧包。

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

- `enabledFingerprint` = 对「启用集」排序后逐条 `id@version@packageHash:permHash` 拼接再 `SHA-256`，
  用于诊断与崩溃报告（「是哪一组插件」）。
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
| **3** | **进入安全模式**：本次启动禁用全部 **L2**（覆盖层：`hide` / `override` / 整页替换）插件；仍失败（计数继续 +1）则下一次再禁用全部 **L1**（slot / 主题），只保留 L0（纯数据）与纯 JSON 声明。 |
| 成功到 `stable` | `suspectCount = 0`，退出安全模式，恢复被**自动**禁用的插件（用户手动禁用的不动）。 |

安全模式期间 UI 必须有：常驻横幅（「插件安全模式：已临时禁用 N 个插件」）+
「插件诊断」页（逐插件显示：层级、最近一次 stage、是否被自动禁用、原因）+
「逐个恢复」入口（恢复一个 → 重启 → 若再失败则回到安全模式并保留该插件为禁用）。

### 6.4 与宿主自身崩溃的区分

- `A2CrashGuard` 已有的崩溃记录（`docs/ARCHITECTURE.md`）与 stage marker **互不替代**：
  CrashGuard 记的是「崩了」，stage marker 记的是「崩在插件生命周期的哪一段」。
- 插件只能影响 `boot → ui` 这一段（Phase B 的 `onLoad`/`onBoot`）。所以判定一律以
  「stage 是否早于首帧」为准，不看崩溃信号的类型 —— 类型会误导（同一插件可能以不同信号崩）。

---

## 七、存储与隔离

| 项 | 规则 |
|---|---|
| 插件私有存储 | `air2.storage`，物理位置 `Plugins/<pluginId>/data/`，宿主维护索引；单键 ≤ 64 KB，总量 ≤ 1 MB |
| 跨插件读取 | 不存在任何 API；文件系统层面也不给路径 |
| 日志 | 全部经宿主格式化，带 `[PLUGIN:<id>]` 前缀；**任何看起来像 token 的串（长度 ≥ 32 的 base64/hex）一律替换为 `<redacted>`** |
| 崩溃日志 | 记插件 id 与当前 stage，不记插件变量内容 |
| 删除插件 | 同时删 `data/`（除非用户在卸载提示里选「保留数据」） |

---

## 八、安全相关的验收清单（P1/P2 实现时必须逐条可测）

1. 未签名包申请 `launch.args` → 安装器**不列出**该权限，装完后 `air2.launch.addArg` 不存在。
2. 有效签名但指纹不在白名单 → 仍判 T0，critical 不可授予。
3. 同 `(pluginId, packageHash)` 二次安装 → 幂等成功，不再弹授权。
4. 同 `pluginId` 装**新版本**（`packageHash` 因此变化）→ 重新走一次性授权；
   同 `version` 但内容不同 → **拒装**（见 `PLUGIN-SYSTEM.md` 4.5：同版本内容不同，可能是被替换的包）。
5. 包内多一个未在 `manifest.files` 里的文件 → 拒装。
6. `manifest.files` 少一个实际存在的文件 → 拒装。
7. 解压后手工改 `entry.js` → 下次加载拒绝，`tampered=true`。
8. 组合 `launch.args` + `java.agent` → 拒装，文案含两个 id。
9. `-Dminecraft.api.auth.host=...` 出现在插件参数里 → 该条被丢弃并记 `plugin-forbidden-arg`。
10. `--accessToken` 出现在插件参数里 → 丢弃；最终命令行里仍只有宿主追加的那一份。
11. 连崩两次（stage 停在 `boot`）→ 最近启用的插件被禁用。
12. 连崩三次 → 进安全模式，L2 全禁，横幅可见。
13. 首帧后 5 秒内用户强杀 → 不算失败，`suspectCount` 不变。
14. 签名包的 `AIR2SIG.json` 结构损坏 → 降为 T0 而不是报「包损坏」。

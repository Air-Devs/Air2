# Air2 插件系统（P0 设计）

> **状态**：P0 —— 只有文档，没有一行实现代码。本文定义**契约**，实现按第七节的里程碑推进。
> **适用范围**：iOS 宿主（当前唯一可用平台）。多端契约见 `PLUGIN-COMPAT.md`，跨端只承诺契约，不承诺时间。
> **配套文档**：`PLUGIN-API.md`（API 面）、`PLUGIN-SECURITY.md`（权限 / 授权 / 哈希 / 崩溃）、
> `PLUGIN-PAGE.md`（v3 原生页面模型）、`PLUGIN-COMPAT.md`（多端与本地化）、
> `PLUGIN-AUTHORING.md`（作者指南）、`plugin.schema.json`（manifest 机器可读契约）。
> **决策记录**：ADR-014～ADR-023（见 `docs/DECISIONS.md`）。
>
> **v2 变更（2026-10-31）**：取消官方签名与信任等级，改为安装时逐项授权；
> critical 权限三次 5 秒确认；新增 v3 页面模型与 1～10 号插件所需扩展点。
> 改动摘要见 `P0-V2-CHANGELOG.md`。
>
> **v3 变更（2026-10-31）**：critical 授权从「绑定包哈希」改为「绑定权限集 + 哈希白名单」
> （registry 新增 `approvedHashes`，最多 5 个）；registry 新增取证用的 `source` 来源字段；
> P1 增加最小崩溃闭环（连续 3 次未跨过首帧即自动停用）；安装页权限按 5 个后果组折叠展示。
> 决策见 ADR-024，改动摘要见 `P0-V3-CHANGELOG.md`。

---

## 一、目标与非目标

### 1.1 目标

1. **外观可改，进程不可控**：第三方能换图标、卡片徽标、主题 token、版本显示名，
   但拿不到进程级能力（不注入代码、不读账号、不碰网络栈内部）。
2. **启动参数可改，但每一条可审计**：高级用户能调 `-D` / `-Xmx` / JVM 参数 / 游戏参数，
   前提是每条参数在安装时被逐项展示、被权限点覆盖、被宿主复核。
3. **任何插件都不能把启动器带崩**：插件出错 → 该插件被禁用 → 启动器正常起来。
   靠崩溃安全模式（`PLUGIN-SECURITY.md` 第六节），不靠插件自律。
4. **闭环都在宿主侧**：安装、加载、权限、完整性四件事全在宿主实现，
   插件作者无法「选择不校验」。
5. **失败可见**：每次拒装 / 拒载 / 禁用都能在管理页看到一句人话原因，
   不许静默降级。
6. **新手能装、能手写**：导入后一页看清「这是什么、要什么权限、有什么风险」；
   纯 JSON 插件不写代码也能做，复杂插件再引入 JS 与页面模型。

### 1.2 非目标（v1 明确不做）

| 不做 | 原因 |
|---|---|
| 验证作者身份 | 取消签名后没有可信身份源；安装页只展示「作者自述」与来源，不提供「官方 / 已验证」徽标 |
| 替换下载引擎 | 下载链是启动器的可靠性核心（ADR-011 的多源候选链）。插件只允许**追加**下载源候选，不允许替换引擎 |
| 任意路径访问 | 暴露文件系统路径等于把哈希校验与 token 白名单作废（插件可以改自己的文件再自证清白） |
| 远程代码执行 | 禁止 `eval` / `new Function` / `Function.constructor` / `WebAssembly`。这条是**硬禁**，不是权限 |
| 账号 token 读写 | accessToken / refreshToken 属于宿主私有状态，插件 API 面里**根本不存在**对应对象 |
| 游戏内 UI hook | v1 只做启动器 UI。游戏内渲染/输入 hook 与渲染后端强耦合（Metal/EAGL 双后端），放在 v1 之外评估 |
| 用 WebView 兜底复杂页面 | 复杂页面走 v3 原生 JSON 页面模型（`PLUGIN-PAGE.md`）；`ui.web` 只在 P5 作为独立能力存在 |

---

## 二、概念模型

插件系统分四层，每层有明确的失败语义：

| 层 | 载体 | 失败时 |
|---|---|---|
| **包**（Package） | 单个 `.air2plugin` 文件（zip） | 安装器拒装，磁盘无残留 |
| **安装**（Install） | `Plugins/<pluginId>/<version>/` 目录 | 回滚到安装前状态（旧版仍在） |
| **注册**（Registry） | `registry.json` 条目 | 条目被标 `invalid`，管理页可见，不参与加载 |
| **运行时**（Runtime） | 进程内的插件实例（JSCore 上下文） | 该实例被卸载 + 计数，不中断宿主 |

### 2.1 插件三型

| 类型 | `type` | 能做什么 | 实现阶段 |
|---|---|---|---|
| **纯 JSON 插件** | `json` | 声明式 UI（slot 注册、主题 token、静态页面）、版本元数据装饰、下载源候选与版本过滤器（P4） | P2 |
| **JS 插件** | `js` | 上面全部 + 事件回调 + 启动参数 / 文件读写 / 网络 / 页面动作（按权限） | P3a（运行时）/ P3b（页面） |
| **原生插件** | `native` | 自带 iOS dylib，直连宿主 C 接口 | P5（仅 TrollStore / 越狱，门槛见 ADR-020 修订） |

> 注意：`type` 在 manifest 里只有 `json` / `js` 两个合法值（见 `plugin.schema.json`）。
> `native` 是 P5 才引入的**附加字段**（`native` 对象 + `formatVersion` ≥ 3），
> 不是 v2 里的第三个枚举值 —— 这样 v2 的校验器看到原生插件会**拒装**而不是**误装**，
> 属于有意的失败方向。

### 2.2 三个层级（L0 / L1 / L2）

| 层 | 内容 | 失败后果 | 安全模式 |
|---|---|---|---|
| **L0 数据层** | 版本元数据装饰、下载源候选、版本过滤器 | 数据缺失，UI 照常 | 不禁止 |
| **L1 装饰层** | slot 注册、图标、主题 token、`home.section`、页面入口 | 该贡献被丢弃，其余照常 | 第二次进安全模式时禁止 |
| **L2 覆盖层** | `hide` / `override` / 整页替换 / `launch.overlay` | 可能让界面「变空」 | 进安全模式优先禁止 |

层由插件**申请的能力**推导，不由作者填写：
申请了 `ui.override` 的插件一定是 L2；申请了 `ui.contribute` 的是 L1；
只申请 `version.decorate` / `download.source` / `version.filter` 的是 L0。
（作者填什么不影响判定，避免「声明自己是 L0 实际做 L2 的事」。）

---

## 三、包格式 `.air2plugin`

### 3.1 容器

- 后缀：`.air2plugin`（内容就是 zip，允许改名成 `.zip` 后手工查看）。
- 压缩：deflate 或 stored，UTF-8 文件名标志位必须置位（bit 11），禁止非 UTF-8 文件名。
- **`manifest.json` 必须在包根**（不是子目录里）。找不到即拒装，理由文案固定为
  「包根缺少 manifest.json」。
- 不允许多个 manifest（例如 `sub/manifest.json` 同时存在视为夹带，按 3.3 拒绝）。
- **不允许 zip64 / 加密 / 多卷**。遇到即拒装，文案「请用普通 zip 重新打包」。
  这不是永久限制：P1 的 `A2ZipReader` 扩展后可以再评估，但 v2 契约先写死。

### 3.2 目录结构

```
hello.air2plugin
├── manifest.json            # 必须，UTF-8 无 BOM
├── entry.js                 # type=js 时必须（路径由 manifest.entry 指定）
├── pages/
│   └── downloads.json       # v3 可选：静态页面树（必须在 manifest.files 里）
├── ui/
│   └── theme.json           # 可选，被 manifest.files 列出才会被加载
├── assets/
│   ├── common/              # 平台无关资源
│   └── ios/                 # iOS 专属资源，覆盖 common 同名文件
├── locales/
│   ├── zh-Hans.json
│   └── en.json
├── schematics/              # 可选：.schem / .litematic 等蓝图文件
└── native/                  # P5 才允许出现（formatVersion ≥ 3）
    └── ios/air2_hello.dylib
```

规则：

1. `assets/common/**` 与 `assets/<platform>/**` 按 `PLUGIN-COMPAT.md` 第三节叠加。
2. `locales/` 下的文件名即 BCP-47 语言标记，回退顺序见 `PLUGIN-COMPAT.md`。
3. `native/` 出现在 `formatVersion 2` 的包里 → 拒装（「本宿主不支持原生插件」）。
4. `ui/`、`pages/`、`assets/`、`locales/`、`schematics/` 下的每个文件**必须在 `manifest.files` 里**，
   且 `manifest.files` 里的每个路径**必须真实存在** —— 双向严格相等，多一个少一个都拒装。
5. 包根**不允许** `AIR2SIG.json`。出现即拒装（`E_LEGACY_SIGNATURE`），文案
   「此包使用了已移除的签名格式，请重新导出」。

### 3.3 硬性上限（防 zip 炸弹与解压穿越）

| 项 | 上限 | 超限处理 |
|---|---|---|
| 包文件大小 | 64 MB | 拒装 |
| 解压后总大小 | 256 MB | 拒装 |
| 文件数 | 4096 | 拒装 |
| 单文件解压后大小 | 32 MB | 拒装 |
| 路径长度 | 255 字节 | 拒装 |
| 路径深度 | 8 层 | 拒装 |
| 压缩比 | 单文件 100:1 | 拒装（正常资源不会超） |

路径校验：拒绝 `..`、绝对路径（`/` 开头、`C:` 形式）、反斜杠、`.` 结尾、
保留名（`CON`、`NUL`、`aux` 等）、符号链接与硬链接条目、
以及任何含控制字符的路径。校验在**解压前**对中央目录做一遍，解压后再对实际落盘路径复核一遍
（防「中央目录老实、本地头使坏」的经典手法）。

> **P1 实现提醒**：现有 `A2ZipReader` 只有 `entryNames` / `dataForEntry`，会把整个条目读进内存，
> 也没有中央目录预检。P1 必须先扩：枚举条目元数据（`uncompressedSize` / `compressedSize` /
> `isDirectory` / `generalPurposeBitFlag`）、流式解压、解压前上限检查。
> 详见 `P0-V2-CHANGELOG.md` 的仓库补丁清单。

### 3.4 `formatVersion` 语义

- 当前受支持的值：**2**（P1/P2/P3a）与 **3**（P3b 起）。
- 语义：**包格式版本**（zip 布局 + manifest 结构 + 新增字段），**不是** API 版本，
  也**不是**插件自身版本。
- 读取到 `> 宿主支持的最大值` 一律拒装，理由文案「需要更新版本的 Air2」；
  读取到 `< 2` 同样拒装并提示重新导出。
- 版本差异：

| 版本 | 新增 | 宿主 |
|---|---|---|
| **v2** | 当前基线：`ui.slots`（叶子组件）、`ui.theme`、`contributes` | P1/P2 起 |
| **v3** | `ui.pages`（原生页面模型）、`ui.overrides`（hide / override）、`native/` 目录结构 | P3b 起；`native/` 还要 P5 + 设备能力 |

- 升级策略：新增**可选**字段不升 `formatVersion`；新增**必填**字段、改变语义、或新增
  `type` 枚举值才升版本。宿主接受 `formatVersion ∈ [2, 自身支持的最大值]`。
- `plugin.schema.json` 同时定义 v2 与 v3；v2 宿主读到 v3 包必须拒装，
  不能「忽略 pages 继续装」—— 否则用户会看到一个缺页的插件。

---

## 四、安装流程（原子）

### 4.1 目录布局

根目录固定在：

```
<App 容器>/Library/Application Support/Air2/
└── Plugins/
    ├── registry.json                  # 注册表（原子替换写）
    ├── .bootstate.json                # 崩溃 stage marker（P1 起）
    ├── .staging/<uuid>/               # 解压暂存，安装成功后整体 rename 走
    └── <pluginId>/
        ├── <version>/                 # 已安装的版本目录（可并存两版）
        └── <version-1>/               # 上一版，保留至下次成功启动后清理
```

**为什么放 `Library/Application Support` 而不是 `Documents`**：

- `Documents` 在 `UIFileSharingEnabled` 打开时对用户/第三方文件 App 可见可写 ——
  用户手改插件目录后，哈希校验就只剩「要么拒载要么信任篡改」，两头都不对。
- `Application Support` 不暴露给文件 App，也不在「文稿」的备份/同步语义里，
  它的写入者只有宿主一个。
- 目录设 `NSURLIsExcludedFromBackupKey`：插件可由包重新安装，不必进 iCloud 备份
  （省配额，也避免「恢复备份 = 恢复一份被篡改的插件」）。
- 插件目录与 registry 使用 `NSFileProtectionCompleteUntilFirstUserAuthentication`。

### 4.2 七个步骤

```
① 导入      文件选择器 / 分享 → 复制 zip 到 .staging/<uuid>/package.air2plugin
② 结构校验  中央目录预检（路径 / 条目数 / 大小 / 压缩比 / zip64 / 加密）→ 解压到 .staging/<uuid>/root/
③ manifest  读根 manifest.json → JSON Schema 校验（plugin.schema.json）→ 语义校验
            → 宿主能力门（formatVersion / type / platforms / 里程碑）
④ 完整性    按 manifest.files 逐文件算 SHA-256 并与清单比对（全量）
⑤ 授权      安装详情页 + 逐项授权（低/中默认开，critical 三次 5 秒） + 组合风险判定
⑥ 换目录    .staging/<uuid>/root/ → Plugins/<pluginId>/<version>/ （同卷 rename，原子）
⑦ 提交      registry.json 原子替换（write-temp + fsync + rename + fsync 目录）
```

失败处理：

- ①②③④⑤ 任一步失败 → 删除整个 `.staging/<uuid>/`，**registry 完全不动**，
  管理页弹出一条带 `code` 的失败原因。
- ③ 的宿主能力门：P1/P2 读到 `type: js` → `E_TYPE_UNSUPPORTED`；P3b 之前读到
  `formatVersion: 3` → `E_FORMAT_VERSION`；`platforms` 不含当前平台 → `E_PLATFORM`。
- ⑤ 中用户取消某个 critical 权限**不算失败**：安装继续，只是该权限不授予。
- ⑥ 成功、⑦ 失败 → 目录已就位但没有注册表条目 ⇒ 下次启动的「孤儿目录清理」会删掉它。
  注册表是**唯一事实来源**，目录不是。
- ⑥ 失败（rename 跨卷 / 目标已存在 / 磁盘满）→ staging 保留供重试，registry 不动。

### 4.3 原子性论证

- 目录切换靠同卷 `rename(2)`：要么旧路径还在，要么新路径已在，**没有「半个插件目录」的中间态**。
- 注册表靠 `write-temp → fsync(文件) → rename(临时, registry.json) → fsync(目录)`：
  崩溃后读到的永远是某一个完整版本，不会读到半截 JSON。
- 因此「安装」对宿主其余部分是**瞬时**的：任何时刻中断，系统都处于「旧状态」或「新状态」。

### 4.4 崩溃残留

启动 Phase A 的第一件事：

1. 写 `.bootstate.json` 的 `stage:"boot"`（P1 起；先于任何插件加载）。
2. 删除 `.staging/` 下所有条目（staging 里的东西没有一次是被需要的）。
3. 对 `Plugins/<pluginId>/` 下**不在 registry 里**的版本目录，若其 `installedAt` 早于本进程启动
   且超过 24 小时 → 删除（孤儿目录）。
4. `registry.json` 解析失败 → 整体改名为 `registry.json.corrupt-<时间戳>`，
   用空注册表重建，并把「插件注册表损坏，已重建」写进诊断页。**不猜、不修**。

> 旧渲染器（`Documents/Air2/Renderers/`）**不在此流程内**：P1 不读、不写、不迁移、不删除。
> 双轨期间它由旧 importer 管理，管理页的「插件」与「渲染器」是两个独立入口。
> 详见 `P0-V2-CHANGELOG.md` 的「双轨保留」条目。

### 4.5 覆盖安装 / 升级 / 降级

| 场景 | 行为 |
|---|---|
| 同 `id` 同 `version`，`packageHash` 相同 | 视为重装：直接成功（幂等），不重新弹授权 |
| 同 `id` 同 `version`，`packageHash` 不同 | **拒装**（`E_SAME_VERSION_DIFFERENT_CONTENT`，「同版本内容不同，可能是被替换的包」） |
| 同 `id` 高版本 | 升级：旧目录改名 `<oldVersion>` 保留，装新版本，成功后 registry 记 `previousVersion`；低/中权限沿用；critical **按权限集沿用**：权限集不变且非 `major` → 不重确认（更新页提示「内容已更新，权限未变」），新增 / 变更 critical 或 `major` 变化 → 重走三次确认，权限集缩小 → 自动撤销多余项、不弹窗（`PLUGIN-SECURITY.md` 3.4） |
| 同 `id` 低版本 | **默认拒装**（`E_DOWNGRADE`），文案「默认不允许降级安装」。开发者模式可放行；放行后 UI 标「降级」并要求额外确认 |
| 不同 `id` | 独立安装 |

旧版本保留策略：每个插件最多保留 **1** 个旧版本目录；清理发生在**下一次成功启动**
（首帧后稳定 5s，即 stage 走到 `stable`）之后 —— 这样「新版本一启动就崩」时，
用户还能回退到磁盘上仍在的旧版本。

回退：管理页的「回退到上一版」= 把 registry 的 `activeVersion` 指回 `previousVersion`，
目录已存在，所以是瞬时的，不需要重新安装。回退**不受降级拒装规则限制**（这是本地已有版本，
不是新装一个低版本包）。回退后 critical 授权按 `(pluginId, permissionId)` 继续有效（**不因回退重确认**），
旧包哈希追加进 `approvedHashes`；只有目标版本的权限集与已授权集不同才按
`PLUGIN-SECURITY.md` 3.4 判定 —— 旧版本多要的 critical 项**不授予、不弹窗**，管理页标「未授权」，
用户可去「重新审查权限」逐项授权；`major` 不同则整组重确认。

### 4.6 卸载

1. registry 标记 `uninstalling`（先让加载器跳过它）→ 原子提交。
2. 删目录 → 删条目 → 原子提交。
3. 第 2 步失败不阻塞用户体验：下次启动按孤儿目录清理。
4. 插件数据 `data/` 默认一起删；卸载页提供「保留数据」开关。

---

## 五、加载顺序

### 5.1 两阶段

| 阶段 | 时机 | 允许做 | 不允许做 |
|---|---|---|---|
| **Phase A（bootstrap）** | 启动早期，UI 创建之前 | 写 boot marker、读 registry、算启用集、做依赖拓扑排序、构建 slot 表、跑崩溃计数 | 执行任何插件代码 |
| **Phase B（runtime）** | 首帧之后 | 建 JSCore 上下文、注入能力、跑 `onLoad`、跑 `onBoot`、执行 UI 贡献、挂页面 | 阻塞主线程超过 16 ms |

把「读声明」和「跑代码」切开，是为了让 **UI 在没有任何插件代码参与的情况下先画出来** ——
插件整体挂掉时用户仍能看到一个完整可用的启动器。

### 5.2 排序键

Phase A 生成加载序列，排序键为三元组：

```
(priority ↑, layer ↑, pluginId ↑)     # 全部升序；priority 来自 manifest.ui.priority，缺省 0，范围 [-1000, 1000]
```

- `priority` 相同 → 按层：L0 < L1 < L2；
- 层也相同 → 按 `pluginId` 字典序（保证**确定性**：同一份注册表每次启动顺序一致，
  否则「今天能起、明天不能起」的问题无法复现）。

### 5.3 线程与执行队列

- **每个插件一条独立串行队列**。同一插件的回调不会并发；不同插件可以并行。
- 插件队列**不是主线程**。`render` / `onAction` / `onLoad` 都在插件队列上执行，
  宿主把 UI 提交回主线程。
- 主线程只做三件事：绘制、把用户事件投递给插件队列、把插件返回的 UI 树提交给渲染器。
- 预算（见 `PLUGIN-API.md` 6.2）：

| 回调 | 软预算 | 硬超时 | 超时处理 |
|---|---|---|---|
| `onLoad` / `onBoot` | 200 ms | 2 s | 记 `plugin-timeout`，本次回调作废，不卸载 |
| `render` | 16 ms | 200 ms | 返回错误页，记诊断 |
| `onAction` | 2 s | 10 s | 本次动作作废，记诊断 |
| `instance.beforeOpen/beforeEdit`、`ui.promptSecret` 等交互钩子 | 用户决定 | 60 s | 视为「允许 / 取消」，记诊断 |
| `onVersionList` / `onLaunch` | 50 ms | 500 ms | 本次贡献作废 |

> 「软预算」是诊断阈值，不是杀进程阈值。超过软预算记一条，连续 30 次 → 禁用该插件。
> 硬超时是宿主主动中断的边界。

### 5.4 依赖与冲突

- `depends`：安装期解析，要求被依赖插件已安装且版本满足约束；运行时按拓扑序加载。
- **循环依赖 → 安装期拒装**（不做运行时检测，运行时的循环依赖等于启动挂死）。
- 缺失依赖 → 安装期拒装（不允许装一个注定不工作的插件）。
- 被依赖方被禁用/卸载 → 依赖方随之禁用，管理页给出链式原因。
- **同 slot 冲突**：
  - L1 注册：多个插件注册同一 slot → **共存**，按 5.2 排序键排列；
  - L2 占位：多个插件要求同一 slot 的独占占位 → 安装期拒装（「与已安装插件 X 冲突」），
    同 `priority` 允许两个 L2 抢占同一 slot 在语义上无解，所以不允许。

### 5.5 与启动链的衔接

- 插件只影响「启动参数」与「UI 声明」，**不参与** JIT 供给、VM 创建、GL 初始化 ——
  这些属于启动链的关键路径（见 `docs/ARCHITECTURE.md`、ADR-009/012/013），
  插件对它们的唯一影响是「最终追加到 JVM / 游戏参数列表尾部的那几条」，
  且受 `PLUGIN-SECURITY.md` 与 `PLUGIN-API.md` 第五节约束（受保护参数插件不可写）。
- **`launch.overlay` 指启动器自己的启动遮罩**：用户在点「启动」后、游戏画面出现前看到的
  加载页 / 进度条 / 状态文案。它不是 Minecraft 游戏内的加载界面，也不是游戏渲染的一帧。
  插件只能在这个遮罩上叠加只读信息（阶段、进度、提示），不能阻塞启动、不能替换启动链、
  不能覆盖「取消启动」按钮。
- 首帧之后 5s 的 `stable` 标记是**插件系统专有**的健康信号，与启动遮罩超时无关。

---

## 六、注册表

位置：`Plugins/registry.json`（唯一的插件事实来源）。

```json
{
  "formatVersion": 3,
  "seq": 128,
  "userSeq": 41,
  "plugins": [
    {
      "id": "com.example.hello",
      "activeVersion": "1.0.0",
      "previousVersion": "0.9.0",
      "packageHash": "sha256:…",
      "approvedHashes": [
        "sha256:9f2c0d…",
        "sha256:1a77be…",
        "sha256:c40e13…"
      ],
      "source": {
        "kind": "local-import",
        "sourceDetail": "hello.air2plugin",
        "installedAt": "2026-10-31T10:00:00Z"
      },
      "enabled": true,
      "permissionsGranted": ["version.decorate", "files.game.write.config"],
      "permissionSet": "files.game.write.config:medium\nlaunch.args:critical\nversion.decorate:low",
      "criticalGrants": [
        {
          "permissionId": "launch.args",
          "grantedAt": "2026-10-31T10:02:00Z",
          "method": "three-step",
          "hostVersion": "0.1.0",
          "majorVersion": 1
        }
      ],
      "grantRevision": 2,
      "installedAt": "2026-10-31T10:00:00Z",
      "lastEnabledChangeAt": "2026-10-31T10:00:00Z",
      "lastReviewAt": "2026-10-31T10:02:00Z",
      "suspectCount": 0,
      "autoDisabled": false,
      "tampered": false,
      "invalid": null
    }
  ]
}
```

字段说明：

| 字段 | 说明 |
|---|---|
| `formatVersion` | 注册表自身的结构版本，当前 3；迁移见 6.2 |
| `seq` | 单调递增计数器，每次写 +1，用于诊断「注册表是否被外部改过」 |
| `userSeq` | **用户配置序号**：用户装/卸/开关插件或改授权时 +1；宿主**自动**禁用插件时**不** +1。崩溃归因比较的就是它（见 `PLUGIN-SECURITY.md` 6.1） |
| `activeVersion` | 当前生效版本目录名 |
| `previousVersion` | 上一版目录名，用于回退；没有则为 `null` |
| `packageHash` | 全量内容摘要（定义见 `PLUGIN-SECURITY.md` 第五节）；用于完整性校验、重装幂等判定与展示，**不是**授权绑定键 |
| `approvedHashes` | **用户同意过的内容版本白名单**：`sha256` 数组，新值前插、最多保留最近 **5** 个。只记录「用户在哪些内容上点过同意」，**不参与授权判定**、不授予任何能力（ADR-024） |
| `source` | 来源事实记录（取证最低线）：`kind` 为 `local-import` / `url` / `share-sheet` / `dev-dir`；`sourceDetail` 为域名或文件名（可空）；`installedAt` 为本次安装时间。管理页按事实文本展示，**不做好坏判断、不挂任何徽标** |
| `permissionSet` | 上一版 manifest 的**规范化权限集**（`id:risk` 按 id 排序、`\n` 连接）。用途：升级时不必保留旧目录即可判定「权限集是否变了」 |
| `installedAt` | 首次安装时间（升级不改）；本次安装时间记在 `source.installedAt` |
| `enabled` | 用户开关 |
| `permissionsGranted` | 用户实际授予的低/中权限（**可能少于** manifest 申请集） |
| `criticalGrants` | critical 权限的逐项授权记录，主键 `(pluginId, permissionId)`；每项记 `grantedAt` / `method` / `hostVersion` / `majorVersion`，**不记也不比对** `packageHash`（包内容变化不使授权失效）；**不放在** `permissionsGranted` 里，避免两种生命周期混在一起 |
| `grantRevision` | 授权变更序号；插件加载时用它判断「能力面是否变过」 |
| `lastReviewAt` | 用户最后一次打开安装详情页 / 重新审查权限的时间 |
| `suspectCount` | 连续可疑失败次数，成功到 `stable` 清零（规则见 `PLUGIN-SECURITY.md` 6.3） |
| `autoDisabled` | 是否由崩溃安全模式自动禁用（用于「恢复被自动禁用的插件」时区分用户手动禁用） |
| `tampered` / `invalid` | 加载期发现篡改 / 结构失效的原因；非 `null` 即不加载 |

### 6.1 写入规则

- 只有宿主写；插件 API 里**没有任何**注册表写入口。
- 每次写都是全量重写 + 原子替换（文件很小，不做增量）。
- 写前校验：
  - `permissionsGranted` 里只能有**低/中**权限，且必须 ⊆ manifest 申请集；
  - `criticalGrants[].permissionId` 必须 ⊆ manifest 申请集；manifest 不再申请的项写前移除并记诊断；
    **不得**按 `packageHash` 剔除任何 critical 授权项（授权绑定权限集，不绑定包字节）；
  - `permissionSet` 必须等于当前 `activeVersion` 的 manifest 规范化权限集（不等 → 拒绝写，记 `invalid`）；
  - `approvedHashes` 最多 5 项，每项为 64 位小写 hex（`sha256:` 前缀可选），超出截断最旧；
    它不参与任何授权判定，缺失或损坏不影响授权有效；
  - `source.kind` ∈ {`local-import`, `url`, `share-sheet`, `dev-dir`}，`source.installedAt` 不得为空；
  - `activeVersion` 目录存在；
  - `packageHash` 与磁盘一致（不一致 → 拒绝写，记 `tampered`）。
- 任何一次「授予 / 撤销 / 审查」都让 `grantRevision + 1`、`userSeq + 1`。

### 6.2 迁移

`registry.json` 的 `formatVersion` 与包格式的 `formatVersion` 是**两个独立数字**（同名不共义）。
注册表迁移：读到低版本 → 按迁移表逐级升 → 写回前先备份 `registry.json.bak`。
无法迁移 → 按 4.4 第 4 条处理（重建空表，插件全部转 `invalid`，管理页提示重新安装）。

v2 → v3 的迁移要点：

- 丢弃 `trustLevel` / `signerFingerprint` / `grantBinding`（这些字段在 v2 注册表里可能存在）；
- 把 `permissionsGranted` 里的 critical 项拆到 `criticalGrants`，`majorVersion` 用当前 manifest 的主版本号
  （不写 `packageHash`：v3 的授权不绑定包哈希）；
  无法判断原授权来源的，标 `method:"migrated"`，并在管理页提示「请重新审查」；
- 新增 `source` / `grantRevision` / `lastReviewAt`，缺省值分别为
  `{kind:"local-import",sourceDetail:"旧版安装",installedAt:<原 installedAt>}` / `0` / `installedAt`；
  旧 `kind` 映射：`file → local-import`、`url → url`、`dev → dev-dir`，旧 `displayName` 并入 `sourceDetail`；
- 新增 `approvedHashes`：有任一迁移来的 critical 授权时为 `[当前 packageHash]`，否则为 `[]`；
- 新增 `permissionSet`：按当前 `activeVersion` 的 manifest 重算写入；
- critical 授权**不再**校验 `packageHash`：迁移时即使哈希对不上也保留授权（v2 的「哈希变即失效」
  在 v3 取消），只在管理页标「迁移自旧版本，建议重新审查」。

---

## 七、里程碑

| 里程碑 | 内容 | 验收口径 |
|---|---|---|
| **P0** | 文档：本文 + API + 安全 + 页面 + 兼容 + 作者指南 + `plugin.schema.json` + ADR-014～023 | 文档之间无矛盾；schema 能校验两个最小示例 |
| **P1** | 安装器 / 注册表 / 权限存储 / 最小管理页 / **三步授权** / **boot marker** / **来源记录 + `approvedHashes` + `permissionSet`** / **最小崩溃闭环** | 能装、能启停、能卸载、能看原因；critical 三步 5 秒可测；权限集不变的更新**不**重确认；连续 3 次死在首帧前 → 自动停用最近启用的插件并提示；不动 UI 渲染、不动旧渲染器 |
| **P2** | 注册表化 UI + slot + `ui.contribute` + 导入预览 + **完整安全模式** | JSON 插件能往 slot 塞组件；低/中默认授权可关；第 3 次失败进安全模式禁 L2，再失败禁 L1；逐插件诊断页 + 逐个恢复 |
| **P3a** | **JSCore 运行时 + API 面**（launch / files / storage / instance / crypto） | JS 插件能跑 `onLoad`/`onBoot`；未授权 API 在对象上不存在；插件串行队列与预算可测 |
| **P3b** | **v3 页面模型** + `ui.override` + `launch.overlay` | 静态 / 动态页面能渲染、能交互动；页面横幅强制；无 HTML / 远端图片 / 密码框 |
| **P4** | 下载源候选 + 版本过滤器 + 文件读/导出 + 整合包导出（mrpack / zip）+ 开发模式 | 过滤器能按规则隐藏版本；`files.game.read` 只读且无账号面；导出走系统分享面板；开发模式不污染正式注册表 |
| **P5** | 原生模块 / `ui.web` / Java agent 自挂载 / 多端宿主 | 原生模块只在 TrollStore / 越狱设备列出；三次确认 + 第四页警告；`ui.web` 走独立进程或强隔离 WebView |

> **为什么把 JSCore 与页面模型拆成 3a / 3b**：运行时（上下文、能力注入、队列、预算）与
> 页面模型（组件树、binding、action、渲染器）是两块独立工作量，混在一个里程碑里会导致
> 「运行时能跑但页面画不出」或反过来。3a 可以先让纯回调插件（启动参数、文件、实例钩子）落地，
> 3b 再做复杂页面。

---

## 八、明确不做（写进 ADR，不是「以后再说」）

1. **验证作者身份** —— 没有可信身份源；不提供「官方 / 已验证」徽标。
2. **替换下载引擎** —— 插件只能追加候选源，引擎选择逻辑保留在 Core。
3. **任意路径访问** —— `air2.paths` 只发不透明 token，见 `PLUGIN-COMPAT.md`。
4. **远程代码执行** —— `eval` / `new Function` / `Function.constructor` / `WebAssembly` 在 JSCore 上下文里
   **不注入**（不是「调用时抛错」，见 `PLUGIN-API.md` 6.4）。
5. **账号 token 读写** —— API 面里没有 `air2.account`。
6. **游戏内 UI hook** —— v1 不做，也不预留半成品入口。
7. **用 WebView 兜底插件页面** —— 复杂页面走 v3 原生页面模型。

---

## 九、术语

| 术语 | 含义 |
|---|---|
| 包 / package | 一个 `.air2plugin` 文件 |
| packageHash | 全量内容摘要（清单规范化后的 SHA-256）；用于完整性与展示，**不是**授权绑定键 |
| 权限集 | manifest `permissions` 规范化后的集合（`id:risk` 排序拼接）；critical 授权的绑定对象 |
| approvedHashes | 用户同意过的内容版本白名单（最多 5 个哈希），只取证、不授权 |
| 来源 / source | 安装来源的事实记录（本地导入 / 网址 / 分享面板 / 开发目录），不做信任判断 |
| major | 插件自身语义化版本的主版本号；跨 major 升级视为「可能换了一套东西」，critical 全部重确认 |
| slot | 宿主 UI 里预留的、可被插件放组件的语义位置 |
| 组件 / component | 语义组件名（如 `button.primary`），不是平台控件类名 |
| 能力注入 | 未授权的 API 在插件对象上**不存在**，加载期一次性决定 |
| 逐项授权 | 安装时按权限 id 逐条开关；低/中默认开，critical 默认关 |
| 三步确认 | critical 权限的三次提示框，每次 5 秒后才可继续 |
| stage marker | 启动阶段标记，用于崩溃归因 |
| 安全模式 | 连续可疑失败后按 L2 → L1 顺序禁用插件的降级启动 |
| 页面模型 | v3 的 JSON 组件树 + 插件 `render` / `onAction`，见 `PLUGIN-PAGE.md` |
| 开发模式 | P4 起：从本地目录直载插件，不写正式注册表，允许降级；授权流程不变 |

# Air2 插件系统（P0 设计）

> **状态**：P0 —— 只有本文档，没有一行实现代码。本文定义**契约**，实现按第七节的里程碑推进。
> **适用范围**：iOS 宿主（当前唯一可用平台）。多端契约见 `PLUGIN-COMPAT.md`，跨端只承诺契约，不承诺时间。
> **配套文档**：`PLUGIN-API.md`（API 面）、`PLUGIN-SECURITY.md`（权限 / 信任 / 哈希 / 签名）、
> `PLUGIN-COMPAT.md`（多端与本地化）、`PLUGIN-AUTHORING.md`（作者指南）、`plugin.schema.json`（manifest 机器可读契约）。
> **决策记录**：ADR-014～ADR-020（见 `docs/DECISIONS.md`）。

---

## 一、目标与非目标

### 1.1 目标

1. **外观可改，进程不可控**：第三方能换图标、卡片徽标、主题 token、版本显示名，
   但拿不到进程级能力（不注入代码、不读账号、不碰网络栈内部）。
2. **启动参数可改，但每一条可审计**：高级用户能调 `-D` / `-Xmx` / JVM 参数，
   前提是每条参数在安装时被逐项展示、被权限点覆盖、被宿主复核。
3. **任何插件都不能把启动器带崩**：插件出错 → 该插件被禁用 → 启动器正常起来。
   靠崩溃安全模式（第七节），不靠插件自律。
4. **闭环都在宿主侧**：安装、加载、权限、签名校验四件事全在宿主实现，
   插件作者无法「选择不校验」。
5. **失败可见**：每次拒装 / 拒载 / 禁用都能在管理页看到一句人话原因，
   不许静默降级。

### 1.2 非目标（v1 明确不做）

| 不做 | 原因 |
|---|---|
| 替换下载引擎 | 下载链是启动器的可靠性核心（ADR-011 的多源候选链）。插件只允许**追加**下载源候选，不允许替换引擎。 |
| 任意路径访问 | 暴露文件系统路径等于把签名与哈希校验作废（插件可以改自己的文件再自证清白）。 |
| 远程代码执行 | 禁止 `eval` / `new Function` / `Function.constructor` / `WebAssembly`。这条是**硬禁**，不是权限。 |
| 账号 token 读写 | accessToken / refreshToken 属于宿主私有状态，插件 API 面里**根本不存在**对应对象。 |
| 游戏内 UI hook | v1 只做启动器 UI。游戏内渲染/输入 hook 与渲染后端强耦合（Metal/EAGL 双后端），放在 v1 之外评估。 |

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
| **纯 JSON 插件** | `json` | 声明式 UI（slot 注册、主题 token）、版本元数据装饰、下载源候选与版本过滤器（P4） | P2 |
| **JS 插件** | `js` | 上面全部 + 事件回调 + 启动参数 / 文件写入 / 网络（按权限） | P3（JSCore 运行时） |
| **原生插件** | `native` | 自带 iOS dylib，直连宿主 C 接口 | P5（门槛见 ADR-020） |

> 注意：`type` 在 manifest 里只有 `json` / `js` 两个合法值（见 `plugin.schema.json`）。
> `native` 是 P5 才引入的**附加字段**（`native` 对象 + `formatVersion` 升版），
> 不是 v2 里的第三个枚举值 —— 这样 v2 的校验器看到原生插件会**拒装**而不是**误装**，
> 属于有意的失败方向。

---

## 三、包格式 `.air2plugin`

### 3.1 容器

- 后缀：`.air2plugin`（内容就是 zip，允许改名成 `.zip` 后手工查看）。
- 压缩：deflate 或 stored，UTF-8 文件名标志位必须置位（bit 11），禁止非 UTF-8 文件名。
- **`manifest.json` 必须在包根**（不是子目录里）。找不到即拒装，理由文案固定为
  「包根缺少 manifest.json」。
- 不允许多个 manifest（例如 `sub/manifest.json` 同时存在视为夹带，按 3.3 拒绝）。

### 3.2 目录结构

```
hello.air2plugin
├── manifest.json            # 必须，UTF-8 无 BOM
├── AIR2SIG.json             # 可选，签名块（见 PLUGIN-SECURITY.md 第六节）
├── entry.js                 # type=js 时必须（路径由 manifest.entry 指定）
├── ui/
│   └── theme.json           # 可选，被 manifest.files 列出才会被加载
├── assets/
│   ├── common/              # 平台无关资源
│   └── ios/                 # iOS 专属资源，覆盖 common 同名文件
├── locales/
│   ├── zh-Hans.json
│   └── en.json
└── native/                  # P5 才允许出现
    └── ios/air2_hello.dylib
```

规则：

1. `assets/common/**` 与 `assets/<platform>/**` 按 `PLUGIN-COMPAT.md` 第三节叠加。
2. `locales/` 下的文件名即 BCP-47 语言标记，回退顺序见 `PLUGIN-COMPAT.md`。
3. `native/` 出现在 `formatVersion 2` 的包里 → 拒装（「本宿主不支持原生插件」）。
4. `ui/`、`assets/`、`locales/` 下的每个文件**必须在 `manifest.files` 里**，
   且 `manifest.files` 里的每个路径**必须真实存在** —— 双向严格相等，多一个少一个都拒装。

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

### 3.4 `formatVersion` 语义

- 当前唯一受支持的值：**2**。
- 语义：**包格式版本**（zip 布局 + manifest 结构 + 签名块位置），**不是** API 版本，也**不是**插件自身版本。
- 读取到 `> 2` 一律拒装，理由文案「需要更新版本的 Air2」；读取到 `< 2` 同样拒装并提示重新导出。
- 升级策略：新增**可选**字段不升 `formatVersion`；新增**必填**字段、改变语义、或新增 `type` 枚举值
  才升版本（例如 P3 引入 `hide`/`override`/整页替换、P5 引入 `native`）。
  宿主接受 `formatVersion ∈ [2, 自身支持的最大值]`。
- `plugin.schema.json` 是 `formatVersion 2` 的机器可读定义，`additionalProperties: false`
  —— 写错字段名会在安装期被抓到，不会静默忽略。

---

## 四、安装流程（原子）

### 4.1 目录布局

根目录固定在：

```
<App 容器>/Library/Application Support/Air2/
└── Plugins/
    ├── registry.json                  # 注册表（原子替换写）
    ├── .staging/<uuid>/               # 解压暂存，安装成功后整体 rename 走
    ├── signatures/                    # 签名指纹缓存（keyId → 已验公钥）
    └── <pluginId>/
        ├── <version>/                 # 已安装的版本目录（可并存两版）
        └── <version-1>/               # 上一版，保留至下次成功启动后清理
```

**为什么放 `Library/Application Support` 而不是 `Documents`**：

- `Documents` 在 `UIFileSharingEnabled` 打开时对用户/第三方文件 App 可见可写 ——
  用户手改插件目录后，哈希校验与签名就只剩「要么拒载要么信任篡改」，两头都不对。
- `Application Support` 不暴露给文件 App，也不在「文稿」的备份/同步语义里，
  它的写入者只有宿主一个。
- 目录带 `NSURLIsExcludedFromBackupKey`：插件可由官方仓库重新下载，不必进 iCloud 备份
  （省配额，也避免「恢复备份 = 恢复一份被篡改的插件」）。

### 4.2 七个步骤

```
① 导入      文件选择器 / 分享 → 复制 zip 到 .staging/<uuid>/package.air2plugin
② 结构校验  中央目录预检（路径 / 条目数 / 大小 / 压缩比）→ 解压到 .staging/<uuid>/root/
③ manifest  读根 manifest.json → JSON Schema 校验（plugin.schema.json）→ 语义校验
④ 完整性    按 manifest.files 逐文件算 SHA-256 并与清单比对（全量）
⑤ 授权      权限 + 组合风险判定 → T0 一次性授权弹窗 / T1 确认 / 拒装
⑥ 换目录    .staging/<uuid>/root/ → Plugins/<pluginId>/<version>/ （同卷 rename，原子）
⑦ 提交      registry.json 原子替换（write-temp + fsync + rename + fsync 目录）
```

失败处理：

- ①②③④⑤ 任一步失败 → 删除整个 `.staging/<uuid>/`，**registry 完全不动**，
  管理页弹出一条带 `code` 的失败原因。
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

1. 删除 `.staging/` 下所有条目（staging 里的东西没有一次是被需要的）。
2. 对 `Plugins/<pluginId>/` 下**不在 registry 里**的版本目录，若其 `installedAt` 早于本进程启动
   且超过 24 小时 → 删除（孤儿目录）。
3. `registry.json` 解析失败 → 整体改名为 `registry.json.corrupt-<时间戳>`，
   用空注册表重建，并把「插件注册表损坏，已重建」写进诊断页。**不猜、不修**。

### 4.5 覆盖安装 / 升级 / 降级

| 场景 | 行为 |
|---|---|
| 同 `id` 同 `version` | 视为重装：若 `packageHash` 相同 → 直接成功（幂等）；不同 → 拒装（「同版本内容不同，可能是被替换的包」） |
| 同 `id` 高版本 | 升级：旧目录改名 `<oldVersion>` 保留，装新版本，成功后 registry 记 `previousVersion` |
| 同 `id` 低版本 | 降级：允许，但 UI 标「降级」并要求二次确认 |
| 不同 `id` | 独立安装 |

旧版本保留策略：每个插件最多保留 **1** 个旧版本目录；清理发生在**下一次成功启动**
（首帧后稳定 5s，即 stage 走到 `stable`）之后 —— 这样「新版本一启动就崩」时，
用户还能回退到磁盘上仍在的旧版本。

回退：管理页的「回退到上一版」= 把 registry 的 `activeVersion` 指回 `previousVersion`，
目录已存在，所以是瞬时的，不需要重新安装。

### 4.6 卸载

1. registry 标记 `uninstalling`（先让加载器跳过它）→ 原子提交。
2. 删目录 → 删条目 → 原子提交。
3. 第 2 步失败不阻塞用户体验：下次启动按孤儿目录清理。

---

## 五、加载顺序

### 5.1 两阶段

| 阶段 | 时机 | 允许做 | 不允许做 |
|---|---|---|---|
| **Phase A（bootstrap）** | 启动早期，UI 创建之前 | 读 registry、算启用集、做依赖拓扑排序、构建 slot 表、跑崩溃安全模式判定 | 执行任何插件代码 |
| **Phase B（runtime）** | 首帧之后 | 建 JSCore 上下文、注入能力、跑 `onLoad`、跑 `onBoot`、执行 UI 贡献 | 阻塞主线程超过 50 ms |

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

### 5.3 三个层

| 层 | 内容 | 失败后果 | 安全模式 |
|---|---|---|---|
| **L0 数据层** | 版本元数据装饰、下载源候选、版本过滤器（P4） | 数据缺失，UI 照常 | 不禁止 |
| **L1 装饰层** | slot 注册、图标、主题 token | 该贡献被丢弃，其余照常 | 第二次进安全模式时禁止 |
| **L2 覆盖层** | `hide` / `override` / 整页替换（P3） | 可能让界面「变空」 | 进安全模式优先禁止 |

层由插件**申请的能力**推导，不由作者填写：
申请了 `hide`/`override`/`page` 的插件一定是 L2，申请了 slot/theme 的是 L1，
只申请 `version.decorate` / `download.source` / `version.filter` 的是 L0。
（作者填什么不影响判定，避免「声明自己是 L0 实际做 L2 的事」。）

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
  这些属于启动链的关键路径（见 `docs/LAUNCHCHAIN-DEADCODE.md`、ADR-009/012/013），
  插件对它们的唯一影响是「最终追加到 JVM 参数列表尾部的那几条」，
  且受 `PLUGIN-SECURITY.md` 第五节约束（受保护参数插件不可写）。
- 首帧之后 5s 的 `stable` 标记是**插件系统专有**的健康信号，与启动遮罩超时无关。

---

## 六、注册表

位置：`Plugins/registry.json`（唯一的插件事实来源）。

```json
{
  "formatVersion": 2,
  "seq": 128,
  "userSeq": 41,
  "plugins": [
    {
      "id": "com.example.hello",
      "activeVersion": "1.0.0",
      "previousVersion": "0.9.0",
      "packageHash": "sha256:…",
      "enabled": true,
      "trustLevel": "T1",
      "signerFingerprint": "sha256:…",
      "permissionsGranted": ["version.decorate"],
      "grantBinding": { "packageHash": "sha256:…", "grantedAt": "2026-10-31T10:00:00Z" },
      "installedAt": "2026-10-31T10:00:00Z",
      "lastEnabledChangeAt": "2026-10-31T10:00:00Z",
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
| `formatVersion` | 注册表自身的结构版本，当前 2；迁移见 6.2 |
| `seq` | 单调递增计数器，每次写 +1，用于诊断「注册表是否被外部改过」 |
| `userSeq` | **用户配置序号**：用户装/卸/开关插件或改授权时 +1；宿主**自动**禁用插件时**不** +1。崩溃归因比较的就是它（见 `PLUGIN-SECURITY.md` 6.1） |
| `activeVersion` | 当前生效版本目录名 |
| `previousVersion` | 上一版目录名，用于回退 |
| `packageHash` | 全量内容摘要（定义见 `PLUGIN-SECURITY.md` 第五节），是 T0 授权的绑定键 |
| `enabled` | 用户开关 |
| `trustLevel` | `T0` / `T1` / `T2`（见 SECURITY 第三节） |
| `signerFingerprint` | 签名者指纹（未签名时为 `null`） |
| `permissionsGranted` | 用户实际授予的权限（**可能少于** manifest 申请集） |
| `grantBinding` | 授权绑定的包哈希与时间；哈希变了即失效 |
| `suspectCount` | 连续可疑失败次数，成功到 `stable` 清零（规则见 `PLUGIN-SECURITY.md` 6.3） |
| `autoDisabled` | 是否由崩溃安全模式自动禁用（用于「恢复被自动禁用的插件」时区分用户手动禁用） |
| `tampered` / `invalid` | 加载期发现篡改 / 结构失效的原因；非 `null` 即不加载 |

### 6.1 写入规则

- 只有宿主写；插件 API 里**没有任何**注册表写入口。
- 每次写都是全量重写 + 原子替换（文件很小，不做增量）。
- 写前校验：`permissionsGranted ⊆ manifest 申请集`；`activeVersion` 目录存在；
  `packageHash` 与磁盘一致（不一致 → 拒绝写，记 `tampered`）。

### 6.2 迁移

`registry.json` 的 `formatVersion` 与包格式的 `formatVersion` 是**两个独立数字**（同名不共义）。
注册表迁移：读到低版本 → 按迁移表逐级升 → 写回前先备份 `registry.json.bak`。
无法迁移 → 按 4.4 第 3 条处理（重建空表，插件全部转 `invalid`，管理页提示重新安装）。

---

## 七、里程碑

| 里程碑 | 内容 | 验收口径 |
|---|---|---|
| **P0** | 文档：本文 + API + 安全 + 兼容 + 作者指南 + `plugin.schema.json` + ADR-014～020 | 文档之间无矛盾；schema 能校验两个最小示例 |
| **P1** | 安装器 / 注册表 / 权限存储 / 最小管理页 | 能装、能启停、能卸载、能看原因；不动 UI 渲染 |
| **P2** | 注册表化 UI + slot + `register` + 导入预览 + **签名与信任等级** | JSON 插件能往 slot 塞组件；未签名包走 T0 一次性授权；签名校验通过则升 T1 |
| **P3** | `hide` / `override` / 整页替换 + **JSCore 运行时** | JS 插件能跑 `onLoad`/`onBoot`；未授权 API 在对象上不存在（不是抛错） |
| **P4** | 下载源候选 + 版本过滤器 + 开发模式（本地目录直载、跳过签名但强制 T0） | 过滤器能按规则隐藏版本；开发模式不污染正式注册表 |
| **P5** | 原生模块 / `ui.web` / Java agent 自挂载 / 官方仓库 / 多端宿主 | 原生模块按 ADR-020 门槛审核；`ui.web` 走独立进程或强隔离 WebView |

> **签名提前到 P2** 是刻意的：如果 P3 才有签名，P2 阶段装进来的包在 P3 上线时全部变成「不可信」，
> 等于强迫全部用户重装。签名面先落地，后加能力，才不会做出兼容性债务。

---

## 八、明确不做（写进 ADR，不是「以后再说」）

1. **替换下载引擎** —— 插件只能追加候选源，引擎选择逻辑保留在 Core。
2. **任意路径访问** —— `air2.paths` 只发不透明 token，见 `PLUGIN-COMPAT.md`。
3. **远程代码执行** —— `eval` / `new Function` / `Function.constructor` / `WebAssembly` 在 JSCore 上下文里
   **不注入**（不是「调用时抛错」，见 `PLUGIN-API.md` 第四节）。
4. **账号 token 读写** —— API 面里没有 `air2.account`。
5. **游戏内 UI hook** —— v1 不做，也不预留半成品入口。

---

## 九、术语

| 术语 | 含义 |
|---|---|
| 包 / package | 一个 `.air2plugin` 文件 |
| packageHash | 全量内容摘要（清单规范化后的 SHA-256），T0 授权的绑定键 |
| slot | 宿主 UI 里预留的、可被插件放组件的语义位置 |
| 组件 / component | 语义组件名（如 `button.primary`），不是平台控件类名 |
| 能力注入 | 未授权的 API 在插件对象上**不存在**，加载期一次性决定 |
| stage marker | 启动阶段标记，用于崩溃归因 |
| 安全模式 | 连续可疑失败后按 L2 → L1 顺序禁用插件的降级启动 |
| 开发模式 | P4 起：从本地目录直载插件，强制 T0，不写正式注册表 |

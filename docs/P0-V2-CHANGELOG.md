# P0 文档 v2 改动摘要（2026-10-31）

> 这份文件是给开发者开工 P1 前的**交接说明**。它不替代任何契约文档；
> 有冲突时以 `PLUGIN-SECURITY.md` / `PLUGIN-SYSTEM.md` / `plugin.schema.json` 为准。
>
> **已被 v3 修订（2026-10-31）**：本文件的「critical 按 `packageHash` 绑定、哈希变即重确认」
> 与「P1 只写 marker + 计数、不自动禁用」两条已失效，以 `P0-V3-CHANGELOG.md` /
> `PLUGIN-SECURITY.md` 3.4 与 6.4 为准。其余内容仍然有效。

---

## 一、这版改了什么（一句话）

**取消官方签名与 T0/T1/T2 信任等级**，改为安装时**逐项授权**；
critical 权限必须连续 **三次提示框、每次等 5 秒**；
补上 **v3 原生 JSON 页面模型** 与 1～10 号插件需要的扩展点；
把 P1 的范围收紧到「安装器 + 注册表 + 权限存储 + 最小管理页 + 三步授权 + boot marker」。

---

## 二、核心决策变更

| 项 | 旧（P0 v1） | 新（P0 v2） |
|---|---|---|
| 作者身份 | Ed25519 签名 + keyring + 白名单 + T0/T1/T2 | **不验证作者身份**；删除全部签名/信任字段；安装页标「作者自述」 |
| 权限授予 | T0 只能低/中；T1/T2 可 critical；红色二次确认 | 低/中默认开、可逐项关；critical 默认关，每个权限独立三次 5 秒确认 |
| critical 绑定 | T0 按 `(pluginId, packageHash)`；T1/T2 可跨版本沿用 | **每个 critical 权限**绑定 `(pluginId, packageHash, permissionId)`；包哈希变一次就重确认一次 |
| 低/中绑定 | 未明确 | 按 `(pluginId, permissionId)` 跨版本沿用 |
| 降级 | 允许，UI 标「降级」 | **默认拒装**（`E_DOWNGRADE`）；开发者模式例外；本地 `previousVersion` 回退不受影响 |
| 签名文件 | `AIR2SIG.json` 可选 | 包根出现即拒装（`E_LEGACY_SIGNATURE`） |
| 复杂页面 | 等 P3 整页替换 / P5 `ui.web` | **v3 原生 JSON 页面模型**（`ui.pages`），不用 WebView 兜底 |
| 纯 JSON 页面 | 未明确 | `type: json` 只能声明 `mode: "static"`；动态页面必须 `type: js`；static 页面不能声明 manifest `state` |
| P1/P2 的 JS 插件 | 可安装 | **拒装**（`E_TYPE_UNSUPPORTED`）；P3a 起才允许 `type: js` |
| 包格式 | 未明确 | P1/P2/P3a 接受 v2；P3b 起接受 v2 / v3；v3 才允许 pages / overrides / native |
| 列表项动作 | 无 | `itemKey` 把当前行标量解析为 `payload.itemKey`；缺失 → 动作禁用 + `E_ITEM_KEY_MISSING` |
| JS 回调线程 | 全部主线程 | **每插件独立串行队列**；UI 提交主线程；`render` ≤16ms，`onAction` ≤2s，交互钩子 ≤60s |
| 崩溃自动禁用 | P1 就做 | **P1 只写 marker + 计数**；P2 起才自动禁用 / 安全模式 |
| 旧渲染器 | 未明确 | **双轨保留**；P1 不读不写不迁移 `Documents/Air2/Renderers/`；管理页两个入口 |
| 多端 | iOS 唯一 | `ios` / `android` / `desktop`（Windows/macOS/Linux）；仍只承诺契约，不承诺时间 |
| 整合包导出 | 无 | **mrpack + zip**；`archive.create` + `files.export` |

---

## 三、文档改动清单

| 文件 | 改动 |
|---|---|
| `PLUGIN-SECURITY.md` | **重写**。删除信任等级/签名/白名单/吊销；新增逐项授权、三步 5 秒、包哈希绑定、组合提示、存储保护、账号边界、P1/P2 验收清单 |
| `PLUGIN-SYSTEM.md` | 安装七步改授权；registry 去 `trustLevel`/`signerFingerprint`，加 `source`/`criticalGrants`/`grantRevision`；降级改默认拒装；里程碑改 P1/P2/P3a/P3b/P4/P5；`launch.overlay` 明确为启动器遮罩；删除不存在的 `LAUNCHCHAIN-DEADCODE.md` 引用 |
| `PLUGIN-API.md` | 新增 7 项权限对应的 API；新增 `files.read/list/export`、`archive`、`crypto`、`instance` hooks、`launch.addGameArg`、`onLaunchResult`、`download.fetchToFile`、`ui.promptSecret`；回调改串行队列 + 预算表；补 v3 页面 API 摘要 |
| `plugin.schema.json` | 删除 `author.fingerprint`；权限 24 项；slot 7（v2）/9（v3）；组件叶子 + 容器；UI 节点加 `id/action/binding/itemKey/visibleWhen/enabledWhen/children`；新增 `ui.pages`/`ui.overrides`/`native`；v2 条件禁止 pages/overrides/native；`type: json` 禁止 dynamic 页面，static 页面禁止 `state` |
| `PLUGIN-AUTHORING.md` | **重写**。删除签名章节；加授权说明（用户看到什么、作者该做什么）；`minHostVersion` 改 `0.1.0`；加 v3 页面示例与 mrpack/zip 导出示例；说明纯 JSON 只能静态页面；拒装码更新（含 `E_TYPE_UNSUPPORTED`） |
| `PLUGIN-COMPAT.md` | slot 加 `home.section`/`launch.overlay`/`home.page`/`versions.list.page`；组件加容器与扩展叶子；加页面跨端约束与「JSON 只能 static」；token 表加 `gameRead`/`instanceDir`/`export`；矩阵改 P1/P2/P3a/P3b/P4/P5 |
| `DECISIONS.md` | ADR-007～013 标「预留，本分支未实现」；ADR-016/018/020 标部分被取代；新增 ADR-021（取消签名 + 三步授权）、ADR-022（v3 页面模型）、ADR-023（扩展点与 1～10 覆盖） |
| `PLUGIN-PAGE.md` | **新增**。v3 页面模型完整契约：manifest、静态/动态（JSON 只能 static）、组件树、state/binding、action / `itemKey`、chrome、安全、限制、失败处理、跨端、验收清单 |
| `P0-V2-CHANGELOG.md` | **新增**。本文件 |

---

## 四、新增扩展点（1～10 号插件覆盖）

### 4.1 新增权限（7 项，总数 17 → 24）

| 权限 | 风险 | 用途 |
|---|---|---|
| `ui.contribute` | 低 | slot / 主题 / 页面注册 |
| `ui.override` | 中 | hide / override / 整页替换 / `launch.overlay` |
| `files.game.read` | 中 | 读配置 / 日志 / 存档 / mods / 资源包内容 |
| `files.export` | 中 | 通过系统分享面板导出文件 |
| `instance.guard` | 中 | 打开/编辑实例前检查 |
| `launch.gameArgs` | **critical** | 主类之后的游戏参数 |
| `download.fetch` | 中 | 插件发起的下载任务（需同时申请 `network.http`） |

### 4.2 新增 slot

- v2：`home.section`、`launch.overlay`
- v3：`home.page`、`versions.list.page`（`versions.list.page` 从 v2 移到 v3）

### 4.3 新增 API

| API | 说明 |
|---|---|
| `air2.files.list/stat/read/writeGame/remove/export/copy` | 受限文件面；游戏 token 需对应权限 |
| `air2.archive.list/extract/create` | zip / mrpack 读写 |
| `air2.download.fetchToFile/cancel/listJobs` | 异步下载任务 + `onDownloadProgress` / `onDownloadComplete` |
| `air2.crypto.digest/randomBytes` | SHA-1/256/512、随机字节 |
| `air2.instance.list/get` + `onBeforeOpen/onBeforeEdit` | 实例元数据 + 守卫 |
| `air2.launch.addGameArg` | 游戏参数（主类之后） |
| `onLaunchResult` | 启动结果回调 |
| `air2.ui.promptSecret/confirm/toast/openPage/closePage` | 宿主自绘交互 |
| `air2.page.setState/getState/open/close` | v3 页面状态与导航 |

### 4.4 其他

- 整合包导出：`mrpack` + `zip`；`archive.create` 只写临时目录，`files.export` 交给用户。
- `schematics/**` 加入 `files.game.write.content` 白名单。
- `launch.overlay` = 启动器自己的启动遮罩（不是 Minecraft 游戏内加载界面）。
- v3 列表项动作新增 `itemKey`：宿主把当前项标量解析为 `payload.itemKey`；缺失则动作禁用并记 `E_ITEM_KEY_MISSING`。
- 纯 JSON 插件只能声明静态页面（`root` / `source`）；动态页面必须 `type: js` + `render`。
- P1 / P2 宿主拒装 `type: js`（`E_TYPE_UNSUPPORTED`）；P3a 起才允许；P3b 起才接受 v3 包。
- `#11 Air2 Server`、`#13 自动化`：暂不做插件，接受后续内置。

---

## 五、P1 范围（开发者从这里开始）

P1 **只做**下面五件事，不碰 UI 渲染、不碰旧渲染器、不跑插件代码：

1. **安装器**
   - 文件选择器 / 分享导入 `.air2plugin`；
   - staging → 中央目录预检 → 解压 → manifest schema/语义校验 → 全量 SHA-256 → 授权 → 同卷 rename → registry 原子替换；
   - 失败删除 staging，registry 不动；
   - `AIR2SIG.json` → `E_LEGACY_SIGNATURE`；
   - P1 只接受 `formatVersion 2` + `type: json`：v3 包 → `E_FORMAT_VERSION`，`type: js` → `E_TYPE_UNSUPPORTED`；
   - 同版本不同内容 → `E_SAME_VERSION_DIFFERENT_CONTENT`；
   - 降级 → `E_DOWNGRADE`（开发者模式例外）。
2. **注册表**
   - `registry.json` v3：`source` / `permissionsGranted` / `criticalGrants` / `grantRevision` / `userSeq` / `suspectCount`；
   - 原子写；损坏改名重建；孤儿目录清理（24h）。
3. **权限存储 + 三步授权**
   - 低/中默认开、可逐项关；
   - critical 默认关、每个权限三次 5 秒；
   - `criticalGrants` 绑定 `(pluginId, packageHash, permissionId)`；
   - 包哈希变化 → 重新确认；
   - 管理页可撤销 / 重新审查。
4. **最小管理页**
   - 插件列表：名称、id、版本、作者（自述）、来源、包哈希短串、启用开关、卸载；
   - 权限明细：已授予 / 未授予 / 当前版本不可用；
   - 诊断：最近 stage、`suspectCount`、`tampered`、`invalid`；
   - **不显示**官方/已验证/信任等级/签名者。
5. **boot marker**
   - Phase A 最早写 `stage:"boot"`；首帧 `stage:"ui"`；稳定 5s `stage:"stable"` 并清除；
   - 下次启动按 `userSeq` 算 `suspectCount`；
   - **只记录，不自动禁用**。

### 5.1 P1 验收清单

1. 能导入一个 v2 纯 JSON 插件，走完详情页 → 授权 → 安装 → 出现在管理页。
2. 能启用 / 禁用 / 卸载；卸载后目录与 registry 条目都消失。
3. 低/中权限默认开启；关掉后管理页标「未授权」。
4. critical 权限默认关闭；点「授权」连续三次，每次按钮 5 秒内不可点。
5. 第 2 次取消 → 该权限不授予；安装仍成功；管理页标「功能受限」。
6. 第 3 次确认 → `criticalGrants` 出现，含 `packageHash` / `grantedAt` / `method:"three-step"`。
7. 同包重装 → 幂等，不再弹三次。
8. 新版本（哈希变化）→ critical 重新弹；低/中沿用。
9. 同版本不同内容 → 拒装。
10. 降级 → 拒装；开发者模式放行后 UI 标「降级」。
11. 包根 `AIR2SIG.json` → 拒装 `E_LEGACY_SIGNATURE`。
12. 包内多文件 / 少文件 → 拒装 `E_FILE_SET_MISMATCH`。
13. 首帧前崩溃两次 → `suspectCount=2`；**不自动禁用**。
14. 首帧后 5 秒内强杀 → `suspectCount` 不变。
15. 旧渲染器目录不被读写；管理页「插件」与「渲染器」两个入口都在。
16. 导入 `type: js` 包 → 拒装 `E_TYPE_UNSUPPORTED`，不落 registry。
17. 导入 v3 包 → 拒装 `E_FORMAT_VERSION`，文案「需要更新版本的 Air2」。

---

## 六、仓库补丁清单（P1 开工前 / 同期）

> 这些不在 P0 文档包内，但开发者需要知道，避免「文档对了、仓库还是旧口径」。

### 6.1 文档与规范

| 文件 | 补丁 |
|---|---|
| `Air2/docs/ARCHITECTURE.md` | 把 SwiftUI / Swift 改成 **ObjC（+C）**（ADR-014）；登记 `Air2/Core/Plugin/`、`Air2/UI/Plugin/`、`Air2/Core/Plugin/Page/` 目录与分层 |
| `Air2/docs/DECISIONS.md` | 合入 ADR-014～023；ADR-007～013 标「预留，本分支未实现」；ADR-016/018/020 标部分被取代 |
| `skills/air2-architecture`（如存在） | 删除 SwiftUI / Swift 表述；补插件目录与「Core 不依赖 UI」约束 |
| `skills/air2-engineering`（如存在） | 补插件日志前缀 `[PLUGIN:<id>]`、三步授权测试、哈希测试 |
| `skills/air2-index`（如存在） | 路由补 `air2-plugin` 文档入口（若新增 skill） |
| `scripts/lint_structure.sh` | 加 `Air2/Core/Plugin`、`Air2/UI/Plugin` 白名单；加「禁止新增 `.swift`」；加「禁止 `T0/T1/T2/AIR2SIG/Ed25519` 出现在插件代码注释」可选检查 |

### 6.2 代码能力

| 文件 / 模块 | 补丁 |
|---|---|
| `Air2/Core/Addons/A2ZipReader.[hm]` | 枚举条目元数据（`uncompressedSize` / `compressedSize` / `isDirectory` / `generalPurposeBitFlag`）；流式解压；解压前上限检查；拒绝 zip64 / 加密 / 多卷 / 符号链接 |
| `Air2/App/A2CrashGuard.m` | 接入 `.bootstate.json` 的 `boot` / `ui` / `stable` 写入；不要与现有崩溃记录混用 |
| `Air2/Core/Renderer/A2RendererImporter.m` | **不改**；P1 双轨保留，管理页「渲染器」入口继续走旧 importer |
| `Air2/Core/Addons/A2ModPack.h` | 当前只有导入解析；导出（mrpack / zip）放 P4 新模块，不要塞进 importer |
| SHA-256 | 仓库只有 MurmurHash2；用 CommonCrypto `CC_SHA256` 写一个小 helper（`A2SHA256`），不要自己实现 |
| JSON Schema | 仓库没有 schema 库；P1 手写语义校验器；CI 用 Python `jsonschema` 对照 fixtures（本地/CI 装依赖即可） |
| 文件保护 | 插件目录与 registry 设 `NSFileProtectionCompleteUntilFirstUserAuthentication` + `NSURLIsExcludedFromBackupKey` |
| Info.plist | `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` **保留**（用户文件仍需要）；插件目录不在 Documents，不受影响 |

### 6.3 双轨保留（重要）

- 旧渲染器 manifest 是 `formatVersion: 1`（`rendererId` / `rendererGLPath` / `libraryLayout`），
  新系统 `< 2` 会拒装。**不要**把旧 importer 改成走新校验器，否则现有渲染器全部失效。
- P1 不读、不写、不迁移 `Documents/Air2/Renderers/`；不删旧目录；不改旧 manifest。
- 管理页两个入口：「插件」走新系统，「渲染器」走旧 `A2RendererImporter`。
- 将来合并（如果做）必须新开 ADR，先解决 `formatVersion 1 → 2` 的迁移与回滚。

### 6.4 已知缺口 / 风险

| 缺口 | 影响 | 建议 |
|---|---|---|
| 没有作者身份 | 无法防仿冒 | 安装页明确写「不验证作者」；发布页让作者公布 `packageHash` |
| 没有 JSON Schema 库 | P1 不能直接 `jsonschema.validate` | 手写语义校验器 + CI fixtures；schema 仍作为契约 |
| `A2ZipReader` 全量进内存 | 大包可能 OOM | P1 先扩流式 API；上限 64MB / 单文件 32MB |
| JSCore 同进程 | 沙箱越界风险 | P3 封死 `eval` / `Function` / `WebAssembly`；原生面 P5 |
| P3b 页面模型工作量大 | 粗估 4～6k 行 ObjC | 拆 3a / 3b；先做 static 页面，再做 dynamic |
| 24 项权限安装页很长 | 授权疲劳 | 按风险分组；低/中默认开但可折叠；critical 逐项展开 |
| 三次 5 秒确认 | 用户可能不耐烦 | 文案必须具体；不重复弹已授权项；支持「稍后授权」 |
| 旧文档漂移 | 开发者照旧文档做出签名逻辑 | 以本包为准；仓库 `docs/` 按第六节 patch |

---

## 七、交付前自检

- [x] 契约正文不再把 `T0/T1/T2`、`trustLevel`、`signerFingerprint`、Ed25519、keyring、吊销
      当作现行机制。允许的残留只有三类：① 明确拒装的包根 `AIR2SIG.json`（`E_LEGACY_SIGNATURE`）；
      ② 通用安全术语「白名单」（域名 / 参数前缀 / 路径）；③ 本 changelog 与 `DECISIONS.md`
      的旧机制对照、ADR 历史说明。
- [x] `plugin.schema.json` 是合法 JSON；权限 24 项与 `PLUGIN-SECURITY.md` 第二节逐项一致。
- [x] `formatVersion 2` 分支禁止 `ui.pages` / `ui.overrides` / `native`；v3 才允许。
- [x] `type: json` 只能声明 `mode: "static"`；`mode: "static"` 不能带 `state`；两处都有 schema 条件与反例。
- [x] `itemKey` 在 `PLUGIN-PAGE.md` 5.1、`PLUGIN-COMPAT.md` 2.3、`plugin.schema.json` 的节点字段三处一致；
      缺失 → 动作禁用 + `E_ITEM_KEY_MISSING`。
- [x] P1/P2 拒装 `type: js`（`E_TYPE_UNSUPPORTED`）；P3a 起允许 JS；P3b 起接受 v3 包。
- [x] 所有示例的 `minHostVersion` 是 `0.1.0`（或省略），不再出现 `2.0.0`。
- [x] `PLUGIN-SYSTEM.md` 不再引用不存在的 `docs/LAUNCHCHAIN-DEADCODE.md`。
- [x] `PLUGIN-API.md` 的 `manifest.ui.pages` 与 schema 的 `ui.pages` 一致。
- [x] `launch.overlay` 在所有文档里都明确为「启动器自己的启动遮罩」。
- [x] 整合包导出在 API / AUTHORING / SECURITY 三处都写 `mrpack + zip`。
- [x] ADR-001 已标注技术栈部分被 ADR-014 取代；ADR-021/022/023 已追加，016/018/020 已标取代关系。

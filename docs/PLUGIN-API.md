# Air2 插件 API（v1）

> **状态**：P0 契约。API 主版本 `1`，冻结后只增不改（见第九节）。
> **前提**：宿主是 ObjC 单进程应用（ADR-014），插件运行在宿主进程内的 JSCore 上下文里。
> 因此「沙箱」是**能力注入式**的 —— 不是「给了能力再拒绝调用」，而是**没给的能力对象根本不存在**。
>
> **v2 变更（2026-10-31）**：新增 `launch.gameArgs`、`files.read/list/export`、`archive`、
> `crypto`、`instance` hooks、`download.fetchToFile`、`ui.promptSecret`、v3 页面 API；
> JS 回调从「全部主线程」改为「每插件独立串行队列」。
> 页面模型完整契约见 `PLUGIN-PAGE.md`。

---

## 一、三种运行时层级

| 层级 | 何时可用 | 代码 | 能力面 |
|---|---|---|---|
| **纯 JSON** | P2 | 无（只有 `manifest.json`） | 声明式 UI、元数据装饰、静态页面（v3）、下载源候选 / 版本过滤器（P4） |
| **JS** | P3a | `entry.js`（JSCore） | JSON 全部 + 事件回调 + 按权限开放的宿主能力 |
| **原生** | P5 | `native/ios/*.dylib` | C 接口直连；仅 TrollStore / 越狱设备，按 ADR-020 修订门槛 |

**纯 JSON 插件能做的事是「声明」，不是「执行」**：它没有 `entry.js`，宿主把 manifest 里的
`ui.slots` / `ui.theme` / `ui.pages` / `contributes` 读出来直接当数据用。这条边界的意义是：
一个纯 JSON 插件**没有可执行面**，因此它的风险上限由它申请的权限决定，而不是由代码质量决定。

---

## 二、`air2.host` 字段（两个同名对象，不是同一个东西）

这点必须写死，否则作者一定会混淆：

| 位置 | 名字 | 性质 | 谁写 |
|---|---|---|---|
| `manifest.json` | `air2.host` | **声明**：我要什么样的宿主 | 作者 |
| 运行时全局 | `air2.host` | **只读视图**：我面对的是什么样的宿主 | 宿主 |

### 2.1 manifest 里的 `air2.host`（声明，安装期校验）

```json
"air2": {
  "host": {
    "apiVersion": 1,
    "minHostVersion": "0.1.0"
  }
}
```

| 字段 | 必填 | 语义 | 不满足时 |
|---|---|---|---|
| `apiVersion` | 是 | 插件使用的 API 主版本。v1 只允许 `1` | 拒装：「需要更新版本的 Air2」（宿主 API 更低）/「插件使用了不支持的 API」（宿主 API 更高且已不兼容 v1） |
| `minHostVersion` | 否 | 宿主版本下限（含） | 拒装：「需要 Air2 ≥ x.y.z」 |
| `maxHostVersion` | 否 | 宿主版本上限（含），**只用于已知不兼容的场景** | 拒装：「插件声明不支持当前 Air2 版本」 |

> 当前宿主版本是 **0.1.0**。示例里写 `minHostVersion: "2.0.0"` 会被直接拒装；
> 只有在确实用到新能力时才填下限，否则建议不填。

`apiVersion` 是**主版本号**，不是「API 1.3」这种小版本；小版本内的新增以
「新字段 / 新命名空间」形式出现，旧插件不感知、不报错（见第九节）。

### 2.2 运行时的 `air2.host`（只读视图）

```js
air2.host = {
  apiVersion: 1,            // 宿主实现的 API 主版本
  hostVersion: "0.1.0",     // 宿主版本（semver 字符串）
  platform: "ios",          // "ios" | "android" | "desktop"
  osVersion: "26.0",        // 平台系统版本，供降级判断
  locale: "zh-Hans-CN",     // 当前生效语言（已按 BCP-47 回退链解析后的结果）
  nativePluginsSupported: false, // 仅 TrollStore / 越狱设备为 true
  uiCapabilities: {         // 能力协商，不是权限
    "color.glass": true,
    "motion.spring": true,
    "haptics": true,
    "blur.backdrop": false,
    "grid.columns": 3,
    "minTapTarget": 44
  }
}
```

- 全部字段**只读**（写入抛 `TypeError`，因为这属于「对象存在、属性不可写」，
  不是能力缺失）。
- `uiCapabilities` 与 `permissions` 是两回事：前者告诉插件「宿主画不画得出」，
  后者告诉插件「宿主准不准你做」。
- `nativePluginsSupported` 与 `permissions` 也是两回事：它只表示设备能不能装载原生模块，
  不表示用户授权了 `native.module`。
- 运行时 `air2.host` **一定存在**，即使插件一个权限都没申请。

---

## 三、能力注入（关键契约）

### 3.1 规则

**未授权的宿主能力，在插件对象上不存在。**

这里的「不存在」有两级，必须同时成立：

1. **整个对象不存在**：例如只申请 `version.decorate` 的插件没有 `air2.launch`，
   `air2.net` / `air2.download` / `air2.page` 也不存在。
2. **对象存在、但受权限控制的方法 / token 构造器不存在**：例如 `air2.files` 是每个
   JS 插件都有的基础对象（用于插件自有数据），但没有 `files.game.write.content` 时
   `air2.files.writeGame` 与 `air2.paths.gameContent` 都不存在；没有 `ui.contribute` 时
   `air2.ui.register` / `air2.ui.openPage` 不存在。

```js
// 插件只申请了 version.decorate：
typeof air2.launch             // "undefined"
"launch" in air2               // false
typeof air2.files              // "object"（基础文件面）
typeof air2.files.writeGame    // "undefined"（无写权限）
typeof air2.ui                 // "object"（confirm / promptSecret / toast）
typeof air2.ui.register        // "undefined"（无 ui.contribute）
Object.keys(air2)              // ["host","log","i18n","storage","crypto","paths","ui","files","version"]
```

> 基础对象只包含**不需要权限**的安全方法：`ui.confirm` / `ui.promptSecret` / `ui.toast`、
> `files` 的插件自有 token 读写、`instance.list/get` 等。凡是能影响游戏目录、宿主界面、
> 启动参数、网络的能力，对应的**方法或 token 构造器**仍然按授权注入。

### 3.2 为什么是「不存在」而不是「调用时拒绝」

| 方案 | 问题 |
|---|---|
| 运行时拒绝（`throw new Error("permission denied")`） | ① 插件可以先 `try { air2.files.write(...) } catch {}` 探测，把「有没有权限」变成可枚举信息；② 错误信息里必然要写清「缺哪个权限」，等于把权限目录和宿主实现细节泄露给插件；③ 部分插件会用 try/catch 兜住一切，把「确实需要权限才能工作」退化成「静默不工作」，用户看到的是功能消失而不是权限不足。 |
| **加载期能力注入（本方案）** | ① 插件可以在 `onLoad` 第一行就 `if (!air2.files.writeGame) { air2.log.warn("需要写入权限"); return; }`，失败前移且可判定；② 权限差异在**对象或方法形状**上可见，调试和测试都能直接断言；③ 宿主不需要在实现里到处塞权限检查（少一类遗漏可能）。 |

### 3.3 注入时机

- 注入发生在**建 JSCore 上下文时**，早于 `entry.js` 第一行执行，之后**不再变化**。
- 不支持「运行期加权限」：用户改授权 → 插件**重新加载**（卸载再加载），拿到新对象。
  这保证「同一个上下文内能力面恒定」，插件可以放心在 `onLoad` 里做一次性分支。
- `grantRevision` 变化时宿主重载插件；插件不需要自己监听授权变化。

---

## 四、API 面总表

| 对象 | 需要的权限 | 出现阶段 | 说明 |
|---|---|---|---|
| `air2.host` | 无 | P3a | 只读视图，见第二节 |
| `air2.log` | 无 | P3a | `debug/info/warn/error`，统一加 `[PLUGIN:<id>]` 前缀 |
| `air2.i18n` | 无 | P3a | `t(key, params)`，按 `locales/` 回退 |
| `air2.storage` | 无 | P3a | 插件私有键值存储，单键 ≤ 64 KB，总量 ≤ 1 MB |
| `air2.paths` | 基础 token 无；游戏 token 见 `PLUGIN-COMPAT.md` 3.2 | P3a | 不透明 token，不暴露绝对路径 |
| `air2.ui` | 基础交互无；slot / 页面需 `ui.contribute` / `ui.override` | P2（声明）/ P3a（调用）/ P3b（页面） | slot 注册、主题 token、确认框、密码输入、页面导航 |
| `air2.version` | `version.decorate` / `version.patch` | P2 / P3a | 版本元数据与补丁；无权限时整个对象不存在 |
| `air2.launch` | `launch.*` 系列 | P3a | 启动参数、游戏参数、属性、环境变量；无任一 `launch.*` 时对象不存在，具体方法按权限注入 |
| `air2.files` | 基础文件面无；游戏文件 / 导出见 4.5 | P3a / P4 | 插件自有文件 + 游戏目录受限读写、导出 |
| `air2.archive` | 无（读取仍需 token 对应权限） | P4 | 读 / 写 zip，生成 mrpack 导出包 |
| `air2.crypto` | 无 | P3a | SHA-1 / SHA-256 / SHA-512、随机字节 |
| `air2.instance` | 元数据无；钩子需 `instance.guard` | P3a（元数据）/ P4（钩子） | 实例元数据 + 打开/编辑前钩子 |
| `air2.net` | `network.http` | P4 | 出站 HTTP，仅 GET/POST，域名白名单 + 出站提示 |
| `air2.download` | `download.source` / `download.fetch` | P4 | 追加下载源候选、发起插件下载任务；无任一权限时对象不存在 |
| `air2.page` | `ui.contribute` | P3b | v3 页面状态与导航，见 `PLUGIN-PAGE.md` |
| `air2.native` | `native.module` | P5 | 原生模块装载 |
| `air2.webview` | `ui.web` | P5 | 内嵌 WebView 承载页面 |

### 4.1 纯 JSON 插件（无 `air2` 对象）

纯 JSON 插件**没有运行时**，`air2` 对象不存在。它能表达的只有 manifest 里的声明：

| 能力 | manifest 位置 | 权限 | 阶段 |
|---|---|---|---|
| 往 slot 放组件 | `ui.slots[]` | `ui.contribute`（低） | P2 |
| 主题 token 覆盖 | `ui.theme.tokens` | `ui.contribute`（低） | P2 |
| 静态页面 | `ui.pages[]`（`mode:"static"`） | `ui.contribute`（低） | P3b |
| 版本显示名 / 副标题装饰 | `contributes.versionDecorate` | `version.decorate` | P2 |
| 下载源候选 | `contributes.downloadSources` | `download.source` | P4 |
| 版本过滤器 | `contributes.versionFilter` | `version.filter` | P4 |
| 界面覆盖 / 整页替换 | `ui.overrides[]` | `ui.override` | P3b |

> 纯 JSON 插件的页面只能是 `mode:"static"`；`dynamic` 页面需要 `type:"js"` 和 `render`，
> 二者在 schema / 安装期都会被校验。

### 4.2 JS 插件额外能做的

- **事件回调**：`onLoad` / `onBoot` / `onVersionList` / `onLaunch` / `onLaunchResult` /
  `onUnload` / `contribute` / `render` / `onAction` / `onBeforeOpen` / `onBeforeEdit` /
  下载事件（见第六节）。
- **动态 UI 贡献**：`air2.ui.register(slot, descriptor)` —— 用 JS 计算后再交组件描述，
  相比 JSON 的静态 `ui.slots` 多一层「按数据决定」。
- **启动参数**：`air2.launch.setProperty` / `addArg` / `addGameArg` / `addEnv` 等，受第五节约束。
- **文件读写**：`air2.files.read` / `list` / `writeGame` / `export`，受权限区分。
- **归档**：`air2.archive.list` / `extract` / `create`，用于整合包导入 / 导出。
- **版本补丁**：`air2.version.patchFiles`（`version.patch`，critical）。
- **网络与下载源**：P4 起，`air2.net` / `air2.download`。
- **实例钩子**：`onBeforeOpen` / `onBeforeEdit`（`instance.guard`）。
- **交互**：`air2.ui.confirm` / `air2.ui.promptSecret`（宿主自绘，最长 60 秒）。

### 4.3 P5 才开的三个面

| 面 | 权限 | 门槛 |
|---|---|---|
| `air2.native`（自带 dylib） | `native.module` | 设备能力 + 三次确认 + 第四页原生警告，见 ADR-020 修订 |
| `air2.webview`（内嵌页面） | `ui.web` | 独立 WebView 进程或强隔离（禁 file://、禁 JS 桥直通） |
| Java agent 自挂载 | `java.agent` | 插件自带 agent jar，由宿主按清单挂载并校验哈希 |

> `java.agent` 这个权限 id 在 P3a 就存在（用于允许 `-javaagent` / `-agentlib` / `-agentpath` /
> `-Xrunjdwp`），P5 的差别只有一点：**jar 由插件自带而不是用户提供**，届时新增 `agentFiles`
> 清单字段，权限 id 不新增 —— 权限含义是「允许引入 Java 侧代码」，来源不同不改变含义。

### 4.4 `air2.ui` 的方法

`air2.ui` 本身始终存在（基础交互无权限）；下表中需要权限的方法在未授权时**属性不存在**。

| 方法 | 权限 | 说明 |
|---|---|---|
| `ui.register(slot, descriptor)` | `ui.contribute` | 动态注册 slot 组件；descriptor 与 manifest `ui.slots[]` 同构 |
| `ui.override(target, descriptor)` | `ui.override` | 隐藏 / 替换宿主界面；target 见 `PLUGIN-COMPAT.md` 2.2 |
| `ui.openPage(pageId)` | `ui.contribute` | 打开 v3 插件页面 |
| `ui.closePage()` | `ui.contribute` | 关闭当前插件页面 |
| `ui.confirm({ title, message, confirmLabel?, destructive? })` | 无 | 宿主自绘确认框，返回 `true` / `false`；最长等待 60 秒，超时 `false` |
| `ui.promptSecret({ title, message, placeholder? })` | 无 | 宿主自绘安全输入页，返回字符串或 `null`；**插件页面里不允许画密码框** |
| `ui.toast(message)` | 无 | 轻提示，最多 2 行 |

> `ui.promptSecret` 的返回值会进入插件内存。它适合「用户愿意交给插件的 API Key」，
> **不适合**账号密码 —— 宿主不会把账号密码交给插件，插件也不应该索取。

### 4.5 `air2.files` 的方法

`air2.files` 是基础对象：插件自有 token（`air2.paths.pluginData/pluginCache/pluginAsset/tmp`）
的 `list/stat/read/remove` 始终可用；下表中标记权限的方法在未授权时**属性不存在**。

| 方法 | 权限 | 说明 |
|---|---|---|
| `files.list(token)` | token 对应权限 | 列出目录项：`{ name, size, isDir, mtime }`，不含绝对路径 |
| `files.stat(token)` | token 对应权限 | 单文件元数据 |
| `files.read(token, { encoding })` | `files.game.read`（游戏 token）/ 无（插件 token） | `encoding` 为 `"utf8"` 或 `"base64"`；单次 ≤ 8 MB |
| `files.writeGame(token, data, { encoding })` | `files.game.write.config` / `.content` | `data` 为字符串；二进制用 base64 |
| `files.remove(token)` | 对应写权限 | 删除游戏文件或插件文件；游戏文件删除前进备份区 |
| `files.export(token, { suggestedName, mime })` | `files.export` | 交给系统分享面板；插件不能指定落盘路径 |
| `files.copy(fromToken, toToken)` | 两端权限 | 复制；用于整合包解压后落位 |

`encoding` 默认 `"utf8"`。二进制内容一律 base64，避免跨 JSCore 边界传 `ArrayBuffer`
造成「看起来能传、实际类型不稳定」的兼容问题。

### 4.6 `air2.archive` 的方法

| 方法 | 说明 |
|---|---|
| `archive.list(token)` | 列出 zip 条目：`{ name, size, compressedSize, isDir }`；不支持 zip64 / 加密 / 多卷 |
| `archive.extract(token, entryName, destToken, { overwrite })` | 解压单条到目标 token；路径逃逸 → `E_FORBIDDEN_ARG` |
| `archive.create({ format, entries, manifest? })` | 创建临时归档，返回 token。`format` 为 `"zip"` / `"mrpack"`；`entries` 为 `[{ token, name }]`；`mrpack` 会自动写入 `modrinth.index.json`（内容由 `manifest` 提供） |

`archive.create` 只写宿主临时目录，不直接落盘到用户可见位置；要交给用户，必须再走
`files.export`。这样「生成整合包」和「把整合包交给用户」是两个可审计的动作。

### 4.7 `air2.crypto` 的方法

| 方法 | 说明 |
|---|---|
| `crypto.digest(algo, dataOrToken, { encoding })` | `algo` 为 `"sha1"` / `"sha256"` / `"sha512"`；`dataOrToken` 为字符串或文件 token；返回 hex 小写 |
| `crypto.randomBytes(n)` | 返回 base64 字符串；`n` ≤ 64 |

`crypto.digest` 读文件 token 时仍受该 token 的读权限约束；没有权限 → token 不存在。

### 4.8 `air2.download` 的方法

| 方法 | 权限 | 说明 |
|---|---|---|
| `download.addSource(descriptor)` | `download.source` | 追加候选源；与 manifest `contributes.downloadSources` 同构 |
| `download.fetchToFile({ url, destToken, sha256?, maxBytes? })` | `download.fetch` + `network.http` | **异步任务**：立即返回 `jobId`，完成后回调 `onDownloadComplete` |
| `download.cancel(jobId)` | `download.fetch` | 取消任务；已写入的部分文件删除 |
| `download.listJobs()` | `download.fetch` | 当前插件的任务列表 |

下载事件：

```js
onDownloadProgress(jobId, received, total) { /* 节流到 4 次/秒 */ }
onDownloadComplete(jobId, result) {
  // result = { ok, token?, size?, sha256?, error? }
}
```

`fetchToFile` 不阻塞插件队列：宿主在独立下载队列执行，事件回到插件串行队列。
单插件并发 ≤ 3，全局 ≤ 8；单文件 ≤ 512 MB；`sha256` 不匹配 → 删除临时文件并 `ok:false`。

### 4.9 `air2.instance` 的方法

`air2.instance` 的基础元数据面（`list` / `get`）不需要权限；`onBeforeOpen` / `onBeforeEdit`
只在授予 `instance.guard` 后由宿主调用，未授权时插件即使定义回调也不会被调用。

| 方法 | 权限 | 说明 |
|---|---|---|
| `instance.list()` | 无 | 实例元数据：`{ id, name, versionId, loader, lastPlayedAt }`，不含路径 |
| `instance.get(id)` | 无 | 单个实例元数据 |
| `onBeforeOpen(instance)` | `instance.guard` | 返回 `{ allow, message? }`；可调用 `ui.confirm` / `ui.promptSecret` |
| `onBeforeEdit(instance, changes)` | `instance.guard` | 同上；`changes` 是拟修改的字段摘要，不含账号 |

`instance.guard` 只能否决，不能改实例数据。宿主在用户点击「打开 / 编辑」后、真正执行前调用；
超时 60 秒视为允许并记诊断。

---

## 五、`air2.launch` 的硬性边界

这是整个 API 里唯一能影响进程的参数面，规则比其它面严格得多（完整权限表见 `PLUGIN-SECURITY.md`）。

### 5.1 允许的写入

| 方法 | 需要的权限 | 写什么 |
|---|---|---|
| `launch.setProperty(name, value)` | `launch.properties` | `-D<name>=<value>`，`name` 必须以 `fml.` / `forge.` / `neoforge.` / `mixin.` / `fabric.` / `quilt.` / `iris.` / `sodium.` 开头（**前缀白名单**） |
| `launch.addArg(arg)` | `launch.args`（**critical**） | 追加一条裸 JVM 参数（主类之前） |
| `launch.addGameArg(arg)` | `launch.gameArgs`（**critical**） | 追加一条游戏参数（主类之后） |
| `launch.addEnv(name, value)` | `launch.env` | 一条进程环境变量（静态值） |
| `launch.addEnvFromCode(fn)` | `launch.env.code`（**critical**） | 由插件代码在启动时计算出的环境变量 |
| `launch.setTuning(obj)` | `launch.tuning` | 结构化调优项（内存、GC、渲染开关），宿主负责翻译成参数 |
| `launch.addClassPathEntry(p)` | `launch.classpath`（critical） | `-cp` 追加条目 |
| `launch.setLibraryPath(p)` | `launch.libraryPath`（critical） | `-Djava.library.path` |
| `launch.addAgent(...)` | `java.agent`（critical） | `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` |

### 5.2 无论什么权限都禁止的

| 禁止项 | 判据 | 处理 |
|---|---|---|
| `-Dminecraft.api.*.host` | 参数名精确匹配（含 `=` 前的空格式变体） | **直接禁止**，不降级为「需要权限」。这类值决定游戏往哪发认证请求，改它等于拿到 token 的转发权。 |
| 受保护参数 `--gameDir` / `--assetsDir` / `--version` / `--username` / `--uuid` / `--accessToken` | 参数名匹配（`--name` 与 `--name=value` 两种写法都要拦） | 插件**不可写**；宿主在插件之后**统一追加**，且追加的值写在插件参数之后的位置，保证「后出现者生效」的那类 JVM 语义不会让插件覆盖它。 |
| `-Xbootclasspath` / `-Xbootclasspath/a` / `-Xbootclasspath/p` / `--patch-module` | 前缀匹配 | 除 `launch.args` 外**另需** `launch.classpath`；两者都缺 → 拒绝该条参数（不是拒装） |
| 环境变量 `JAVA_TOOL_OPTIONS` / `_JAVA_OPTIONS` / `JDK_JAVA_OPTIONS` / `DYLD_*` / `HOME` / `TMPDIR` / `JAVA_HOME` | 名字精确 / 前缀匹配 | 拒绝该条并记 `plugin-forbidden-env`；这些变量会绕过参数白名单 |
| `eval` 类构造 | 见 3.3 与 6.4 的禁用面 | JSCore 上下文不注入，无从调用 |

### 5.3 追加位置

宿主构建最终命令行时，顺序固定为：

```
[宿主固定 JVM 参数]
  → [插件 JVM 参数（按 5.2 的加载顺序）]
  → [受保护 JVM 参数（宿主统一追加）]
  → [主类]
  → [插件游戏参数（按加载顺序）]
  → [受保护游戏参数（宿主统一追加）]
  → [用户手填参数]
```

「用户手填」排最后，因为用户是权限最高的一方；插件永远排在受保护参数**之前**。
`launch.gameArgs` 只能落在主类之后，不能跨段注入 JVM 参数。

---

## 六、JS 插件的入口与回调

### 6.1 入口文件与回调清单

`manifest.entry` 指向 `entry.js`（包内相对路径）。宿主在 JSCore 上下文里执行它，
脚本必须调用一次**宿主注入的全局函数** `definePlugin(object)`：

```js
definePlugin({
  onLoad()   { /* 上下文就绪，能力已注入 */ },
  onBoot(boot) { /* { bootId, gameDirToken, versionId } */ },
  onVersionList(versions) { /* 返回过滤/标注后的数组 */ },
  onLaunch(req) { /* { versionId, permissions } */ },
  onLaunchResult(result) { /* { ok, exitCode?, durationMs?, error? } */ },
  contribute(ctx) { /* 返回 UI 贡献数组，P3a */ },

  // v3 页面（P3b）
  render(pageId, state) { /* 返回组件树 */ },
  onAction(pageId, actionId, payload, state) { /* 返回新 state 或 { state, toast? } */ },
  onPageOpen(pageId, state) {},
  onPageClose(pageId, state) {},

  // 实例钩子（P4）
  onBeforeOpen(instance) { return { allow: true }; },
  onBeforeEdit(instance, changes) { return { allow: true }; },

  // 下载事件（P4）
  onDownloadProgress(jobId, received, total) {},
  onDownloadComplete(jobId, result) {},

  onUnload() { /* 清理；不要在这里同步做超过 100ms 的事 */ }
});
```

规则：

- 只接受**一个**对象参数；多次调用 → 第二次起抛错（防止两套回调并存）。
- 回调**同步执行**；不要返回 Promise 让宿主等待。需要异步的操作走 `air2.download` 的任务 +
  事件，或下一次回调。
- 所有回调在**该插件的串行队列**上执行，不在主线程。同一插件不会重入；不同插件可并行。
- 宿主把 UI 提交回主线程；插件不能在回调里直接操作 UIKit。
- 回调抛出的异常被宿主捕获 → 记 `[PLUGIN:<id>] error` + 该回调本次失效；**不卸载**插件。
  同一回调连续 3 次抛错 → 卸载并禁用，管理页给原因。

### 6.2 时间预算与超时

| 回调 | 软预算 | 硬超时 | 超时处理 |
|---|---|---|---|
| `onLoad` / `onBoot` | 200 ms | 2 s | 记 `plugin-timeout`，本次回调作废，不卸载 |
| `onVersionList` / `onLaunch` / `onLaunchResult` | 50 ms | 500 ms | 本次贡献作废 |
| `contribute` | 16 ms | 200 ms | 本次贡献作废 |
| `render` | 16 ms | 200 ms | 页面显示错误态，记诊断 |
| `onAction` | 2 s | 10 s | 本次动作作废，页面保留旧 state |
| `onPageOpen` / `onPageClose` | 100 ms | 1 s | 记诊断，不影响页面 |
| `onDownloadProgress` | 16 ms | 200 ms | 丢弃本次进度事件 |
| `onDownloadComplete` | 100 ms | 1 s | 记诊断 |
| `onBeforeOpen` / `onBeforeEdit` | 用户决定 | 60 s | 视为「允许」，记诊断 |
| `onUnload` | 100 ms | 1 s | 强制清理 |

- 「软预算」是诊断阈值：超过记一条 `plugin-budget`，连续 30 次 → 禁用该插件。
- 「硬超时」是宿主主动中断的边界：JSCore 侧中断执行，回调作废。
- `ui.confirm` / `ui.promptSecret` 等待用户时**不算**插件执行时间，但会占住该插件的串行队列
  （同一插件的其它回调排队），最长 60 秒。

### 6.3 序列化边界

跨宿主 / 插件边界只传 JSON 值：`string` / `number` / `boolean` / `null` / `array` / `object`。

- **不传函数**（回调一律走「事件订阅」，不走「传回调」）。
- **不传对象引用**：传过去的对象是**深拷贝**，插件改了不会影响宿主状态。
- **不传 `undefined`**：序列化为 `null` 或省略字段。
- **二进制用 base64 字符串**：不传 `ArrayBuffer` / `Uint8Array`，避免 JSCore 与宿主之间
  的类型桥接差异。
- 数值：只保证 IEEE-754 double 精度；不使用 BigInt。
- 单个回调的返回值 ≤ 1 MB；页面树 ≤ 512 KB；state ≤ 64 KB。

### 6.4 禁用面（JSCore 上下文里不注入）

| 禁用 | 说明 |
|---|---|
| `eval` / `new Function` / `Function.constructor` | 不注入 `eval`（`typeof eval === "undefined"`）；`Function` 构造器指向一个抛 `TypeError` 的桩，`Function.prototype.constructor` 同样被封 |
| `WebAssembly` | 整个对象不注入 |
| `XMLHttpRequest` / `fetch` / `WebSocket` | 不注入；出站一律走 `air2.net`（P4，需 `network.http`） |
| `require` / `import` / `module` / `process` | 不注入（JSCore 无宿主模块系统） |
| DOM / `window` / `document` | 不存在 |
| 定时器 | `setTimeout` / `setInterval` 注入但单插件并发上限 8 个，最小周期 100 ms；`onUnload` 时全部清空 |

---

## 七、v3 页面 API（摘要）

完整契约见 `PLUGIN-PAGE.md`。这里只列 JS 侧入口：

```js
// 动态页面：宿主调用 render 拿组件树
render(pageId, state) {
  return {
    component: "column",
    children: [
      { component: "text.heading", label: { text: "下载器" } },
      { component: "button.primary", label: { text: "开始" },
        action: { id: "start", payload: { kind: "all" } } }
    ]
  };
}

// 动作：返回新 state（宿主会重新渲染：dynamic 调 render，static 重新绑定）
onAction(pageId, actionId, payload, state) {
  if (actionId === "start") {
    return { state: { ...state, running: true }, toast: "已开始" };
  }
  return { state };
}
```

`air2.page` 方法：

| 方法 | 说明 |
|---|---|
| `page.setState(pageId, patch)` | 合并 state 并触发重新渲染（dynamic 调 `render`；static 重新绑定）；用于异步任务回调后更新页面 |
| `page.getState(pageId)` | 读当前 state（深拷贝） |
| `page.open(pageId)` | 打开页面 |
| `page.close()` | 关闭当前页面 |

页面顶部由宿主绘制插件名 + 「插件页面」横幅 + 返回按钮，插件不能隐藏。
页面里不允许 HTML、远程图片、密码框；需要密码 / 密钥时调用 `air2.ui.promptSecret`。

- `type: json` 只能声明 `mode: "static"`，且静态页面没有 manifest `state`。
- `list.itemTemplate` 内的动作必须声明 `itemKey`；宿主把当前行标量放进 `payload.itemKey`，
  插件不要自己覆盖这个保留键。

---

## 八、P5 能力面（先定义，后实现）

| 面 | 契约要点 |
|---|---|
| `air2.native` | 插件 dylib 只能链接宿主给出的 `air2_plugin_abi_v1.h` 符号表；不能访问任何未导出符号；ABI 版本不匹配 → 拒绝装载（不是降级）；仅 `nativePluginsSupported == true` 的设备可用 |
| `air2.webview` | 页面必须走 `air2.webview.load(htmlOrURL)`；禁止 `file://`；与插件 JS 之间**不允许**直接桥（数据经宿主序列化中转） |
| Java agent | 宿主按 `agentFiles` 清单校验哈希后写入 `-javaagent=`；参数格式固定 `=<jar>=<opts>`，`opts` 由宿主 JSON→字符串化 |

---

## 九、版本与废弃

- **API 主版本冻结在 1**。破坏性变更 → 升 `apiVersion` 到 2，宿主同时支持 1 和 2 至少一个大版本。
- 新增能力一律**加**：新对象 / 新方法 / 新字段。旧插件不感知 → 不报错。
- 废弃：字段先标 `@deprecated` 并保留**至少一个大版本**，之后才删。
- 权限 id **永不改名**：改名等于让所有已授权插件静默失权。要改语义就新增 id。
- API 变更必须同时改三处：`PLUGIN-API.md`、`plugin.schema.json`（若涉及 manifest）、
  以及在 `DECISIONS.md` 追加一条 ADR。

---

## 十、错误模型

插件看到的错误只用**一个**类型：`Error`，`message` 是给人看的中文短句，`code` 是稳定字符串。

| code | 场景 | 插件应如何处理 |
|---|---|---|
| `E_INVALID_ARG` | 参数类型/取值不合法 | 修代码 |
| `E_FORBIDDEN_ARG` | 命中了 5.2 的禁止项 | 该条作废，不要重试 |
| `E_NOT_GRANTED` | 权限未授予（通常对象不存在，防御性错误） | 提示用户去管理页授权 |
| `E_BUDGET` | 存储/文件超限 | 自行清理 |
| `E_IO` | 磁盘或序列化失败 | 提示用户 |
| `E_TIMEOUT` | 回调或宿主 API 超时 | 稍后重试或降级 |
| `E_NOT_SUPPORTED` | 宿主不支持该平台/该能力 | 降级 |
| `E_QUOTA` | 下载并发 / 页面节点数 / state 超限 | 减少并发或拆页 |

不对插件暴露：栈帧、宿主内部类名、文件系统绝对路径、其它插件的任何信息。

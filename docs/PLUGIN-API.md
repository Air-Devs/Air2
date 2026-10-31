# Air2 插件 API（v1）

> **状态**：P0 契约。API 主版本 `1`，冻结后只增不改（见第八节）。
> **前提**：宿主是 ObjC 单进程应用（ADR-014），插件运行在宿主进程内的 JSCore 上下文里。
> 因此「沙箱」是**能力注入式**的 —— 不是「给了能力再拒绝调用」，而是**没给的能力对象根本不存在**。

---

## 一、三种运行时层级

| 层级 | 何时可用 | 代码 | 能力面 |
|---|---|---|---|
| **纯 JSON** | P2 | 无（只有 `manifest.json`） | 声明式 UI、元数据装饰、下载源候选 / 版本过滤器（P4） |
| **JS** | P3 | `entry.js`（JSCore） | JSON 全部 + 事件回调 + 按权限开放的宿主能力 |
| **原生** | P5 | `native/ios/*.dylib` | C 接口直连，按 ADR-020 门槛单独审核 |

**纯 JSON 插件能做的事是「声明」，不是「执行」**：它没有 `entry.js`，宿主把 manifest 里的
`ui.slots` / `ui.theme` / `contributes` 读出来直接当数据用。这条边界的意义是：
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
    "minHostVersion": "1.0.0",
    "maxHostVersion": "1.9.9"
  }
}
```

| 字段 | 必填 | 语义 | 不满足时 |
|---|---|---|---|
| `apiVersion` | 是 | 插件使用的 API 主版本。v1 只允许 `1` | 拒装：「需要更新版本的 Air2」（宿主 API 更低）/「插件使用了不支持的 API」（宿主 API 更高且已不兼容 v1） |
| `minHostVersion` | 否 | 宿主版本下限（含） | 拒装：「需要 Air2 ≥ x.y.z」 |
| `maxHostVersion` | 否 | 宿主版本上限（含），**只用于已知不兼容的场景** | 拒装：「插件声明不支持当前 Air2 版本」 |

`apiVersion` 是**主版本号**，不是「API 1.3」这种小版本；小版本内的新增以
「新字段 / 新命名空间」形式出现，旧插件不感知、不报错（见第八节）。

### 2.2 运行时的 `air2.host`（只读视图）

```js
air2.host = {
  apiVersion: 1,            // 宿主实现的 API 主版本
  hostVersion: "2.1.0",     // 宿主版本（semver 字符串）
  platform: "ios",          // "ios" | "android" | "desktop"
  osVersion: "26.0",        // 平台系统版本，供降级判断
  locale: "zh-Hans-CN",     // 当前生效语言（已按 BCP-47 回退链解析后的结果）
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
- 运行时 `air2.host` **一定存在**，即使插件一个权限都没申请。

---

## 三、能力注入（关键契约）

### 3.1 规则

**未授权的 API，在 `air2` 对象上不存在。**

```js
// 插件只申请了 version.decorate：
typeof air2.files          // "undefined"
"files" in air2            // false
Object.keys(air2)          // ["host", "log", "i18n", "version", "storage"]
air2.files                 // undefined（不抛错）
```

### 3.2 为什么是「不存在」而不是「调用时拒绝」

| 方案 | 问题 |
|---|---|
| 运行时拒绝（`throw new Error("permission denied")`） | ① 插件可以先 `try { air2.files.write(...) } catch {}` 探测，把「有没有权限」变成可枚举信息；② 错误信息里必然要写清「缺哪个权限」，等于把权限目录和宿主实现细节泄露给插件；③ 部分插件会用 try/catch 兜住一切，把「确实需要权限才能工作」退化成「静默不工作」，用户看到的是功能消失而不是权限不足。 |
| **加载期能力注入（本方案）** | ① 插件可以在 `onLoad` 第一行就 `if (!air2.files) { air2.log.warn("需要 files 权限"); return; }`，失败前移且可判定；② 权限差异在**对象形状**上可见，调试和测试都能直接断言；③ 宿主不需要在实现里到处塞权限检查（少一类遗漏可能）。 |

### 3.3 注入时机

- 注入发生在**建 JSCore 上下文时**，早于 `entry.js` 第一行执行，之后**不再变化**。
- 不支持「运行期加权限」：用户改授权 → 插件**重新加载**（卸载再加载），拿到新对象。
  这保证「同一个上下文内能力面恒定」，插件可以放心在 `onLoad` 里做一次性分支。

---

## 四、API 面总表

| 对象 | 需要的权限 | 出现阶段 | 说明 |
|---|---|---|---|
| `air2.host` | 无 | P3 | 只读视图，见第二节 |
| `air2.log` | 无 | P3 | `debug/info/warn/error`，统一加 `[PLUGIN:<id>]` 前缀 |
| `air2.i18n` | 无 | P3 | `t(key, params)`，按 `locales/` 回退 |
| `air2.storage` | 无 | P3 | 插件私有键值存储，单键 ≤ 64 KB，总量 ≤ 1 MB |
| `air2.ui` | 见 4.2 | P2（声明）/ P3（注册） | slot 注册、主题 token |
| `air2.version` | `version.decorate` / `version.patch` | P2 / P3 | 版本元数据 |
| `air2.launch` | `launch.*` 系列 | P3 | 启动参数与属性，受第五节严格约束 |
| `air2.files` | `files.game.write.*` | P3 | 游戏目录内的受限写 |
| `air2.net` | `network.http` | P4 | 出站 HTTP，仅 GET/POST，域名白名单 + 出站提示 |
| `air2.download` | `download.source` | P4 | 追加下载源候选 |
| `air2.page` | — | P3 | 整页替换（L2），需在 manifest 声明 `ui.pages` |
| `air2.native` | `native.module` | P5 | 原生模块装载 |
| `air2.webview` | `ui.web` | P5 | 内嵌 WebView 承载页面 |

### 4.1 纯 JSON 插件（无 `air2` 对象）

纯 JSON 插件**没有运行时**，`air2` 对象不存在。它能表达的只有 manifest 里的声明：

| 能力 | manifest 位置 | 权限 | 阶段 |
|---|---|---|---|
| 往 slot 放组件 | `ui.slots[]` | 无（L1） | P2 |
| 主题 token 覆盖 | `ui.theme.tokens` | 无（L1） | P2 |
| 版本显示名 / 副标题装饰 | `contributes.versionDecorate` | `version.decorate` | P2 |
| 下载源候选 | `contributes.downloadSources` | `download.source` | P4 |
| 版本过滤器 | `contributes.versionFilter` | `version.filter` | P4 |

### 4.2 JS 插件额外能做的（`air2.ui` 之外）

- **事件回调**：`onLoad` / `onBoot` / `onVersionList` / `onLaunch` / `onUnload` / `contribute`
  （见第六节）。
- **动态 UI 贡献**：`air2.ui.register(slot, descriptor)` —— 用 JS 计算后再交组件描述，
  相比 JSON 的静态 `ui.slots` 多一层「按数据决定」。
- **启动参数**：`air2.launch.setProperty` / `addArg` / `addEnv` 等，受第五节约束。
- **文件写入**：`air2.files.writeGame`，受 `files.game.write.config` / `.content` 区分。
- **版本补丁**：`air2.version.patchFiles`（`version.patch`，critical）。
- **网络与下载源**：P4 起，`air2.net` / `air2.download`。

### 4.3 P5 才开的三个面

| 面 | 权限 | 门槛 |
|---|---|---|
| `air2.native`（自带 dylib） | `native.module` | 单独审核 + 签名白名单，见 ADR-020 |
| `air2.webview`（内嵌页面） | `ui.web` | 独立 WebView 进程或强隔离（禁 file://、禁 JS 桥直通） |
| Java agent 自挂载 | `java.agent` | 插件自带 agent jar，由宿主按清单挂载并校验哈希 |

> `java.agent` 这个权限 id 在 P2 就存在（用于允许 `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp`），
> P5 的差别只有一点：**jar 由插件自带而不是用户提供**，届时新增 `agentFiles` 清单字段，
> 权限 id 不新增 —— 权限含义是「允许引入 Java 侧代码」，来源不同不改变含义。

---

## 五、`air2.launch` 的硬性边界

这是整个 API 里唯一能影响进程的参数面，规则比其它面严格得多（完整权限表见 `PLUGIN-SECURITY.md`）。

### 5.1 允许的三种写入

| 方法 | 需要的权限 | 写什么 |
|---|---|---|
| `air2.launch.setProperty(name, value)` | `launch.properties` | `-D<name>=<value>`，`name` 必须以 `fml.` / `forge.` / `neoforge.` / `mixin.` / `fabric.` / `quilt.` / `iris.` / `sodium.` 开头（**前缀白名单**） |
| `air2.launch.addArg(arg)` | `launch.args`（**critical**） | 追加一条裸 JVM 参数 |
| `air2.launch.addEnv(name, value)` | `launch.env` | 一条进程环境变量（静态值） |
| `air2.launch.addEnvFromCode(fn)` | `launch.env.code`（**critical**） | 由插件代码在启动时计算出的环境变量 |
| `air2.launch.setTuning(obj)` | `launch.tuning` | 结构化调优项（内存、GC、渲染开关），宿主负责翻译成参数 |
| `air2.launch.addClassPathEntry(p)` | `launch.classpath`（critical） | `-cp` 追加条目 |
| `air2.launch.setLibraryPath(p)` | `launch.libraryPath`（critical） | `-Djava.library.path` |
| `air2.launch.addAgent(...)` | `java.agent`（critical） | `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` |

### 5.2 无论什么权限都禁止的

| 禁止项 | 判据 | 处理 |
|---|---|---|
| `-Dminecraft.api.*.host` | 参数名精确匹配（含 `=` 前的空格式变体） | **直接禁止**，不降级为「需要权限」。这类值决定游戏往哪发认证请求，改它等于拿到 token 的转发权。 |
| 受保护参数 `--gameDir` / `--assetsDir` / `--version` / `--username` / `--uuid` / `--accessToken` | 参数名匹配（`--name` 与 `--name=value` 两种写法都要拦） | 插件**不可写**；宿主在插件之后**统一追加**，且追加的值写在插件参数之后的位置，保证「后出现者生效」的那类 JVM 语义不会让插件覆盖它。 |
| `-Xbootclasspath` / `-Xbootclasspath/a` / `-Xbootclasspath/p` / `--patch-module` | 前缀匹配 | 除 `launch.args` 外**另需** `launch.classpath`；两者都缺 → 拒绝该条参数（不是拒装） |
| `eval` 类构造 | 见 3.3 与 6.3 的禁用面 | JSCore 上下文不注入，无从调用 |

### 5.3 追加位置

宿主构建最终命令行时，顺序固定为：

```
[宿主固定参数] → [插件贡献参数（按 5.2 的加载顺序）] → [受保护参数（宿主统一追加）] → [用户手填参数]
```

「用户手填」排最后，因为用户是权限最高的一方；插件永远排在受保护参数**之前**。

---

## 六、JS 插件的入口与回调

### 6.1 入口文件

`manifest.entry` 指向 `entry.js`（包内相对路径）。宿主在 JSCore 上下文里执行它，
脚本必须调用一次**宿主注入的全局函数** `definePlugin(object)`：

```js
definePlugin({
  onLoad()   { /* 上下文就绪，能力已注入 */ },
  onBoot(boot) { /* { bootId, gameDir, versionId } */ },
  onVersionList(versions) { /* 返回过滤/标注后的数组 */ },
  onLaunch(req) { /* { versionId, availablePermissions } */ },
  contribute(ctx) { /* 返回 UI 贡献数组，P3 */ },
  onUnload() { /* 清理；不要在这里同步做超过 20ms 的事 */ }
});
```

规则：

- 只接受**一个**对象参数；多次调用 → 第二次起抛错（防止两套回调并存）。
- 所有回调都在**主线程**执行，总量预算：`onLoad` ≤ 50 ms，其余单次 ≤ 16 ms。
  超预算不杀插件，但记 `plugin-timeout` 诊断（连续 30 次超预算 → 禁用该插件）。
- 回调抛出的异常被宿主捕获 → 记 `[PLUGIN:<id>] error` + 该回调本次失效；**不卸载**插件。
  同一回调连续 3 次抛错 → 卸载并禁用，管理页给原因。

### 6.2 序列化边界

跨宿主 / 插件边界只传 JSON 值：`string` / `number` / `boolean` / `null` / `array` / `object`。

- **不传函数**（回调一律走「事件订阅」，不走「传回调」）。
- **不传对象引用**：传过去的对象是**深拷贝**，插件改了不会影响宿主状态。
- **不传 `undefined`**：序列化为 `null` 或省略字段。
- 数值：只保证 IEEE-754 double 精度；不使用 BigInt。

### 6.3 禁用面（JSCore 上下文里不注入）

| 禁用 | 说明 |
|---|---|
| `eval` / `new Function` / `Function.constructor` | 不注入 `eval`（`typeof eval === "undefined"`）；`Function` 构造器指向一个抛 `TypeError` 的桩，`Function.prototype.constructor` 同样被封 |
| `WebAssembly` | 整个对象不注入 |
| `XMLHttpRequest` / `fetch` / `WebSocket` | 不注入；出站一律走 `air2.net`（P4，需 `network.http`） |
| `require` / `import` / `module` / `process` | 不注入（JSCore 无宿主模块系统） |
| DOM / `window` / `document` | 不存在 |
| 定时器 | `setTimeout` / `setInterval` 注入但单插件并发上限 8 个，最小周期 100 ms；`onUnload` 时全部清空 |

---

## 七、P5 能力面（先定义，后实现）

| 面 | 契约要点 |
|---|---|
| `air2.native` | 插件 dylib 只能链接宿主给出的 `air2_plugin_abi_v1.h` 符号表；不能访问任何未导出符号；ABI 版本不匹配 → 拒绝装载（不是降级） |
| `air2.webview` | 页面必须走 `air2.webview.load(htmlOrURL)`；禁止 `file://`；与插件 JS 之间**不允许**直接桥（数据经宿主序列化中转） |
| Java agent | 宿主按 `agentFiles` 清单校验哈希后写入 `-javaagent=`；参数格式固定 `=<jar>=<opts>`，`opts` 由宿主 JSON→字符串化 |

---

## 八、版本与废弃

- **API 主版本冻结在 1**。破坏性变更 → 升 `apiVersion` 到 2，宿主同时支持 1 和 2 至少一个大版本。
- 新增能力一律**加**：新对象 / 新方法 / 新字段。旧插件不感知 → 不报错。
- 废弃：字段先标 `@deprecated` 并保留**至少一个大版本**，之后才删。
- 权限 id **永不改名**：改名等于让所有已授权插件静默失权。要改语义就新增 id。
- API 变更必须同时改三处：`PLUGIN-API.md`、`plugin.schema.json`（若涉及 manifest）、
  以及在 `DECISIONS.md` 追加一条 ADR。

---

## 九、错误模型

插件看到的错误只用**一个**类型：`Error`，`message` 是给人看的中文短句，`code` 是稳定字符串。

| code | 场景 | 插件应如何处理 |
|---|---|---|
| `E_INVALID_ARG` | 参数类型/取值不合法 | 修代码 |
| `E_FORBIDDEN_ARG` | 命中了 5.2 的禁止项 | 该条作废，不要重试 |
| `E_BUDGET` | 存储/文件超限 | 自行清理 |
| `E_IO` | 磁盘或序列化失败 | 提示用户 |
| `E_NOT_SUPPORTED` | 宿主不支持该平台/该能力 | 降级 |

不对插件暴露：栈帧、宿主内部类名、文件系统绝对路径、其它插件的任何信息。

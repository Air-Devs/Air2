# Air2 插件作者指南

> 面向要写插件的人。**先读本文，再读** `PLUGIN-API.md`（能调什么）、
> `PLUGIN-SECURITY.md`（权限与授权）、`PLUGIN-PAGE.md`（复杂页面）、
> `PLUGIN-COMPAT.md`（多端与本地化）。
> 机器可读的 manifest 契约是 `plugin.schema.json` —— 它与本文如有冲突，**以 schema 为准**
> （并且那是要修的 bug）。
>
> **v2 变更（2026-10-31）**：不再有官方签名 / 信任等级。Air2 不验证作者身份；
> 安装时由用户逐项授权，critical 权限要连续三次、每次等 5 秒。
> 你不需要生成 `AIR2SIG.json`，也不能把它放进包里（会被拒装）。
>
> **v3 变更（2026-10-31）**：critical 授权**绑定权限集，不绑定包哈希** —— 你更新内容但
> `permissions` 不变时，用户不会再被问一遍；只有新增 / 变更 critical 或 `major` 跨版本才重确认。
> 新增第五节「JSON 插件能做到什么 / 做不到什么」，授权页权限改为按后果分 5 组折叠展示。
> 摘要见 `P0-V3-CHANGELOG.md`。

---

## 一、最短路径

```bash
# 1. 建目录
mkdir -p myplugin/assets/ios myplugin/locales

# 2. 写 manifest.json（下面第三节逐字段讲）

# 3. 生成 files 清单（每个文件的 sha256 + size）
python3 - <<'PY'
import hashlib, json, pathlib
root = pathlib.Path('.')
files = []
for p in sorted(root.rglob('*')):
    if p.is_dir():
        continue
    if p.name == 'manifest.json' or p.name.endswith('.air2plugin'):
        continue
    b = p.read_bytes()
    files.append({"path": p.as_posix(), "sha256": hashlib.sha256(b).hexdigest(), "size": len(b)})
print(json.dumps(files, ensure_ascii=False, indent=2))
PY

# 4. 打包（-X 去掉扩展字段，保证不同机器打包的产物可比）
zip -X -r ../myplugin.air2plugin . -x '.DS_Store' -x '__MACOSX/*'
```

装进 Air2：管理页「导入插件」→ 选 `.air2plugin` → 看安装详情 → 逐项授权 → 安装。

> 第一次做插件，建议直接抄第四节「纯 JSON 插件」；它能跑通导入、授权、slot 渲染，
> 再往上加 JS 与页面。

---

## 二、目录结构

```
myplugin/
├── manifest.json           # 必须，包根，UTF-8 无 BOM
├── entry.js                # type=js 必须有
├── pages/
│   └── downloads.json      # v3 可选：静态页面树（必须在 files 清单里）
├── ui/theme.json           # 可选（自定附加数据，必须在 files 清单里）
├── assets/
│   ├── common/             # 平台无关
│   └── ios/                # 覆盖 common 同名文件
├── locales/
│   ├── zh-Hans.json
│   └── en.json
├── schematics/             # 可选：.schem / .litematic 等蓝图
└── native/                 # ❌ formatVersion 2 不允许；P5 v3 才允许
```

四条硬规则，违反了安装器会直接拒装：

1. `manifest.json` 在**包根**，不在子目录。
2. `manifest.files` 与「包内实际文件（除 `manifest.json`）」**双向相等**：
   多一个文件是夹带，少一个文件是清单说谎。
3. **不要**放 `AIR2SIG.json`。签名机制已移除；包根出现它即拒装（`E_LEGACY_SIGNATURE`）。
4. `native/` 出现在 v2 包里 → 拒装（原生插件属 P5，且仅 TrollStore / 越狱设备）。

---

## 三、manifest 字段逐项说明

### 3.1 顶层

| 字段 | 必填 | 类型 | 说明 | 常见错误 |
|---|---|---|---|---|
| `formatVersion` | ✅ | `2` \| `3` | 包格式版本。简单 slot 用 2；页面 / 覆盖 / native 用 3 | 写 `"2"`（字符串）/ 写 `1` |
| `id` | ✅ | string | 全局唯一，建议反向域名；`^[a-z0-9]+(\.[a-z0-9][a-z0-9_-]*)+$` | 用大写、用空格、只有一段（`hello` 不行，要 `top.you.hello`） |
| `name` | ✅ | string ≤64 | 展示名（本地化缺失时的回退） | 塞一长串说明 |
| `version` | ✅ | string | 语义化版本 `1.2.3` / `1.2.3-beta.1` | 写 `v1.2.3`、写 `1.2` |
| `type` | ✅ | `json` \| `js` | `json` 无运行时；`js` 有 `entry.js` | 写 `native`（不是 v2 的 type 值） |
| `description` | — | string ≤512 | 管理页一句话说明 | 写成 README |
| `author` | — | object | `{ name, url? }`；**作者自述，不是身份认证** | 以为写了就是「官方」 |
| `homepage` | — | string | `http(s)://` 开头 | 写相对路径 |
| `license` | — | string | SPDX（`MIT`、`GPL-3.0-only`）或 `FreeText:…` | — |
| `air2` | ✅ | object | 见 3.2 | 漏写 |
| `platforms` | ✅ | array | `ios` / `android` / `desktop`，非空 | 写 `common`（**不是合法值**） |
| `permissions` | — | array | 见 3.3，缺省 `[]` | 申请了用不到的权限（用户会看到更吓人的授权页） |
| `depends` | — | array | `[{ id, version }]`，版本约束 `>=x.y.z` / `^x.y.z` / `~x.y.z` / `x.y.z` | 写 `>=1.0`（必须三段） |
| `entry` | type=js 必填 | string | 入口脚本包内路径 | `type:json` 却写了 `entry`（schema 会拒） |
| `ui` | — | object | 见 3.4 | — |
| `contributes` | — | object | 见 3.5 | — |
| `locales` | — | object | BCP-47 → 文件路径 | 键写 `zh_CN`（要用连字符 `zh-Hans`） |
| `files` | ✅ | array | 见 3.6 | 手工填写漏文件（用第一节脚本生成） |
| `native` | — | object | P5：`{ "ios": "native/ios/x.dylib" }`；v2 不允许 | 在 v2 包里写 native |

### 3.2 `air2.host`（对宿主的要求）

```json
"air2": { "host": { "apiVersion": 1, "minHostVersion": "0.1.0" } }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `apiVersion` | ✅ | 只能是整数 `1`。表示「我用的是 API v1」。 |
| `minHostVersion` | — | 宿主版本下限（含）。**当前宿主是 0.1.0**；不要照抄旧文档的 `2.0.0`，会直接拒装。 |
| `maxHostVersion` | — | 宿主版本上限（含）。**只用于已确认不兼容的场景**，正常别填（填了就永远要维护它）。 |

> 不要和运行时的 `air2.host` 混淆：manifest 里这个是「我要什么样的宿主」，
> 运行时那个是「我面对的是什么样的宿主」（只读，含 `uiCapabilities`）。
> 详见 `PLUGIN-API.md` 第二节。

### 3.3 `permissions`

按需申请，**多申请一项就会在授权页多一条条款**。低/中默认开启、用户可逐项关掉；
critical 默认关闭，用户必须逐项走三次 5 秒确认。没有「签名后自动全给」这回事。

| 权限 | 风险 | 你什么时候需要它 |
|---|---|---|
| `ui.contribute` | 低 | 往 slot 放组件、覆盖主题、注册页面 |
| `version.decorate` | 低 | 改版本列表的标题/副标题/徽标/图标（只影响展示） |
| `version.filter` | 低 | 按规则隐藏/置灰版本（P4） |
| `launch.properties` | 中 | 写 `-Dfabric.*` / `-Dmixin.*` 这类带前缀的属性 |
| `launch.tuning` | 中 | 结构化调内存/GC/渲染开关 |
| `launch.env` | 中 | 静态设置进程环境变量 |
| `files.game.read` | 中 | 读 `options.txt` / `config/**` / `logs/**` / 存档 / mods 与资源包内容（P4） |
| `files.game.write.config` | 中 | 改 `options.txt` / `config/**` |
| `files.export` | 中 | 把文件交给系统分享面板导出（P4） |
| `download.source` | 中 | 追加下载镜像候选（P4） |
| `download.fetch` | 中 | 由插件发起下载任务（P4，需同时申请 `network.http`） |
| `network.http` | 中 | 出站 HTTP（P4） |
| `ui.override` | 中 | 隐藏 / 替换宿主界面、整页替换、`launch.overlay` 扩展（P3b） |
| `instance.guard` | 中 | 打开/编辑实例前做检查（P4） |
| `launch.args` | **critical** | 追加裸 JVM 参数 |
| `launch.gameArgs` | **critical** | 追加游戏主类之后的参数（`--server` / `--width` 等） |
| `launch.env.code` | **critical** | 启动时用代码算环境变量 |
| `launch.classpath` | **critical** | 往 `-cp` 里加东西 |
| `launch.libraryPath` | **critical** | 改 `-Djava.library.path` |
| `java.agent` | **critical** | `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` |
| `files.game.write.content` | **critical** | 写 `mods/*.jar` / 资源包 / 存档 / 蓝图 |
| `version.patch` | **critical** | 改版本目录内容（补丁文件、`version.json` 副本） |
| `native.module` | **critical** | 自带 dylib（P5，仅 TrollStore / 越狱） |
| `ui.web` | **critical** | 内嵌 WebView（P5） |

`type: json` 只能申请 `version.decorate` / `download.source` / `version.filter` /
`ui.contribute` / `ui.override`（没有运行时，其它权限给了也用不上 —— schema 会直接拒）。
能力边界见第五节。

**授权绑定的是权限，不是包字节**：更新内容时只要 `permissions` 不变、`major` 不变，用户的
critical 授权继续有效，**不会**再弹三次确认；只有新增 / 变更 critical 或 `major` 变化才重确认。
所以**不要**为了让用户「再看一眼」特意加一个权限或抬 `major` —— 那只会造成授权疲劳，
也不会带来任何额外的安全收益。

**降级要求**：每个权限都可能被用户关掉。你的插件必须在 `onLoad` / `render` 里判断
`typeof air2.xxx === "undefined"`，然后：
- 隐藏对应按钮 / 显示「需要授权」提示；
- 不要反复弹授权页（宿主没有「插件请求授权」的 API）；
- 不要把「没授权」当成错误崩溃。

### 3.4 `ui`

v2（slot + 主题）：

```json
"ui": {
  "priority": 10,
  "slots": [
    {
      "slot": "home.toolbar.action",
      "component": "button.primary",
      "icon": "action.download",
      "label": { "i18n": "action.downloadAll" },
      "action": "download_all",
      "priority": 5
    }
  ],
  "theme": { "tokens": { "color.accent": "#7C4DFF" } }
}
```

| 字段 | 说明 |
|---|---|
| `priority` | 加载顺序权重，`-1000..1000`，越小越先。同值按层、再按 `pluginId` 字典序（保证每次启动顺序一致） |
| `slots[]` | 往宿主预留位置放组件。`slot` / `component` 是**枚举**（见 `PLUGIN-COMPAT.md` 2.2/2.3），写平台控件名会被拒 |
| `slots[].icon` | **语义图标 ID**（`action.download`），不是图片路径；不认识的 ID 渲染成 info 图标，不拒载 |
| `slots[].label` | `{ "i18n": "key" }` 或 `{ "text": "字面量" }`，二选一 |
| `slots[].action` | 字符串或 `{ id, payload }`；JS 插件在 `onAction` 里接，纯 JSON 插件只能用宿主内置动作 |
| `slots[].visibleWhen` | 单条条件，如 `{ "binding": "state.ready", "equals": true }` |
| `theme.tokens` | 主题 token 覆盖，L1 层。未知 token 忽略 + 诊断，不拒载 |

v3（页面 / 覆盖）见 `PLUGIN-PAGE.md`：

```json
"ui": {
  "pages": [
    {
      "id": "downloader",
      "slot": "home.page",
      "title": { "i18n": "page.downloader" },
      "icon": "action.download",
      "mode": "dynamic"
    }
  ],
  "overrides": [
    { "target": "versions.list", "mode": "replace", "page": "myversions" }
  ]
}
```

- `mode: "dynamic"` 只能用于 `type: "js"`；纯 JSON 插件只能用 `mode: "static"`（`root` 或 `source`）。
- 纯 JSON 插件没有运行时 state，静态页面的绑定只会得到空值；文案请用 `{ "text": ... }` 字面量。
  JS 插件仍可在 `onPageOpen` / `setState` 里给静态页面 state。
- 需要按数据渲染、响应点击的页面，必须写 JS 插件，见第七节。

### 3.5 `contributes`（数据层）

| 字段 | 需要权限 | 说明 |
|---|---|---|
| `versionDecorate` | `version.decorate` | `titleTemplate` / `subtitleTemplate` / `badge` / `icon`；只影响展示，宿主仍保存「真实名」 |
| `downloadSources` | `download.source`（P4） | `[{ name, urlTemplate, priority? }]`，**只能追加候选**，不能改引擎顺序 |
| `versionFilter` | `version.filter`（P4） | `hidePatterns` / `pinPatterns`，只影响展示与选择，不删文件 |

### 3.6 `files`

```json
"files": [
  { "path": "entry.js", "sha256": "0f1e…", "size": 512 },
  { "path": "locales/zh-Hans.json", "sha256": "9ab3…", "size": 96 }
]
```

- `path` 是包内相对路径（POSIX 分隔符），`sha256` 是小写 hex，`size` 是字节数。
- **不要**把 `manifest.json` 列进来。
- **不要**把 `AIR2SIG.json` 列进来，也不要放这个文件。
- 清单外的文件一律让整包拒装（包根的 README / LICENSE 也一样：不打进包就不用管）。
- `files: []` 是合法的：一个只有 `manifest.json` 的包能装上（schema 的 `minItems` 为 0），
  适合先占个 id、内容后续版本再加。

---

## 四、示例 1：纯 JSON 插件（最小可用）

一个在首页卡片上放状态徽标、并给版本列表加副标题的插件。**没有一行代码**。
纯 JSON 插件也可以加静态页面，但**不能**声明 `mode: "dynamic"`（那需要 JS `render`）。

### `manifest.json`

```json
{
  "formatVersion": 2,
  "id": "top.example.hello",
  "name": "Hello 徽标",
  "version": "1.0.0",
  "type": "json",
  "description": "在首页卡片右上角放一个「就绪」徽标，并给版本列表加一句副标题。",
  "author": { "name": "示例作者" },
  "license": "MIT",
  "air2": { "host": { "apiVersion": 1, "minHostVersion": "0.1.0" } },
  "platforms": ["ios"],
  "permissions": ["ui.contribute", "version.decorate"],
  "ui": {
    "priority": 0,
    "slots": [
      {
        "slot": "home.card.badge",
        "component": "badge.status",
        "label": { "i18n": "badge.ready" },
        "priority": 10
      }
    ],
    "theme": { "tokens": { "color.accent": "#7C4DFF" } }
  },
  "contributes": {
    "versionDecorate": {
      "subtitleTemplate": "由 Hello 插件标注",
      "badge": { "i18n": "badge.example" }
    }
  },
  "locales": {
    "zh-Hans": "locales/zh-Hans.json",
    "en": "locales/en.json"
  },
  "files": [
    { "path": "locales/en.json", "sha256": "<用脚本生成>", "size": 78 },
    { "path": "locales/zh-Hans.json", "sha256": "<用脚本生成>", "size": 74 }
  ]
}
```

### `locales/zh-Hans.json`

```json
{
  "badge.ready": "就绪",
  "badge.example": "示例"
}
```

### `locales/en.json`

```json
{
  "badge.ready": "Ready",
  "badge.example": "Example"
}
```

要点：

- `type: json` → 不能写 `entry`（schema 会拒）。
- 纯 JSON 也能申请 `ui.contribute` / `ui.override`，因为 slot / 页面是声明式的。
- 徽标文字走 `i18n` 而不是 `text`，否则英文用户看到中文。

---

## 五、JSON 插件能做到什么 / 做不到什么

`type: json` 是给「不想写代码也要交付插件」的人准备的。它的边界是**静态**：
宿主只读 JSON 文件，不做任何计算、不执行任何东西。

### 5.1 能做到

| 能做到 | 怎么做到 | 阶段 |
|---|---|---|
| 静态展示：图标、标题、副标题、徽标、主题色、组件布局 | `ui.slots`（叶子组件）/ `ui.theme` / `pages/*.json` 的静态树 | P2（页面 P3b） |
| 声明式动作：关页面、打开本插件另一个页面、回到宿主原列表、重试、复制文本 | 页面节点上的 `action`，只能用 `host.*`（`host.close` / `host.openPage` / `host.showOriginal` / `host.retry` / `host.copy`） | P3b |
| 静态过滤：按**固定字符串规则**隐藏 / 置顶版本 | `contributes.versionFilter` 的 `hidePatterns` / `pinPatterns`（各 ≤ 32 条字符串模式） | P4 |
| 版本显示装饰：名字、副标题、徽标、图标 | `version.decorate` | P2 |
| 追加下载镜像候选（静态 URL 模板） | `download.source` | P4 |
| 多语言文案 | `locales/<lang>.json` | P2 |
| 固定文案与固定值 | 组件里的字面量 `{ "text": "…" }`、`value` | P2 |

### 5.2 做不到

| 做不到 | 为什么 | 需要什么 |
|---|---|---|
| 动态计算（拼字符串、算百分比、求和、格式化日期） | 没有表达式求值器；JSON 里没有运算节点 | `type: js`（P3a） |
| 循环 / 按数据展开列表 | 组件树是静态写死的，没有循环节点 | `type: js` + `render`（P3b） |
| 异步（网络请求、等回调、定时器） | 没有执行环境，JSON 不能持有回调 | `type: js`（P3a） |
| 状态机（多步流程、记住上次点击、撤销） | 变量在页面里，JSON 没有可变状态 | `type: js`（P3a） |
| 按数据条件显隐 | `visibleWhen` 读的是 binding，纯 JSON 页面的 binding 恒为空值，条件永远按「不满足」处理 | `type: js`（P3a/P3b） |
| 读取宿主/游戏数据并显示 | 纯 JSON 没有运行时，`binding` 只会得到 `null`（`PLUGIN-PAGE.md` 第二节） | `type: js` |
| 读写文件、改启动参数、注入 agent、发网络请求 | 这些是 API 调用，不是声明 | `type: js` + 对应权限（多为 critical） |
| HTML / 内联脚本 / WebView / 远程图片 | 硬禁，不是权限问题 | 不存在（P5 的 `ui.web` 也只是宿主控制的 WebView） |

### 5.3 怎么选中了错类型

**一句话判据**：如果你在 JSON 里「想办法算点什么」、「想办法让它按数据变」，这个插件就不该是 `json`。

- 症状 1：写了一大堆只有文案不同的静态页面，想模拟「按状态显示不同内容」→ 该用 `js` + `render`。
- 症状 2：想把 `version.list` 里的字段引用到组件上 → 纯 JSON 页面的 binding 是空值，看不到数据。
- 症状 3：想在按钮里做「先检查再执行」→ 没有回调，只能声明 `host.*` 动作。

正确的拆法是「静态部分留 JSON、计算放 JS」：`type: js` 的插件也能用
`mode: "static"` 的页面，把布局写成 JSON，只在需要算的地方调 `air2.page.setState`。

> `type: json` 申请运行时权限（`launch.*` / `files.*` / `network.http` / `java.agent` / `native.module`）
> 会被 schema **直接拒装**，不是「装了之后没效果」。

---

## 六、示例 2：JS 插件（最小可用）

启动时设置内存调优，并把自己启动过的次数写进私有存储。

### `manifest.json`

```json
{
  "formatVersion": 2,
  "id": "top.example.bootcount",
  "name": "启动计数",
  "version": "0.1.0",
  "type": "js",
  "description": "记录启动次数，并按设备内存设置堆上限。",
  "author": { "name": "示例作者" },
  "license": "MIT",
  "air2": { "host": { "apiVersion": 1, "minHostVersion": "0.1.0" } },
  "platforms": ["ios"],
  "permissions": ["launch.tuning"],
  "ui": { "priority": 100 },
  "entry": "entry.js",
  "files": [
    { "path": "entry.js", "sha256": "<用脚本生成>", "size": 640 }
  ]
}
```

### `entry.js`

```js
definePlugin({
  onLoad() {
    // 能力注入：没有授予 launch.tuning 时，air2.launch 根本不存在
    if (!air2.launch) {
      air2.log.warn("未授予 launch.tuning，跳过调优");
      return;
    }

    air2.launch.setTuning({ maxHeapMB: 2048, gc: "g1" });

    const n = air2.storage.get("boots") || 0;
    air2.storage.set("boots", n + 1);
    air2.log.info("累计启动 " + (n + 1) + " 次（宿主 " + air2.host.hostVersion + "）");
  },

  onBoot(boot) {
    air2.log.info("bootId=" + boot.bootId + " version=" + boot.versionId);
  },

  onUnload() {
    air2.log.info("bye");
  }
});
```

要点：

- **用 `typeof` / 真值判断能力，不要用 try/catch 猜权限**：权限不足时对象不存在，
  `try { air2.launch.addArg() } catch {}` 这种写法在能力注入下只会得到
  `TypeError: undefined is not an object`，而且掩盖了「我需要权限」这件事。
- 回调在**该插件的串行队列**上跑，不在主线程：`onLoad` ≤ 200 ms，`render` ≤ 16 ms，
  `onAction` ≤ 2 s。超了不杀你，但会记诊断。
- `entry.js` 里**没有** `require` / `import` / `fetch` / `eval` / `WebAssembly` —— 它们不存在。
- 回调参数是**深拷贝**的普通 JSON 值，改它不会影响宿主。
- 需要异步（下载、网络）用宿主任务 + 事件，不要返回 Promise 让宿主等。

---

## 七、示例 3：v3 动态页面

一个「下载器」页面：显示列表、按钮点击后更新状态。动态页面必须 `type: "js"`；
纯 JSON 插件做不了这一节。

### `manifest.json`（片段）

```json
{
  "formatVersion": 3,
  "type": "js",
  "permissions": ["ui.contribute"],
  "entry": "entry.js",
  "ui": {
    "pages": [
      {
        "id": "downloader",
        "slot": "home.page",
        "title": { "i18n": "page.downloader" },
        "icon": "action.download",
        "mode": "dynamic"
      }
    ]
  }
}
```

### `entry.js`（片段）

```js
definePlugin({
  render(pageId, state) {
    return {
      component: "column",
      children: [
        { component: "text.heading", label: { text: "可下载内容" } },
        { component: "progress.linear", binding: "state.progress" },
        {
          component: "list",
          items: "state.items",
          itemTemplate: {
            component: "list.row",
            binding: "item.name",
            action: { id: "pick" },
            itemKey: "item.id"
          }
        },
        {
          component: "button.primary",
          label: { text: "刷新" },
          action: "refresh"
        }
      ]
    };
  },

  onAction(pageId, actionId, payload, state) {
    if (actionId === "refresh") {
      return { state: { ...state, progress: 0.2 }, toast: "刷新中" };
    }
    if (actionId === "pick") {
      return { state: { ...state, selected: payload.itemKey } };
    }
    return { state };
  },

  onPageOpen(pageId, state) {
    air2.log.info("打开页面 " + pageId);
  }
});
```

要点：

- `render` 返回**组件树**，不是 HTML；页面 chrome（标题、返回、插件名、横幅）由宿主画。
- `binding` 只读；输入类组件通过 `action` 上报，不要试图直接改 `state`。
- 页面树上限：节点 ≤ 500、深度 ≤ 12、state ≤ 64 KB。
- 页面里**不能**画密码框；需要密钥用 `air2.ui.promptSecret`。
- 页面里**不能**放远程图片；图片用 `image.asset` 指向包内 `assets/**`。

---

## 八、导出整合包（mrpack / zip）

P4 起，插件可以用 `air2.files` + `air2.archive` 做整合包导出。典型流程：

```js
// 1. 读游戏目录里的 mods / config（需要 files.game.read）
const mods = air2.files.list(air2.paths.gameRead("mods"));

// 2. 生成 mrpack 的 modrinth.index.json（由插件构造）
const index = {
  formatVersion: 1,
  game: "minecraft",
  versionId: "1.20.1",
  name: "My Pack",
  files: mods
    .filter((m) => !m.isDir && m.name.endsWith(".jar"))
    .map((m) => ({
      path: "mods/" + m.name,
      hashes: { sha1: air2.crypto.digest("sha1", air2.paths.gameRead("mods/" + m.name)) },
      downloads: ["https://example.com/mods/" + m.name],
      fileSize: m.size
    })),
  dependencies: { minecraft: "1.20.1", "fabric-loader": "0.15.0" }
};

// 3. 建归档（临时 token）
const mrpack = air2.archive.create({
  format: "mrpack",
  manifest: index,
  entries: mods.map((m) => ({
    token: air2.paths.gameRead("mods/" + m.name),
    name: "mods/" + m.name
  }))
});

// 4. 交给系统分享面板（需要 files.export）
air2.files.export(mrpack, { suggestedName: "MyPack.mrpack", mime: "application/x-modrinth-modpack+zip" });
```

zip 版只需把 `format` 改成 `"zip"`：

```js
const zip = air2.archive.create({ format: "zip", entries: [...] });
air2.files.export(zip, { suggestedName: "MyPack.zip", mime: "application/zip" });
```

规则：

- `archive.create` 只写宿主临时目录；**必须**再走 `files.export` 才能交给用户。
- `mrpack` 的 `modrinth.index.json` 由插件提供；宿主只负责打包与导出，不猜你的整合包结构。
- 导出前宿主会展示文件清单与总大小；单次 ≤ 512 MB。
- `files.export` 走系统分享面板，插件不能指定任意落盘路径。

---

## 九、授权：用户会看到什么

这一节决定你的插件「装得上但没人敢用」还是「用户愿意授权」。

### 9.1 低 / 中权限

- 安装页默认**开启**，逐条列出，用户可以关掉。
- 升级时沿用；新增的低/中权限会在更新页列出并默认开启。
- 你不需要做任何额外事，但**要在 `description` 里写清楚为什么需要**。

### 9.2 critical 权限

- 默认**关闭**；用户必须逐项点「授权」，连续三次提示框，每次等 5 秒才能继续。
- 第 1 次讲「能做什么」；第 2 次讲「可能造成什么危害」；第 3 次最终确认。
- 授权绑定 `(pluginId, permissionId)`，**不绑定包哈希**：内容更新（`packageHash` 变）但
  `permissions` 不变 → **不重确认**，更新页只显示「内容已更新，权限未变」。
- 只有这几种情况会重新弹三次：**新增 critical**（只弹新增项）、**中风险升为 critical**、
  **`major` 跨版本**（全部 critical 重弹，无论权限集是否变化）。
- **缩小权限集是安全的**：删掉一个 critical，宿主自动撤销该授权、不弹窗；用户不会因此重审。
- 用户拒绝某个 critical 权限时，插件仍然安装；你必须降级运行，不能崩。

### 9.3 权限会怎么分组显示

安装页不会把你申请的 24 项权限平铺成一列，而是按**后果**归为 5 组，**默认折叠**：

| 组标题（用户看到的） | 收纳的权限 |
|---|---|
| **改游戏文件** —— 能修改游戏内容（等同直接装 mod，可执行代码） | `files.game.write.content`、`files.game.write.config`、`version.patch` |
| **联网** —— 能把数据发到网上 / 从网上下载东西 | `network.http`、`download.source`、`download.fetch`、`ui.web` |
| **读你的数据** —— 能查看你的游戏文件与配置 | `files.game.read`、`files.export` |
| **启动参数** —— 能改游戏如何启动（可注入代码） | `launch.args`、`launch.gameArgs`、`launch.classpath`、`launch.libraryPath`、`launch.env`、`launch.env.code`、`launch.properties`、`launch.tuning`、`java.agent`、`native.module` |
| **改界面** —— 能改启动器看起来的样子 | `ui.contribute`、`ui.override`、`version.decorate`、`version.filter`、`instance.guard` |

对你的影响：

1. **组标题不写你的插件名，也不写权限 id**，写后果。所以你的 `description` 不要重复
   「需要启动参数权限」，而要写「为什么要改启动参数」。
2. **组内逐条仍显示人话后果**（`PLUGIN-SECURITY.md` 第九节），用户点开就能看到具体到每条的能力。
3. **多申请一项 = 多一条可见条目**，还可能把你的插件从「低危组」拖进「含高危」的组。少申请就是更好的说明。
4. 分组只是展示，**不会**因此给你「整组授权」的便利；用户仍然逐项确认。

### 9.3 作者该做的

1. **最小权限**：能不用 critical 就不用。比如「改配置」用 `files.game.write.config`，
   不要为了省事申请 `files.game.write.content`。
2. **写清用途**：`description` 里一句话说明每个 critical 权限为什么必需。
3. **可降级**：没授权时隐藏功能，显示「需要授权」；不要反复弹窗。
4. **不要伪装官方**：`name` / `author` / 图标不要冒充 Air2 官方；安装页会标「作者自述」。
5. **发布哈希**：在发布页写 `packageHash`，用户导入后可以对照。

### 9.4 没有签名

- 不要生成 `AIR2SIG.json`；它会被拒装。
- 没有「签名后 critical 自动可授」这回事；每个用户、每个包哈希都要自己确认。
- Air2 不验证作者身份。用户只能看来源、作者自述、包哈希与权限说明。
  这是 ADR-021 的明确取舍。

---

## 十、打包

```bash
cd myplugin
zip -X -r ../bootcount.air2plugin . -x '.DS_Store' -x '__MACOSX/*'
```

- `-X`：不写额外字段（时间戳类的元数据会破坏「同内容同哈希」的可比性）。
- **必须从插件目录内部打包**（`manifest.json` 要落在压缩包根，而不是 `myplugin/manifest.json`）。
- 不要 zip64 / 加密 / 多卷；不要符号链接。
- 打包前用 schema 验一遍：

```bash
python3 -c "
import json, jsonschema
s = json.load(open('path/to/docs/plugin.schema.json'))
m = json.load(open('myplugin/manifest.json'))
jsonschema.validate(m, s); print('manifest ok')
"
```

> 仓库/CI 没有内置 JSON Schema 库时，P1 会提供手写语义校验器 + fixtures；
> 作者侧仍建议用 `jsonschema` 自查。

---

## 十一、调试

| 手段 | 说明 |
|---|---|
| 管理页「插件诊断」 | 逐插件显示：层级、加载状态、最近 stage、被禁用原因、权限授予明细 |
| 宿主日志 | 所有插件日志带 `[PLUGIN:<id>]` 前缀；看起来像 token 的串会被替换成 `<redacted>` |
| `air2.log.warn/error` | 出现在诊断页的「最近事件」里 |
| 开发模式（P4） | 从本地目录直载插件，不写正式注册表，允许降级；**授权流程不变**（critical 仍三次 5 秒） |
| 完整性检查 | 管理页手动按钮，做全量哈希比对 |

**不要**为了调试去改 `Plugins/` 目录下的文件：加载期会验 `manifest.json` / `entry.js` /
`ui/**` / `pages/**` / `native/**` 的哈希，改了会被判 `tampered` 并拒绝加载。走开发模式。

---

## 十二、常见拒装原因

| code | 原因 | 怎么修 |
|---|---|---|
| `E_MANIFEST_MISSING` | 包根没有 `manifest.json` | 从插件目录内部打包 |
| `E_SCHEMA` | manifest 不符合 `plugin.schema.json` | 按报错字段改；注意 `additionalProperties: false`，拼错的字段也算错 |
| `E_FORMAT_VERSION` | `formatVersion` 不是 2/3，或 v2 宿主读到 v3 | v2 宿主只收 v2；页面/覆盖/native 要 v3 |
| `E_PATH_ESCAPE` | 包里有 `..`、绝对路径、符号链接 | 重新打包，别手工塞条目 |
| `E_SIZE_LIMIT` | 超包体/解压/文件数/单文件上限 | 裁资源（见 `PLUGIN-SYSTEM.md` 3.3） |
| `E_FILE_SET_MISMATCH` | `files` 清单与实际文件不一致 | 用第一节脚本重新生成 |
| `E_HASH_MISMATCH` | 文件内容与 `sha256` 不符 | 重新生成清单（打包后又改过文件） |
| `E_PLATFORM` | `platforms` 不含当前平台 | 加 `ios` |
| `E_TYPE_UNSUPPORTED` | 宿主阶段不支持该插件类型（P1/P2 装 `type: js`） | 等 P3a，或改写成纯 JSON 插件 |
| `E_LEGACY_SIGNATURE` | 包根有 `AIR2SIG.json` | 删除；签名机制已移除 |
| `E_PERM_CONFLICT` | 命中组合拒装规则（如 `launch.args` + `java.agent`） | 见 `PLUGIN-SECURITY.md` 4.1；拆成两个插件也没用 —— 改成不申请其中一个 |
| `E_JSON_PERM` | `type: json` 申请了运行时权限 | 改成 `js`，或去掉该权限 |
| `E_DEP_MISSING` / `E_DEP_CYCLE` | 依赖缺失 / 循环依赖 | 补依赖或去掉 `depends` |
| `E_SLOT_CONFLICT` | L2 独占 slot 已被占用 | 换 slot 或改用 L1 |
| `E_NATIVE_UNSUPPORTED` | v2 包里出现 `native/`，或设备不支持 | 去掉；原生插件属 P5 + TrollStore/越狱 |
| `E_DOWNGRADE` | 装的是低于已装版本的包 | 默认不允许；开发者模式可放行 |
| `E_SAME_VERSION_DIFFERENT_CONTENT` | 同版本但内容变了 | 升 `version` 再打包 |
| `E_PAGE_INVALID` | v3 页面树不合法（节点超限 / 绑定路径错 / 容器嵌套错） | 按 `PLUGIN-PAGE.md` 检查 |
| `E_BINDING_INVALID` | `binding` 不是 `state.*` / `item.*` | 改绑定路径 |
| `E_ACTION_UNKNOWN` | 纯 JSON 插件用了宿主不认识的动作 | 纯 JSON 只能用内置动作；复杂交互改 `js` |

### 机器码对照（管理页显示的就是这一列）

上表是**归类**用的文档码；管理页与安装失败详情里显示的是**机器码**
（`A2PluginErrorCodeString()`）。两者可能不同 —— 本表是唯一口径，代码里有新码就必须在这里加一行：

| 文档码 | 机器码（实际报出来的） |
|---|---|
| `E_MANIFEST_MISSING` | `E_MANIFEST_MISSING` |
| `E_SCHEMA` | `E_FORMAT`（JSON 整体不成立）/ `E_FIELD`（字段层）/ `E_PERM_UNKNOWN`（权限 id 不在目录里） |
| `E_FORMAT_VERSION` | `E_FORMAT_VERSION` |
| `E_PATH_ESCAPE` | `E_PATH_ESCAPE`（zip 条目跑出包目录）/ `E_LINK`（符号链接条目）/ `E_PATH`（manifest 里的路径字符集或 `..`） |
| `E_SIZE_LIMIT` | `E_SIZE` |
| `E_TYPE_UNSUPPORTED` | `E_TYPE_UNSUPPORTED` |
| `E_PLATFORM` | `E_PLATFORM` |
| `E_JSON_PERM` | `E_JSON_PERM` |
| `E_LEGACY_SIGNATURE` | `E_LEGACY_SIGNATURE` |
| `E_FILE_SET_MISMATCH` | `E_FILE_SET_MISMATCH` |
| `E_HASH_MISMATCH` | `E_HASH_MISMATCH` |
| `E_DOWNGRADE` | `E_DOWNGRADE` |
| `E_SAME_VERSION_DIFFERENT_CONTENT` | `E_SAME_VERSION_DIFFERENT_CONTENT` |
| `E_PERM_CONFLICT` / `E_DEP_MISSING` / `E_DEP_CYCLE` / `E_SLOT_CONFLICT` / `E_NATIVE_UNSUPPORTED` / `E_PAGE_INVALID` / `E_BINDING_INVALID` / `E_ACTION_UNKNOWN` | 尚未实现（对应里程碑见 `PLUGIN-SYSTEM.md` 第六节），实现时沿用同名机器码 |

宿主侧的原因（不是包的问题，没有文档码，但同样会带着机器码弹出来）：

| 机器码 | 含义 |
|---|---|
| `E_IO` | 建目录 / 换目录 / 删目录 / 写注册表失败 —— 磁盘或权限问题 |
| `E_NO_PREVIOUS` | 没有可回退的上一版 |
| `E_BUILTIN` | 随 Air2 打包的内置插件，不能卸载 |
| `E_LAUNCH_CHAIN_UNCONFIRMED` | 会改启动链的包没有过 10 次免责确认（调用方没给闸门） |
| `E_USER_CANCELLED` | 用户在免责确认里点了取消 |

---

## 十三、发布

1. 源码仓库 + 可复现构建脚本（用户/审计者能自己打出同一个 `packageHash`）。
2. 权限最小化说明：每一项申请都要写「为什么必需」。
3. 在发布页写 `packageHash` 与 `filesDigest`，方便用户对照。
4. **不要**提供签名文件；不要声称「官方认证」。
5. 拒绝项：任何 RCE 面、任何形式的账号数据访问、混淆过的 `entry.js`。
6. 原生代码（`native.module`）只在 P5、且只对 TrollStore / 越狱设备发布；
   安装页会额外显示一页「未审核原生代码」警告。

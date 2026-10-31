# Air2 插件页面模型（v3）

> **状态**：P0 契约，P3b 实现。本文是 v3 `ui.pages` / `ui.overrides` 的**唯一权威定义**。
> **范围**：复杂插件页面（下载器、版本管理、整合包导出、设置面板等）。
> **不是**：WebView、HTML、远程页面、游戏内 UI。
>
> **决策**：ADR-022。复杂页面走**原生 JSON 页面模型**，不用 WebView 兜底。
> `ui.web` 是 P5 的独立能力，不参与本模型。

---

## 一、为什么是 JSON 页面模型

| 方案 | 问题 |
|---|---|
| WebView + HTML | 与宿主设计语言割裂；无法保证 MD3 / 液态玻璃一致；JS 桥是第二个信任域；页面可加载远端内容；性能与无障碍都不可控 |
| 插件直接操作 UIKit | iOS 专属，Android / 桌面无法复用；插件可以绕过宿主布局与主题；崩溃归因困难 |
| **JSON 组件树 + 宿主渲染** | 跨端可映射；插件拿不到控件与路径；宿主统一处理主题、无障碍、动效、错误态；页面树可校验、可限流 |

代价是表现力受限：插件不能用任意 CSS / 自定义绘制。这是**有意接受**的取舍 ——
需要任意绘制时，应该做成宿主功能，而不是插件。

---

## 二、manifest 声明

### 2.1 最小页面

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

### 2.2 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 页面 id，插件内唯一；`^[a-z][a-z0-9_.-]*$`，≤64 |
| `slot` | ✅ | `home.page` = 首页新增入口；`versions.list.page` = 替换版本列表整页 |
| `title` | ✅ | `{ i18n }` 或 `{ text }`；显示在页面标题栏 |
| `icon` | — | 语义图标 ID；`home.page` 入口用 |
| `mode` | ✅ | `static` = 使用 `root` / `source` 的静态树；`dynamic` = 由 JS `render` 返回。**`dynamic` 只能用于 `type: js`** |
| `root` | static 二选一 | 内联组件树根节点 |
| `source` | static 二选一 | 包内 JSON 文件路径，内容是一个根节点；必须在 `manifest.files` 里 |
| `state` | — | 初始 state（仅 dynamic），JSON 对象，≤64 KB；static 页面不能声明，初始为 `{}` |
| `priority` | — | 同 slot 多个页面时的排序权重，`-1000..1000` |

> **纯 JSON 插件只能声明 `mode: "static"`**（schema 会拒装 `type: json` + `dynamic`）。
> 纯 JSON 插件没有运行时，静态页面的 `binding` 只会得到 `null`；文案用 `{ "text": ... }` 字面量。
> JS 插件仍可在 `onPageOpen` 返回 state 或用 `air2.page.setState` 更新静态页面；
> 需要 `render` 每次重建整棵树的页面，必须做成 `type: js` + `dynamic`。

### 2.3 slot 语义

| slot | 行为 | 层 |
|---|---|---|
| `home.page` | 在首页导航 / 卡片区新增一个入口；点击进入插件页面；不影响宿主原有入口 | L2（页面入口） |
| `versions.list.page` | 替换版本列表整页；宿主仍保留「显示原列表」入口与返回按钮 | L2 |

规则：

1. `home.page` 的 `id` 在插件内唯一；不同插件可以同名 id，宿主按 `pluginId + pageId` 区分。
2. `versions.list.page` 同 slot **只允许一个**插件占用；冲突在安装期拒装（`E_SLOT_CONFLICT`）。
3. 页面不能覆盖「插件管理」「安全模式横幅」「插件页面横幅」「返回 / 关闭」。
4. `versions.list.page` 必须允许用户回到原列表；宿主在标题栏溢出菜单提供「显示原列表」，
   插件不能移除它。
5. 页面入口本身属于 L2；安全模式优先禁用 `ui.override` / 页面插件。

### 2.4 `ui.overrides`

```json
"overrides": [
  { "target": "versions.list", "mode": "replace", "page": "myversions" },
  { "target": "home.card", "mode": "hide" }
]
```

| 字段 | 说明 |
|---|---|
| `target` | `home.card` / `home.toolbar` / `versions.list` / `version.detail` / `settings` / `launch.overlay` |
| `mode` | `hide` = 隐藏宿主原界面；`replace` = 用 `page` 替换。`launch.overlay` 只允许 `replace` |
| `page` | `mode=replace` 必填；必须引用本插件 `ui.pages` 里的 id |
| `priority` | 同 target 多个 override 时的排序 |

> `target: "launch.overlay"` + `mode: "hide"` 被 schema 拒绝。替换遮罩内容时，宿主仍绘制
> 「取消启动」、安全模式横幅与启动失败页，插件不能隐藏它们。

不可覆盖的目标（宿主硬编码）：插件管理页、安全模式横幅、插件页面横幅、启动失败页、
「取消启动」按钮、系统权限弹窗。

---

## 三、组件树

### 3.1 节点通用字段

每个节点是一个 JSON 对象：

```json
{
  "component": "button.primary",
  "id": "start",
  "label": { "i18n": "action.start" },
  "action": { "id": "start", "payload": { "kind": "all" } },
  "visibleWhen": { "binding": "state.ready", "equals": true },
  "enabledWhen": { "binding": "state.running", "equals": false },
  "style": "tonal"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `component` | ✅ | 组件名，见 3.2 / 3.3 |
| `id` | — | 页面内唯一；供动作、测试、无障碍定位；≤64 |
| `children` | 容器必填 | 子节点数组；数量与深度见 3.4 |
| `label` | 视组件 | `{ "i18n": "key" }` 或 `{ "text": "字面量" }` |
| `icon` | 视组件 | 语义图标 ID（不是路径） |
| `value` | 视组件 | 静态值；与 `binding` 二选一 |
| `binding` | 视组件 | 只读绑定 `state.*` / `item.*` |
| `itemKey` | `list.itemTemplate` 内的 `action` | 当前项的标量字段绑定（`item.*`）；宿主把它作为 `payload.itemKey` 传给 `onAction` |
| `action` | 视组件 | 字符串或 `{ id, payload }` |
| `visibleWhen` | — | 单条条件；不满足时不渲染（不占位） |
| `enabledWhen` | — | 单条条件；不满足时渲染为禁用态 |
| `placeholder` | 视组件 | 输入类占位文案 |
| `items` | `list` 必填 | 绑定到数组的路径 |
| `itemTemplate` | `list` 必填 | 单项模板；模板内用 `item.*` 绑定 |
| `columns` | `grid` | 1–4，默认 1 |
| `style` | — | `plain` / `card` / `tonal` / `danger` |
| `maxLines` | 文本类 | 1–8 |
| `asset` | `image.asset` 必填 | `assets/**` 相对路径 |
| `options` | `select.menu` 必填 | `[{ value, label }]`，≤32 |

### 3.2 容器

| component | 语义 | 约束 |
|---|---|---|
| `column` | 纵向排列 | 子节点纵向堆叠；可嵌套 |
| `row` | 横向排列 | 窄屏自动换行；子节点 ≤16 |
| `card` | 卡片容器 | 宿主画 MD3 surface / elevation；子节点 ≤32 |
| `section` | 带标题分区 | 必须有 `label`；子节点 ≤32 |
| `scroll` | 可滚动容器 | 只能有一个子节点；用于长页面 |
| `list` | 数据列表 | `items` + `itemTemplate`；虚拟化渲染；模板内的动作必须声明 `itemKey` |
| `grid` | 网格 | `columns` 1–4；子节点等宽 |

容器可以嵌套，但总深度 ≤12。`scroll` 里不要再放 `scroll`（宿主只保留外层滚动）。

### 3.3 叶子

| component | 必填 | 行为 |
|---|---|---|
| `text.label` | `label` | 单行短文本，超出截断 |
| `text.caption` | `label` | 次要说明，最多 `maxLines` 行 |
| `text.heading` | `label` | 区块标题，单行 |
| `button.primary` | `label` | 主按钮；`action` 为空则禁用 |
| `button.secondary` | `label` | 次按钮 |
| `button.text` | `label` | 文字按钮，低优先级 |
| `switch.toggle` | `label` + `binding` | 开关；切换时发 `onAction(actionId, { value }, state)` |
| `list.row` | `label` | 一行；可带 `icon` / `action`；用于 `itemTemplate` |
| `badge.status` | `label` | 徽标；文字 ≤12 字符 |
| `icon.glyph` | `icon` | 纯图标，无语义 |
| `divider` | — | 分隔线 |
| `spacer` | `value` | 间距；值只允许 8 / 16 / 24 |
| `progress.linear` | `binding` | 进度 0–1；可选 `label` |
| `image.asset` | `asset` | 包内图片；`label` 作为无障碍替代文本 |
| `text.field` | `label` + `binding` | 单行文本输入；**不允许密码模式** |
| `select.menu` | `label` + `options` | 下拉选择；当前值走 `binding` |

#### `switch.toggle` / `text.field` / `select.menu` 的交互

这些组件是**受控组件**：显示值来自 `binding`，用户操作只发动作，不直接改 state。

```json
{
  "component": "switch.toggle",
  "label": { "text": "启用加速" },
  "binding": "state.accelerate",
  "action": "toggle_accelerate"
}
```

宿主行为：

1. 用户切换 → 立即显示新值（本地乐观更新）；
2. 调 `onAction(pageId, "toggle_accelerate", { value: true }, state)`；
3. 插件返回新 state → 宿主重新渲染（dynamic 重新 `render`；static 重新绑定）；
4. 若插件返回的 state 没变，宿主回滚到旧值并 toast「设置未保存」。

`text.field` 的 `action` 在**提交**（回车 / 失焦）时触发，payload 为 `{ value: "..." }`；
不做逐字符回调。`select.menu` 在选项变化时触发 `{ value: "..." }`。

### 3.4 数量与深度

| 限制 | 值 | 超限 |
|---|---|---|
| 单页节点数 | 500 | 页面错误态（`E_PAGE_LIMIT`） |
| 树深度 | 12 | 页面错误态 |
| 单容器子节点 | 64（`row` 16） | 页面错误态 |
| `list` 单次渲染项 | 200 | 只渲染前 200，滚动时再取；插件应分页 |
| 动作数 / 页 | 128 | 多余动作被忽略 + 诊断 |
| state | 64 KB | `E_QUOTA`，动作作废 |
| 返回树 | 512 KB | 页面错误态 |
| 文本长度 | 256 字符 | 截断 + 诊断 |
| 图片 | 单张 4 MB / 总 16 MB | 加载失败占位，不崩 |

---

## 四、state 与 binding

### 4.1 state

- 每个页面实例一份 state，JSON 对象，≤64 KB。
- 初始值来自 `manifest.ui.pages[].state`（dynamic）；static 页面固定为 `{}`，且不能声明 `state`。
- JS 插件可以在 `onPageOpen` 返回 `{ state }`，或用 `air2.page.setState` 更新 static 页面的 state。
- 纯 JSON 插件没有 `air2` 对象，无法调用 `setState`，所以它的页面只适合做静态说明 / 导航。
- state **不自动持久化**；需要跨会话保存用 `air2.storage`。
- 页面关闭后 state 丢弃；下次打开重新初始化。
- state 只能由 `onPageOpen` / `onAction` 返回值或 `air2.page.setState(pageId, patch)` 修改，且都是**浅合并**。

### 4.2 binding

```json
{ "component": "text.label", "binding": "state.title" }
{ "component": "text.label", "binding": "item.name" }
```

- 路径只允许 `state.` / `item.` 前缀，点分，段名 `[A-Za-z0-9_-]+`。
- `binding` **只读**。插件不能通过 binding 写宿主或页面 state。
- 路径不存在 → `null`；`text.*` 显示空串，`progress.linear` 显示 0，`switch.toggle` 显示 false。
- 类型不匹配 → 组件降级（例如 `progress` 收到字符串 → 0），记 `binding-type` 诊断，不崩。
- `list.items` 必须是数组；不是数组 → 空列表 + 诊断。
- `item.*` 只在 `list.itemTemplate` 内有效；在模板外使用 → 空值 + 诊断。

### 4.3 条件

```json
{ "binding": "state.ready", "equals": true }
{ "binding": "state.count", "notEquals": 0 }
{ "binding": "state.mode", "in": ["a", "b"] }
{ "binding": "state.error", "exists": true }
```

- 只支持**单条比较**；复杂逻辑在 `render` 里算好，不要试图写布尔表达式。
- `exists` 判断路径是否存在（不是 truthy）。
- `visibleWhen` 不满足 → 节点不渲染，不占位。
- `enabledWhen` 不满足 → 渲染禁用态；动作不会触发。

---

## 五、动作与事件流

### 5.1 动作声明

```json
{ "component": "button.primary", "label": { "text": "开始" }, "action": "start" }
{ "component": "button.secondary", "label": { "text": "删除" }, "action": { "id": "delete", "payload": { "id": "abc" } } }
```

- `action` 字符串等价于 `{ id }`。
- `payload` 只能是 JSON 标量对象，≤1 KB，≤16 个键；`itemKey` 是宿主保留键，插件不能自己写。
- 宿主把 `(pageId, actionId, payload, state)` 交给 `onAction`。
- **列表项动作**：`list.itemTemplate` 里带 `action` 的节点必须声明 `itemKey`
  （例如 `"itemKey": "item.id"`）。宿主解析当前项的该字段，把标量合并为
  `payload.itemKey`；插件用 `payload.itemKey` 定位是哪一行。`itemKey` 缺失 →
  该动作禁用并记 `E_ITEM_KEY_MISSING`；解析结果不是标量 → 动作作废并记诊断。

### 5.2 内置动作（纯 JSON 插件也能用）

以 `host.` 开头的动作由宿主处理，不交给插件：

| 动作 | payload | 行为 |
|---|---|---|
| `host.close` | — | 关闭当前插件页面 |
| `host.openPage` | `{ pageId }` | 打开本插件的另一个页面 |
| `host.showOriginal` | — | 仅 `versions.list.page`：显示宿主原列表 |
| `host.retry` | — | 错误态重试 |
| `host.copy` | `{ text }` | 复制文本到剪贴板（≤4 KB） |

规则：

- `type: json` 的插件只能使用 `host.*` 动作；使用其它动作 → 安装期 `E_ACTION_UNKNOWN`。
- `type: js` 可以使用任意动作 id；`host.*` 保留给宿主，插件不能注册同名动作。
- 未知动作 id → 宿主 toast「未知操作」+ 诊断，不崩。

### 5.3 `onAction` 返回值

```js
onAction(pageId, actionId, payload, state) {
  return {
    state: { ...state, running: true },   // 替换 state（浅合并到当前 state）
    toast: "已开始",
    close: false,
    openPage: "detail",
    error: null
  };
}
```

| 字段 | 说明 |
|---|---|
| `state` | 新 state；省略则保持不变；必须是 JSON 对象 |
| `statePatch` | 与 `state` 二选一；浅合并到当前 state |
| `toast` | 轻提示，≤2 行 |
| `close` | `true` 关闭页面 |
| `openPage` | 打开本插件另一个页面（等价 `host.openPage`） |
| `error` | `{ message }`；显示错误条，保留旧 state |

`onAction` 抛错 / 超时 → 宿主显示错误条，保留旧 state，记诊断；不关闭页面。

### 5.4 异步任务

`onAction` 里不要阻塞等待下载 / 网络。正确做法：

```js
onAction(pageId, actionId, payload, state) {
  if (actionId === "start") {
    const jobId = air2.download.fetchToFile({ url, destToken });
    return { state: { ...state, jobId, running: true } };
  }
}

onDownloadComplete(jobId, result) {
  air2.page.setState("downloader", {
    running: false,
    progress: result.ok ? 1 : 0,
    error: result.ok ? null : result.error
  });
}
```

`air2.page.setState` 会触发重新渲染（dynamic 调 `render`；static 重新绑定）；宿主合并同一帧内的多次 setState。

### 5.5 生命周期

| 时机 | 回调 | 说明 |
|---|---|---|
| 页面打开 | `onPageOpen(pageId, state)` | 可返回 `{ state }` 作为初始 state（static / dynamic 都适用）；可发起异步任务 |
| 每次渲染 | `render(pageId, state)` | 仅 dynamic；必须纯函数；不得 I/O、不得改 state |
| 用户动作 | `onAction(pageId, actionId, payload, state)` | 返回新 state / toast / close |
| 页面关闭 | `onPageClose(pageId, state)` | 清理定时器；不要做超过 100 ms 的同步工作 |
| 插件卸载 | `onUnload()` | 所有页面先关闭，再调 onUnload |

`render` 可能被宿主多次调用（state 变化、主题变化、旋转、语言变化）。
不要在 `render` 里 `air2.storage.set` 或发网络请求。

---

## 六、页面 chrome 与导航

宿主绘制的固定结构（插件不能覆盖）：

```
┌──────────────────────────────────────────────┐
│ [←]  <页面标题>                  [⋯]         │  ← 标题栏
│ ┌──────────────────────────────────────────┐ │
│ │ 由 <插件名> 提供 · 插件页面               │ │  ← 强制横幅
│ └──────────────────────────────────────────┘ │
│                                              │
│  <插件组件树渲染区>                           │
│                                              │
└──────────────────────────────────────────────┘
```

规则：

1. 横幅**必须**常驻，文案包含插件名与「插件页面」；点击可展开插件 id / 版本 / 包哈希短串。
2. 返回按钮**必须**存在；`versions.list.page` 额外提供「显示原列表」。
3. 插件不能隐藏 / 移动 / 改文案 / 改颜色横幅与返回按钮。
4. 页面标题来自 manifest `title`；插件不能运行时改标题（可以渲染 `text.heading` 作为内容标题）。
5. 页面加载中显示宿主骨架屏；渲染失败显示宿主错误页 + 「返回」+「重试」。
6. 页面打开时不阻塞主线程；首帧前显示宿主占位。

---

## 七、安全约束

| 约束 | 说明 |
|---|---|
| 无 HTML / CSS / JS 注入 | `text.*` 只渲染纯文本；`label.text` 里的 `<b>` 原样显示，不解析 |
| 无远程资源 | `image.asset` 只能引用包内 `assets/**`；禁止 `http(s)://`、`file://`、绝对路径、`..` |
| 无密码框 | 没有 `secure` / `password` 组件；需要密钥走 `air2.ui.promptSecret` |
| 无任意颜色 / 字体 | 只能用 `style` 语义与宿主主题 token；不允许 hex 颜色、字体名、字号 |
| 无绝对定位 | 不允许 `x` / `y` / `width` / `height` / `position` |
| 无文件路径 | 页面树里不能出现绝对路径；`asset` 是包内相对路径 |
| 无账号 | 页面不能读账号 / token；API 面里没有这些对象 |
| 无宿主控件引用 | 组件名是语义名；不能传 `UIButton` / `android.widget.*` |
| 无跨插件 | 页面只能引用本插件的资源与 action |
| 无隐藏 chrome | 横幅 / 返回 / 插件管理入口不可覆盖 |

页面树在安装期做 schema 校验，在运行时做语义校验（节点数、深度、绑定路径、动作合法性）。
运行时不认识的组件（理论上不会发生，因为 schema 枚举）→ 错误页，不静默忽略。

---

## 八、性能与预算

| 项 | 软预算 | 硬超时 | 超时 |
|---|---|---|---|
| `render` | 16 ms | 200 ms | 错误页 + 诊断 |
| `onAction` | 2 s | 10 s | 错误条，保留旧 state |
| `onPageOpen` | 100 ms | 1 s | 记诊断，页面照常显示 |
| `onPageClose` | 100 ms | 1 s | 强制清理 |
| 同帧 setState 合并 | — | 30 fps | 多余更新合并 |

- `render` 在插件串行队列执行；宿主把树提交主线程。
- 同一页面同时只有一个 `render` 在跑；state 变化时如果有 render 在跑，合并成一次后续 render。
- `list` 虚拟化：只渲染可视区 + 前后各 5 项；插件不要一次返回 1000 个 `list.row`。
- 图片异步解码；解码失败显示占位，不阻塞页面。

---

## 九、失败处理

| 情况 | 宿主行为 |
|---|---|
| `render` 返回非对象 / 缺 `component` | 错误页「插件页面渲染失败」+ 重试 |
| 节点数 / 深度超限 | 错误页 `E_PAGE_LIMIT` |
| `binding` 路径非法 | 该节点按空值渲染 + 诊断；不整页失败 |
| 未知组件 | 错误页（schema 应在安装期拦住） |
| `onAction` 抛错 / 超时 | 错误条 + 保留旧 state + 诊断 |
| `onPageOpen` 抛错 | 页面照常打开，state 用初始值；诊断 |
| 插件被禁用 / 卸载 | 关闭所有页面，显示「插件已停用」 |
| 权限被撤销 | 关闭依赖该权限的页面；显示「权限已撤销」 |
| 页面树超过 512 KB | 错误页 + 诊断 |

错误页由宿主绘制，包含插件名、错误码、简短原因、「重试」「返回」。
不向用户展示 JS 栈帧、绝对路径、其它插件信息。

---

## 十、跨端映射

| 语义 | iOS | Android | desktop |
|---|---|---|---|
| `column` / `row` | UIStackView / 自绘 | LinearLayout / Compose Row | 宿主布局 |
| `card` | MD3 surface + 圆角 + 阴影 | MaterialCardView | 宿主卡片 |
| `button.primary` | MD3 filled | Material FilledButton | 宿主主按钮 |
| `switch.toggle` | UISwitch（MD3 皮肤） | Material Switch | 宿主开关 |
| `list` | UITableView / UICollectionView | RecyclerView | 宿主列表 |
| `progress.linear` | UIProgressView（MD3 皮肤） | LinearProgressIndicator | 宿主进度条 |
| `image.asset` | UIImage | Bitmap | 宿主图像 |

- 同一棵树的**语义与交互**一致；视觉按各端设计系统。
- 动画只承诺语义（入场 / 强调 / 错误），曲线由各端决定。
- 无障碍：每个可交互节点必须有 `label`；`image.asset` 用 `label` 作 alt；
  宿主负责 VoiceOver / TalkBack 焦点顺序。

---

## 十一、示例

### 11.1 静态页面（纯 JSON）

`manifest.json` 片段：

```json
"ui": {
  "pages": [
    {
      "id": "about",
      "slot": "home.page",
      "title": { "text": "关于" },
      "icon": "action.info",
      "mode": "static",
      "source": "pages/about.json"
    }
  ]
}
```

`pages/about.json`：

```json
{
  "component": "column",
  "children": [
    { "component": "text.heading", "label": { "text": "Hello 插件" } },
    { "component": "text.caption", "label": { "text": "版本 1.0.0 · 作者自述" } },
    { "component": "divider" },
    {
      "component": "button.secondary",
      "label": { "text": "关闭" },
      "action": "host.close"
    }
  ]
}
```

### 11.2 动态列表

```js
definePlugin({
  render(pageId, state) {
    return {
      component: "column",
      children: [
        {
          component: "text.heading",
          label: { text: "版本列表" }
        },
        {
          component: "list",
          items: "state.versions",
          itemTemplate: {
            component: "list.row",
            binding: "item.name",
            action: { id: "open" },
            itemKey: "item.id"
          }
        },
        {
          component: "button.primary",
          label: { text: "刷新" },
          action: "refresh",
          enabledWhen: { binding: "state.loading", equals: false }
        }
      ]
    };
  },

  onAction(pageId, actionId, payload, state) {
    if (actionId === "refresh") {
      return { state: { ...state, loading: true }, toast: "刷新中" };
    }
    if (actionId === "open") {
      return { state: { ...state, selected: payload.itemKey } };
    }
    return { state };
  }
});
```

> `payload` 里写 `"item.id"` 只是字面量，**不会**插值；列表项要定位当前行，必须用
> `itemKey: "item.id"`，宿主会把它解析成 `payload.itemKey`。P0 不定义模板插值语法，
> 避免页面模型变成模板语言。

### 11.3 设置页（switch + text.field）

```json
{
  "component": "section",
  "label": { "text": "下载设置" },
  "children": [
    {
      "component": "switch.toggle",
      "label": { "text": "启用镜像加速" },
      "binding": "state.mirror",
      "action": "toggle_mirror"
    },
    {
      "component": "text.field",
      "label": { "text": "并发数" },
      "binding": "state.concurrency",
      "placeholder": { "text": "1-8" },
      "action": "set_concurrency"
    },
    {
      "component": "select.menu",
      "label": { "text": "下载源" },
      "binding": "state.source",
      "options": [
        { "value": "auto", "label": { "text": "自动" } },
        { "value": "official", "label": { "text": "官方" } }
      ],
      "action": "set_source"
    }
  ]
}
```

---

## 十二、验收清单（P3b 逐条可测）

1. 静态页面能渲染，`source` 文件必须在 `manifest.files` 里。
2. 动态页面 `render` 被调用；state 变化后重新渲染。
3. `onAction` 返回 `state` 后页面更新；返回 `toast` 显示轻提示。
4. `onAction` 超时 → 错误条 + 旧 state 保留，页面不崩。
5. `render` 超时 / 返回非法树 → 错误页 + 重试。
6. 页面顶部始终有插件名 + 「插件页面」横幅；插件无法隐藏。
7. `versions.list.page` 有「显示原列表」，且能返回宿主原列表。
8. `list` 只渲染可视区；1000 项不卡主线程。
9. `binding` 路径不存在 → 空值，不崩。
10. `image.asset` 指向 `http(s)://` / 绝对路径 / `..` → 拒绝该节点。
11. `text.field` 没有密码模式；`promptSecret` 走宿主安全输入页。
12. 页面树 501 个节点 / 深度 13 → 错误页 `E_PAGE_LIMIT`。
13. state >64 KB → `E_QUOTA`，动作作废。
14. 插件被禁用时，打开中的页面关闭并提示。
15. 安全模式下 `ui.override` / 页面插件被禁用，横幅可见。
16. 同一 `versions.list.page` 第二个插件安装 → `E_SLOT_CONFLICT`。
17. 纯 JSON 插件使用非 `host.*` 动作 → 安装期 `E_ACTION_UNKNOWN`。
18. 页面关闭后 state 丢弃；重新打开回到初始值。
19. `list.itemTemplate` 内的动作带 `itemKey` → `payload.itemKey` 是当前行标量；
    缺 `itemKey` → 动作禁用 + 诊断，不误操作其它行。
20. `type: json` + `mode: "dynamic"` → 安装期拒装；`mode: "static"` + manifest `state` → 安装期拒装。
21. JS 插件 + static 页面：`onPageOpen` 返回 state 后绑定更新；纯 JSON 插件同一页面仍显示空值。

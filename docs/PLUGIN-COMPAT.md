# Air2 插件多端兼容契约

> **状态**：P0 契约。目标是让「在 iOS 上写的插件」不必为 Android / 桌面改写，
> 同时**不假装**各端能做到一样的事。
> **原则**：契约层面跨端，实现层面各端自己决定；做不到的能力**明确不可用**，
> 不用「差不多也能画」的兼容层糊过去。

---

## 一、平台标识与回退

### 1.1 `platforms`

`manifest.platforms`（必填，非空数组）只写**目标平台**，取值：

| 值 | 含义 | 当前状态 |
|---|---|---|
| `ios` | iPhone / iPad | **已实现**（唯一可用） |
| `android` | Android | 契约占位，宿主不存在 |
| `desktop` | macOS / Windows / Linux 桌面宿主 | 契约占位，宿主不存在 |

规则：

1. `platforms` **不含当前平台** → 拒装，文案「此插件不支持 <平台>」。**不静默降级**：
   声明不支持却强行加载，只会让作者拿到一堆「在我的机器上好好的」的崩溃报告。
2. 不写 `platforms` → schema 校验失败（必填）。
3. `"common"` **不是** `platforms` 的合法值。`common` 只用于**资源目录**的回退（1.2）。

### 1.2 资源回退 `assets/`

| 顺序 | 路径 | 说明 |
|---|---|---|
| 1 | `assets/<platform>/**` | 平台专属，优先级最高 |
| 2 | `assets/common/**` | 平台无关，作为基线 |
| 3 | 宿主内置默认 | 两者都没有时使用宿主默认资源（图标/占位图） |

- 回退是**逐文件**的：`assets/ios/icon.png` 存在就用它覆盖 `assets/common/icon.png`，
  不存在则用 common 的；**不是**「整个目录二选一」。
- 两者都不存在 → 只有在 `manifest` 显式引用该文件时才报错（拒装），
  隐式资源缺失则退回宿主默认，不报错。

### 1.3 词表回退（组件 / slot / 图标）

宿主词表（1.4 / 1.5 / 1.6）是**跨端契约**：同一份 manifest 在 Android 宿主上表示同样的东西，
只是渲染成 Material 组件而不是 UIKit 组件。词表**不含**平台特有项
（没有 `ui.ios.navigationBar` 这种），要加平台差异一律走 `uiCapabilities` 降级，
不走「平台专属组件」。

---

## 二、语义组件，不是平台控件

### 2.1 规则

manifest 里的 `component` 字段写**语义名**，不写控件类名：

```json
{ "slot": "home.toolbar.action", "component": "button.primary", "icon": "action.download", "label": { "i18n": "home.download" } }
```

| 写法 | 判定 |
|---|---|
| `"button.primary"` | ✅ 语义名，宿主映射到 MD3 FilledButton / UIKit 对应实现 |
| `"MD3FilledButton"` / `"UIButton"` / `"android.widget.Button"` | ❌ 平台控件名，schema 枚举拒绝 |

理由：

- 平台控件名会把插件的可见性绑死在某一端的实现上。iOS 侧我们做 MD3 外观（ADR-010），
  Android 侧是原生 MD3 —— 同一个语义名在两端的**视觉**不同，但**语义**一致，
  这才是有意义的跨端。
- 语义名让宿主可以在不破坏插件的前提下换实现（例如整页替换从 XIB 换到代码布局）。

### 2.2 宿主词表 v1：slot

| slot | 位置 | 建议层 | 说明 |
|---|---|---|---|
| `home.toolbar.action` | 首页顶部工具栏右侧 | L1 | 放按钮/开关，数量上限 4 |
| `home.card.badge` | 首页卡片右上角 | L1 | 放徽标，数量上限 1（多者取 priority 最高） |
| `versions.list.badge` | 版本列表项右侧 | L1 | 放徽标/短文本 |
| `version.detail.header` | 版本详情页标题区 | L1 / L2 | 放徽标、短文本、图标 |
| `settings.section` | 设置页附加分区 | L1 / L2 | 放整块设置区 |
| `versions.list.page` | 版本列表整页 | **L2** | 整页替换（P3），同 slot 只允许一个 |

### 2.3 宿主词表 v1：component

| component | 语义 | 宿主渲染 |
|---|---|---|
| `text.label` | 只读短文本 | MD3 label 样式，单行截断 |
| `text.caption` | 次要说明 | MD3 bodySmall，最多 2 行 |
| `button.primary` | 主操作按钮 | MD3 filled button，最小点击区 44×44 |
| `button.secondary` | 次操作按钮 | MD3 tonal/outlined button |
| `switch.toggle` | 布尔开关 | MD3 switch |
| `list.row` | 一行（标题 + 副标题 + 可选尾部） | MD3 list item |
| `badge.status` | 状态徽标（文字 + 语义色） | MD3 badge，最多 12 字符 |
| `icon.glyph` | 纯图标 | 见 2.4 语义 ID |
| `divider` | 分隔线 | 1px hairline |
| `spacer` | 间距 | 固定 8/16/24 三档 |

### 2.4 图标语义 ID

`icon` 字段写语义 ID，不写图片路径：

| ID | 含义 |
|---|---|
| `action.download` | 下载 |
| `action.play` | 启动 |
| `action.settings` | 设置 |
| `action.folder` | 目录/文件 |
| `action.share` | 分享 |
| `action.info` | 信息 |
| `action.warning` | 警告 |
| `status.online` / `status.offline` | 在线/离线 |
| `media.pack` / `media.world` | 整合包 / 存档 |

- 语义 ID 由**宿主**映射到具体图标集（iOS 端用 SF Symbols + 自绘），插件不提供字形。
- 未识别的 ID → 宿主渲染 `action.info` 并记一条 `unknown-icon` 诊断，**不拒载**。
  这样宿主可以新增图标而插件不会因为「用了新 ID」在旧宿主上崩。
- 自定义图标（`assets/` 里的图片）在 P2 **不允许**在 `icon` 里引用；
  要自定义图形请用 `ui.iconOverride`（P3 引入）并声明模板化与尺寸。

---

## 三、`air2.paths` 抽象（不暴露真实路径）

### 3.1 规则

插件**永远拿不到**绝对路径。`air2.paths` 返回的是**不透明 token**（形如 `tok:gameDir`），
只在 API 调用里当下标的参数用：

```js
air2.files.writeGame(air2.paths.pluginData("cache.json"), bytes);   // ✅
air2.files.writeGame("/var/mobile/…/config/x.json", bytes);         // ❌ E_INVALID_ARG
```

### 3.2 token 目录

| token | 指向 | 需要的权限 |
|---|---|---|
| `air2.paths.pluginData(name)` | `Plugins/<id>/data/<name>` | 无（插件自有） |
| `air2.paths.pluginCache(name)` | `Plugins/<id>/cache/<name>` | 无（可被系统清理） |
| `air2.paths.pluginAsset(name)` | `Plugins/<id>/<ver>/assets/…/<name>` | 无（只读） |
| `air2.paths.gameDir()` | 当前版本的游戏目录**根** | `files.game.write.config` 或 `.content` |
| `air2.paths.gameConfig(name)` | 游戏目录内配置白名单路径 | `files.game.write.config` |
| `air2.paths.gameContent(name)` | 游戏目录内内容白名单路径 | `files.game.write.content` |
| `air2.paths.tmp(name)` | 宿主临时目录 | 无 |

- 未授权的 token 函数**不存在**（能力注入，见 `PLUGIN-API.md` 第三节）。
- token 不携带路径信息（不是 base64 路径，是随机句柄），插件无法从 token 反推目录结构。
- 所有 token 都受「必须在目标根目录之内」的复核：解析后若逃逸（`..`、符号链接）→ `E_FORBIDDEN_ARG`。

### 3.3 为什么这条路不能松

一旦给出真实路径，插件就能：

1. 绕过 `air2.files` 的路径白名单（直接 `NSFileManager` 也拿不到，但字符串可用于其它面）；
2. 把路径写进日志 / 上报，形成「用户目录结构」的泄露；
3. 在 `launch.args` 里把路径拼进参数（`-cp /绝对路径`），从而绕过 `launch.classpath`
   的「条目必须落在插件或游戏目录内」校验 —— 因为宿主要判断的就是「这个路径属不属于我允许的根」。

所以路径抽象不是「好看」，是**权限校验的前置条件**。

---

## 四、BCP-47 语言回退

### 4.1 声明

```json
"locales": {
  "zh-Hans": "locales/zh-Hans.json",
  "zh-Hant": "locales/zh-Hant.json",
  "en": "locales/en.json"
}
```

- 键是 BCP-47 语言标记（大小写不敏感，宿主统一规范化为 `language-Script-REGION` 形式比较）。
- 值是包内相对路径，必须出现在 `manifest.files` 里。

### 4.2 回退顺序

给定宿主当前语言链（`locale` + `preferredLanguages` + 区域设置），逐语言按下面顺序找：

```
精确匹配（zh-Hans-CN）
  → 去 REGION（zh-Hans）
  → 去 Script（zh）
  → 语言主标签（zh）
  → 宿主默认语言链的下一个语言（重复上面四步）
  → 内置 en
  → manifest.name（标题）/ 空串（正文）
```

具体到中文：

| 宿主语言 | 依次尝试 |
|---|---|
| `zh-Hans-CN` | `zh-Hans-CN` → `zh-Hans` → `zh` → `en` |
| `zh-Hant-TW` | `zh-Hant-TW` → `zh-Hant` → `zh` → `en` |
| `zh-CN` | `zh-CN` → `zh` → `en` |
| `en-US` | `en-US` → `en` |
| `ja-JP`（插件只有 zh/en） | `ja-JP` → `ja` → `en` |

- **不做**「简体↔繁体自动转换」。写了 `zh-Hant` 才有繁体；只写 `zh` 表示通用中文，
  简繁都用它（不做字形转换，转换是错的比不转更糟）。
- 缺失键的处理：`air2.i18n.t(key)` 找不到 → 返回 `en` 的同名键 → 仍找不到返回 `key` 本身
  并记一条 `missing-i18n-key` 诊断。**不回退到宿主文案**（宿主文案与插件语义无关，回退只会让文案错得更离谱）。
- 语言文件结构：扁平 `key → string`，值内 `{name}` 形式占位符，最多 3 个参数。

---

## 五、`uiCapabilities`（能力协商，不是权限）

宿主运行时通过 `air2.host.uiCapabilities` 告知**画不画得出**，插件据此降级。
这与 `permissions`（准不准做）是两个正交维度。

| 键 | 类型 | 含义 | iOS 当前值 |
|---|---|---|---|
| `color.glass` | bool | 是否支持液态玻璃材质 | `true`（iOS 26+），否则 `false` |
| `blur.backdrop` | bool | 是否支持背景模糊 | 视设备而定（低端机 `false`） |
| `motion.spring` | bool | 是否启用弹簧动效 | `true`（「减弱动态效果」开启时为 `false`） |
| `haptics` | bool | 是否支持触觉反馈 | `true`（iPad 无 Taptic 时为 `false`） |
| `grid.columns` | int | 首页网格列数 | 横屏 3（iPad 4） |
| `minTapTarget` | int | 最小点击区（pt） | `44` |
| `text.maxLines.badge` | int | 徽标最大行数 | `1` |

使用规则：

1. **能力缺失必须有降级路径**：`color.glass: false` → 用纯色/半透明填充，不是「不画」。
2. 插件**不许**因为能力缺失而 `throw`（那会让整个 `contribute` 失效）。宿主对
   `uiCapabilities` 的读取不做异常保护之外的处理 —— 插件自己负责判断。
3. 新增能力键：客户端忽略未知键；插件也必须容忍「自己认识但宿主没给」→ 当 `false`。
4. 能力**不参与**授权判定：`color.glass: true` 不代表插件能改宿主配色，
   那需要 `ui.theme` 面（属 L1 贡献，不需权限）。

---

## 六、版本兼容矩阵

| 宿主 | API v1 | 包格式 v2 | 插件类型 | 可用权限面 |
|---|---|---|---|---|
| < P2 版本 | — | — | 不支持插件 | — |
| P2 宿主 | 1（声明面） | ✅ | `json` | 低/中（`version.decorate` 等） |
| P3 宿主 | 1（含运行时） | ✅ | `json` / `js` | + critical（`launch.*` / `files.*` / `version.patch`） |
| P4 宿主 | 1 | ✅ | `json` / `js` | + `network.http` / `download.source` / `version.filter` |
| P5 宿主 | 1（+ 原生面） | ✅ / v3 | + `native` | + `native.module` / `ui.web` |

- 插件声明 `air2.host.apiVersion = 1` 而宿主只支持声明面（P2）→ **装得上**，
  但 `entry.js` 不执行，管理页标「当前版本不支持 JS 插件」。宁可装上一个不工作的，
  也不要让用户在「装了之后才发现版本不兼容」这条路上反复试。
  例外：`type: js` 在 P2 宿主上**直接拒装**（因为它在 P2 里完全无法工作，装上去只会误导）。
- 包格式 v3（P3 引入 `hide`/`override`/`page`，P5 引入 `native`）在 v2 宿主上拒装，
  文案「需要更新版本的 Air2」。

---

## 七、跨端不承诺的事

| 不承诺 | 说明 |
|---|---|
| 像素级一致 | 各端按自己的设计语言渲染同一语义组件（ADR-010 / MD3） |
| 同一份 `assets/` 图在两端都一样好看 | 尺寸/DPI 差异由作者提供 `assets/<platform>/` 解决 |
| 插件在任一端都能用 | `platforms` 明确声明；不支持就拒装 |
| 桌面端的窗口/多实例语义 | `desktop` 是占位，v1 不定义 |
| 游戏内 hook 的跨端 | v1 非目标（`PLUGIN-SYSTEM.md` 1.2） |

# Air2 插件作者指南

> 面向要写插件的人。**先读本文，再读** `PLUGIN-API.md`（能调什么）、
> `PLUGIN-SECURITY.md`（权限与信任）、`PLUGIN-COMPAT.md`（多端与本地化）。
> 机器可读的 manifest 契约是 `docs/plugin.schema.json` —— 它与本文如有冲突，**以 schema 为准**
> （并且那是要修的 bug）。

---

## 一、最短路径

```bash
# 1. 建目录
mkdir -p myplugin/assets/ios myplugin/locales

# 2. 写 manifest.json（下面第二节逐字段讲）

# 3. 生成 files 清单（每个文件的 sha256 + size）
python3 - <<'PY'
import hashlib, json, pathlib
root = pathlib.Path('.')
files = []
for p in sorted(root.rglob('*')):
    if p.is_dir() or p.name in ('manifest.json', 'AIR2SIG.json') or p.name == 'myplugin.air2plugin':
        continue
    b = p.read_bytes()
    files.append({"path": p.as_posix(), "sha256": hashlib.sha256(b).hexdigest(), "size": len(b)})
print(json.dumps(files, ensure_ascii=False, indent=2))
PY

# 4. 打包（-X 去掉扩展字段，保证不同机器打包的产物可比）
zip -X -r ../myplugin.air2plugin . -x '.DS_Store' -x '__MACOSX/*'
```

装进 Air2：管理页「导入插件」→ 选 `.air2plugin` → 看导入预览 → 授权 → 完成。

---

## 二、目录结构

```
myplugin/
├── manifest.json           # 必须，包根，UTF-8 无 BOM
├── AIR2SIG.json            # 可选，签名块（发布时生成）
├── entry.js                # type=js 必须有
├── ui/theme.json           # 可选（自定附加数据，必须在 files 清单里）
├── assets/
│   ├── common/             # 平台无关
│   └── ios/                # 覆盖 common 同名文件
├── locales/
│   ├── zh-Hans.json
│   └── en.json
└── native/                 # ❌ formatVersion 2 不允许出现
```

三条硬规则，违反了安装器会直接拒装：

1. `manifest.json` 在**包根**，不在子目录。
2. `manifest.files` 与「包内实际文件（除 `manifest.json` / `AIR2SIG.json`）」**双向相等**：
   多一个文件是夹带，少一个文件是清单说谎。
3. `native/` 出现在 v2 包里 → 拒装（原生插件属 P5）。

---

## 三、manifest 字段逐项说明

### 3.1 顶层

| 字段 | 必填 | 类型 | 说明 | 常见错误 |
|---|---|---|---|---|
| `formatVersion` | ✅ | `2` | 包格式版本，只能是**数字 2** | 写 `"2"`（字符串）/ 写 `1` |
| `id` | ✅ | string | 全局唯一，建议反向域名；`^[a-z0-9]+(\.[a-z0-9][a-z0-9_-]*)+$` | 用大写、用空格、只有一段（`hello` 不行，要 `top.you.hello`） |
| `name` | ✅ | string ≤64 | 展示名（本地化缺失时的回退） | 塞一长串说明 |
| `version` | ✅ | string | 语义化版本 `1.2.3` / `1.2.3-beta.1` | 写 `v1.2.3`、写 `1.2` |
| `type` | ✅ | `json` \| `js` | `json` 无运行时；`js` 有 `entry.js` | 写 `native`（v2 不接受） |
| `description` | — | string ≤512 | 管理页一句话说明 | 写成 README |
| `author` | — | object | `{ name, url?, fingerprint? }` | `fingerprint` 只用于展示，**不作为信任依据** |
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

### 3.2 `air2.host`（对宿主的要求）

```json
"air2": { "host": { "apiVersion": 1, "minHostVersion": "2.0.0" } }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `apiVersion` | ✅ | 只能是整数 `1`。它在 **v2 的阶段面**里表示「我用的是 API v1」。 |
| `minHostVersion` | — | 宿主版本下限（含）。只在确实需要新能力时填。 |
| `maxHostVersion` | — | 宿主版本上限（含）。**只用于已确认不兼容的场景**，正常别填（填了就永远要维护它）。 |

> 不要和运行时的 `air2.host` 混淆：manifest 里这个是「我要什么样的宿主」，
> 运行时那个是「我面对的是什么样的宿主」（只读，含 `uiCapabilities`）。
> 详见 `PLUGIN-API.md` 第二节。

### 3.3 `permissions`

按需申请，**多申请一项就会在授权页多一条吓人的条款**，而且 critical 权限在 T0 下根本授不下来。

| 权限 | 风险 | 你什么时候需要它 |
|---|---|---|
| `version.decorate` | 低 | 改版本列表的标题/副标题/徽标/图标（只影响展示） |
| `version.filter` | 低 | 按规则隐藏/置灰版本（P4） |
| `download.source` | 中 | 追加下载镜像候选（P4） |
| `launch.properties` | 中 | 写 `-Dfabric.*` / `-Dmixin.*` 这类带前缀的属性 |
| `launch.tuning` | 中 | 结构化调内存/GC/渲染开关 |
| `launch.env` | 中 | 静态设置进程环境变量 |
| `files.game.write.config` | 中 | 改 `options.txt` / `config/**` |
| `launch.args` | **critical** | 追加裸 JVM 参数 |
| `launch.env.code` | **critical** | 启动时用代码算环境变量 |
| `launch.classpath` | **critical** | 往 `-cp` 里加东西 |
| `launch.libraryPath` | **critical** | 改 `-Djava.library.path` |
| `java.agent` | **critical** | `-javaagent` / `-agentlib` / `-agentpath` / `-Xrunjdwp` |
| `files.game.write.content` | **critical** | 写 `mods/*.jar` / 资源包 / 存档 |
| `version.patch` | **critical** | 改版本目录内容（补丁文件、`version.json` 副本） |
| `network.http` | 中 | 出站 HTTP（P4） |
| `native.module` | **critical** | 自带 dylib（**P5 且仅 T2**） |
| `ui.web` | **critical** | 内嵌 WebView（P5） |

`type: json` 只能申请 `version.decorate` / `download.source` / `version.filter`
（没有运行时，其它权限给了也用不上 —— schema 会直接拒）。

### 3.4 `ui`

```json
"ui": {
  "priority": 10,
  "slots": [
    {
      "slot": "home.toolbar.action",
      "component": "button.primary",
      "icon": "action.download",
      "label": { "i18n": "action.downloadAll" },
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
| `theme.tokens` | 主题 token 覆盖，L1 层。未知 token 忽略 + 诊断，不拒载 |

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
- **不要**把 `manifest.json` 或 `AIR2SIG.json` 列进来。
- 清单外的文件一律让整包拒装。

---

## 四、示例 1：纯 JSON 插件（最小可用）

一个在首页卡片上放状态徽标、并给版本列表加副标题的插件。**没有一行代码**。

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
  "air2": { "host": { "apiVersion": 1, "minHostVersion": "2.0.0" } },
  "platforms": ["ios"],
  "permissions": ["version.decorate"],
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
- `permissions` 只能是 `version.decorate` / `download.source` / `version.filter`。
- 徽标文字走 `i18n` 而不是 `text`，否则英文用户看到中文。

---

## 五、示例 2：JS 插件（最小可用）

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
  "air2": { "host": { "apiVersion": 1, "minHostVersion": "2.0.0" } },
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
  `try { air2.launch.addArg() } catch {}` 这种写法在能力注入下只会得到 `TypeError: undefined is not an object`，
  而且掩盖了「我需要权限」这件事。
- 回调都在**主线程**跑：`onLoad` ≤ 50 ms，其余单次 ≤ 16 ms。超了不杀你，但会记诊断。
- `entry.js` 里**没有** `require` / `import` / `fetch` / `eval` / `WebAssembly` —— 它们不存在。
- 回调参数是**深拷贝**的普通 JSON 值，改它不会影响宿主。

---

## 六、打包

```bash
cd myplugin
zip -X -r ../bootcount.air2plugin . -x '.DS_Store' -x '__MACOSX/*'
```

- `-X`：不写额外字段（时间戳类的元数据会破坏「同内容同哈希」的可比性）。
- **必须从插件目录内部打包**（`manifest.json` 要落在压缩包根，而不是 `myplugin/manifest.json`）。
- 打包前用 schema 验一遍：

```bash
python3 -c "
import json, jsonschema
s = json.load(open('path/to/docs/plugin.schema.json'))
m = json.load(open('myplugin/manifest.json'))
jsonschema.validate(m, s); print('manifest ok')
"
```

---

## 七、签名（发布必做）

签名让用户从「未验证」变成「已验证」，并让 critical 权限**有可能**被授予（T0 下不授予任何 critical）。

签名对象是**规范化 manifest + 文件哈希清单**，不是 zip 字节：

```
signedMessage = "AIR2PLUGIN-SIG-V1\n" + manifestDigest + "\n" + filesDigest
signature     = base64(Ed25519_sign(privkey, signedMessage))
```

`AIR2SIG.json`（包根）：

```json
{
  "version": 1,
  "algorithm": "ed25519",
  "keyId": "your-key-2026",
  "signerFingerprint": "sha256:<SHA-256(公钥原始 32 字节)>",
  "manifestDigest": "sha256:<JCS(manifest) 的 SHA-256>",
  "filesDigest": "sha256:<files 清单规范化后的 SHA-256>",
  "signature": "base64…"
}
```

- 签名有效**不等于**被信任：T1 要求指纹在宿主的白名单里。自签名的包仍然是 T0。
- 想要进 T1：先提交公钥给官方仓库审核（P5 起开放流程）；在此之前自签名只对本地开发有意义。
- 不要为了「过签名」而手改清单 —— `manifestDigest` 与 `filesDigest` 都会对不上，
  结果是降级成 T0（不是报损坏，但也没拿到任何好处）。

---

## 八、调试

| 手段 | 说明 |
|---|---|
| 管理页「插件诊断」 | 逐插件显示：层级、加载状态、最近 stage、被禁用原因、权限授予明细 |
| 宿主日志 | 所有插件日志带 `[PLUGIN:<id>]` 前缀；看起来像 token 的串会被替换成 `<redacted>` |
| `air2.log.warn/error` | 出现在诊断页的「最近事件」里 |
| 开发模式（P4） | 从本地目录直载插件，强制 T0，跳过签名，**不写正式注册表**；插件集变化不触发崩溃计数 |
| 完整性检查 | 管理页手动按钮，做全量哈希比对 |

**不要**为了调试去改 `Plugins/` 目录下的文件：加载期会验 `manifest.json` / `entry.js` / `ui/**` / `native/**`
的哈希，改了会被判 `tampered` 并拒绝加载。走开发模式。

---

## 九、常见拒装原因

| code | 原因 | 怎么修 |
|---|---|---|
| `E_MANIFEST_MISSING` | 包根没有 `manifest.json` | 从插件目录内部打包 |
| `E_SCHEMA` | manifest 不符合 `plugin.schema.json` | 按报错字段改；注意 `additionalProperties: false`，拼错的字段也算错 |
| `E_FORMAT_VERSION` | `formatVersion` 不是 2 | 改数字 2（不是字符串） |
| `E_PATH_ESCAPE` | 包里有 `..`、绝对路径、符号链接 | 重新打包，别手工塞条目 |
| `E_SIZE_LIMIT` | 超包体/解压/文件数/单文件上限 | 裁资源（见 `PLUGIN-SYSTEM.md` 3.3） |
| `E_FILE_SET_MISMATCH` | `files` 清单与实际文件不一致 | 用第一节脚本重新生成 |
| `E_HASH_MISMATCH` | 文件内容与 `sha256` 不符 | 重新生成清单（打包后又改过文件） |
| `E_PLATFORM` | `platforms` 不含当前平台 | 加 `ios` |
| `E_PERM_TRUST` | T0 包申请了 critical 权限 | 去掉该权限，或走签名 + 白名单 |
| `E_PERM_CONFLICT` | 命中组合拒装规则（如 `launch.args` + `java.agent`） | 见 `PLUGIN-SECURITY.md` 4.1，拆成两个插件也没用 —— 改成不申请其中一个 |
| `E_JSON_PERM` | `type: json` 申请了运行时权限 | 改成 `js`，或去掉该权限 |
| `E_DEP_MISSING` / `E_DEP_CYCLE` | 依赖缺失 / 循环依赖 | 补依赖或去掉 `depends` |
| `E_SLOT_CONFLICT` | L2 独占 slot 已被占用 | 换 slot 或改用 L1 |
| `E_NATIVE_UNSUPPORTED` | v2 包里出现 `native/` | 去掉，原生插件属 P5 |

---

## 十、提交到官方仓库（P5 起）

1. 源码仓库 + 可复现构建脚本（官方要能自己打出同一个 `filesDigest`）。
2. 权限最小化说明：每一项申请都要写「为什么必需」。
3. 签名公钥 + 指纹。
4. 拒绝项：任何 RCE 面、任何原生代码（除单独审核过的 `native.module`）、
   任何形式的账号数据访问、混淆过的 `entry.js`。

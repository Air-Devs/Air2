# Air2 渲染器插件规范 v1

> 一个 `.air2plugin`（zip）就是一个渲染器。导入后自动出现在「设置 → 渲染」里，无需重启。

---

## 一、包结构

```
myrenderer.air2plugin          ← 就是个 zip，扩展名改一下
├── manifest.json              ← 必需，渲染器描述
├── icon.png                   ← 可选，列表图标（建议 128x128）
└── libs/
    ├── libmygl.dylib          ← GL 库
    └── libmyegl.dylib         ← EGL 库
```

**注意**：`libs/` 下的文件必须是 **iOS 可加载的 `.dylib`**（不是 Android 的 `.so`）。
如果是为 FCL 做的 `.so` 插件，**不能直接用**，需要用 iOS 工具链重新编译。

---

## 二、manifest.json

### 2.1 最小示例

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",
  "displayName": "MyGL",
  "description": "基于 Mesa 的 GL 转译层",
  "version": "1.0.0",
  "author": "example",
  "rendererGLPath": "libs/libmygl.dylib",
  "rendererEGLPath": "libs/libmyegl.dylib"
}
```

### 2.2 完整示例

```json
{
  "formatVersion": 1,
  "rendererId": "com.example.mygl",
  "displayName": "MyGL",
  "description": "基于 Mesa 的 GL 转译层",
  "version": "1.0.0",
  "author": "example",
  "homepage": "https://github.com/example/mygl",

  "rendererGLPath": "libs/libmygl.dylib",
  "rendererEGLPath": "libs/libmyegl.dylib",
  "dlopenLibPaths": [
    "libs/libmygl_deps.dylib"
  ],

  "minMCVer": "1.16.5",
  "maxMCVer": "1.21.4",

  "env": [
    { "type": "NormalEnv",   "key": "MESA_GL_VERSION_OVERRIDE", "value": "4.0" },
    { "type": "ToggleableEnv","key": "ZINK_DEBUG", "value": "compact",
                               "title": "Zink 调试", "toggle": false },
    { "type": "SelectableEnv","key": "MESA_LOADER_DRIVER_OVERRIDE",
                               "title": "驱动",
                               "check": true,
                               "items": {
                                 "defaultValue": "zink",
                                 "values": [
                                   { "value": "zink",   "label": "Zink (Vulkan)" },
                                   { "value": "virpipe","label": "VirGL" }
                                 ]
                               } },
    { "type": "CustomizableEnv","key": "MESA_SHADER_CACHE_MAX_SIZE",
                                "title": "着色器缓存大小",
                                "defaultValue": "512M" }
  ],

  "ios": {
    "minSystemVersion": "14.0",
    "requiresJIT": false,
    "notes": "需要 Metal 设备"
  }
}
```

---

## 三、字段说明

### 3.1 顶层

| 字段 | 必需 | 说明 |
|---|---|---|
| `formatVersion` | ✅ | 目前固定 `1` |
| `rendererId` | ✅ | 全局唯一，建议反向域名 |
| `displayName` | ✅ | 列表显示的短名 |
| `description` | | 一句话说明 |
| `version` | | 插件版本 |
| `author` | | 作者 |
| `homepage` | | 主页链接 |
| `rendererGLPath` | ✅ | GL 库相对路径（相对包根） |
| `rendererEGLPath` | ✅ | EGL 库相对路径 |
| `dlopenLibPaths` | | 额外需要预加载的库（依赖） |
| `minMCVer` / `maxMCVer` | | 支持的 MC 版本范围 |
| `env` | | 环境变量列表（见 3.2） |
| `ios` | | iOS 特有信息（见 3.3） |

### 3.2 env 的四种类型

对应 FCL 的 v2 规格，**格式完全兼容**：

| type | 用途 | 关键字段 |
|---|---|---|
| `NormalEnv` | 固定值 | `key`, `value` |
| `ToggleableEnv` | 开关 | `key`, `value`, `title`, `toggle`（默认值） |
| `SelectableEnv` | 单选 | `key`, `title`, `check`, `items.defaultValue`, `items.values[]` |
| `CustomizableEnv` | 自由输入 | `key`, `title`, `defaultValue` |

**这不是单纯的数据**：`Toggleable`/`Selectable`/`Customizable` 会在设置里**生成对应的 UI 控件**，
用户的选择存进 UserDefaults，启动时拼成环境变量。

### 3.3 ios 块（Air2 扩展）

| 字段 | 说明 |
|---|---|
| `minSystemVersion` | 最低 iOS 版本 |
| `requiresJIT` | 是否依赖 JIT 权限 |
| `notes` | 给用户看的注意事项 |

> FCL 的 manifest 没有这一段。加它是因为 iOS 有 JIT / 签名这些额外约束，
> 渲染器作者需要能表达出来。

---

## 四、加载流程

```
用户导入 zip
   ↓
① 解压到 Documents/Air2/Renderers/{rendererId}/
② 校验 manifest 字段完整性
③ 校验 libs/ 下的文件存在
④ 尝试 dlopen 探测能否加载
   ├─ 成功 → 标记 available，加入列表
   └─ 失败 → 标记 unavailable，附上原因（签名无效 / 架构不匹配 / 缺依赖）
   ↓
⑤ 写入索引 Documents/Air2/Renderers/index.json
   ↓
⑥ 发通知 → 设置页自动刷新，新渲染器出现
```

**第 ④ 步失败不等于导入失败** —— 用户仍能看到这个渲染器，
只是不能选，并显示具体原因。这样 Troubleshooting 容易得多。

---

## 五、iOS 的限制（必须让用户知道）

| 环境 | 能否 dlopen 导入的 dylib |
|---|---|
| **TrollStore** | ✅ 可以（ldid 伪签名即可） |
| **越狱** | ✅ 可以 |
| **正常签名（AltStore/Sideloadly）** | ❌ 提示 "code signature invalid" |
| **App Store** | ❌ 同上 |

**导入页会检查当前环境**，并给出对应说明：

```
· TrollStore 环境 → "可以直接导入使用"
· 其他环境 → "导入的库需要与 Air2 使用相同签名，否则无法加载。
             请用 tools/inject_renderer.sh 把库注入 ipa 后重新签名。"
```

---

## 六、兼容 FCL 插件

FCL 的插件是 APK（含 .so），**不能直接导入**（架构不同）。
但提供**转换器**：如果用户手上有 FCL 插件的源码/配置，

```bash
tools/convert_fcl_manifest.py \
    --input  fcl_plugin_manifest.json \
    --libs   libgl4es_114.so libEGL.so \
    --arch   arm64 \
    --output manifest.json
```

只转**配置部分**（字段一一对应），`.so → .dylib` 需要重新编译 —— 脚本会提示。

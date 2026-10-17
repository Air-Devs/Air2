# 渲染器接入指南

> 给两类读者的文档：
> **① App 集成方** —— 怎么把渲染器系统接进启动流程
> **② 渲染器作者** —— 怎么把自己的 GL 实现打包成 `.air2plugin`

---

# 第一部分：App 集成方

## 1.1 模块总览

```
Core/Renderer/
├── A2RendererPlugin.{h,m}           manifest 解析 + 三级校验
├── A2RendererImporter.{h,m}         zip 导入 → 解压 → 安装
├── A2RendererRegistry.{h,m}         内置 + 插件的统一注册表
└── A2Renderer.{h,m}                 （已有）内置渲染器基类

UI/Screens/Settings/
├── A2RendererSettingsViewController  渲染器选择 + 插件配置
└── A2RendererPluginViewController    插件导入/卸载管理

docs/
├── RENDERER_PLUGIN_SPEC.md         插件包格式规范
└── RENDERER_INTEGRATION.md         本文档
```

## 1.2 数据流

```
插件 zip
   │  A2RendererImporter importPluginAtPath:
   ↓
Documents/Air2/Renderers/{rendererId}/
   │  A2RendererImporter reloadAll
   ↓
A2RendererPlugin（含 availability）
   │  A2RendererRegistry reload
   ↓
A2RendererEntry（内置 + 插件统一）
   │
   ├→ 设置页列出、用户选择
   └→ 启动时解析环境变量
```

## 1.3 关键接口

### 导入插件

```objc
[[A2RendererImporter shared]
    importPluginAtPath:zipPath
              progress:^(double p, NSString *msg) {
                  // 更新进度 UI
              }
            completion:^(A2RendererImportResult *result) {
                if (!result.success) {
                    // result.errorMessage 是给人看的原因
                }
                // 成功后自动发 A2RendererPluginsDidChangeNotification
            }];
```

### 读取渲染器列表

```objc
NSArray<A2RendererEntry *> *all = A2RendererRegistry.shared.allRenderers;
NSArray<A2RendererEntry *> *usable = A2RendererRegistry.shared.availableRenderers;
```

### 选中的渲染器

```objc
// 读
NSString *current = A2RendererRegistry.shared.selectedIdentifier;

// 写（会自动持久化）
A2RendererRegistry.shared.selectedIdentifier = @"builtin.nggl4es";
```

### 解析环境变量（启动时用）

```objc
A2RendererEntry *e = [A2RendererRegistry.shared
                      rendererWithIdentifier:A2RendererRegistry.shared.selectedIdentifier];

NSDictionary<NSString *, NSString *> *env =
    [A2RendererRegistry.shared environmentForRenderer:e];

for (NSString *key in env) {
    setenv(key.UTF8String, env[key].UTF8String, 1);
}
```

## 1.4 启动流程接入点

**目前启动流程未实现。** 接进来时按这个顺序：

```objc
// 1. 取当前渲染器
A2RendererEntry *renderer = [registry
    rendererWithIdentifier:registry.selectedIdentifier];

// 2. 检查可用性
if (renderer.availability != A2RendererAvailabilityAvailable) {
    // 提示用户换一个 —— 不要继续，否则会崩在 dlopen
    return;
}

// 3. 检查版本兼容
if (![registry renderer:renderer supportsMCVersion:mcVersion]) {
    // 提示「该渲染器不支持 1.21.5」
    return;
}

// 4. 应用环境变量
NSDictionary *env = [registry environmentForRenderer:renderer];
for (NSString *k in env) setenv(k.UTF8String, env[k].UTF8String, 1);

// 5. 加载库
NSString *glPath  = renderer.plugin ? renderer.plugin.absoluteGLPath  : builtinGLPath(renderer);
NSString *eglPath = renderer.plugin ? renderer.plugin.absoluteEGLPath : builtinEGLPath(renderer);

void *gl = dlopen(glPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
if (!gl) {
    // dlerror() 里有具体原因
}

// 6. 交给 LWJGL / pojav 的 GL 函数表
```

**⚠️ 注意 RTLD_GLOBAL**：GL 库的符号需要全局可见，
否则后续 `dlsym` 拿不到 `glGetString` 这些。

## 1.5 内置渲染器的库路径

内置渲染器的 `.dylib` 应放在：

```
Air2.app/Frameworks/
├── libnggl4es.dylib
├── libzink.dylib
└── libmobileglues.dylib
```

通过 `NSBundle` 取：

```objc
NSString *path = [NSBundle.mainBundle
    pathForAuxiliaryExecutable:@"libnggl4es.dylib"];
```

**注意**：`pathForAuxiliaryExecutable:` 找的是 `Frameworks/` 和可执行文件同级目录。
用 `pathForResource:ofType:` 找不到（那不是 bundle resource）。

---

# 第二部分：渲染器作者

## 2.1 从 MobileGlues 改一个

MobileGlues 的 CMake **已经支持 iOS**（`if(MACOS)` 分支），
所以改造工作量主要在**构建配置**与**打包**上。

### 步骤

```bash
# 1. Fork 仓库
git clone https://github.com/<你>/MobileGlues.git
cd MobileGlues

# 2. 确认 CMake 的 iOS 分支
#    MobileGlues-cpp/CMakeLists.txt 里已有：
#      if(MACOS)
#          target_link_libraries(... -framework Metal ...)
```

### 3. 新增 iOS 构建脚本

在仓库根建 `build-ios.sh`：

```bash
#!/bin/bash
# 构建 iOS 版 MobileGlues dylib
set -e

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS=14.0
ARCH=arm64

mkdir -p build-ios
cd build-ios

cmake ../MobileGlues-cpp \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=./install

cmake --build . --config Release --parallel

# 产物是 .dylib，改名成插件需要的名字
mkdir -p ../plugin/libs
cp libmobileglues.dylib ../plugin/libs/libMobileGlues.dylib
```

### 4. 写 manifest.json

```json
{
  "formatVersion": 1,
  "rendererId": "com.airdevs.mobileglues",
  "displayName": "MobileGlues",
  "description": "Metal 原生 GL 转译，性能最优",
  "version": "1.0.0",
  "author": "Air-Devs",

  "rendererGLPath": "libs/libMobileGlues.dylib",
  "rendererEGLPath": "libs/libMobileGlues.dylib",

  "minMCVer": "1.17",

  "env": [
    {
      "type": "ToggleableEnv",
      "key": "MG_DEBUG",
      "value": "1",
      "title": "调试日志",
      "toggle": false
    },
    {
      "type": "SelectableEnv",
      "key": "MG_PRECISION",
      "title": "着色器精度",
      "items": {
        "defaultValue": "highp",
        "values": [
          { "value": "highp", "label": "高精度（画质优先）" },
          { "value": "mediump", "label": "中精度（性能优先）" }
        ]
      }
    }
  ],

  "ios": {
    "minSystemVersion": "14.0",
    "requiresJIT": false
  }
}
```

### 5. 打包

```bash
cd plugin
zip -r ../MobileGlues.air2plugin manifest.json libs/ icon.png
```

**注意**：zip 的根必须是 `manifest.json`，不要多套一层目录
（虽然我们支持套一层，但直接放根更规范）。

### 6. 签名（重要）

**如果这个插件是要给自己/用户直接导入的**，需要签名：

```bash
codesign -f -s - --timestamp=none libs/libMobileGlues.dylib
```

- `-s -` 表示 ad-hoc 签名（TrollStore/越狱可用）
- 如果是正规分发，用户需要用自己的证书重签

**如果是随 Air2 一起编译的**，Xcode 会自动签名，不用管。

## 2.2 MobileGlues 特有注意事项

| 项 | 说明 |
|---|---|
| **CMake 已有 iOS 分支** | `if(MACOS)` 里链接了 Metal / QuartzCore |
| **需要 external/ 框架** | `-F${CMAKE_SOURCE_DIR}/external`，确认里面有 libEGL / libGLESv2 |
| **LGPL-2.1 许可** | 修改后分发**必须开源你的修改** |
| **产物名** | CMake 项目名是 `mobileglues`，产物可能叫 `libmobileglues.dylib` |
| **GL + EGL 同一库** | MobileGlues 把两者编在一起，`rendererGLPath` 与 `rendererEGLPath` 填同一个文件即可 |

## 2.3 调试

导入失败时看这几处：

| 现象 | 原因 | 解决 |
|---|---|---|
| 「找不到 GL 库」 | manifest 里的路径不对 | 检查 `rendererGLPath` 相对包根 |
| 「这是 Android 的 .so」 | 打包了 .so | 用 iOS 工具链重编 |
| 「代码签名无效」 | dylib 未签名 | `codesign -f -s -` |
| 「缺少依赖库」 | 依赖的 dylib 不在包里 | 加进 `dlopenLibPaths` 与 `libs/` |
| 「不是有效的 Mach-O」 | 文件损坏或不是动态库 | 用 `file xxx.dylib` 检查 |

**App 内会显示具体的失败原因** —— 不用猜。

---

# 第三部分：其他实现方案（备选）

如果「导入 zip」不适用你的场景，还有这些路：

| 方案 | 适用场景 | 工作量 |
|---|---|---|
| **A. 编译进 IPA** | 内置渲染器（推荐给官方） | 小 |
| **B. 导入 zip** | 用户自行扩展（本文档） | 已完成 |
| **C. 注入注入重打包** | 正规签名环境下分发 | 需外部工具 |
| **D. 越狱/插件管理器** | 越狱用户 | 需越狱环境 |

### 方案 C：注入重打包

正规签名下 `dlopen` 会拒绝未与 App 同签名的 dylib。
绕过方式是在**打包时**就把库放进 `Frameworks/` 并一起签名：

```bash
# 1. 解包 ipa
unzip Air2.ipa -d work
APP=work/Payload/Air2.app

# 2. 放入 dylib
cp libMobileGlues.dylib "$APP/Frameworks/"

# 3. 重签
codesign -f -s "$IDENTITY" "$APP/Frameworks/libMobileGlues.dylib"
codesign -f -s "$IDENTITY" --deep "$APP"

# 4. 重新打包
cd work && zip -r ../Air2-patched.ipa Payload
```

**这条路的好处**：签完就能用，不依赖 TrollStore。

---

# 附录：关键代码位置

| 功能 | 文件:方法 |
|---|---|
| manifest 解析 | `A2RendererPlugin.m: pluginWithManifest:installPath:` |
| 三级校验 | `A2RendererPlugin.m: validate` |
| 架构检测 | `A2RendererPlugin.m: isArm64MachO:error:` |
| dlopen 探测 | `A2RendererPlugin.m: probeLoadabilityOfPath:reason:` |
| 解压安装 | `A2RendererImporter.m: importPluginAtPath:progress:completion:` |
| 环境变量合成 | `A2RendererRegistry.m: environmentForRenderer:` |
| 渲染器列表 UI | `A2RendererSettingsViewController.m: rebuildList` |
| 插件配置 UI | `A2RendererSettingsViewController.m: showConfigForRenderer:` |

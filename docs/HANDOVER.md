# Air2 项目交接文档

> **最后更新**：2026-10-07
> **当前进度**：UI 层完成度约 85%，Core 层完成度约 60%
> **接手须知**：先读「第二章 硬性约束」，那里写了不能违反的规则
>
> ⚠️ **注意：游戏启动流程（Bridge / Natives / Player / JavaApp）已由其他人负责，不要重复开发。**
> 本文档中涉及启动流程的部分仅作接口说明，供协作对接使用。

---

# 第一章 项目概况

## 1.1 基本信息

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/Air-Devs/Air2 |
| 可见性 | public |
| 主分支 | `main` |
| 当前规模 | 118 个 ObjC 文件 / 18523 行 |
| 构建产物 | 未签名 IPA（需自行签名安装） |

## 1.2 项目定位

iOS 端 Minecraft: Java Edition 启动器，基于 pojav 后端重新开发。

**核心诉求（用户原话）**：
- 「禁止石山代码」
- 「UI 必须好看、必须有动画」
- 「先完成 UI + 动画」→ 已完成
- 「版本隔离采用和 ZL2 一样的」
- 「参考一下 ZL2」+「不要完全照抄 ZL2」（边界见 2.4）

## 1.3 参考项目（设计依据）

遇到拿不准的实现，**直接读这两家的源码**，不要凭感觉写：

| 项目 | 地址 | 参考范围 |
|---|---|---|
| **ZL2** | `ZalithLauncher/ZalithLauncher2` | **Android 端成熟实现。UI 排版规格、版本隔离规则、下载引擎、双平台集成、账号流程 —— 全部以它为准** |
| **Amethyst-iOS** | `herbrine8403/Amethyst-iOS-MyRemastered` | iOS 端 pojav 后端落地经验：JIT 环境、渲染桥、Natives 层、启动流程 |

拉源码的方式：
```bash
curl -s -H "Authorization: token <TOKEN>" \
  "https://raw.githubusercontent.com/ZalithLauncher/ZalithLauncher2/main/<文件路径>"
```

ZL2 的完整文件树可以先下载缓存：
```bash
curl -s "https://api.github.com/repos/ZalithLauncher/ZalithLauncher2/git/trees/main?recursive=1" -o zl2.json
python3 -c "
import json
d=json.load(open('zl2.json'))
for x in d['tree']:
    print(x['type'], x['path'])
"
```

---

# 第二章 硬性约束（不可违反）

## 2.1 技术栈（已定，不要改）

| 层 | 语言 | 说明 |
|---|---|---|
| UI | **Objective-C** | 不是 Swift！不是 SwiftUI！ |
| Core | **Objective-C** | |
| 原生层 | Objective-C / C | |
| 启动核心 | Java | 复用 pojav 系 |
| 构建 | Xcode + Makefile + CMake | 不是 Gradle |

**Swift 仅保留为极少量衔接点** —— 目前工程里**一个 Swift 文件都没有**。
用户明确要求过「主用 ObjC」。

## 2.2 依赖方向（CI 强制检查）

```
App → UI → Player → Core → Bridge → Natives
              ↘ Utils ↙
```

- **Core 层禁止 import UIKit / SwiftUI**（CI 会失败）
- **Bridge 层不得包含业务逻辑**
- **Utils 不得反向依赖任何业务层**
- 新增目录必须先登记 `docs/ARCHITECTURE.md`，否则 CI 失败

## 2.3 路径与隔离规则

**`A2GamePath` 是游戏路径的唯一出口**，业务代码禁止手写路径拼接。

版本隔离规则（**逐条对照 ZL2 的 `VersionConfig.kt` / `Version.kt`**）：

```kotlin
isIsolation() = isolationType.toBoolean(全局的 versionIsolation)
  其中 toBoolean:
    FOLLOW_GLOBAL → 全局设置的值      ← 最容易漏，务必确认
    ENABLE        → true
    DISABLE       → false

getGameDir():
    isIsolation()    → {gameHome}/versions/{版本名}/
    customPath 非空  → customPath
    否则             → {gameHome}/

各隔离目录 = getGameDir() + 文件夹名
```

可隔离的五个目录：`mods` / `resourcepacks` / `saves` / `shaderpacks` / `screenshots`
**`libraries` 与 `assets` 始终共用**。

`tests/Core/test_version_isolation.py` 有 22 项验证，改隔离逻辑必须跑。

## 2.4 设计边界：参考 ZL2 的什么、不参考什么

用户说过两句话，边界在这里：

| 参考 ZL2 ✅ | 自己设计 ❌ |
|---|---|
| 布局结构（横屏三区、左右分栏） | 配色方案 |
| 尺寸规格（30%/70% 分区、12 边距、28 圆角） | 具体视觉风格 |
| 交互决策（卡片形态、设置行分组方式） | 动画曲线与时长 |
| 算法（隔离规则、下载校验、双平台映射） | 图标与图标风格 |

**教训**：曾经看到用户发的 ZL2 截图就开始逐像素复刻，被批评了。
正确的做法是读懂它的**设计决策**，然后用 iOS 的方式实现。

## 2.5 不要乱加功能

**用户明确批评过「乱加设置」** —— 我曾编了 30 个设置项但全都没有实现。

**规则：新增设置项 / 按钮 / 页面的前提是有真实实现。**

反面例子（我犯过的）：
- 渲染器选择 —— 但没有任何渲染器代码
- Java 运行时管理 —— 但没有 JRE 管理逻辑
- 内存分配滑块 —— 但没有内存分配逻辑
- 「检查更新」按钮 —— 但没有更新检查实现

**宁缺毋滥。** 没有实现就不放 UI，比放个点了没反应的按钮好。

## 2.6 提交规范

```
<类型>(<范围>): <描述>

类型：feat | fix | refactor | perf | docs | test | chore | build
范围：app | ui | core | bridge | natives | java | ci | docs
```

提交者信息（用户要求）：
```
user.name  = yitenchen123
user.email = 224235981+yitenchen123@users.noreply.github.com
```

推送命令（远程不存 token）：
```bash
git -c http.version=HTTP/1.1 \
    -c http.https://github.com/.extraheader="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64)" \
    -c http.lowSpeedLimit=0 -c http.lowSpeedTime=999 \
    push origin main
```
网络不稳，失败要重试（3-5 次），`http.version=HTTP/1.1` 能显著提高成功率。

## 2.7 改动后必须做的事

```bash
# 1. 跑检查（必须全绿才能提交）
bash scripts/lint_structure.sh

# 2. 改了文件结构后重新生成工程
python3 scripts/gen_xcodeproj.py

# 3. 改了核心算法要跑测试
python3 tests/Core/test_version_isolation.py
python3 tests/Core/test_download_ledger.py
python3 tests/Core/test_resume_validation.py
python3 tests/Core/test_zip_reader.py
```

**⚠️ `Air2.xcodeproj/project.pbxproj` 是脚本生成的**，
不要手工编辑，改了文件结构后重跑 `gen_xcodeproj.py` 即可。

**⚠️ 检查脚本报错时先怀疑自己的改动，不要改脚本绕过。**
每条规则都对应一次真实的 CI 失败。

---

# 第三章 进度总览

## 3.1 完成度

| 模块 | 完成度 | 说明 |
|---|---|---|
| 主题系统 | **95%** | 五套主题 + 动态取色 + 亮暗模式 + 四种配色风格 |
| 基础组件 | **90%** | 卡片、按钮、设置行、进度、导航等 16 个组件 |
| 页面 UI | **85%** | 11 个页面已完成，缺游戏内触控层与文件管理 |
| 下载引擎 | **90%** | 分片、断点续传、镜像、校验齐全；进度 UI 已接 |
| 双平台资源 | **85%** | Modrinth 完整；CurseForge 缺 MurmurHash2 |
| 版本隔离 | **100%** | 逐条对照 ZL2，22 项测试全过 |
| 版本管理 | **80%** | 扫描/选择/删除/重命名完成 |
| 版本安装 | **70%** | 7 阶段流程完成，加载器安装完成 |
| 账号体系 | **80%** | 三种登录方式完成；皮肤/披风未做 |
| 模组加载器 | **75%** | 查询 + 安装完成；OptiFine 不支持自动装 |
| 游戏启动 | — | **已分配给其他人，不要重复开发** |
| 渲染后端 | — | 同上（跟随启动流程一起做） |
| 全局设置 | **20%** | 散在 UserDefaults 里，未做注册表 |

## 3.2 当前能跑通 / 跑不通

**能跑通**：
```
打开 App → 主页显示 → 账号登录（微软/离线/第三方）
        → 设置（主题/背景/镜像开关）
        → 版本管理（列表/切换/删除/重命名）
        → 版本设置（隔离开关，真实读写配置）
        → 下载（Modrinth/CurseForge 切换、搜索、筛选、排序）
        → 下载资源到对应目录
        → 安装版本（7 阶段真实流程）
```

**尚未接通**（由其他人负责）：
```
⬜ 点「启动游戏」—— 目前只有个假动画占位，等 Bridge 层就绪后对接
⬜ 游戏内触控
⬜ 渲染后端
```

**协作接口**：`A2LauncherViewController` 的 `launchGame` 方法是启动入口，
目前只有假动画。启动流程就绪后，把实现替换进去即可。
详见第六章的「协作接口」小节。

---

# 第四章 目录结构与模块清单

## 4.1 完整目录树

```
Air2/
├── App/                    应用入口、生命周期、根导航        （6 文件，648 行）✅
│   ├── main.m
│   ├── A2AppDelegate        （锁横屏）
│   ├── A2SceneDelegate
│   ├── A2RootViewController （根容器 + 任务抽屉）
│   ├── A2NavigationController（自定义转场）
│   └── A2CrashGuard         （崩溃日志落盘）
│
├── Bridge/                 Swift↔ObjC↔JVM 桥接              ⬜ 空，待实现
│
├── Core/                   业务核心（禁止 import UIKit）      （15 文件，6709 行）
│   ├── Account/            ✅ A2Account / A2AccountManager / A2MicrosoftAuth
│   ├── Addons/             ✅ A2ModrinthAPI / A2CurseForgeAPI / A2ContentSource
│   │                          A2MirrorResolver / A2ModLoaderAPI
│   │                          A2ModLoaderInstaller / A2ZipReader
│   ├── Download/           ✅ A2DownloadEngine / A2DownloadTask
│   ├── Path/               ✅ A2VersionIsolation（含 A2GamePath）
│   ├── Version/            ✅ A2VersionManager / A2GameInstaller
│   ├── Renderer/           ⬜ 空，渲染后端选择
│   └── Settings/           ⬜ 空，全局设置注册表
│
├── UI/                     界面                              （38 文件，11166 行）
│   ├── Screens/            ✅ 11 个页面（见 4.3）
│   ├── Components/         ✅ 16 个组件（见 4.2）
│   ├── Control/            ⬜ 空，游戏内触控层
│   └── Theme/              ✅ 主题系统
│
├── Player/                 ⬜ 空，游戏会话宿主
├── Utils/                  ⬜ 空
│
├── Natives/                ⬜ 空，ObjC/C 原生层（渲染桥、输入注入）
├── JavaApp/                ⬜ 空，Java 启动核心
├── Libraries/              ⬜ 空，预编译二进制
├── Assets/                 ⬜ 空，图标与本地化
├── cmake/ scripts/ docs/ tests/
└── Air2.xcodeproj/         （脚本生成，勿手改）
```

## 4.2 组件清单（`UI/Components/`）

| 文件 | 作用 |
|---|---|
| `A2GlassCard` | MD3 卡片。用 `surfaceContainer` 五档层级表达深度，**不用毛玻璃** |
| `A2CardPosition` | 分组内元素的圆角位置计算 |
| `A2CardTitleBar` | 卡片顶栏 |
| `A2PrimaryButton` | 渐变主按钮，弹簧按压 + 加载态 |
| `A2SettingsRow` | 设置行（支持图标/副标题/箭头/开关/自定义右侧） |
| `A2SettingsSection` | 设置分组（**自动处理首/中/末行圆角**） |
| `A2CategoryNavView` | 左侧分类导航（设置页与下载页共用） |
| `A2RingProgress` | 环形进度 |
| `A2ProgressBar` | 线性进度条 + 速度 |
| `A2TaskProgressView` | 任务卡片 |
| `A2TaskDrawer` | 底部任务抽屉（可拖拽展开） |
| `A2VersionCard` | 版本卡片 |
| `A2QuickActionCard` | 快捷操作卡 |
| `A2BackgroundView` | 自定义背景（含**右侧渐隐**处理） |
| `A2ColorWheel` | 二维大色盘 |
| `A2Toast` | 轻提示 |

## 4.3 页面清单（`UI/Screens/`）

| 页面 | 状态 | 说明 |
|---|---|---|
| `Home/A2LauncherViewController` | ✅ | 横屏三区主界面 |
| `A2BaseViewController` | ✅ | 页面基类（统一顶栏 + 背景） |
| `Account/A2AccountViewController` | ✅ | 账号列表 |
| `Account/A2LoginViewController` | ✅ | 三种登录方式 |
| `Settings/A2SettingsViewController` | ✅ | 设置（左导航 + 右内容） |
| `Settings/A2AppearanceSettings` | ✅ | 外观分组构建器 |
| `Settings/A2BackgroundSettingsViewController` | ✅ | 背景设置 |
| `Settings/A2ColorThemeDialog` | ✅ | 颜色主题弹窗（大色盘） |
| `Version/A2VersionListViewController` | ✅ | 版本管理（左目录 + 右列表） |
| `Version/A2VersionSettingsViewController` | ✅ | 版本设置（含隔离） |
| `Version/A2VersionRowView` | ✅ | 版本行 |
| `Download/A2DownloadViewController` | ✅ | 下载中心（左导航） |
| `Download/A2DownloadListViewController` | ✅ | 资源列表（搜索/筛选/排序） |
| `Download/A2InstallingViewController` | ✅ | 安装进度（7 阶段） |

---

# 第五章 关键设计决策（改动前必读）

## 5.1 主题系统：不用 UIColor 动态颜色 ⚠️

**踩过的坑**：最初用 `colorWithDynamicProvider` 做亮暗适配，
结果 iPhone 暗色模式下卡片仍是亮色。

**根因**：动态颜色由「视图自身的 trait 环境」解析，
而取色发生在 `applyTheme` 时，视图往往**还没加入 window 层级**，
解析用的是默认 trait（亮色）。

**现方案**：色板分两段

```objc
A2ColorSlot  → 同时持有亮色与暗色的【具体】色值
cXxx 字段    → 经 resolvedForDark: 解析后的具体 UIColor
```

视图统一用 `s.cPrimary` / `s.cSurface` 取色，**不依赖 trait 解析时机**。

**改色板时必须同步四处**（有检查脚本兜底）：
1. `A2ColorScheme.h` 的 `A2ColorSlot *xxx` 声明
2. `A2ColorScheme.h` 的 `cXxx` 解析字段声明
3. `A2ColorScheme.m` 的 `cXxx` 属性 + `A2RESOLVE(xxx, cXxx)`
4. `A2ColorTheme.m` 的亮暗两套推导值 + `A2PAIR(xxx)`

漏一处不会编译报错，但**运行期会取到 nil**（界面透明或黑块）。
`scripts/check_imports.py` 有色板对齐检查。

## 5.2 下载引擎：断点续传要严格校验 ⚠️

来自 ZL2 的 `Fetcher.ResumeContext.canResume`：

- 必须 **206**（200 说明服务端忽略了 Range）
- `Content-Encoding` 必须是 `identity`（压缩传输时 Range 语义错乱）
- `contentLength == bodyLength + 已收字节`
- 优先用 **strong ETag**（`W/` 开头的弱 ETag 不作依据），否则校验 URL + Last-Modified
- `Content-Range` 的 start/end/total 逐字段精确匹配
- `end - start + 1 == bodyLength`

**为什么这么严**：接受「看起来差不多」的 206 会导致文件**静默损坏**——
大小对、内容错，极难排查。

**其他机制**：
- 半成品写 `.part`，校验通过后原子替换
- 看门狗看「有没有真的写进文件」（CDN 心跳字节会让 URLSession 空闲超时永不触发）
- 测速**逐秒采样、不平滑不外推**（ZL2 的做法）
- 进度支持**负 delta 回退**（换源/重试时上报负值）

**⚠️ 暂停/恢复用自有断点机制**（半成品文件 + Range 请求），
**不要用** `cancelByProducingResumeData:` —— 那是 `NSURLSessionDownloadTask` 的方法，
我们用的是 `dataTask`，**两套 API 不能混用**。

## 5.3 双平台资源抽象 ⚠️

两家的数据模型差异不小，若让 UI 分别处理，每个页面都要写两套：

| 项 | Modrinth | CurseForge |
|---|---|---|
| 项目 ID | 字符串 | 数字 |
| 分类 | facets 字符串 | classId 数字 |
| 分页 | offset/limit | index/pageSize |
| 排序 | 字符串 | 数字码 |
| 下载限制 | 无 | `allowModDistribution` |

**统一成 `A2ContentItem` / `A2ContentVersion`**，UI 只面对一种结构。

**两个照搬 ZL2 的设计**：

1. **排序字段枚举同时携带两家的值**
```objc
A2ContentSortFieldRelevance → CurseForge "1" / Modrinth "relevance"
A2ContentSortFieldDownloads → CurseForge "6" / Modrinth "downloads"
A2ContentSortFieldPopularity→ CurseForge "2" / Modrinth "follows"
A2ContentSortFieldNewest    → CurseForge "11"/ Modrinth "newest"
A2ContentSortFieldUpdated   → CurseForge "3" / Modrinth "updated"
```
新增排序只需加一个枚举项，不用改两处 switch。

2. **分类一对多映射**
`A2ContentClass` 同时给出 CurseForge `classId`、Modrinth `project_type`、
以及对应的**版本隔离目录名**。

## 5.4 镜像加速

CurseForge 与 Modrinth 的 CDN 在国内访问很慢，MCIM 做了反向代理：

```
https://edge.forgecdn.net  →  https://mod.mcimirror.top
https://cdn.modrinth.com   →  同上
https://media.forgecdn.net →  同上
```

策略（与 ZL2 一致）：
- **只在检测到中国大陆网络时启用**（看时区，不发请求探测 IP ——
  判断错了只影响快慢，不影响功能）
- 用户可选「官方优先」/「镜像优先」
- 返回**候选列表**交给下载引擎依次尝试 —— 天然支持失败回退

## 5.5 凭据存储

**API Key / Token 存 Keychain，不硬编码**（硬编码会进 git 历史且无法吊销）。

- CurseForge Key：`A2CurseForgeAPI`，用
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（仅本机、不参与 iCloud 备份）
- 账号文件：`Documents/accounts.json`，权限收紧到 `0600`

## 5.6 UI 规格速查

**主页布局**（横屏三区）：
```
┌──────────────────────────────────────────────────┐
│  Air2                            [账号] [下载] [设置] │
├────────────────────────┬─────────────────────────┤
│                        │  账户卡（头像 64 居中）    │
│   自定义背景 / 主题渐变   │  版本卡（含启动按钮）      │
│   70%                  │  最近游玩（横滑）          │
│                        │  30%                    │
└────────────────────────┴─────────────────────────┘
```
「操作区 30% / 内容区 70%」来自 ZL2 的 `ContentWeight=7f : ActionMenuWeight=3f`。

**尺寸常量**（`A2Metrics.h`）：
| 项 | 值 |
|---|---|
| 卡片外边距 / 内边距 / 间距 | 12 / 12 / 12 |
| 圆角（MD3 Shape Scale） | 4 / 8 / 12 / 16 / **28** |
| 顶栏高 | 52 |
| 按钮高 | 52 |
| 头像 | 大 64 / 小 48 |
| 触控最小尺寸 | 44 |

**「一组行拼成一张卡」**（`A2SettingsSection`）：
```
┌────────────────┐  ← 圆角 28（首行）
│ 设置项          │
├────────────────┤  ← 圆角 4（中间行）
│ 设置项          │
├────────────────┤  ← 圆角 4（中间行）
│ 设置项          │
└────────────────┘  ← 圆角 28（末行）
     行间距 2
```

**动画**：统一用 `UIViewPropertyAnimator` + `UISpringTimingParameters`（damping 0.78）。
`A2ExpressiveSpring`（damping 0.72）用于强调操作。
**不用 ease-in-out**（iOS 上手感发木）。

---

# 第六章 协作分工与接口

## 6.1 分工现状

| 范围 | 负责人 | 状态 |
|---|---|---|
| **UI 层**（`Air2/UI/`） | 本文档的接手人 | 完成度 85% |
| **Core 层**（`Air2/Core/`） | 本文档的接手人 | 完成度 60% |
| **游戏启动流程** | **其他人** | 进行中 |
| └ `Air2/Bridge/` | 其他人 | 未开始 |
| └ `Air2/Natives/` | 其他人 | 未开始 |
| └ `Air2/Player/` | 其他人 | 未开始 |
| └ `Air2/JavaApp/` | 其他人 | 未开始 |

**⚠️ 不要重复开发启动流程。** 本文档只说明需要对接的接口。

## 6.2 需要对接的接口

### 6.2.1 启动入口（UI → 启动流程）

**位置**：`Air2/UI/Screens/Home/A2LauncherViewController.m`

```objc
- (void)launchGame {
    // 目前是假动画占位，等启动流程就绪后替换为真实实现
    _launchButton.loading = YES;
    dispatch_after(..., ^{
        self.launchButton.loading = NO;
        [A2Toast show:@"启动流程尚未接入" inView:self.view];
    });
}
```

**启动流程侧需要提供的接口**（建议签名，可协商）：

```objc
/// 启动游戏
@protocol A2GameLaunching <NSObject>
- (void)launchVersion:(A2Version *)version
              account:(A2Account *)account
             progress:(void (^)(NSString *stage, double progress))progress
           completion:(void (^)(BOOL success, NSError *error))completion;
@end
```

**所需数据**（UI 侧已准备好，可直接取）：

| 数据 | 来源 |
|---|---|
| 要启动的版本 | `A2VersionManager.shared.currentVersion` |
| 版本所在目录 | `A2Version.gameDirectory`（隔离逻辑已处理） |
| 版本 json 路径 | `A2Version.jsonPath` |
| 客户端 jar 路径 | `A2GamePath.versionJarPath:` |
| 当前账号 | `A2AccountManager.shared.currentAccount` |
| 账号凭据 | `A2Account.accessToken` / `.profileID` / `.username` |
| 内存分配 | `A2VersionIsolation.ramAllocation`（-1 表示跟随全局） |
| JVM 参数 | `A2VersionIsolation.jvmArgs` |
| 游戏参数 | `A2VersionIsolation.gameArgs` |
| 隔离开关 | `A2Version.isIsolationEnabled` |

### 6.2.2 进度回传（启动流程 → UI）

启动过程较长，UI 侧已准备好进度显示组件：

| 组件 | 用途 |
|---|---|
| `A2RingProgress` | 环形总进度 |
| `A2ProgressBar` | 线性进度 + 速度 |
| `A2TaskProgressView` | 任务卡片 |
| `A2TaskDrawer` | 底部任务抽屉（可拖拽展开） |
| `A2InstallingViewController` | 完整的分阶段进度页（可参考它的 7 阶段实现） |

`A2InstallingViewController` 里的阶段枚举可作为启动阶段的参考：

```objc
typedef NS_ENUM(NSInteger, A2InstallStage) {
    A2InstallStageFetchManifest = 0,
    A2InstallStageDownloadJSON,
    A2InstallStageDownloadJar,
    A2InstallStageDownloadLibraries,
    A2InstallStageDownloadAssets,
    A2InstallStageInstallLoader,
    A2InstallStageFinalize,
    A2InstallStageCount,
};
```

### 6.2.3 版本安装器（可作为启动流程的参考）

`A2GameInstaller` 已经实现了完整的**版本安装**流程，
启动流程可以参考它的编排方式与进度回传机制：

```objc
- (void)install:(A2InstallRequest *)request
       progress:(void (^)(A2InstallStage stage, double progress, NSString *message))progress
     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
```

**注意**：`A2GameInstaller` 是**安装**（下载文件到磁盘），
不是**启动**（创建 JVM 并运行）。两者是不同阶段，不要混淆。

## 6.3 启动流程需要参考的资料

如果协作方需要，这些是本项目已确认的参考来源：

| 要做的事 | 参考文件 |
|---|---|
| JVM 启动 | Amethyst `Natives/JavaLauncher.m` |
| 渲染桥 | Amethyst `Natives/ctxbridges/{osm,gl,vk}_bridge.m` |
| 渲染面 | Amethyst `Natives/SurfaceViewController.m` |
| Metal layer | Amethyst `Natives/GameSurfaceView.m` |
| JIT 环境 | Amethyst `Natives/pocketj_jit/` |
| 输入注入 | Amethyst `Natives/input/` |
| 参数拼装 | ZL2 `game/launch/LaunchArgs.kt`、`GameLauncher.kt` |
| 启动流程 | ZL2 `game/launch/GameLaunchFlow.kt` |
| Java 侧核心 | Amethyst `JavaApp/src/launcher/` |

## 6.4 本文档接手人应做的事

**不包含启动流程**，focus 在这些：

| 优先级 | 任务 | 说明 |
|---|---|---|
| P1 | `Core/Renderer/` | 渲染后端注册与选择（供启动流程调用） |
| P1 | `Core/Settings/` | 全局设置注册表（目前散在 UserDefaults） |
| P1 | 皮肤 / 披风 | 账号页有入口但无实现，参考 ZL2 `game/account/wardrobe/` |
| P2 | CurseForge 更新检查 | 缺 MurmurHash2 实现 |
| P2 | `UI/Control/` | 游戏内触控层（也可归入启动流程侧） |
| P2 | 文件管理页 | 浏览游戏目录，参考 ZL2 `filemanager/` |
| P2 | 整合包导入/导出 | 参考 ZL2 `game/download/modpack/` |
| P3 | 应用图标、本地化、崩溃上报 | 打磨项 |

# 第七章 环境限制与工作方式

## 7.1 iSH 环境的坑

| 坑 | 现象 | 解决 |
|---|---|---|
| `file_write` 静默失败 | 报告成功但文件没写 | 目标目录不存在时会发生。**先 `mkdir -p` 确认成功再写文件** |
| `mkdir -p` 偶发失败 | `can't create directory` | 重试几次，或换个已存在的目录 |
| BusyBox grep | 不支持 `--include`（GNU 扩展） | 用 `find ... -name` 喂文件 |
| 正则爆内存 | `MemoryError` | 检查脚本里的正则要简单直接，避免嵌套量词 |
| 无 ObjC 编译器 | 只能靠 CI | **见 7.2** |

## 7.2 关于本地编译验证

**iSH 里没有 ObjC 编译器**，所以本地只能做静态检查，
真正的编译验证要靠 CI。

曾尝试装 clang（`apk add clang`），但：
- 包很大（17 个依赖，几百 MB）
- 安装耗时超过 15 分钟，中途容易被中断
- **即使装上也只能做语法检查**（缺 iOS SDK，编不了 target）

**结论：暂时不装，靠 CI + 静态检查脚本。**

### 这套静态检查已经抓过的问题

`scripts/` 下的检查脚本不是摆设，每一条规则都对应一次真实的 CI 失败：

| 规则 | 抓过的真实错误 |
|---|---|
| 只读属性赋值 | `UIViewPropertyAnimator.delay` 是只读的 |
| 属性归属 | 在 `A2ColorScheme` 上访问 `A2ColorTheme` 的属性 |
| 约束数组嵌套 | `A2GlassCard` 启动崩溃（数组套数组） |
| 变量声明顺序 | `use of undeclared identifier 't'` |
| 头文件引用 | CI 三次失败 |
| 声明实现一致 | `cancelAll` 声明了但没实现 |
| 属性修饰符跨文件 | `illegal redeclaration` |
| block 循环引用 | 4 处真实内存泄漏 |
| 色板字段对齐 | 2 个色槽从未被解析（运行期取 nil） |
| 组件间依赖 | `unknown type name`（10 个编译错误） |

**所以：改完代码一定要跑 `bash scripts/lint_structure.sh`。**
它拦下来的问题，比你想象的要多。

## 7.3 CI 与日志获取

**CI**：`.github/workflows/build.yml`，macOS runner，产出未签名 IPA。

**拿日志的方式**：
```bash
# 列出最近的 run
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/Air-Devs/Air2/actions/runs?per_page=5"

# 看某个 run 的 job 状态
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/Air-Devs/Air2/actions/runs/<RUN_ID>/jobs"

# 下载编译日志（失败时自动上传 build-log artifact）
curl -sL -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/Air-Devs/Air2/actions/artifacts/<ARTIFACT_ID>/zip" -o log.zip
unzip -o log.zip && grep -E "error:|warning:" xcodebuild.log
```

**注意**：job logs API 需要 admin 权限（403），但 artifact 可以下载。

## 7.4 推送重试

网络不稳，推送经常失败：
```bash
for i in 1 2 3 4 5; do
  timeout 100 git -c http.version=HTTP/1.1 \
      -c http.https://github.com/.extraheader="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64)" \
      -c http.lowSpeedLimit=0 -c http.lowSpeedTime=999 \
      push origin main 2>&1 | tail -2 && break
  sleep 15
done
```

---

# 第八章 已知问题清单

## 8.1 代码层面的隐患

| 问题 | 影响 | 状态 |
|---|---|---|
| CurseForge 更新检查 | 用 MurmurHash2 而非 SHA1，未实现 | 接口返回 nil 而不给错数据 |
| OptiFine 不支持自动安装 | 官方无公开 API | UI 需明确标注「手动安装」 |
| `Core/Settings/` 未实现 | 设置散在 UserDefaults | 后续重构 |
| 部分页面用示例数据 | 版本列表已接真实数据，其他待接 | — |

## 8.2 未验证的部分

**代码从未在真机完整跑过 UI 流程**。CI 只能验证编译通过，
实际运行表现需要真机测试。

已知会在真机暴露的问题类型：
- 布局在横屏 iPad 与 iPhone 上的适配
- 动画流畅度
- 暗色模式下的实际观感

## 8.3 安全提醒

⚠️ **GitHub Token 曾在会话中明文出现，需要 revoke 并重新生成。**

⚠️ **CurseForge API Key 也曾在会话中明文出现**，
如果在意安全可以去 console.curseforge.com 重新生成。

**不要把任何 Key 硬编码进源码。**

---

# 第九章 快速上手

## 9.1 第一天的建议顺序

```bash
# 1. 确认 clang 装好了（如果没有，先装）
which clang || nohup apk add --no-cache clang > /tmp/clang.log 2>&1 &

# 2. 克隆仓库
git clone https://github.com/Air-Devs/Air2.git && cd Air2

# 3. 跑检查，建立基线
bash scripts/lint_structure.sh

# 4. 跑测试，确认核心算法没问题
for t in tests/Core/*.py; do python3 "$t" | tail -3; done

# 5. 生成 Xcode 工程看看结构
python3 scripts/gen_xcodeproj.py

# 6. 读这个文档的第二章（硬性约束）和第五章（关键设计）
```

## 9.2 第一个任务建议

**⚠️ 不要做启动流程 —— 那部分已分配给其他人。**

接手人的第一个任务建议从 **`Core/Settings/` 全局设置注册表**开始，因为：

- 它是 P1，且**多个模块依赖它**（渲染器选择、内存分配、Java 运行时都要读设置）
- 目前设置散落在 `A2GlobalGameSettings` 和裸的 UserDefaults 里，
  每加一个设置就要改三处，已经是负担
- 可以独立开发，不阻塞其他部分
- ZL2 有完整的参考实现：`setting/AllSettings.kt`、`setting/SettingsRegistry.kt`

**具体做法**：
1. 读 ZL2 的 `setting/` 目录，理解它的注册表模式
2. 在 `Air2/Core/Settings/` 下实现：
   - 设置项的类型安全定义（Bool / Int / String / Enum）
   - 默认值 + 持久化 + 变更通知
   - 集中注册，避免散落
3. 把现有的 `A2GlobalGameSettings` 迁移进去

**第二个任务**：`Core/Renderer/` 渲染后端注册与选择。
这部分 UI 已有入口（设置页），但后端是空的。

## 9.3 有问题时怎么办

1. **读 ZL2 / Amethyst 的源码** —— 它们是真机验证过的
2. **看 `docs/` 下的其他文档**：
   - `ARCHITECTURE.md` —— 目录职责权威定义
   - `DECISIONS.md` —— 架构决策记录（ADR）
   - `DEPENDENCIES.md` —— 依赖清单
   - `UI-DESIGN.md` —— UI 设计规范
3. **检查脚本的报错要认真看** —— 每条规则都对应一次真实失败

---

# 附录 A：常用命令速查

```bash
# 检查
bash scripts/lint_structure.sh
python3 scripts/lint_objc.py
python3 scripts/check_imports.py
python3 scripts/verify_pbxproj.py

# 测试
python3 tests/Core/test_version_isolation.py
python3 tests/Core/test_download_ledger.py
python3 tests/Core/test_resume_validation.py
python3 tests/Core/test_zip_reader.py

# 工程
python3 scripts/gen_xcodeproj.py

# 统计
find Air2 -name '*.m' -o -name '*.h' | xargs wc -l | tail -1
```

# 附录 B：文件规模约定

| 行数 | 处理 |
|---|---|
| ≤ 1000 | 正常 |
| > 1000 | 检查脚本会提示，确认是否承担了多个职责 |

**注意：不设硬性行数上限。**
判断标准是「文件里是否存在两组不相干的关注点」，不是行数。
（早期曾设 400 行硬限，导致为满足指标而拆出无意义的分类文件，
反而增加复杂度 —— 已废弃该规则。）

**当前最大文件**：`A2LauncherViewController.m` 约 760 行。

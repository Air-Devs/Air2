# 插件系统 × 主页自定义：现状、计划与实现目标

> 版本：2026-11-01 · 分支 `feat/plugin-merge`（工作树 `Air2_pmerge2`）
> 读者：下周接着做的自己（含新加入的人）
> 口径：**只写代码里能指出行号的事实**；没验证的一律标「未验证」。

---

## 0. 一句话结论

- **插件系统的「地基」已经完整**：manifest 校验 → 贡献点校验 → 注册表 → 权限存储 → 安装/卸载接线 → 7 处 UI 插入点，全部落地且构建机编译通过。
- **主页自定义只完成了模型层（M1）**：布局文档 / 落盘 / 数据源三件已进主线，**UI 一层没接**（网格、卡片、编辑态都在 `home-wip` 分支，未移植）。
- **当前真正的阻塞点是「两套东西抢同一块地」**：插件想往主页贴东西，主页自定义想「用户说了算」。解法已定：**结构层（用户）/ 内容层（插件）分离**，中间用「卡片实例」对齐。

---

## 1. 现状：插件系统

### 1.1 已实现（代码在主线，可指出行号）

| 模块 | 文件 | 行数 | 作用 |
|---|---|---|---|
| 贡献点校验器 + 注册表 | `Air2/Core/Plugin/A2PluginContribution.h/.m` | 382 / 1640 | v2 manifest 的 `ui.slots` / `theme` / `version.decorate` / `settings` 四类贡献点校验、排序、去重、幂等卸载 |
| manifest 校验（P1） | `Air2/Core/Plugin/A2PluginManifest.m` | 1359 | 字段/类型/路径安全/体积限制；`entry` 为 js 必填、json 禁止 |
| 安装器 | `Air2/Core/Plugin/A2PluginInstaller.m` | 1116 | 解包 → 校验 → 算哈希 → 落盘 → 接入贡献点；`contributionSetForInstalledPluginId:` 取回 |
| 权限存储 | `Air2/Core/Plugin/A2PluginPermissionStore.m` | 820 | 授权记录 + 里程碑（P1…P5）；**「当前版本不可用」的判定来源** |
| 包解压/预检 | `A2PluginPackageExtractor.m` | — | 中央目录预检、根 manifest 检查、type/里程碑预检（本轮新增） |
| UI：列表/详情/权限/确认 | `Air2/UI/Plugin/*` | 9 个文件 | 插件管理页、详情页、权限授予页、关键能力二次确认、启动链确认 |
| UI：贡献点渲染 | `A2PluginContributionHost.h/.m` | — | 7 处插入点的统一出口（工具栏 / 卡片徽标 / 版本列表徽标 / 版本详情头 / 设置分区 / 主页分区 / 启动遮罩） |
| 单测 | `tests/Plugin/plugin_contribution_tests.m` | 767 | 11 组用例（校验/排序/去重/幂等卸载/错误码） |

### 1.2 本轮从真机反馈修掉的两处

1. **「任何权限都显示『当前版本不可用』」**
   根因：`A2PluginListViewController.m` 里 `_hostMilestone = A2PluginMilestoneP1`（枚举值 1），而所有权限的生效里程碑是 P2。
   修法：改成 `A2PluginMilestoneP2`（宿主当前阶段）。
2. **`bad-js-type` 报 `E_FIELD` 而不是 `E_TYPE_UNSUPPORTED`**
   根因：P1 字段校验先发现「type=js 但缺 entry」，于是报字段错。
   修法：`A2PluginPackageExtractor` 在解析 manifest **之前**做「类型 + 里程碑」预检，P2 宿主见 `js` 直接返回 `E_TYPE_UNSUPPORTED`。

### 1.3 验收状态（务必照此复测）

- 构建机（Ubuntu + CMake）**编译通过**（`BUILD_RC=0`，0 个 `error:`）。
- 单测：**只跑过 `--syntax-only` 类型检查**（Linux 无 ObjC 运行时）。**行为验证必须在 macOS 上跑**：
  `python3 tests/Plugin/run_plugin_tests.py`
- 真机用例（用 `Air2-P2-plugin-fixtures.zip`，共 8 个包）：

| 用例 | 期望 | 判据日志 |
|---|---|---|
| `good-badge` | 主页卡片右上角出现「测试徽标」 | `[A2-PLUGIN-UI] home.card.badge 渲染 1 条（跳过 0 条）` |
| `good-settings` | 设置页「插件」分类下多一张卡 | `[A2-PLUGIN] 贡献点校验通过：<id> <ver>` |
| `good-full` | 徽标 + 设置卡 + 版本行装饰一起出现 | 同上 + `[A2-PLUGIN] 贡献点已接入注册表` |
| `bad-*`（7 个） | 全部被拒，错误码分别为 `E_SLOT_UNKNOWN` / `E_COMPONENT_UNKNOWN` / `E_CONTRIB_DUPLICATE` / `E_FIELD` / `E_HOST_VERSION_MIN` / `E_FORMAT_VERSION` / `E_TYPE_UNSUPPORTED` | 安装失败提示里的错误码 |
| 卸载 `good-badge` | 徽标消失、无残影 | `[A2-PLUGIN] 贡献点已移出注册表：<id> 共 N 条` |
| `good-theme` / `good-full` 的颜色主题 | 设置 → 外观 → 颜色主题：左列出现「插件主题」分组（含主色点），选中并确认后整套界面换色；杀进程重开仍是它 | `[A2-PLUGIN-UI] 颜色主题 列出来自插件的主题 N 套（已启用插件 M 个）` + `[A2-PLUGIN-UI] 颜色主题 已切换为插件主题：<id>（N 色）` |

### 1.4 已知缺口（按优先级）

1. **`theme` 贡献点的 UI 入口** —— 已接（缺口②修好）：`设置 → 外观 → 颜色主题` 里多了「插件主题」分组，
   数据来自**每个已启用插件自己**的 `themeTokens`（`A2PluginContributionRegistry -themeTokensForPlugin:`），
   选中即生效并持久化（`A2ThemeManager -applyPluginThemeFromPlugin:name:tokens:`，会先关掉自动取色、清掉手动种子色）。
   没有插件提供色板时该分组整个不出现。
2. **单测只在 Linux 做过类型检查**，行为未验证。
3. **P2 阶段不支持 `type: js`**（没有 JSCore）——按设计拒装，不是 bug。

---

## 2. 现状：主页自定义

### 2.1 已进主线（M1，模型层）

| 文件 | 行数 | 作用 |
|---|---|---|
| `Air2/Core/Home/A2HomeLayout.h/.m` | — / 1138 | 五段式卡片布局文档：卡片实例列表（`kind` / `size` / `target` / 顺序 / 方案）、档位白名单、规范化兜底 |
| `Air2/Core/Home/A2HomeStore.h/.m` | — / 453 | 落盘（`home-layout.json`）、多方案、导入导出（先备份 `.bak`）、恢复默认只重置当前方案 |
| `Air2/Core/Home/A2HomeRuntime.h/.m` | — / 206 | 数据源：最近游玩、收藏等 |

卡片实例模型（`A2HomeLayout.h:241-246`）：

```objc
@property (nonatomic, assign) A2HomeCardKind kind;     // 内置卡种类
@property (nonatomic, assign) A2HomeCardSize size;      // 四档尺寸
@property (nonatomic, strong, nullable) A2HomeCardTarget *target;  // 绑定目标（版本/实例）
```

### 2.2 **没进主线**的部分

- `A2HomeGridView`（436 行，含拖拽）、`A2HomeCardView`（616 行）、加卡面板、编辑态工具条 —— 都在 `home-wip` 分支。
- 该分支**没有 CMakeLists**（旧构建体系），且比主线少 145 个提交 ⇒ **只能按文件移植，绝不能整支合并**。
- 主题亮暗切换时卡片不重着色；`position` 只有字段没有自由布局交互；多方案没有「切换方案」入口。

---

## 3. 实现目标（把两件事合成一条线）

### 3.1 职责划分（这是全案的根）

```
结构层（用户拥有）：布局文档 home-layout.json
  卡片实例列表：kind / size / target / 顺序 / 方案
  谁排第几、多大、在哪 —— 只有用户能改

内容层（插件拥有）：贡献点
  插件只声明「我能提供什么内容」，不碰布局
  宿主把「内容」填进「卡片实例」或「固定锚点」
```

### 3.2 slot 的两类锚点

```
固定锚点（与布局无关，永不被用户重排）
  home.toolbar.action   工具栏按钮（上限 4）
  home.section          卡片区下方的插件分区（上限 1）

卡片锚点（绑到具体卡片，跟着卡片走）
  card.badge            挂在指定 card（按 kind 或 cardId）
  card.content          插件提供的卡片正文（只对 kind=plugin 的卡有效）
```

### 3.3 冲突规则（写进规范，避免以后扯皮）

1. 插件优先级只决定「首次插入时的默认位置」，用户排过之后一律以布局为准。
2. 容量上限（工具栏 4、徽标 1、插件卡每插件默认 1 张）由宿主裁剪。
3. 插件禁用 ⇒ 卡转占位；插件卸载 ⇒ 占位保留 7 天或用户手动清（软失败，不自动删卡）。
4. 主页编辑态下插件内容只读（不能点、不能拖卡内元素）。

---

## 4. 计划（按步可验证，每步都能单独编译）

### 4.1 里程碑表

| 步骤 | 内容 | 状态 |
|---|---|---|
| Step 1 | 搬 Core/Home 三件 + 单测（不碰 UI） | ✅ 完成 |
| Step 2 (M2) | Host 增加「卡片来源解析」接口（内置卡 / 插件卡 / 不可用三态，纯模型） | ⏳ **下一步第一件事** |
| Step 3 | 一次改主页 VC：网格 + 插件插槽同时接（同文件只改一次） | 待做 |
| Step 4 | `home.toolbar.action` / `home.section` 先接（不在卡片内，风险最低） | 待做 |
| Step 5 | `card.badge` 加 target 绑定（兼容旧插件：未指定 = 挂首张卡） | 待做 |
| Step 6 | 插件卡（`kind=plugin`）可拖拽、可删 | 待做 |
| Step 7 | 主页 P1/P2：自由布局、每卡设置、多方案入口、iPhone 单列 | 待做 |
| Step 8（新增） | 插件页面能力：**只做内置 HTML 页面** + 网络总开关 | 规划中（未实现） |

### Step 8 插件页面（2026-11-07 阿帅拍板，先入规划、以后再做）

口径固定为四条，后续实现不得偏离：

1. **只支持“内置 HTML 页面”**：插件包内 `html/` 目录，manifest 里的 `entry` 必须是
   包内相对路径且以 `.html` 结尾；**不做在线网页内嵌**（任何远程 URL 不得直接当页面源）。
2. **默认禁网**：页面只能读自己的 `air2plugin://<pluginId>/...` 资源；
   `http/https` 的导航与子资源一律拦截。需要联网的插件必须在 manifest 里显式申请。
3. **网络总开关**：在**该插件自己的设置界面**里放一行「允许联网」。
   用户同意前一律禁网；关闭后立即生效（导航与子资源都被拦），状态持久化、按插件独立记录。
4. **安全边界**：scheme 只读、路径穿越拦截、注入 CSP；页面外的原生导航由宿主负责
   （插件不得自行 push 页面）。

分层定位（最终形态）：

| 层 | 形态 | 状态 |
|---|---|---|
| 1 | 声明式 JSON 页面（宿主用 MD3 组件渲染） | 默认层，后续做 |
| 2 | 内置 HTML（沙箱 + 默认禁网） | **Step 8 要做** |
| 3 | 外链（SFSafariViewController 打开） | 只作为“链接卡”，不进 App 内嵌 |
| 4 | JS 自定义视图（JSCore） | P3a 之后 |

已知代价：一个 WKWebView 约 50~100MB 内存；与 MD3 / 液态玻璃观感不一致，
因此只建议给「信息展示类」页面用（帮助、统计、图表），不要拿它做设置页。

### 4.2 插件侧后续

| 阶段 | 内容 |
|---|---|
| P2 收尾 | 补 `theme` 贡献点的 UI 入口（本轮缺口②） |
| P3a | JSCore 运行时 ⇒ 允许 `type: js` |
| P3b | v3 页面模型 + 覆盖（`formatVersion 3`） |
| P5 | 内置插件：默认关、只能禁用不能删、支持 `.air2plugin` 内置；native 能力 |

---

## 5. 下一步具体动作（下周开工照这个做）

1. **M2：`A2HomeCardSource.{h,m}`**
   输入：`A2HomeCard`（kind/size/target）+ 已安装插件的贡献点集合。
   输出：三态之一 —— 内置卡（映射到现有卡片视图）/ 插件卡（pluginId + contributionId 能对上）/ 不可用（占位描述）。
   约束：纯逻辑，不建视图、不碰 UIViewController；**必须写一个单测当第一个调用方**（`tests/Home/`，照 `home_layout_tests` 的写法）。
2. **主题入口（缺口②）**
   在「设置 → 外观 → 颜色主题」里列出已启用插件提供的 `resolvedThemeTokens`；选中即生效并持久化，复用 `A2ThemeManager` 的现有路径，不另造一套。
3. 两步都在构建机上真编译（`cmake --build build/cmake -j8`）＋ `python scripts/lint_objc.py` 过了再交。

### 验收判据（必须贴原始输出）

```
 BUILD_RC=0 ；grep -c 'error:' == 0
 lint_objc.py：只允许既有 1 条 A2HomeLayout 误报
 新增符号必须能指出「谁调它 · 哪一行」（石山自检）
```

---

## 6. 硬约束（别踩）

1. **禁石山**：新增类/文件/符号必须能指出调用点；禁顺手重构/改名；禁抄别人代码；文件量大先做最小必需集。
2. **公共仓库**：不直推 `main`；一切走分支（当前 `feat/plugin-merge`），提交前 `git status` 只 add 自己的路径。
3. **别动 IPA 内已有文件**（破坏签名会崩）；只允许新增/同内容替换/删减。
4. **`a2_log_f` 不支持 `%@`**，要 `%s` + `UTF8String`；`NSLog` 才是 `%@`。
5. **注释里不要点名不在本层 import 的类**（`check_imports.py` 会把注释里的类名当成缺 import 报错）。

---

## 7. 文件地图

```
插件
  Air2/Core/Plugin/A2PluginManifest.{h,m}           P1：manifest 字段校验
  Air2/Core/Plugin/A2PluginContribution.{h,m}       P2：贡献点校验 + 注册表
  Air2/Core/Plugin/A2PluginPackageExtractor.{h,m}   解包/预检（含 type 预检）
  Air2/Core/Plugin/A2PluginInstaller.{h,m}          安装/卸载/接入
  Air2/Core/Plugin/A2PluginPermissionStore.{h,m}    权限 + 里程碑
  Air2/UI/Plugin/*                                  管理页/详情/权限/确认/贡献点宿主
  tests/Plugin/plugin_contribution_tests.m          11 组单测

主页
  Air2/Core/Home/A2HomeLayout.{h,m}                布局文档（卡片实例）
  Air2/Core/Home/A2HomeStore.{h,m}                 落盘/多方案/导入导出
  Air2/Core/Home/A2HomeRuntime.{h,m}               最近游玩/收藏数据源
  （home-wip 分支）GridView / CardView / 加卡面板    尚未移植
```

---

## 8. 参考文档

**本树内**（`Air2_pmerge2`）：

- `docs/PLUGIN-SYSTEM.md` —— 贡献点、层级、slot 词表
- `docs/PLUGIN-AUTHORING.md` —— 插件作者指南（写给外部作者看的口径）

**不在本树，需从 `home-wip` 分支取**：

- `docs/HOME-DESIGN.md` —— 布局模型、§4.5 软失败、§4.6 分阶 P0/P1/P2
- `docs/HOME-WIP-STATUS.md` —— home-wip 分支的代码盘点
  取法：`git show home-wip:docs/HOME-DESIGN.md > /tmp/HOME-DESIGN.md`

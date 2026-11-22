# 控件系统对比与改进方案（含 iOS 15 可行性评审）

> 2026-11-15 定稿。范围：**只读参考** `Air-Legacy` 中的 ZalithLauncher2（下称 ZL2）与 FoldCraftLauncher（下称 FCL），
> 对比 Air2 现有控件系统，给出改进清单，并逐条验证「能否在 iOS 15+ 实现」。
> **状态：分析 + 可行性评审，未实施。** 本文不含代码改动。

---

## 一、结论先行

### 1.1 总判断

> ZL2 / FCL 已把控件做成 **可序列化的领域模型 + 独立运行时**；
> Air2 目前是 **1746 行的 UIView 硬编码集合 + 编辑器改 frame**。

差距不在“功能多少”，而在**缺少承载功能的结构**：没有模型层、没有事件层、没有图层、没有版本迁移。

### 1.2 可行性总览

| 组 | 内容 | 项数 | iOS 15 可实现 | 需缩小范围 | 需先补基础设施 |
|---|---|---|---|---|---|
| **A** | 立即修（现存缺陷） | 8 | 8 | 0 | 0 |
| **B** | 结构重构 | 5 | 5 | 0 | 0 |
| **C1** | 手感层 | 5 | 5 | 1（虚拟光标） | 0 |
| **C2** | 生产力层 | 5 | 5 | 0 | 1（文本翻译） |
| **C3** | 生态层 | 3 | 3 | 0 | 1（后端服务） |

**没有任何一项因 iOS 平台能力缺失而不可行。**

必须提前接受的三条边界（详见 §六）：

1. **系统指针无法隐藏或锁定** —— iOS 无公开 API。虚拟光标只在“手指拖动触摸板”模式成立；
   接实体鼠标时系统指针必然可见，只能做“按住拖动 → 增量视角”。
2. **翻译文本能力受限于项目现状** —— Air2 全仓 `NSLocalizedString` 使用数为 **0**，没有 `Localizable.strings`。
   ZL2 的 `TranslatableString`（default + 多语言）无法直接照搬，只能先做单语言文本控件并预留 key 结构。
3. **在线控制器仓库的瓶颈是后端与内容治理**，不是 iOS 能力。

### 1.3 前置决策（必须先定）

| 项 | 现状 | 建议 |
|---|---|---|
| 部署目标 | `scripts/gen_xcodeproj.py:20` `DEPLOYMENT_TARGET = "14.0"` | **改为 `"15.0"`** 并重新生成工程。否则所有 15+ API 都要 `@available` 双分支，收益低、易漏。 |
| 玻璃材质 | `scripts/check_no_glass.py` 对 `Air2/` 全目录禁用 `UIVisualEffectView` / `UIBlurEffect` | 控件层重构进 `Air2/UI/Control/` 后**只能自绘材质**（纯色/渐变/描边/阴影）。当前控件本就是 `colorWithWhite:alpha:`，兼容，无需破例。 |
| 文件规模 | `scripts/lint_structure.sh` 对 > 1000 行文件告警 | `A2GameControlsView.m` 1746 行已触发。拆分后每个文件控制在 300–600 行。 |

> 部署目标若坚持 14.0：A/B 两组 100% 仍可做（都不依赖 15+ API）；仅
> `CADisplayLink.preferredFrameRateRange`、`UIWindowScene.keyWindow`、`UISheetPresentationController`
> 三处需要 `@available` 分支——其中前两处仓库里已有先例（`Natives/Input/a2_controls_overlay.m:67`）。

---

## 二、参考实现解剖

### 2.1 ZL2：模型纯度 + 版本演进

```
layer_controller/                    ← 纯模型层，无 Android UI 依赖
├── layout/ControlLayout.kt          info / layers / styles / special / editorVersion
├── layout/ControlLayer.kt           hide · hideWhenMouse|Gamepad|Joystick · visibilityType
│                                    · normalButtons · textBoxes
├── data/NormalData.kt               uuid · position · buttonSize · buttonStyle(uuid 引用)
│                                    · textAlignment+Bold+Italic+Underline
│                                    · clickEvents · isSwipple · isPenetrable · isToggleable
├── data/TextData.kt                 纯文本控件（可翻译）
├── data/ButtonStyle.kt              uuid 复用 + common/light/dark 三套 + pressed 全套
├── data/ButtonSize.kt               dp | percentage | wrap_content
│                                    + reference: screen_width | screen_height（100..10000）
├── data/ButtonPosition.kt           0..10000 万分比
├── data/ButtonShape.kt              四角独立圆角 0..100
├── data/JoystickStyle.kt            死区 / 锁定色 / 形状 / 尺寸
├── event/ClickEvent.kt              Key · LauncherEvent · SwitchLayer · ShowLayer
│                                    · HideLayer · SendText
├── event/EventHandler.kt            事件派发（含图层切换回调）
├── TouchProcessor.kt / TouchSession.kt   帧级命中 · 指针占用 · 深度检测 · 越界释放
└── Version.kt                       EDITOR_VERSION = 11，逐版本迁移
game_control/ControlManager.kt        DIR_CONTROL_LAYOUTS/*.json + assets 默认
                                      + 版本不支持时 isSupport=false 降级（不崩）
```

三个可借鉴的设计：

1. **图层是一等公民**：`ControlLayer` 自带 `hide`、三种“何时自动隐藏”（鼠标/手柄/摇杆）、三种可见性（always/in_game/in_menu）。
2. **样式按 uuid 引用**：`NormalData.buttonStyle` 存 uuid 字符串，改一处全局生效，且亮/暗双套 + `animateSwap`。
3. **触控是全局管线**：`TouchProcessor` 做指针占用，一个 touch 落进摇杆后不再给按钮。

版本迁移是最值得抄的一条：`updateLayoutToNew` 按 `editorVersion` 逐版本递归升级，老布局永远能开。

### 2.2 FCL：事件表达力 + 生态

| 类 | 关键字段 |
|---|---|
| `BaseInfoData` | `visibilityType`(always/game/menu)、`xPosition/yPosition` 千分比、`sizeType`(percentage/absolute) + `reference` |
| `ButtonEventData` | **press / longPress / click / doubleClick 四事件**，每事件含 `autoKeep`、`autoClick`、`openMenu`、`switchTouchMode`、`switchMouseMode`、`input`、`quickInput`、`outputText`、`outputKeycodes[]`、`bindViewGroup[]`；另有 `pointerFollow`、`movable` |
| `DirectionEventData` | 四向键码列表 + `sneak` 开关与键码 + `FollowOption` 三模式 |
| `ControlViewGroup` | 视图组，运行时整组切换 |
| `ControlButtonStyle` / `ControlDirectionStyle` | 普通/按压态全套；direction 有 `BUTTON`/`ROCKER` 两型 + `interval` 连发 |
| `MenuSetting.kt` | 约 30 项游戏内设置（手势模式与延迟、鼠标灵敏度/大小/偏移、陀螺仪、手柄死区、物品栏尺寸…） |
| `Controller` + `Controllers` + 4 个管理页 | 控制器文件化 + 在线仓库 |

**分工结论**：模型照 ZL2，事件与生态照 FCL。

### 2.3 不照抄的部分

| 不抄 | 原因 |
|---|---|
| JavaFX `Property` 观察者模型 | 那是 JavaFX 绑定体系的要求。ObjC 用 KVO 或“渲染器主动 diff”更轻，硬搬会得到强引用环与通知风暴。 |
| Compose 帧级重组管线 | Android 上每帧遍历很便宜；UIKit 上全量重排要么耗电要么退化回事件驱动。**借语义（指针占用 + 深度命中），不借执行模型。** |
| ZL2 的 11 级迁移链 | Air2 只需建立 `editorVersion` 字段 + 一条 `v1→v2` 示例证明机制，历史三套格式标记 legacy 只读。 |
| FCL 的 ~30 项设置 | 多数在 Air2 无意义（窗口缩放、JVM 内存），或应放系统设置。先挑 8–10 项真正影响手感的。 |

---

## 三、Air2 现状

### 3.1 组件地图

| 文件 | 职责 | 规模 |
|---|---|---|
| `Natives/Input/A2GameControlsView.m` | 控件构建 + 布局 + 手势 + 编辑 + 导入导出 + 组合键 + 键盘 | **1746 行 / 79 KB** |
| `Natives/Input/A2ControlLayoutIO.m` | A2/FCL/ZL2 三格式解析与导出 | 178 行 |
| `Natives/Input/a2_glfw_input.m` | 触摸 → 光标/左键/滚轮 | 25 KB |
| `Natives/Input/a2_sdl_input.m` | 26.3 SDL 事件镜像 | 4.7 KB |
| `Air2/UI/Screens/Settings/A2ControlsEditorViewController.m` | 编辑页（4 个按钮） | 290 行 |

分层落点其实已经登记好，但目录是空的：

- `docs/ARCHITECTURE.md:77` 规定 `Air2/UI/Control/` = 游戏内控件层（目前只有 `.gitkeep`）
- `docs/ARCHITECTURE.md:101` 规定 `Natives/Controls/` = 自定义控件原生渲染与运行操作（目前只有 `.gitkeep`）

### 3.2 已验证缺陷（行号均已核对）

| # | 现象 | 根因 | 落点 |
|---|---|---|---|
| 1 | 进游戏后自定义键消失 | `a2_addCustomControlWithTitle:` 首行 `if (!_editing) return;`，而布局重建正是从非编辑态调用它 | `:1204-1205` ↔ `:1041` |
| 2 | 导入 FCL/ZL2 “成功但没变化” | 解析出的 id 是外部 uuid，`_movable[cid]` 查不到就 `continue`，从不新建 | `:1580-1595`；`A2ControlLayoutIO.m:62,79,119` |
| 3 | 导出自己的组合键再导入 → **崩溃** | 导出时 `key` 是数组（`:1477,1573`），导入时 `[c[@"key"] intValue]` 对 `NSArray` 发消息 | `:1590` |
| 4 | 三键组合只发前两键 | `modifier = codes[0]; target = codes[1];` 之后未遍历 | `:1520-1547` |
| 5 | 攻/用 超过 2 秒自动松手 | `NSTimer` 看门狗替代正确的 touch-up 兜底 | `:833`、`:849` |
| 6 | 26.3 输入无字符/文本事件 | `a2_sdl_input.h` 仅有 cursor / button / key / active | `a2_sdl_input.h` 全文 |
| 7 | 26.3 符号键、方向键、编辑键失效 | `a2_sdl_keycode_from_glfw` 只映射 A-Z、0-9、Space、Esc、Enter、Tab、BS、F1-F12、小键盘、Shift/Ctrl/Alt | `a2_sdl_input.m:89-114` |
| 8 | 摇杆固定 190×190、热键条固定 9 格 | 硬约束；热键条写死发 `48+tag` | `:325-330`、`:777-781` |
| 9 | 编辑器“取消”不撤销 | `a2_cancel` 直接 dismiss，未重载存档 | `A2ControlsEditorViewController.m:253-255` |
| 10 | 编辑器只有 4 个按钮 | 导入/导出/＋按键/删除，无对齐、无网格、无样式、无图层 | 同上 `:222` |

### 3.3 坐标三套口径

| 场景 | 单位 | 位置 |
|---|---|---|
| 运行时内存 | 绝对 pt（center/bounds） | `:994-996` |
| 存档 | 绝对 pt + `_w/_h` 记录画布 | `:1012-1013`、`:1051-1056` |
| 导入导出 | 0..1 归一化 | `:1570-1571` |
| 外部格式 | FCL 千分比 / ZL2 万分比 | `A2ControlLayoutIO.m:55,120` |

换设备、换方向、走一次导入导出，各丢一次精度。

---

## 四、逐维度对比

| 维度 | Air2 | ZL2 | FCL |
|---|---|---|---|
| 数据模型 | 无（散落字典） | `ControlLayout/Layer/NormalData/TextData` 完整值对象 | `ControlButtonData/DirectionData/ViewGroup` |
| 坐标 | 三套口径混用 | 万分比 0..10000 | 千分比 0..1000 |
| 尺寸 | 绝对 pt | dp / percentage / wrap_content + 屏宽或屏高基准 | percentage / absolute + 基准 |
| 图层 | 无 | `layers[]` + 3 可见性 + 3 自动隐藏 | `viewGroups[]` 运行时可切 |
| 样式 | 写死在构建函数 | uuid 复用 + 亮/暗/通用 + pressed + 动画 | Button/Direction 样式 + 按压态 |
| 文本控件 | 无 | `TextData` + 可翻译 | 按钮 text + 样式 |
| 事件模型 | 单个 key（int 或数组） | 6 类事件（键 / launcher / 切显隐层 / 发文本） | 4 时机 × 十余动作 |
| 触控 | 每控件 4 个手势 | 全局 TouchProcessor + 指针占用 | 每控件手势 + TouchPad + pointerFollow |
| 摇杆 | 方形固定 190 | 死区 + 前推锁定 + 按形状命中 | 死区 + rocker + 连发 interval |
| 编辑器 | 4 按钮 | 图层/样式/事件/信息/克隆/翻译 | 信息/事件双 tab + 视图组 + 对齐线 |
| 布局管理 | NSUserDefaults 单 key + 设备前缀 | `DIR_CONTROL_LAYOUTS/*.json` + assets 默认 + 版本降级 | 控制器文件 + 在线仓库 |
| 版本迁移 | 单步：`kA2CtrlLayoutVer` 1/2→3，**只重锚五键**，无字段级 schema（`:677-685`、`:1716`） | `editorVersion` 1→11 逐版本 | `controllerVersion` |
| 外设 | 无手柄/陀螺仪 | 手柄映射 + 陀螺仪 + 外接鼠标 + 手写笔 | 手柄轴/键、陀螺仪、物理鼠标 |
| 游戏内菜单 | 无（编辑在设置里） | 悬浮球 + 4 组设置 | 悬浮球(png/gif) + 双抽屉 + ~30 项 |
| 可测试性 | 0 单测，UI 与逻辑耦合 | 模型层可纯测 | 数据类可纯测 |

---

## 五、iOS 15 可行性矩阵

> 判定口径：**「可行」= 有公开 API，且 iOS 15.0 即可用，无需私有接口、无需越狱、无 App Store 风险。**
> 版本号后标 ⚠ 的表示该能力在 iOS 15 上有**范围限制**，见 §六。

### 5.1 运行时与触控

| ID | 能力 | 关键 API（最低版本） | iOS 15 | 结论 |
|---|---|---|---|---|
| F1 | 全局触控管线（单容器收全部触摸） | `UIView` `touchesBegan/Moved/Ended/Cancelled`（2.0）、`multipleTouchEnabled`（2.0）、`hitTest:withEvent:`（2.0） | ✅ | 可行。**前提：所有控件渲染视图设 `userInteractionEnabled = NO`**，否则命中被 subview 吃掉；容器必须开 `multipleTouchEnabled`。 |
| F2 | 指针占用 / 深度排序 / 越界释放 | 纯计算；`CADisplayLink`（3.1）、`preferredFrameRateRange`（**15.0**） | ✅ | 可行。仅在需要动画时驱动 display link，不要常驻。 |
| F3 | 万分比坐标 + 尺寸类型 | 纯算术 + 容器 `bounds` | ✅ | 可行。**不要用 `UIScreen.mainScreen.bounds`**（iOS 26 弃用，且分屏/多窗口不准），一律用控件容器 bounds。 |
| F4 | 图层 + 可见性 + 自动隐藏 | `UIView.hidden` / `alpha`（2.0） | ✅ | 可行。自动隐藏的输入信号来自 F10/F12/F13。 |
| F9 | 摇杆形状命中 + 死区 + 前推锁定 | 纯几何；`pointInside:withEvent:` 或自算 | ✅ | 可行。圆形命中建议 override `pointInside:`，避免方形热区抢触摸。 |
| F15 | 编辑器对齐线/网格/多选/撤销 | UIKit + `UIImpactFeedbackGenerator`（10.0）+ `UIViewPropertyAnimator`（10.0） | ✅ | 可行。画布捏合与控件捏合需用 `shouldRecognizeSimultaneouslyWithGestureRecognizer` 区分。 |

### 5.2 事件与输入

| ID | 能力 | 关键 API（最低版本） | iOS 15 | 结论 |
|---|---|---|---|---|
| F7 | 四事件（press/longPress/click/doubleClick） | 触摸时间 + 位移判定 + `dispatch_source`/`NSTimer` | ✅ | 可行。iOS 无 `doubleClickInterval`，双击阈值自定义（建议 0.3s）。 |
| F8 | 多键码 / 输出文本 / 快捷输入 / 自动连发 | 现有 `a2_glfw_input_post_key/char`；新增 `a2_sdl_input_char`（自研 C，无 OS 依赖） | ✅ | 可行。**必须在一个 Dispatcher 内统一 GLFW 与 SDL 两套修饰键语义**，否则 26.3 与旧版行为不一致。 |
| F14 | 系统键盘文字输入（含 26.3） | 隐藏 `UITextField`（现状）、`pressesBegan` + `UIKey`（13.4）、`GCKeyboard`（14.0） | ✅ ⚠ | 可行。限制见 L8（第三方输入法 composition 期间拿不到候选文本）。26.3 需补 `kA2SdlTextInput` 桥。 |
| F11 | 滚轮 + 右键虚拟键 | `UIScrollView.allowedScrollTypesMask`（13.4，仓库已用）、`UIEvent.buttonMask`（13.4）、自绘按钮 | ✅ ⚠ | 可行。触屏无原生滚轮，只能靠实体鼠标/触控板或自绘按钮；26.3 需补 wheel 事件桥（当前只镜像 key/button/cursor）。 |
| F10 | 鼠标 SLIDE/CLICK + 虚拟光标 | `UITouch.type == .indirectPointer`（13.4）、`UIPanGestureRecognizer` | ✅ ⚠ | **需缩小范围**：见 L1。虚拟光标只在手指拖动触摸板模式成立。 |

### 5.3 外设

| ID | 能力 | 关键 API（最低版本） | iOS 15 | 结论 |
|---|---|---|---|---|
| F12 | 手柄映射 | `GCController`（7.0）、`GCExtendedGamepad`（7.0）、`buttonMenu/buttonOptions`（13.0）、`leftThumbstickButton`（12.1）、`GCController.current`（14.0） | ✅ ⚠ | 可行。震动无公开 API（见 L3）。App Store 建议声明 `GCSupportedGameControllers`。 |
| F13 | 陀螺仪 | `CMMotionManager` `startDeviceMotionUpdatesUsingReferenceFrame:`（5.0） | ✅ | 可行。**无需 Info.plist 权限**（DeviceMotion 不属于 Motion & Fitness 受限项）。需低通滤波 + 高负载降采样。 |
| F20 | 触觉反馈 | `UIImpactFeedbackGenerator`（10.0）、`impactOccurredWithIntensity:`（13.0） | ✅ | 可行。低电量模式会抑制；需 `prepare()` 降低延迟。 |

### 5.4 数据、编辑器与生态

| ID | 能力 | 关键 API（最低版本） | iOS 15 | 结论 |
|---|---|---|---|---|
| F5 | 样式库（uuid 引用 + 亮暗双套 + pressed） | `UIColor` 动态色（13.0）、`traitCollectionDidChange:`（8.0，17.0 起弃用）、`CALayer` 圆角/边框/阴影 | ✅ | 可行。`registerForTraitChanges:` 是 17+，15 上不要用（见 L5）。玻璃被 lint 禁用，只能自绘材质。 |
| F6 | 文本控件 | `UILabel` / `CATextLayer`、`NSAttributedString` 粗/斜/下划线、`NSLocalizedString` | ✅ ⚠ | 可行，但**翻译能力受限**：仓库 0 处 `NSLocalizedString`、无 `Localizable.strings`（见 L10）。先做单语言 + 预留 key。 |
| F17 | 布局文件化 + schema 迁移 + 导入导出 | `NSFileManager`、`NSJSONSerialization`、`UIDocumentPickerViewController(forOpeningContentTypes:)`（14.0）、`UTType`（14.0）、`UIActivityViewController` | ✅ | 可行。现有代码用的是 iOS 14 起弃用的 `initWithDocumentTypes:inMode:`，15 上仍可用，建议顺手替换。 |
| F18 | 多布局/多控制器管理页 | `UICollectionView` + `UICollectionViewDiffableDataSource`（13.0）、`UIDragInteraction`（11.0） | ✅ | 可行。 |
| F16 | 悬浮球 + 游戏内菜单 | 浮层 `UIView`/`UIWindow` + `UIPanGestureRecognizer`；`UISheetPresentationController`（15.0） | ✅ ⚠ | 可行。15 只有 `.medium()` / `.large()`，自定义高度用自绘面板（见 L4）。必须有“菜单锁定/隐藏”开关，避免遮挡 MC 触控热区。 |
| F19 | 在线控制器仓库 | `NSURLSession` + ATS（HTTPS） | ✅ | iOS 侧可行。**瓶颈是后端、审核与内容治理**，不是平台能力。 |
| F21 | 120Hz / 帧率自适应（可选） | `CADisplayLink.preferredFrameRateRange`（15.0）、`CAFrameRateRange`（15.0） | ✅ | 可行。需 Info.plist `CADisableMinimumFrameDurationOnPhone = YES`。 |

---

## 六、硬性限制与降级方案

| ID | 限制 | 事实 | 降级方案 |
|---|---|---|---|
| **L1** | 系统指针无法隐藏/锁定 | iOS 无公开 API 可隐藏或锁定系统鼠标指针（`UIPointerInteraction` 只能给自家视图设 hover 样式）。 | **虚拟光标只用于“手指拖动触摸板”模式**：手指拖动产生增量 → 自绘光标 → 发绝对坐标。接实体鼠标时保留系统指针，走“按住左键拖动 → 增量 → 视角”，并在 UI 里说明两种模式差异。**不要承诺 FCL/ZL2 那种“捕获鼠标、无限位移”的体验。** |
| **L2** | 无 raw HID / 后台输入 | 无法直接读 HID 报文；App 进入后台后不投递触摸/按键。 | 手柄统一走 GameController 框架；所有按键在 `touchesCancelled` 与 `UIApplicationWillResignActiveNotification` 时强制全释放（顺带解决 A5 看门狗问题）。 |
| **L3** | 手柄震动无公开 API | `GCDeviceHaptics` 为私有。 | 只用 `UIImpactFeedbackGenerator` 做屏幕侧反馈；文档中不承诺手柄震动。 |
| **L4** | 自定义 sheet 高度 | `UISheetPresentationController.Detent.custom` 需 16.0；15 只有 `.medium()` / `.large()`。 | 游戏内菜单用自绘面板（本来就是浮层，成本低）；系统 sheet 只用于设置类二级页。 |
| **L5** | 无 `registerForTraitChanges:` | 该 API 为 17.0+。 | 用 `traitCollectionDidChange:`（已弃用但 15 上完整可用）。 |
| **L6** | 无 `UIEditMenuInteraction` | 16.0+。 | 文本编辑菜单用 `UIMenuController`（15 可用）或自绘；控件编辑不需要系统编辑菜单。 |
| **L7** | 模拟器不覆盖验收 | 模拟器无陀螺仪、无手柄、多点触控仅 ⌥ 模拟两指。 | F9/F10/F12/F13 与多指并发的验收**必须在真机**（至少一台 iOS 15.x、一台当前主力版本）。 |
| **L8** | 第三方输入法 composition 不可靠 | `UITextField` 隐藏方案在拼音/五笔候选阶段拿不到中间串。 | 只转发上屏文本；控件“输出文本”功能在 UI 上标注“建议用英文/数字”。 |
| **L9** | `UIScreen.main` 弃用 | iOS 26 弃用；分屏/多窗口下不准。 | 一律用控件容器 `bounds`；取窗口用 `view.window.windowScene`。 |
| **L10** | 无本地化基础设施 | 全仓 `NSLocalizedString` = 0，无 `Localizable.strings`。 | 文本控件先做单语言；数据模型预留 `textKey` 字段，待引入本地化后再接翻译。**不要把“可翻译”写进一期验收。** |

---

## 七、改进清单

### A. 立即修（P0｜不改架构｜1–2 天｜每项可独立提交）

| 项 | 改法 | 验收 | 可行性 |
|---|---|---|---|
| A1 自定义键不重建 | 拆开“创建控件”与“编辑态校验”：新增内部 `a2_installCustomControlWithTitle:cid:`，`if (!_editing)` 只留在用户入口 | 编辑态加键 → 退出 → 重进游戏，键仍在 | F1 |
| A2 导入空操作 | `a2_applyControlsNormalized:` 增加“未命中则新建”分支；外部 id 映射为本地 `customN`，标题取 `label` | 导入 FCL/ZL2 示例布局，控件数与源一致 | F17 |
| A3 组合键导入崩溃 | `key` 支持 `NSNumber` / `NSArray` 双形态，统一走 `a2_codesForControl:` 的归一化 | 导出组合键 → 清空 → 导入，不崩且绑定正确 | F8 |
| A4 三键以上丢键 | 循环 `codes[1..n]`：修饰键 = `codes[0]`，其余依次单点 | F3+1+2 三键全部到达 | F8 |
| A5 2s 看门狗 | 改为 `UIControlEventTouchUpOutside/TouchCancel` + 视图移除时 `a2_releaseAll`（`:505-506` 已有）+ 退到后台强制全释放 | 长按攻/用 5s 不断；切后台再回来不粘键 | L2 |
| A6 SDL 缺 char/text | `a2_sdl_input.h/.m` 补 `a2_sdl_input_char(codepoint)` / `a2_sdl_input_text(utf8)`，新增 `kA2SdlTextInput` | 26.3 下系统键盘能打字 | F14 |
| A7 SDL 键码表不全 | switch 补符号键、方向键 262-265、Insert/Delete/Home/End/PageUp/Down、左右 Shift/Ctrl/Alt/Super | 26.3 下 F3 调试、方向键菜单可用 | F8 |
| A8 取消不撤销 | 进入编辑时快照；`cancel` 时 `a2_reloadSavedLayout` | 编辑后点取消，布局回到进入前 | F15 |

> A 组做完，控件从“不可用”回到“基础可用”。建议单独出一版，不与 B 组混。

**实施状态（`feat/control-system-runtime`）**：A1–A8 已全部落地。A1 拆出
`a2_installCustomControlWithTitle:cid:`；A2/A3/A4 重写导入与组合键派发；A5 删除
2 秒看门狗，改为 `TouchCancel` + 退后台统一释放；A6/A7 补齐 SDL 文本与键码；
A8 增加编辑器快照/回滚。原生编译与真机验证待在 macOS / GitHub Actions 完成。

**收尾阶段（同一分支）**：在 A 组自查中又补掉了 6 个会直接影响可用性的缺陷——
① 自定义键在游戏里没有 touchDown/Up，导入后看得见按不动 ⇒ 统一走
`a2_holdControl:fallback:down:`；② 方向/跳跃/攻击/使用/热键仍绕过 `_bindings` ⇒
全部改为按绑定派发，组合键在按住型控件上也整体按下/放开；③ 退后台只释放方向键，
跳跃/攻击/使用会卡住 ⇒ `a2_releaseAll` 释放 `_heldCodes` 全表；④ SDL 鼠标中键
映射成右键 ⇒ 按 SDL 的 1/2/3 语义修正；⑤ 键位表 `.` 与 `/` 同为 47 ⇒ 改为 46；
⑥ FCL 的 `sneakKeycode` 兼容标量与数组。另把 `run_control_layout_io_tests.py`
接入 macOS CI，并修正测试运行器路径与 FCL 项数断言。Windows 本机无 clang，
上述编译与单测仍以 CI / macOS 结果为准。

### B. 结构重构（P1｜2–3 周｜决定后面还能不能继续加功能）

| 项 | 内容 | 可行性 |
|---|---|---|
| B1 拆单体 | 按 §八 目录拆分，`A2GameControlsView` 只保留“容器 + 组装”，目标 < 300 行 | F1/F2 |
| B2 持久化迁出 | 每布局一个 `Documents/ControlLayouts/<name>.json` + `editorVersion` + `v1→v2` 迁移链；`NSUserDefaults` 只存“当前布局名” | F17 |
| B3 坐标统一 | 内部一律万分比 + 尺寸类型，仅在渲染时换算 pt；外部格式在 IO 层转换一次 | F3 |
| B4 全局触控管线 | 单 `A2ControlTouchRouter` 取代每控件 4 个手势：深度倒序命中、先到先占、越界释放、滑动链 | F1/F2 |
| B5 补纯逻辑单测 | `A2ControlLayoutIO`（三格式往返）、坐标换算、schema 迁移、事件序列化——四块都可脱离 UIKit 测 | — |

**顺序约束**：B2/B3 **必须**在 C1 之前。否则新加的事件与图层会再次落进旧的绝对坐标 + 字典存储。

### C1. 手感层（P2）

| 项 | 内容 | 可行性 |
|---|---|---|
| C1-1 事件模型 | 照 FCL：`press/longPress/click/doubleClick` × `outputKeycodes[] / outputText / autoKeep / autoClick / quickInput / bindViewGroup` | F7/F8 |
| C1-2 摇杆升级 | 死区比例、前推锁定、按形状命中（圆/方）、可调尺寸 | F9 |
| C1-3 鼠标能力 | SLIDE/CLICK 双模式、虚拟光标（**仅触摸板模式**）、右键与滚轮键、灵敏度/大小 | F10/F11，**受 L1 限制** |
| C1-4 虚拟热键条 | 可增删格数、可绑任意键，替代写死 9 格 `1..9`（`:777-781`） | F8 |
| C1-5 触觉与自动释放 | 按压/吸附触觉；`touchesCancelled` + 退后台全释放 | F20/L2 |

### C2. 生产力层（P2）

| 项 | 内容 | 可行性 |
|---|---|---|
| C2-1 图层 | 新建/重命名/复制/删除；每层 3 可见性 + 3 自动隐藏 | F4 |
| C2-2 样式库 | 样式对象 + uuid 引用 + 亮暗双套 + pressed，改一处全局生效 | F5 |
| C2-3 文本控件 | 对齐/粗斜体/下划线；**单语言**，预留 `textKey` | F6，**受 L10 限制** |
| C2-4 编辑器增强 | 对齐线与吸附、网格、多选、克隆、撤销/重做、事件编辑 tab | F15 |
| C2-5 布局管理页 | 新建/重命名/复制/删除/导入/导出/设为默认；文件化存储 | F17/F18 |

### C3. 生态层（P3）

| 项 | 内容 | 可行性 |
|---|---|---|
| C3-1 游戏内悬浮球 + 菜单 | 把“编辑/切布局/切鼠标/开手柄”从设置页搬回游戏内；菜单锁定/隐藏开关 | F16，**受 L4 限制** |
| C3-2 手柄 + 陀螺仪 | 键/轴映射 + 死区；陀螺仪灵敏度/采样 | F12/F13，**受 L3 限制** |
| C3-3 控制器市场 | 控制器文件格式 + 导入/导出/在线仓库 | F19，**依赖后端**；没有 B1/B2 的文件化存储做不了 |

---

## 八、落盘结构（符合 ARCHITECTURE 与 lint）

沿用仓库已登记但空置的两处，不新增大目录：

```
Air2/UI/Control/                 ← iOS 侧：模型、存储、编辑器
├── Model/   A2Control.h/.m              值对象（id/type/pos/size/alpha/styleId/events）
│            A2ControlLayout.h/.m        info + layers + styles + editorVersion
│            A2ControlEvent.h/.m         事件值对象
├── Store/   A2ControlStore.h/.m         NSUserDefaults ↔ 文件；每布局独立 json；schema 迁移
└── Editor/  A2ControlEditor*.m          图层 / 样式 / 事件 / 信息 / 对齐子页

Natives/Controls/                ← 原生侧：运行时
├── A2ControlRenderer.h/.m               模型 → UIView 渲染与增量刷新
├── A2ControlTouchRouter.h/.m            全局命中 + 指针占用 + 深度排序 + 越界释放
└── A2ControlDispatcher.h/.m             事件 → GLFW / SDL 输入层
```

需遵守的既有约束：

| 约束 | 来源 | 影响 |
|---|---|---|
| `Air2/` 内禁用 `UIVisualEffectView` / `UIBlurEffect` / `UIVibrancyEffect` | `scripts/check_no_glass.py` | 控件材质只能自绘；不要为控件层申请白名单。 |
| 单文件 > 1000 行告警 | `scripts/lint_structure.sh` | 拆分后每文件 300–600 行。 |
| 新 `.m` 自动收录 | `scripts/gen_xcodeproj.py` `scan_sources()` | 无需手工登记 pbxproj；但改部署目标必须改该脚本第 20 行后重新生成。 |
| `#import "X.h"` 必须可解析 | `scripts/check_imports.py` | 新目录要确认头文件搜索路径。 |
| 顶层目录白名单 | `scripts/lint_structure.sh` | 不要新建顶层目录。 |

---

## 九、路线图

| 阶段 | 内容 | 时长 | 产出判据 |
|---|---|---|---|
| **0** | 部署目标 → 15.0（改 `gen_xcodeproj.py:20` 并重新生成） | 0.5 天 | 工程可编译，无 `@available` 新增分支 |
| **1** | A 组 8 项 | 1 周 | 自定义键持久、三格式导入有效、组合键不崩、26.3 可打字 |
| **2** | B1 拆分 + B2 文件化 + B3 万分比 + B5 单测 | 2–3 周 | 单文件 < 600 行；跨设备布局零漂移；IO/迁移有测试 |
| **3** | C1 手感 | 1–2 周 | 四事件可用、摇杆手感达标、热键条可配 |
| **4** | C2 编辑器 | 2 周 | 图层/样式/文本/对齐/布局管理可用 |
| **5** | C3 生态 | 按需 | 悬浮球 + 手柄/陀螺仪；市场视后端进度 |

每阶段独立可发布，互不阻塞。

---

## 十、验收与验证方法

| 验证项 | 方法 | 环境 |
|---|---|---|
| F1 多指并发 | 同时按住 W+A+S+D+跳+攻，检查无丢键、无串键 | 真机 |
| F1 指针占用 | 从摇杆边缘滑出到按钮上，检查按钮不被误触发 | 真机 |
| F2 帧率 | Instruments → Core Animation，确认无持续 60/120Hz 全量重排 | 真机 |
| F3 坐标一致性 | 同布局在横/竖屏、不同机型上截图叠比，偏差 < 1pt | 2 台真机 |
| F7 四事件 | 单点/长按 0.5s/双击 0.3s 间隔，检查事件数与顺序 | 真机 |
| F8 组合键 | 2 键、3 键、4 键各测一次；比较 26.3 与旧版行为 | 真机 |
| F10 鼠标 | 触摸板模式 vs 实体鼠标模式分别验收；确认系统指针行为符合 L1 描述 | 真机 + 蓝牙鼠标 |
| F12 手柄 | DualSense / Xbox 手柄各一，测键、轴、死区 | 真机 |
| F13 陀螺仪 | 静置 10s 检查漂移；快速转动检查延迟 | 真机（模拟器无效） |
| F14 输入 | 英文、数字、中文各输入一次；26.3 与旧版各一次 | 真机 |
| F16 菜单 | 打开菜单时检查 MC 触控热区是否被遮挡；锁定/隐藏开关生效 | 真机 |
| F17 迁移 | 用 v1 存档打开，确认自动升级且不丢控件 | 真机 |
| L2 后台释放 | 按住攻 → 下拉通知中心 → 回前台，检查无粘键 | 真机 |

---

## 十一、风险登记

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 全局触控管线与现有手势冲突 | 中 | 高 | B4 一次性替换；保留旧路径 feature flag 一版，出问题可回退 |
| 拆文件后 `A2GameControlsView` 外部调用点遗漏 | 中 | 中 | 先加 `A2ControlFacade` 收口公开方法，再拆内部实现 |
| 万分比换算引入视觉偏移 | 中 | 中 | B3 落地前先用单测覆盖换算（B5），并保留“按 pts 校准”调试开关 |
| 悬浮球遮挡游戏热区 | 中 | 中 | 默认靠边 + 透明度可调 + 一键隐藏（照 FCL `MenuSetting`） |
| iOS 15 实机留存下降，测试机不足 | 中 | 低 | 至少保一台 iOS 15.x 真机；CI 只做编译，不替代手感验收 |
| 文本翻译被误当一期需求 | 低 | 中 | 本文 L10 明确：翻译不在 A/B/C1 范围 |

---

## 十二、附：与备份分支的关系

对比基线为 `main` @ `dbbecdc`。备份分支 `backup/main-20261025`（旧 main `7e502a6`）保留未动，
本轮分析未基于该分支，也未对其做任何修改。

---

## 十三、引用

- `Natives/Input/A2GameControlsView.m`（缺陷行号见 §3.2）
- `Natives/Input/A2ControlLayoutIO.m` / `.h`
- `Natives/Input/a2_glfw_input.m`（`:300-309` 滚轮、`:312-317` 轻点/长按判定）
- `Natives/Input/a2_sdl_input.m` / `.h`（`:89-114` 键码表）
- `Air2/UI/Screens/Settings/A2ControlsEditorViewController.m`
- `docs/ARCHITECTURE.md:77`（`UI/Control/`）、`:101`（`Natives/Controls/`）
- `docs/UI-DESIGN.md:141-150`（玻璃使用边界）
- `scripts/gen_xcodeproj.py:20`（部署目标）、`scripts/check_no_glass.py`、`scripts/lint_structure.sh`

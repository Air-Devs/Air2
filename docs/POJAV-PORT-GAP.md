# Air2 Pojav 后端移植缺口审计（以 Air1 为基准）

> 审计对象：上游 `Air-Devs/Air2`（本地树 `D:/CTF/_510src/upstream_fix`）
> 基准：Air1 / Amethyst（本地树 `D:/CTF/_510src/tree510`）
> 方式：只读静态比对（文件差集 + 符号差集 + 构建脚本/引用解析 + git 历史），未修改任何代码、未拉取大文件、未推送仓库。

---

## 0. 结论摘要

| 指标 | 值 |
|---|---|
| 缺项总数 | **18** |
| 阻断级（缺了编不过 / 起不来） | **2** |
| 功能级（部分版本或功能不可用） | **13** |
| 边缘（日志 / 诊断 / 可选） | **3** |

**一句话**：Java 侧（`JavaApp/src` 的 `net/kdt/pojavlaunch`、LWJGL 垫片、caciocavallo）已 100% 同步（两端各 120 个文件、差集为 0）；缺口全部集中在 **iOS 原生层（`Natives/*.m` → `Air2/Player/*`）**，且它们是**一次性删除**的结果，不是"没搬"，是"搬了又删、调用点留着"。

**Top5 缺项**

| # | 缺项 | 等级 | 直接后果 |
|---|---|---|---|
| 1 | `shaderc_include.c/.h`（`#include <minecraft:...>` 展开器） | 阻断 | `shaderc_shim.c` 编译期缺头 + 链接期 `_ame_source_has_include` 未定义 |
| 2 | Forge/NeoForge/OptiFine 自动安装（headless processor 执行器） | 功能 | 装不了 Forge；A2 自承"启动核心尚未就绪，请手动安装" |
| 3 | 陶瓦联机传输层（SOCKS5Proxy + PortForwarder + Terracotta bridge） | 功能 | 联机页只有状态机，房主/房客都连不上 |
| 4 | 硬件键盘链路（IME 组字 + 键位表 + SDL 键态镜像） | 功能 | 妙控键盘打不了中文、组合键/小键盘/F13-F24 无效 |
| 5 | JIT 能力探测与启动门禁（26 个函数） | 功能 | 无 JIT 环境下不再给明确失败，退化为卡死/崩溃 |

**最小补齐顺序（摘要，详见 §5）**：`P0 编译止血` → `P1 键盘/输入` → `P2 JIT 门禁` → `P3 JNA 重绑定` → `P4 联机传输` → `P5 Forge 安装` → `P6 AWT 宿主 / 麦克风 / 第三方认证` → `P7 入口接线 + 边缘项`。

---

## 1. 审计口径

1. **基准选取**：以 Air1 `Natives/CMakeLists.txt`（873 行，A1 唯一的原生构建清单）+ `Amethyst.xcodeproj` + 实际目录为"应存在"集合。
2. **差异来源**：
   - 文件差集（排除 `_bak_*`、`external/`、`Assets.xcassets`）；
   - 同名文件的行数与符号差集（ObjC 方法名 + C 函数名，正则提取后做集合差）；
   - `#import/#include` 可解析性扫描（判断编译是否成立）；
   - 构建脚本（`Makefile` / `cmake/CMakeLists.txt` / `scripts/gen_xcodeproj.py`）引用的文件是否真实存在；
   - `git log` 中引入/删除这些文件的提交（定性用）。
3. **排除项**：`Natives/external/*`（第三方源码，30k 文件，A2 走 `Libraries/external`，属依赖而非移植）；UI/业务层文件（A2 已用 `A2*` 重写，不算缺口，见 §6）。

---

## 2. 两端结构对照

| 维度 | Air1（`tree510/Natives`） | Air2（`upstream_fix/Air2`） |
|---|---|---|
| 目录形态 | 扁平：322 个文件堆在 `Natives/` 根 + 子目录（`ctxbridges/ input/ awt_xawt/ authenticator/ installer/ customcontrols/ AI/ TouchController/ terracotta/ pocketj_jit/`） | 分层：`App/ Core/ Player/ UI/ Utils/`，原生层收在 `Player/{Context,Renderer,Input,Support}` + `Player/{Controls,GameUI}` |
| ObjC/C 代码文件 | 448 个 / 155,968 行（不含 external、_bak_） | 391 个 / 97,742 行 |
| Pojav 原生层 | 322 文件（根目录） | 109 文件 / 43,342 行（`Player/`：Context 26、Renderer 26、Input 10、Support 21、Controls 16、GameUI 10） |
| Java 启动核心 | `JavaApp/src`（120 文件） | `JavaApp/src`（120 文件，**逐文件一致**） |
| 构建入口 | `Makefile`(1457 行) → `cmake Natives/CMakeLists.txt` | `Makefile`(5.5KB) → `cmake Air2/Player/CMakeLists.txt`（**不存在**）；实际 CI 走 `scripts/gen_xcodeproj.py` + `xcodebuild` |
| 渲染桥 | `ctxbridges/{gl,egl,osm,vk}_bridge.m` + `sdl3_hook.m` | `Player/Renderer/*`（同名同量，行数 +1~3%） |
| 关键文件行数对照（A1 → A2） | | |
| `main_hook.m` | 2807 | 2342（**-465**） |
| `input_bridge_v3.m` | 2205 | 1869（**-336**） |
| `KeyboardInput.m` | 441 | 195（**-246**） |
| `TrackedTextField.m` | 354 | 273（**-81**） |
| `utils.m` | 2886 | 2109（**-777**，含 JIT 门禁 26 函数） |
| `JavaLauncher.m` | 3458 | 3281（-177） |
| `SurfaceViewController.m` | 3769 | 3617（-152） |
| `gl_bridge / egl_bridge / sdl3_hook` | 2065 / 1084 / 3653 | 2087 / 1141 / 3675（**基本持平**） |

**历史定性（关键证据）**

| commit | 动作 | 影响 |
|---|---|---|
| `2424b42` | `feat: 完整移植 Air1 的 pojav 启动核心与全部依赖` | 全量搬入（含本次缺口） |
| `932f22d` | `refactor(natives): 按 Air2 架构重组启动核心，删除 Air1 业务层` | **一次删除 276 个文件，其中 275 个至今仍不存在**；`shaderc_include.*`、`JavaGUIViewController.*`、`audio_capture_bridge.m`、`SOCKS5Proxy.*`、`PortForwarder.*`、`Terracotta*`、`TouchControllerBridge.*`、`SilentAudioPlayer.*`、`SurfaceViewController+Navigation.m`、`AmePerfProbe.*` 均在此次被删 |
| `fcd014c` | `chore: 清理占位文件与非核心文件` | 删除 `Natives/authenticator/*`（`ThirdPartyAuthenticator.m` 1072 行等），但 `JavaLauncher.m` 的 authlib 调用点只做了 `#if 0` |

> 结论性判据：A2 里大量 `#if 0` / no-op 桩 / "已不存在"注释，都是"调用点留下、实现删掉"的残留，而非设计性裁撤。

---

## 3. 差异清单（分级 · 带证据）

### 3.1 阻断级（2 项）

| ID | 缺项 | Air1 侧（基准） | Air2 现状 | 证据（路径:行） | 影响 |
|---|---|---|---|---|---|
| **B1** | `shaderc_include.c` / `shaderc_include.h`（RenderPearl 26.3 `#include <minecraft:...>` 文本展开器） | `Natives/shaderc_include.c` 326 行 + `.h` 90 行（自包含，仅依赖 libc；公开 `ame_source_has_include()` / `ame_include_expand()`） | **两端均无**：`find upstream_fix -name "shaderc_include*"` 为空 | 调用点仍在：`Air2/Player/Renderer/shaderc_shim.c:221` `#include "shaderc_include.h"`；`:1145` `ame_source_has_include(...)`；`:1160` `ame_include_expand(...)`。编译单元被纳入：`scripts/gen_xcodeproj.py:145-147`（`Renderer/*.c` 全部 `impl.append`），`NATIVES_CORE_DIRS` 含 `Air2/Player/Renderer/`（`:115-120`） | 编译期 `'shaderc_include.h' file not found`；即使补头也链接失败（`_ame_source_has_include` / `_ame_include_expand` undefined）。**静态判定，未能本机编译验证（Windows 无 Xcode）** |
| **B2** | 原生层构建入口断裂 | `Natives/CMakeLists.txt`（873 行，列出 218 个源文件） | 根 `Makefile:103-112` `natives:` 目标只查 `Air2/Player/CMakeLists.txt` → **该文件不存在** → 打印 `(cmake/CMakeLists.txt 尚未就绪)` 后**空转成功**；`cmake/CMakeLists.txt` 是 Air1 副本，仍引用 10 个已删文件 | `cmake/CMakeLists.txt:278` `audio_capture_bridge.m`、`:468` `JavaGUIViewController.m`、`:469-477` `ZeroTierBridge.m / SOCKS5Proxy.m / PortForwarder.m`、`:618-625` `TouchControllerBridge.m / TouchControllerPreferencesViewController.m / TerracottaBridge.m / TerracottaManager.m / SilentAudioPlayer.m / TerracottaViewController.m`、`:392` `shaderc_include.c` | `make natives` 静默不产出任何产物（假绿）：本地按 README 构建会得到一个**没有 Pojav 原生层**的包；CI 走 `gen_xcodeproj` 不受影响 → 双轨不一致 |

### 3.2 功能级（13 项）

| ID | 缺项 | Air1 侧 | Air2 现状 | 证据 | 影响面 |
|---|---|---|---|---|---|
| **F1** | AWT / Caciocavallo 宿主（Java GUI 窗口） | `JavaGUIViewController.m` 667 行：`AWTInputBridge_nativeSendData()`（:23）、`CTCAndroidInput.receiveData` 反射桥、`SurfaceView` 宿主、虚拟鼠标指针视图、`SPECIALBTN_*` 菜单 | 无同名/等价文件。但 AWT 仍在启动参数里：`-Djava.awt.headless=false`、`-Dawt.toolkit=...CTCToolkit`、`-Djava.awt.graphicsenv=...CTCGraphicsEnvironment`、`--add-exports java.desktop/java.awt` | A2 `JavaLauncher.m:2294 / 2330 / 2331 / 2334`；`#if` 残留注释 `ios_uikit_bridge.m:308`、`gl_bridge.m`（"Return from JavaGUIViewController"） | `execute_jar` 路径（OptiFine 安装器 GUI）、任何 Swing/AWT 窗口（部分 mod 配置界面）无宿主：无画面、无输入注入 |
| **F2** | 硬件键盘 IME（组字） | `input/KeyboardIMEHost.h` 45 行 + `.m` 50 行（`ameIMEHostActive/Composing/SetFlushHandler`）；`TrackedTextField.m` 354 行（`becomeFirstResponder` 注册 flush、`unmarkText`、`ameFlushCompositionIfNeeded`） | 文件不存在；`TrackedTextField.m` 273 行，缺上述 3 个符号（符号差集命中 `ameFlushCompositionIfNeeded / becomeFirstResponder / unmarkText`）；`KeyboardInput.m` 中 IME 关键字 **0 处（A1 为 11 处）** | `Natives/input/KeyboardIMEHost.h:1-45`；A1 `KeyboardInput.m:3` `#import "KeyboardIMEHost.h"`；A1 `TrackedTextField.m:4` 同 | 妙控键盘/外接键盘无法输入中文（组字期原始字母还会被当按键转发 → 重复上屏） |
| **F3** | JNA `_dlsym` 槽重绑定 + JVM `_dlopen` 链重绑定（Task132/133） | `main_hook.m:208-450`：`ame_task132_rebind_jna_dlsym_ex()`（Mach-O 符号表遍历 + `vm_protect` 改指针槽 + 写回校验）、`ame_task133_install_name/basename/rebind_image_sym`、`ame_task134_*`（等待 JNA 加载的重试看门狗）、`ame_jna_rebind_probe` | **no-op 桩**，且自承未实现 | A2 `main_hook.m:196-206`：`// Task 132/133 构建修复桩：...真实实现从未进仓库（sdl3_hook.m 内无此二函数）... TODO(port)`；`:201` `NSLog(@"[Task132] stub: JNA dlsym rebind not yet ported, skipping")` | 依赖 JNA 的 mod（符号拦截/符号替换类）在 iOS 上失效；`hooked_dlsym` 热路径对 JNA 镜像不可见 |
| **F4** | JIT 可用性探测 + 启动门禁 + exec2（26 个函数） | `utils.m`（2886 行）中的 `AMEDeviceCanExecuteJITCode`、`AMEDeviceProbeJITExecCapability`、`AMEDeviceProbeFileBackedJITExecCapability`、`AMEJITEnsureJITUsable`、`AMEJITCapabilitySummary`、`AMEJITLaunchGateReason`、`AMEJITExec2AllowNoExec`、`AMEJITExec2LaunchBlockReason`、`ameJITExec2ReadCsFlags`、`ameJITTrollStoreSelfEnable`、`AmeLaunchGateMayBlock/NoteNonBlock/KindName` 等（共 26 个） | `utils.m` 2109 行；**全树 0 引用**（`AMEDeviceCanExecuteJITCode` / `AMEJITEnsureJITUsable` / `AMEJITLaunchGateReason` / `AMEJITCapabilitySummary` / `AMEJITExec2LaunchBlockReason` / `ameJITTrollStoreSelfEnable` 均查无） | A1 调用点：`JavaLauncher.m:565`（能力快照日志）、`DownloadViewController.m:3949`、`LauncherNavigationController.m:749`、`LauncherRightPanelViewController.m:919 / 1767`；A2 符号差集输出见 §7 | 无 JIT / 未开 JIT / exec2 受限环境：不再"启动前拦下并给原因"，退化为 `JIT26CreateRegionLegacy` 失败重试 → 卡死或 SIGBUS，用户只看到"闪退"；排障失去 `[JIT-CAP]` 能力快照 |
| **F5** | 麦克风采集（语音聊天 mod） | `audio_capture_bridge.m` 267 行：`AVAudioEngine` 采集 → 环形缓冲（`48000*2*8`）→ JNI 读取接口；`Natives/CMakeLists.txt` 单独产出 `libaudio_capture.dylib` | 两端无等价物；A2 全树无 `AVAudioEngine` / `AVCaptureSession` / `inputNode`（只有 `SurfaceViewController.m:1382` 的 `AVAudioSession` 类别配置，用于播放） | A1 `audio_capture_bridge.m:1-45`；A2 `cmake/CMakeLists.txt:278-281`（残留 `add_library(audio_capture SHARED ...)`） | Simple Voice Chat 一类 mod 无法录音；`libaudio_capture.dylib` 未进包 |
| **F6** | 陶瓦联机**传输层** | `SOCKS5Proxy.m` 1486 行（本地 SOCKS5 服务，把 MC 全量 TCP 导向房主）+ `PortForwarder.m` 1241 行（房主侧端口转发 / 房客侧本地端口）+ `TerracottaBridge.m` 235 + `TerracottaManager.m` 292 + `terracotta.h` 75 + `MultiplayerManager.m` 2539（状态机 + 角色判定） | `A2Multiplayer.m` **391 行**：只有状态轮询 + 玩家模型 + UI 通知；libterracotta 用 **weak 符号**绑定，注释自承"当前工程里没有 libterracotta.xcframework，所以这些函数指针全为 NULL" | A2 `A2Multiplayer.m:30-44`（weak 声明 + 注释）、`:45-46`；`JavaLauncher.m:1963-2009` **仍读** `AMETHYST_SOCKS5_PROXY` 注入 JVM，但全树**无人 setenv**（`grep AMETHYST_SOCKS5_PROXY` 仅 4 处，全是消费者）；`Libraries/terracotta/libterracotta.xcframework` **确实存在**（与注释矛盾）；`SurfaceViewController.m:3582` 注释承认"原代码仅停止 LanPortDetector，不清理 SOCKS5 代理 / 端口转发 /…" | 联机页可开、状态可滚，但房主不转发端口、房客不走代理 → MC 永远连不上；这属"UI 与后端断层"，比"没做"更难查 |
| **F7** | Forge / NeoForge / OptiFine 自动安装（headless processor 执行器） | `installer/ForgeProcessorExecutor.m` 1265 行（commands.json 序列化 → `launchHeadlessJVM` → 轮询 status.json）、`ForgeDirectInstaller.m` 1343、`NeoForgeDirectInstaller.m` 1162、`NeoForgeVersionFetcher.m` 416、`FabricUtils.m` 46 | `A2ModLoaderInstaller.m` 仅下载级；对需要跑 JVM 的加载器直接失败 | A2 `A2ModLoaderInstaller.m:150-180`：注释完整描述了 A1 的"进程内 headless JVM"方案（5 步），随后 `[self failWithMessage:@"OptiFine 需要运行其自带的 Patcher 程序才能安装，当前启动核心尚未就绪，请手动安装"]` | Forge/NeoForge/OptiFine 只能手装；**底层能力 A2 已有**（`JavaLauncher.m:903 / 1252 / 2636` 的 `launchHeadlessJVM`、`g_ame_suppressJvmExit`（`main_hook.m:163`）、`g_ame_headlessJvmFinished`）→ 缺的只是上层执行器 |
| **F8** | 第三方认证 authlib-injector 注入 | `authenticator/ThirdPartyAuthenticator.m` 1072 行（`getJvmArgsForAuthlib`、authlib-injector 1.2.7 下载/版本文件/BMCLAPI 镜像回退、Java 25 class 版本处理） | 整段 `#if 0` 屏蔽 | A2 `JavaLauncher.m:2111-2137`：`#if 0 /* ★CI★ 本段引用的 BaseAuthenticator / ThirdPartyAuthenticator 在仓库里已不存在（CI: use of undeclared identifier 'BaseAuthenticator'）。整段保留不参与编译，待认证体系恢复后再启用。 */` | 第三方（外置登录）账号**能登录**（`A2AccountManager.m:78/142/167` 直连 `/authserver/authenticate|validate|refresh`），但进游戏后**不注入 authlib-injector** → 皮肤/披风不显示，部分服务端的 authlib 校验链路失效 |
| **F9** | 游戏内菜单能力（FCL 风格 9 项） | `SurfaceViewController+Navigation.m` 453 行：强制关闭 / 日志输出 / **按键布局编辑** / **联机** / FPS·内存显示开关 / 隐藏显示控制按钮 / **虚拟鼠标开关** / 游戏内键盘 / 分辨率 / 设置 | 只剩顶部工具条 3 项 | A2 `A2JVMRunningViewController.m:76-80`（`键盘` / `日志` / `强制关闭`）；`A2ControlEditorViewController.m` **全树无调用点**（编辑器写好了但没入口）；`virtualMouseEnabled` 变量+指针视图都在（`SurfaceViewController.m:1204/1208/1239/1262`），仅缺开关入口（A1 在菜单项 `game.menu.toggle_virtual_mouse`，开关实现在 `JavaGUIViewController.m:584`） | 游戏内改按键布局、开虚拟鼠标、调分辨率、进联机、切 FPS 显示均无入口（功能在、门锁了） |
| **F10** | TouchController bridge + 偏好页 | `TouchControllerBridge.m` 218 行（`dlsym(RTLD_DEFAULT,"touchcontroller_ios_*")`）、`TouchControllerPreferencesViewController.m` 408 行、`Natives/TouchController/TouchController.xcframework` | 无 bridge、无偏好页；UDP 发包代码仍内联在 `SurfaceViewController.m`（`TC_MOD_PORT`），`JavaLauncher.m:1457-1467` 仍读 `touchcontroller.*` 偏好 | A2 `SurfaceViewController.m:78-253 / 280-500`（内联实现）；`cmake/CMakeLists.txt:113-163 / 617-619`（残留引用） | 只有 UDP 模式可用；静态库模式、端口/开关设置 UI 缺失 |
| **F11** | ZeroTier 联机通道 | `ZeroTierBridge.m` 619 行 + `Libraries/external/ZeroTierFramework`（A1 侧 `Natives/external/`） | 无文件；仅 `cmake/CMakeLists.txt:60-75 / 719` 残留 | A1 `Natives/ZeroTierBridge.m` | "右上角可切 ZeroTier"的第二种联机方式不可用（属可选通道） |
| **F12** | 后台音频保持 | `SilentAudioPlayer.m` 249 行（静音音频循环，切后台/息屏时保活 AVAudioSession） | 无文件；只有 `AVAudioSession` 类别设置 | A2 `SurfaceViewController.m:1382-1388`；`cmake/CMakeLists.txt:624` 残留 | 切后台/锁屏后游戏音频可能被系统挂起（与"联机时切后台断线"相关） |
| **F13** | 硬件键盘按键链路（键位表 + 修饰键 + SDL 键态镜像） | `input/KeyboardInput.m` 441 行：完整 HID→GLFW 键码表（含 `'`、End、Insert、PrintScreen、Pause、小键盘 `.`、Application、F13-F24、左右 ⌘）、`hwKBDIsJudgeKey/hwKBDKeyName/hwKBDModsName`；`input_bridge_v3.m` 2205 行含 `ame_hwKbdMirrorKeyState`、`ame_hwKbdGet/SetModStateFunc`、`ame_glfwModsToSDLKeymod`、`ame106_resolveKeyDownBufferOnJavaThread`、`ame_jni_env_for_current_thread`、`ame_jni_detach_if_attached` | `KeyboardInput.m` 195 行（**无键位表、无修饰键组合**）；`input_bridge_v3.m` 1869 行，上述 8 个函数全部缺失（符号差集） | A1 `KeyboardInput.m:1-20`（[HWKBD-KEYMAP] 说明：缺表 → `keycode==0` → 静默丢弃，只剩一行 Unhandled）；A2 同名文件仅 2 个符号 | 外接键盘部分按键无响应；⇧/⌘/⌥/⌃ 组合键在游戏内不可靠；MC 26.3 走 SDL3 后键态镜像缺失 → 组合键"按了没反应" |

### 3.3 边缘级（3 项）

| ID | 缺项 | Air1 侧 | Air2 现状 | 证据 | 影响 |
|---|---|---|---|---|---|
| **E1** | JIT 缓存预启动日志 | `ameJITCacheLogPreLaunch()` | 缺失（A2 无 JIT cache 相关符号） | 符号差集 `JavaLauncher.m`：`ameJITCacheLogPreLaunch` | 只是少一段启动前诊断 |
| **E2** | SIGBUS 取指保护失败分类 | `ameSigbusIsInstructionFetch(si, pc)`（`|si_addr - pc| <= 4` 判定"在不可执行页取指"）→ 打印 `FATAL: INSTRUCTION FETCH on non-executable page` + `pc_in_jit26_prepared_region` 等 | `ameTolerantSigbusHandler` 仍在（`JavaLauncher.m:408`），但只计数放行，不分类 | A1 `JavaLauncher.m:396-440`；A2 `JavaLauncher.m:405-423` | JIT 相关 SIGBUS 的根因日志缺失（崩溃仍会发生，只是难定位） |
| **E3** | 性能探针 | `AmePerfProbe.m/.h` 190 行 | 无；A2 用 `Core/A2Metrics.m` 替代 | `932f22d` 删除；A2 `A2Metrics.m` 存在 | 无影响（已被新实现覆盖），仅统计口径不同 |

---

## 4. 分级统计

| 等级 | 数量 | ID |
|---|---|---|
| 阻断 | 2 | B1, B2 |
| 功能 | 13 | F1–F13 |
| 边缘 | 3 | E1–E3 |
| **合计** | **18** | |

按"整文件缺失 / 文件内能力缺失"分：

| 形态 | 数量 | ID |
|---|---|---|
| A1 侧整文件缺失（文件已从 A2 删除且无等价实现） | 11 项（对应 40 个文件） | B1, F1, F2, F5, F6, F7, F8, F10, F11, F12, E3 |
| 文件仍在但能力被削掉（符号差集） | 7 项 | B2, F3, F4, F9, F13, E1, E2 |

> 说明：`932f22d` 一次删除 276 个文件、275 个至今缺失，其中约 235 个属 UI/业务层（A2 已有 `A2*` 重写，**不算缺口**，见 §6），落在 Pojav 后端域的是上表 11 项（40 个文件：shaderc 2、JavaGUI 2、IME 2、audio_capture 1、联机 11、安装器 10、ThirdParty 2、TouchController 4、ZeroTier 2、SilentAudio 2、PerfProbe 2）。

---

## 5. 最小补齐清单（按优先级 · 含依赖与工作量）

工作量口径：**小** ≤ 1 天（纯拷贝/改名 + 1 次编译）；**中** 2–4 天（要改接口/接线 + 真机验证）；**大** ≥ 5 天（跨模块 + 需要真机反复迭代）。

### P0 · 编译止血（必须先做，否则后面都验证不了）

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 1 | **补 shaderc include 展开器** | `Natives/shaderc_include.c`(326) + `.h`(90) → `Air2/Player/Renderer/`（同名放置即可，`shaderc_shim.c` 的 `#include "shaderc_include.h"` 是同目录引用） | 无（自包含，仅 libc）。API 已与 A2 调用点对齐（`:1145/:1160` 用的正是这两个函数） | **小** |
| 2 | **修构建双轨** | 二选一：<br>(a) 新增 `Air2/Player/CMakeLists.txt`（可从 A1 `Natives/CMakeLists.txt` 裁出 218 项里仍存在的部分）；<br>(b) 让根 `Makefile:103-112` 的 `natives:` 改调 `python3 scripts/gen_xcodeproj.py`（与 CI 同路径）——**推荐 (b)**，一行级改动、消除假绿。<br>同时清理 `cmake/CMakeLists.txt` 的 10 处死引用（`:278 / :392 / :468 / :469-477 / :618-625`）或整体删除该文件 | 与 CI 对齐；`verify_pbxproj.py` 已存在，可加进 `make lint` | **中**（(b) 实为小） |

### P1 · 输入链路（用户感知最强，且自包含）

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 3 | **硬件键盘 IME** | `input/KeyboardIMEHost.{h,m}` → `Air2/Player/Input/`；`TrackedTextField.m` 补 3 方法（`becomeFirstResponder / unmarkText / ameFlushCompositionIfNeeded`）；`KeyboardInput.m` 补 IME 抑制逻辑（A1 11 处关键字） | 只依赖 `TrackedTextField`/`KeyboardInput` 自身；无外部符号 | **小** |
| 4 | **键位表 + 修饰键 + SDL 键态镜像** | `KeyboardInput.m` 补齐 HID→GLFW 全表（441-195=246 行）；`input_bridge_v3.m` 补 `ame_hwKbdMirrorKeyState` / `ame_hwKbdGet/SetModStateFunc` / `ame_glfwModsToSDLKeymod` / `ame106_resolveKeyDownBufferOnJavaThread` / `ame_jni_env_for_current_thread` / `ame_jni_detach_if_attached` | 依赖 3（同一链路的文本/按键分工）；`ame106_*` 依赖 `runtimeJNIEnvPtr`（A2 已有） | **中** |

### P2 · JIT 与符号层（决定"能不能起 / 起来后 mod 能不能用"）

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 5 | **JIT 能力探测 + 启动门禁 + exec2** | `utils.m` 补 26 个函数（`AMEDeviceCanExecuteJITCode`、`AMEDeviceProbeJITExecCapability`、`AMEDeviceProbeFileBackedJITExecCapability`、`AMEDeviceHasRealJITEntitlement`、`AMEJITEnsureJITUsable`、`AMEJITCurrentUsability`、`AMEJITCapabilitySummary`、`AMEJITLaunchGateReason`、`AMEJITExec2AllowNoExec`、`AMEJITExec2LaunchBlockReason`、`ameJITExec2ReadCsFlags`、`AMEJITBothMappingKindsExecutable`、`AMEJITEnvironmentKind/Name`、`AMEJITPathForceMode`、`AMEJITUsabilityDisplayKey`、`AMEJITInvalidateUsabilityCache`、`AMEDeviceInvalidateJITExecProbe`、`ameJITExecProbeSignalHandler`、`ameJITInvalidateStatusProbe`、`ameJITTrollStoreSelfEnable`、`AmeLaunchGateKindName/MayBlock/NoteNonBlock`、`AMEJITAppendCrashNote`、`AmeLaunchProgress` 侧展示） | A1 的 `utils.m` 版本可直接对照移植；依赖已有的 `JIT26*` 原语（A2 `utils.m` 99 处、`utils.h` 25 处，**已在**）→ 属"同一文件的增量"，冲突面最大，建议按函数块分批合 | **中**（约 1200 行，但自包含） |
| 6 | **Task132/133 真实现** | `main_hook.m` 补 `ame_task132_rebind_jna_dlsym_ex` / `amethyst_task132_rebind_jna_dlsym` / `ame_task133_{install_name,basename,rebind_image_sym}` / `amethyst_task133_rebind_image_dlopen` + Task134 重试看门狗（`ame_task134_*`）；**移走 `main_hook.m:196-206` 的 no-op 桩**（注释已提醒：不删会 duplicate symbol） | 依赖 fishhook（A2 已编 `Libraries/external/fishhook/fishhook.c`）；与 5 无耦合 | **中** |

### P3 · 联机（价值高、耦合高，放中段）

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 7 | **陶瓦联机传输层** | `SOCKS5Proxy.{h,m}`(1486) + `PortForwarder.{h,m}`(1241) + `TerracottaBridge.{h,m}`(235) + `TerracottaManager.{h,m}`(292) + `terracotta.h`(75)；`A2Multiplayer.m` 从 391 行状态机扩到"状态机 + 传输"，把 weak 符号换成实链 `Libraries/terracotta/libterracotta.xcframework`；`JavaLauncher.m:1971` 的消费者需要有人 `setenv("AMETHYST_SOCKS5_PROXY", ...)` | 需要 6 的 JNA/JVM 链？**不需要**（SOCKS5 是纯 TCP 服务）。但 `A2Multiplayer.h` 的 UI 契约要保留（`A2MultiplayerStateDidChangeNotification`） | **大**（~3300 行 + 真机双机联调） |
| 8 | **SilentAudioPlayer**（顺带，和联机切后台断线相关） | `SilentAudioPlayer.{h,m}`(249) → `Air2/Player/Support/`，接在 `SurfaceViewController.m:1382` 音频会话配置后 | 无 | **小** |
| 9 | **ZeroTier 通道（可选）** | `ZeroTierBridge.{h,m}`(619) + `Libraries/external/ZeroTierFramework`（已 vendored，A2 未用） | 依赖 7 的联机状态机（第二通道） | **大**（可延后 / 可不做） |

### P4 · 安装器与账号

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 10 | **Forge/NeoForge/OptiFine 安装** | `installer/ForgeProcessorExecutor.{h,m}`(1265) + `ForgeDirectInstaller.{h,m}`(1343) + `NeoForgeDirectInstaller.{h,m}`(1162) + `NeoForgeVersionFetcher.{h,m}`(416) + `FabricUtils`(46)；改 `A2ModLoaderInstaller.m:150-180` 的 fail 分支为调用执行器 | **底层已在**：`JavaLauncher launchHeadlessJVM`、`g_ame_suppressJvmExit`(main_hook.m:163)、`g_ame_headlessJvmFinished`。需注意"进程内 JVM 只能建一次、装完必须重启 App"的原有约束 | **大** |
| 11 | **authlib-injector 注入** | `authenticator/ThirdPartyAuthenticator.m`(1072) → `Air2/Core/Account/A2ThirdPartyAuth.m`（只取 `getJvmArgsForAuthlib` + authlib-injector 下载/版本文件/mirror）；解开 `JavaLauncher.m:2111` 的 `#if 0` 并改成 `A2AccountManager` 接口 | 依赖 A2 已有 `A2AccountManager`（第三方登录已实现）；**注意许可证**：authlib-injector 为 GPL-2.0-class 上游产物，按 A2 现有 LICENSE 口径核对后再随包分发 | **中** |

### P5 · AWT 宿主与采集

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 12 | **AWT / Caciocavallo 宿主** | `JavaGUIViewController.{h,m}`(667) → `Air2/Player/GameUI/A2JavaGUIViewController.{h,m}`：改名为 A2 前缀、去掉对 `BackgroundManager`（A2 无）与 `customcontrols/*`（A2 用 `A2Control*`）的引用、保留 `AWTInputBridge_nativeSendData` / `CTCAndroidInput` 反射桥 / 虚拟鼠标指针 / `SPECIALBTN_*` 菜单；入口挂到 `A2JVMRunningViewController` 或 `A2LauncherViewController` | 依赖 `SurfaceViewController`（已在）、`TrackedTextField`（P1 已修）；`-Djava.awt.headless=false` 等 JVM 参数**无需改**（A2 已有） | **中** |
| 13 | **麦克风采集** | `audio_capture_bridge.m`(267) → `Air2/Player/Support/`，恢复独立 dylib 目标（`libaudio_capture.dylib`）并加进 payload + `java.library.path` | 无（`AVFoundation` 系统框架）；`NSMicrophoneUsageDescription` **A2 已在**（`Air2/Player/Info.plist:168`），无需补 | **小** |
| 14 | **TouchController bridge + 偏好页** | `TouchControllerBridge.{h,m}`(218) + `TouchControllerPreferencesViewController.{h,m}`(408)；把 `SurfaceViewController.m` 内联 UDP 代码收敛到 bridge | 依赖 `Natives/TouchController/TouchController.xcframework`（**A2 未 vendored，需从 A1 拷**，54 KB：`libproxy_server_ios.a` 9 KB + 头） | **中** |

### P6 · 入口接线与边缘

| 序 | 动作 | 搬什么 | 依赖 | 工作量 |
|---|---|---|---|---|
| 15 | **游戏内菜单补齐** | 不是搬文件，是接线：在 `A2JVMRunningViewController.m:76-80` 的工具条加 4 项 → 按键布局（`A2ControlEditorViewController`，现为死代码）、虚拟鼠标开关（写 `control.virtmouse_enable`）、联机（`A2MultiplayerViewController`）、分辨率（`A2ResolutionSettingsView`） | 依赖 7（联机项）、`A2ControlEditorViewController`（已在） | **小** |
| 16 | JIT 缓存预启动日志 | `ameJITCacheLogPreLaunch` | 依赖 5 | **小** |
| 17 | SIGBUS 取指分类 | `ameSigbusIsInstructionFetch` + 分类日志（`FATAL: INSTRUCTION FETCH...` / `pc_in_jit26_prepared_region`） | 无（`ameTolerantSigbusHandler` 已在） | **小** |
| 18 | 性能探针对齐（可选） | 用 `A2Metrics` 补齐 A1 `AmePerfProbe` 的 JIT/FPS 采样口径 | 无 | **小** |

**关键依赖图（简）**

```
B1(shaderc_include) ──────────────► 能编出包（否则一切无法验证）
B2(构建入口) ─────────────────────► 同上
  │
  ├─ P1 键盘(3,4) ──► F12 AWT 宿主(12)   [AWT 需要 TrackedTextField 的组字修复]
  ├─ P2 JIT(5) ─────► E1 日志(16)
  ├─ P2 JNA(6) ─────► （独立）
  ├─ P3 联机(7,8) ──► 菜单"联机"入口(15) / ZeroTier(9)
  ├─ P4 Forge(10) ──► （依赖已有 launchHeadlessJVM）
  └─ P4 authlib(11) ─► （独立）
```

**若只做一件事**：B1 + B2（否则后续任何改动都无法验证）。
**若只做三件事**：B1 + B2 + P1（键盘链路归零 2 条功能级缺项，用户可感知最强）。

---

## 6. 已确认"不算缺口"的项（避免重复劳动）

| A1 文件 | A2 对应 | 判据 |
|---|---|---|
| `JavaApp/src/**`（120 文件） | `JavaApp/src/**`（120 文件） | 逐文件差集为 0（仅 A1 多 4 个 `_bak_metallum_agent` 备份 jar），Java 侧 pojav 启动核心**完全同步** |
| `ctxbridges/{gl,egl,osm,vk}_bridge.m`、`bridge_tbl.h`、`sdl3_hook.m`、`shaderc_impl_glue.c`、`shaderc_sandbox.m`、`spvc_shim.c`、`gl4es_family_boot.m`、`virgl_server.m` | `Player/Renderer/` 同名 | 符号差集 0，行数 ±1~3% |
| `PLPreferences` / `LauncherPreferences` / `environ.h` / `jni.h` / `PLLogOutputView` / `PLCrashView` / `GameSurfaceView` / `ios_uikit_bridge` | `Player/Context|Support/` 同名 | 符号差集 0（A2 的 `environ.h` 反而更全：86→108 行） |
| `authenticator/{Base,Microsoft,Local}Authenticator` | `Core/Account/A2AccountManager` + `A2MicrosoftAuth` | 账号/微软登录链路已重写（第三方登录直连 Yggdrasil，见 F8） |
| UI/业务层（下载页、版本管理、模组页、联机页、AI 助手、新闻、公告、主题…约 235 个文件） | `Air2/UI`、`Air2/Core` 的 `A2*` | 架构性重写，非移植欠账；**唯独 `JavaGUIViewController` 例外**（它是 AWT 宿主，不是业务页） |
| `include/ZipArchive.h` / `SSZipArchive` | `Core/Addons/A2ZipReader/A2ZipWriter` | 已换实现 |
| `cmake/ltw_compat/threads.h` | `cmake/natives/ltw_compat/threads.h` | 仅移动位置 |

---

## 7. 复现与验证命令（只读）

```bash
# 1) 两端代码规模
find tree510/Natives -type f \( -name '*.m' -o -name '*.h' -o -name '*.c' \) ! -path '*_bak_*' ! -path '*/external/*' | wc -l   # 448
find upstream_fix/Air2 -type f \( -name '*.m' -o -name '*.h' -o -name '*.c' \) | wc -l                                            # 391

# 2) B1 铁证：调用点在、实现在两树都不存在
grep -n 'shaderc_include.h\|ame_include_expand\|ame_source_has_include' upstream_fix/Air2/Player/Renderer/shaderc_shim.c
find upstream_fix -name 'shaderc_include*' | wc -l     # 0
grep -n 'NATIVES_CORE_DIRS' -A 6 upstream_fix/scripts/gen_xcodeproj.py

# 3) B2 铁证：make natives 空转
sed -n '103,112p' upstream_fix/Makefile
ls upstream_fix/Air2/Player/CMakeLists.txt             # No such file
grep -n 'audio_capture_bridge\|JavaGUIViewController\|SOCKS5Proxy\|PortForwarder\|Terracotta\|SilentAudioPlayer' upstream_fix/cmake/CMakeLists.txt

# 4) F6 铁证：消费者在、生产者不在
grep -rn 'AMETHYST_SOCKS5_PROXY' upstream_fix/Air2   # 4 处，全是 getenv/注释，无 setenv
sed -n '30,46p' upstream_fix/Air2/Core/Multiplayer/A2Multiplayer.m   # weak 符号 + "当前工程里没有 libterracotta.xcframework"
ls upstream_fix/Libraries/terracotta                 # 实际存在 → 注释与事实矛盾

# 5) F3 铁证：自承 no-op 桩
sed -n '196,206p' upstream_fix/Air2/Player/Context/main_hook.m
grep -n 'ame_task132_rebind_jna_dlsym_ex\|ame_task133_rebind_image_sym' tree510/Natives/main_hook.m   # A1 有实现

# 6) F4 铁证：26 个 JIT 门禁函数全树 0 引用
for f in AMEJITEnsureJITUsable AMEDeviceCanExecuteJITCode AMEJITLaunchGateReason AMEJITExec2LaunchBlockReason; do
  echo "$f A2=$(grep -rl "$f" upstream_fix/Air2 | wc -l) A1=$(grep -rl "$f" tree510/Natives | grep -vc _bak_)"; done

# 7) F7 铁证
sed -n '150,180p' upstream_fix/Air2/Core/Addons/A2ModLoaderInstaller.m

# 8) 历史定性
cd upstream_fix && git show --stat 932f22d | head -20
git show --diff-filter=D --name-only --pretty=format:"" 932f22d | wc -l    # 276
git show --diff-filter=D --name-only --pretty=format:"" fcd014c | grep authenticator
```

> 局限：Windows 主机无 Xcode，B1 的"编译失败"是基于 `#include` 可解析性与符号引用的**静态判定**，未在 Mac 上实跑 `xcodebuild`。建议在 Mac 上先跑一次 `python3 scripts/gen_xcodeproj.py && xcodebuild` 复核（预计在 `shaderc_shim.c:221` 报 `'shaderc_include.h' file not found`）。

# 启动链石山审计（LAUNCHCHAIN-DEADCODE）

> 审计对象：`Air2/Player/`（54）+ `Natives/Context/`（14）+ `Natives/Support/`（51）+ `Natives/Renderer/`（7）= **126 个文件**
> 基线：`feat/ondevice-pair @ 22acc4d`（含 KW 集成 `fed0f63` / `b20bb7d`）
> 性质：**只读审计**，本文档不含任何代码修改建议以外的动作；所有"删"都需人工执行。

---

## 0. 结论速览

| 项 | 数量 |
|---|---|
| 确定可删（零引用符号 / 整文件） | **18 项**，约 **810 行** |
| 需人工确认（可疑） | **15 项** |
| 死开关（偏好键有读无写） | **12 个键** |
| 重复实现 / 双真相源 | **4 组** |
| 本次被证伪的"零引用"（假阳性，**不要删**） | 7 项（见 §6） |

三条最重要的发现：

1. **JIT 有三处结论来源并存**：启动链主路径认 `A2JITEnabler → A2LegacyJITGate`（`A2JITEnabler.h:89`），但（a）`A2JITEnvironment` 的**自创判据**（`ensureVerifiedWithinBudget` 等，`A2JITEnabler.h:25` 自述"真机证明它是错的、已删除"）仍在仓里，并经 `Air2/Bridge/A2JITEnvironmentProbe.m:84` 被**设置页**使用；（b）TrollStore 装机走 `a2jit_trollstore_ready()`（`A2JITEnabler.m:250-270`），其中"内核级 entitlement / exec-probe"正是头注释声称已删掉的判据。⇒ 用户可能在设置页看到"JIT 可用"、启动却被闸门拦下（或反之）；且**头注释与代码互相打脸**。
2. **`Natives/Context/A2JVMContext.[hm]`（365 行）整类零引用**：头文件只被自己的 `.m` import（全仓唯一 importer），类名在 `Air2/`、`tests/`、其它 `Natives/` 下 0 处引用；真正在用的是 `a2_vmloader` + `a2_jli_launch`（经 `a2_launch.m:21-23`）。这是"第二套建 VM 路径"的半成品。
3. **`Natives/Support/a2_failbanner.[hm]`（148 行）唯一导出函数 0 调用**：`a2_failbanner_show_jit_unavailable()` 全仓无人调；它一死，`utils.h`（29 行）与 `NMToast`（59 行）的唯一调用方也随之消失 ⇒ 形成一条 **236 行的死链**。

---

## 1. 方法与排除项（为什么这些不是"看起来死"）

| 判断手段 | 说明 |
|---|---|
| 文件级"零引用"的**局限** | `scripts/gen_xcodeproj.py:291 scan_sources()` **递归收全部** `Air2/**` 与 `Natives/**` 的 `.m/.mm` ⇒ 所有 `.m` 都在 Sources 阶段。所以"没人 import 的 .m"仍然会被编译进包（且 `DEAD_CODE_STRIPPING=NO`，见 `gen_xcodeproj.py:650`）。**因此判据一律取"符号级零引用"**，而不是"文件在不在编译列表"。 |
| 已检索并排除的**动态分发** | `NSClassFromString` / `sel_registerName` 在 126 个文件里 **0 处**；`@selector` / `performSelector` 共 **15 处**，全部是 `sortedArrayUsingSelector:@selector(compare:)` 或"可选协议方法守卫"（`A2JITExternalToolProvider.m:166`、`a2_rppairing_pairsetup.m:645/684/723/724`、`a2_tlspsk_tunnel.m:180/183`），**没有一处指向本次删除候选**。`a2_gl_bridge.m:227` 的 `NSSelectorFromString(@"layer")` 取的是 CALayer 属性，与本次无关。⇒ 不存在"靠字符串反射调用的类/方法"被误判为死代码。 |
| tests 引用 | 所有删除候选在 `tests/` 下命中数 **0**（逐符号核对，见 §7 复核命令）；测试 harness 的编译列表也不含 `A2JVMContext.m` / `a2_failbanner.m` / `NMToast.m`。 |
| 局部静态函数 | 第一轮扫描把"同文件自用"误判为死代码，已修正为"排除定义行与头文件声明后统计真实调用点"，修正后全仓只剩 4 个零调用函数（其中 2 个是假阳性，见 §6）。 |

统计口径：**外部引用数 = 除符号定义所在文件以外**的命中行数（含注释行；注释命中会单独标注）。

---

## 2. 确定可删（按风险排序：低 → 高）

风险定义：**低** = 无外部引用、无测试断言、文档未登记；**中** = 无引用但文档/注释仍宣称其存在；**高** = 涉及对外头文件 API 或删除后牵连其它文件。

### 2.1 整文件删除

| # | 文件:行 | 符号 | 外部引用数 | 判定 | 建议 |
|---|---|---|---|---|---|
| F1 | `Natives/Support/a2_failbanner.h:22` / `.m:88` | `a2_failbanner_show_jit_unavailable()`（本文件唯一导出） | **0** | 死 | **删整文件**（148 行）。失败提示现由 `A2LaunchSession.m:929 a2_presentLaunchFailureWithMessage:` 承担 |
| F2 | `Natives/Support/utils.h:1-29` | 整文件（仅提供 `AMEJITRegionVerdict`） | importer = 1（仅 `a2_failbanner.h:18`） | 死（F1 的附庸） | **随 F1 删**；`AMEJIT*` 枚举在 `A2JITEnvironment.h:43` 已有等价物 `A2JITRegionVerdict` |
| F3 | `Natives/Support/NMToast.h:18` / `.m:16` | `NMToast` 类（`+showMessage:duration:…`） | 1（仅 `a2_failbanner.m:49`） | 死（F1 的附庸） | **随 F1 删**（59 行）；如后续要做提示条，重新加回来即可 |
| F4 | `Natives/Context/A2JVMContext.h:78` / `.m:110` | `A2JVMContext` 类 + `A2JVMConfig`（`.h:44`） | **0 处代码引用**（头文件唯一 importer 是 `A2JVMContext.m:14`；外部 6 处命中**全是注释**：`gen_xcodeproj.py:54/646`、`a2_glfw_window.m:421`、`A2LaunchPlan.h:14/19`、`A2LaunchChain.h:10`） | 死 | **删整文件**（365 行）+ 同步删 `docs/ARCHITECTURE.md:219` 的登记行与 `scripts/gen_xcodeproj.py:646` 的注释 |

> F1–F3 是**一条死链**（failbanner → utils.h + NMToast），删的时候一次删干净，否则会留下"声明了但没实现"的新石山。
> F4 风险**高**：`docs/ARCHITECTURE.md:219` 明确登记了它，`docs/ARCHITECTURE.md:364` 也引用了它的职责说明 —— 删代码必须同步改文档，否则下一个人按文档找不到实现。

### 2.2 符号级删除（函数 / 方法 / 属性）

| # | 文件:行 | 符号 | 外部引用数 | 判定 | 建议 |
|---|---|---|---|---|---|
| S1 | `Natives/Support/A2JITEnvironment.m:868`（声明 `.h:99`） | `+waitReadyVerified` | **0** | 死 | 删（它是"自创判据"的入口，见 §4-D1） |
| S2 | `Natives/Support/A2JITEnvironment.m:717`（声明 `.h:96`） | `+verifyWritableRegion` | **0**（唯一调用方 S1 也死） | 死 | 删 |
| S3 | `Natives/Support/A2JITEnvironment.m:875`（声明 `.h:106`） | `+execProofObtained` | **0** | 死 | 删（`A2JITEnabler.h:25` 已声明放弃此口径） |
| S4 | `Air2/Player/A2JITProvider.h:82` | `@property userActionHint` | **0 处读取** | 死 | 删属性 + 4 处实现：`A2JITAutomaticPairingProvider.m:451`、`A2JITExternalToolProvider.m:227`、`A2JITImportedPairingProvider.m:164`、`A2JITKernelJITProvider.m:133` |
| S5 | `Air2/Player/A2JITCoordinator.m:91`（声明 `.h:86`） | `+defaultProvidersWithFacts:` | **0** | 死 | 删（工厂方法从未被调用；实际装配在 `A2JITSettings.m:585` 手写） |
| S6 | `Air2/Player/A2JITAutoPairingGuidance.m:110`（声明 `.h:45`） | `+displayNameForPrecondition:` | **0** | 死 | 删（同文件的 `nameKeyForPrecondition:` 才是在用路径） |
| S7 | `Air2/Player/A2JITAutomaticPairingProvider.m:75` / `:79`（声明 `.h:40`/`:44`） | `+defaultGenerationBudget` / `+defaultPairingFileMaxAge` | **0** | 死 | 删（两个"默认值导出"没人读，值内联在实现里） |
| S8 | `Natives/Support/a2_tlspsk_tunnel.m:124`（声明 `.h:108`） | `+setHostPolicy:` | **0** | 死 | 删（host policy 恒为 nil，从未被设置） |
| S9 | `Natives/Support/a2_rppairing_pairsetup_transport.m:58`（声明 `.h:46`） | `+streamToEndpoint:reason:` | **0** | 死 | 删 |
| S10 | `Natives/Support/a2_rppairing_rsd.m:37`（声明 `.h:58`） | `A2RPRSDTransportName()` | **0** | 死 | 删（日志里从未打印 transport 名） |
| S11 | `Natives/Support/a2_rppairing_srp.m:889`（声明 `.h:180`） | `A2RPSRPServerTrace()` | **0** | 死 | 删 |
| S12 | `Natives/Support/a2_rppairing_rsd.h:138` | `@property foundDescriptions` | **0**（无写入也无读取） | 死 | 删属性（`readonly` 且没有任何赋值点 ⇒ 恒 nil，**典型死属性**） |
| S13 | `Air2/Player/A2RuntimeStrings.m:53`、`:65`、`:115`、`:147` | 4 个四语 key：`runtime.row.renderer.detail`、`runtime.row.jre.detail`、`runtime.none`、`runtime.cancel` | **0** | 死 | 删这 4 项（= 16 条文案）。注意 `runtime.jre.8/17` 与 `runtime.renderer.*` 是**格式生成**的（`A2JavaRuntimeCatalog.m:47`、`A2RendererCatalog.m:114`）⇒ **不算死** |
| S14 | `Air2/Player/A2JITStrings.m:891` | key `jit.toast.ddiFetchOff` | **0** | 死 | 删。同表的 `jit.ddi.*` / `jit.autopair.blocker.*` / `jit.autopair.precond.*` 全部经 `A2JITDDIGuidance.m:50/54`、`A2JITAutoPairingGuidance.m:90/94/132` 格式生成 ⇒ **不算死** |

合计：F1–F4 = 601 行；S1–S14 ≈ 210 行（含 4 语文案 20 条）。

---

## 3. 需人工确认（可疑，不能由静态扫描定死）

| # | 文件:行 | 符号 / 现象 | 引用数 | 判定 | 待确认的问题 |
|---|---|---|---|---|---|
| Q1 | `Natives/Support/A2JITEnvironment.m:731`（`.h:89`） | `+ensureVerifiedWithinBudget:reason:` | 3（`A2JITEnvironmentProbe.m:84`、`:23/:24` 注释、`jit_logic_tests.m:1108` 的**源码字符串断言**） | 可疑 | 这是被 `A2JITEnabler.h:25-30` **明文否证**的自创判据，但仍被设置页真调。要么删、要么在 `docs/` 里写清"只作诊断展示、不参与启动"，**不能两套并存而无标注** |
| Q2 | `Natives/Support/A2JITEnvironment.m:854` | `+kickBackgroundVerify` | 0 外部 / 1 内部（`:783`） | 可疑 | 只被 Q1 内部调用 ⇒ Q1 一删它也死。与 Q1 同进同退 |
| Q3 | `Natives/Support/A2JITEnvironment.m:520 / :587 / :485` | `a2_jit_brk69_bounded` / `a2_jit_verify_region_bounded` / `a2_jit_expected_region_bytes` | 仅 Q1 链路 | 可疑 | 属于"自创判据"的支撑代码（约 180 行），随 Q1 决策一起处置 |
| Q4 | `Air2/Bridge/A2JITEnvironmentProbe.m:84` | 设置页注入的"真判据内核" | 1（`A2JITSettings.m`） | 可疑 | 与启动链判据**不是同一个真值源**（见 §4-D1）。要么改为转调 `A2JITEnabler`，要么在 UI 上标明"仅供参考" |
| Q5 | `Natives/Support/a2_remotexpc_framing.m:286` | `A2RXPCStaticTableName()` | 2，**全在 `tests/JIT/remotexpc_tests.m:169-170`** | 可疑 | 生产零调用、仅测试用 ⇒ 要么保留（测试覆盖 HPACK 静态表）并注明"test-only export"，要么删函数+删断言 |
| Q6 | `Air2/Bridge/A2JITDDIDeviceBridge.m:33` | `A2JITDDIDeviceBridge`（全部方法回"未接入"） | 1（`A2JITSettings.m:607` 注入） | 可疑（**已文档化骨架**） | 头注释自述"本类当前是骨架"（`.h:27`）。有调用方 + 有文档 ⇒ **建议保留**；但需要确认它不会在 UI 上被误当成"设备侧可查" |
| Q7 | `Air2/Player/A2JITPairingCodeSession.m:107` | 码已生成、listener 未起 | — | 可疑（**已文档化半成品**） | 自述"真正起 mDNS 广告与 responder 传输未接线"（`.h:21`）⇒ 需确认是否本单收尾范围 |
| Q8 | `Air2/Player/A2LaunchSession.m:216` | `if (!A2JITIsEnabled(0) && ![A2JITEnabler isJITReadyNow])` | 1 | 可疑（**与自我声明冲突**） | 这里在 `A2JITEnabler` 之前先跑了一次 `A2JITIsEnabled(0)`（= `dynamic-codesigning` entitlement 或 `CS_DEBUGGED`，`A2LegacyJITGate.m:102`）短路。`A2JITEnabler.h:25-30` 说这两种都是"能力声明≠可用"、曾导致"放行后闪退"。这个短路是否仍需要？ |
| Q9 | `Air2/Player/A2LaunchSession.m:216 / :812 / :837` | JIT 判据在启动路径上出现**三次**（`A2JITIsEnabled(0)` → `isJITReadyNowWithReason:` → `openLegacyGateBeforeVMBuild:`） | 3 | 可疑（重复实现） | 后两次都落到 `A2LegacyJITGateReadyNow` / `GateOpen`，语义重叠（`ReadyNow` 非镜像走 exec-probe，`GateOpen` 非镜像直接放行）。是否合并为一次判定 + 一次动作？ |
| Q10 | `Air2/Player/A2LaunchSession.m:13` | `#import "A2LaunchOverlay.h"`（位于 `Air2/UI/Components/`） | 2 调用（`:167`、`:716`） | 可疑（**跨层**） | `Player` → `UI` 是逆向依赖（`air2-architecture` 第 2 条）。建议把 overlay 抽成 `Player` 侧协议 + `UI` 实现注入 |
| Q11 | `Air2/Player/A2LaunchSession.m:156` | `+startCurrentVersionWithCompletion:` **单方法约 780 行**（`:156`–`:928`） | 3 处调用（`A2LauncherViewController.m:731`、`A2AppDelegate.m:161`、自递归 `:246`） | 可疑（单一职责） | 与方法行数无关的判据：一个方法同时承担 版本校验 / 渲染器选择 / JRE 选择 / 内存预算 / JIT 闸门 / 建 VM / 失败页。建议按"选参(纯函数) → 组计划 → 建 VM"拆 |
| Q12 | `Natives/Support/A2JITEnvironment.m`（`:30` 起 925 行） | 文件同时承担：brk 原语 / 区域取证 / 匿名页 exec-probe / 缓存 / 日志出口 | — | 可疑（单一职责） | 与 Q1 决策耦合：若保留"只作诊断"，建议把 exec-probe 与 brk 原语拆开 |
| Q13 | `Air2/Player/A2JITStrings.m`（53 KB / 139 key × 4 语） | 文案表 | 消费方 12 处 | 活 | 非死代码，但**无"表内 key 是否都有消费方"的反向断言**（`jit_logic_tests.m:752` 只断言"guidance 产出的 key 都有文案"）⇒ 建议补一条反向断言，否则 §2.2 S13/S14 这类死 key 会持续增殖 |
| Q14 | `Natives/Support/A2JITEnabler.m:78-362` | `a2jit_tool_name` / `a2jit_src_name` / `a2jit_trollstore_*` / `a2jit_url_*` / `a2jit_source*` | 均 ≥1 内部调用 | 活 | 第一轮扫描误报为"零引用"（同文件自用），已证伪；**不要删** |
| Q15 | `Natives/Support/A2JITEnabler.m:250-270` | `a2jit_trollstore_ready()` 的三条放行判据（老 Air 闸门 / 内核级 entitlement / exec-probe） | 1（`A2JITEnabler.m:319`） | 可疑（**注释与代码矛盾**） | 头注释 `A2JITEnabler.h:25-30` 写"放行优先四条已删除、不再有第二套判据参与启动决策"，而本函数仍在用其中两条（`a2_jit_has_kernel_level()`、`a2_jit_exec_probe_anonymous()`）。需拍板：写成"巨魔机专用例外"（改注释）还是并入唯一判据（删这两条） |

---

## 4. 重复实现 / 双真相源（这是本单最贵的一类石山）

| # | 组 | 旧/新两边 | 证据 | 建议 |
|---|---|---|---|---|
| D1 | **JIT 可用性判据** | ① `A2JITEnabler → A2LegacyJITGate`（启动链唯一） ② `A2JITEnvironment` 自创判据（`ensureVerifiedWithinBudget` + exec-probe + 区域尺寸） ③ `a2jit_trollstore_ready()`（TrollStore 装机专线：内核级 entitlement / exec-probe 也放行） | ① `A2JITEnabler.h:89-97`、`A2LaunchSession.m:808-812`；② `A2JITEnvironment.m:731-871`、`A2JITEnvironmentProbe.m:84`；③ `A2JITEnabler.m:242-270` | **合并**：设置页改调 `A2JITEnabler.isJITReadyNowWithReason:`；②整段删或降级为"仅日志"。③与 `A2JITEnabler.h:25-30`「这些判据已删除、不再有第二套判据参与启动决策」**直接矛盾**（头注释说删了，代码里还在用）⇒ 必须先对齐注释与代码 |
| D2 | **JIT 编排层** | ① `A2LaunchChain`（①→②→③，`A2LaunchSession.m:795` 构造） ② `A2JITCoordinator` + 4 个 Provider + `A2JITStrategySelector` / `A2JITStateMachine` / `A2JITDDI*`（`A2JITCoordinator.h:22` 自述"与 A2LaunchChain 分工"） | ②的**唯一生产入口是设置页**：`A2JITSettings.m:585`（`[A2JITAutoPairingEngineBridge alloc]`）、`:607`；`A2JITCoordinator` 外部引用只有 `A2JITSettings.m` + `jit_logic_tests.m` | **保留但降级**：②已事实上是"设置页诊断子系统"，不是启动链。建议在 `A2JITCoordinator.h` 顶部写明"不参与启动决策"，否则下一个人会以为它是 ①的替代 |
| D3 | **偏好通道** | ① `A2Settings`（`Core/Settings`，`config.json` + 通知，`A2Settings.m:120-270`） ② 各层**直接读 `NSUserDefaults`**：`A2LaunchSession.m:299/366/388`、`a2_launch.m:31`、`A2JITEnvironment.m:402`、`A2LegacyJITGate.m:727` | 两套都在用，键互不可见 | 需拍板：要么 `Natives/Player` 一律经 `A2Settings`（跨层注入），要么在文档里承认"native 层直接读 NSUserDefaults"是既定契约 |
| D4 | **建 VM 入口** | ① `a2_vmloader` + `a2_jli_launch`（`a2_launch.m:21-23` 实际使用） ② `A2JVMContext`（dlopen libjvm + `JNI_CreateJavaVM`） | ②整类零引用（§2.1 F4） | **删②**（见 F4） |

---

## 5. 死开关：只读不写的偏好键（12 个）

判据：全仓（`Air2/`、`Natives/`、`tests/`、`docs/`）检索键名字面量，**只有读、没有写** ⇒ 只能靠 `defaults write` 打开，UI 上没有任何入口。

| # | 键 | 读点 | 写点 | 判定 | 建议 |
|---|---|---|---|---|---|
| K1 | `A2KWContextMode` | `a2_gl_bridge.m:602`（常量定义 `:56`） | **无** | 死开关（A/B 探针） | `22acc4d` 新增；注释自述"三档模式 A/B"。要么接设置页，要么删（`air2-architecture` 禁"默认关着的半成品") |
| K2 | `A2KWUseES1` | `a2_gl_bridge.m:610`（常量定义 `:55`） | **无** | 死开关（A/B 探针，已被 K1 兼容层引用） | 同上；两个键是同一能力的两代写法（**重复实现**） |
| K3 | `A2ForceJNIPath` | `a2_launch.m:461-462` | **无** | 死开关（诊断） | 注释自述"诊断开关"；建议在 `docs/` 登记为"仅 defaults write"，否则删 |
| K4 | `A2JITAlwaysAttached` | `A2LegacyJITGate.m:727` | **无** | 死开关 | 影响 `SetDetachAfterFirstBr(!alwaysAttached)`，属真机关键项 ⇒ 建议接设置页或写进 JIT 文档 |
| K5 | `A2AllowJITExecProbe` | `A2JITEnvironment.m:402-403` | **无** | 死开关 | 随 Q1/D1 一起处置 |
| K6 | `A2JITRegionMB` | `A2JITEnvironment.m:486`、`:553` | **无** | 死开关（`docs/DECISIONS.md:316` 有登记） | 已被文档承认 ⇒ **保留**，但需在 README/设置页说明是 defaults-only |
| K7 | `A2SkipJITMachinery` | `A2JITEnvironment.m:736-737` | **无** | 死开关 | 同上；它是"跳过 JIT 机制"的钥匙，隐藏开关风险最高 ⇒ 建议显式登记或删 |
| K8 | `A2XmxMB` | `A2LaunchPlan.m:395` | **无** | 死开关 | 内存档位已有 `A2SettingsKeyRAMAllocationMB`（`A2Settings.m:208`）⇒ **两套内存偏好**，建议合并 |
| K9 | `A2XintMode` | `A2LaunchPlan.m:431-432` | **无** | 死开关 | 建议登记或删 |
| K10 | `A2CodeCacheMB` | `A2LaunchPlan.m:463` | **无** | 死开关 | 同上 |
| K11 | `A2UseMirrorCodeCache` | `A2LaunchPlan.m:488-489` | **无**（默认 YES） | 死开关 | 同上 |
| K12 | `A2VMDiagAll` | `A2LaunchPlan.m:526-527` | **无** | 死开关 + **文档矛盾** | 代码默认 **YES**，而 `docs/COMPAT-MATRIX.md:287` 明写"应改回 NO"⇒ 二者必须对齐 |

补充：`A2UseSystemClassLoader`（`A2LaunchPlan.m:548-549`）只有 `tests/Plan/plan_memory_budget_tests.m:263` 写 ⇒ **测试专用开关**，与上表同性质但优先级最低。

---

## 6. 被证伪的"零引用"（假阳性清单，**别删**）

| 符号 | 表面现象 | 实际调用方 |
|---|---|---|
| `A2RPOPackData`（`a2_rppairing_pairsetup.m:133`） | 首轮扫描 0 外部引用 | 同文件 `:149`、`:151` 调用：`A2RPOPackString(...); A2RPOPackData(...)` 同一行两条语句，被误判为声明 |
| `a2_jit_prove_region_rwx`（`A2JITEnvironment.m:283`） | 外部 0 | `A2JITEnvironment.m:675`（Q1 链路内） |
| `a2_gl_bridge_teardown` / `_renderable_handle` / `_egl_symbol` / `_is_krypton` / `_gles_getprocaddress` / `_krypton_initialize` / `_frame_work` | 外部 0（全是 `static`） | 全部在 `a2_gl_bridge.m` 内部被调用（`:432/:474/:482`、`:436`、`:523-542`、`:508/:596/:682`、`:517`、`:690`、`:380/:765`） |
| `A2JITEnablerRun`（`A2JITEnabler.m:404`） | 头文件里不存在 | 私有类，`A2JITEnabler.m:884 [A2JITEnablerRun new]` |
| `A2JITStrategyDecision`（`A2JITStrategySelector.h:26`） | 外部引用少 | `A2JITStrategySelector.m:16/32/37…` 构造并返回，`A2JITCoordinator` 消费 |
| `A2JITStrings` 的 `jit.ddi.*` / `jit.autopair.*` 共 40 个 key | 字面量零命中 | 由 `A2JITDDIGuidance.m:50/54`、`A2JITAutoPairingGuidance.m:90/94/132` 用 `stringWithFormat:` 生成 |

---

## 7. 活代码取证（"新增即登记"的反向证明）

每一处启动链关键符号都能指到调用行 —— 这份表用于回答"谁调它·哪一行"：

| 符号 | 定义 | 调用点（唯一） |
|---|---|---|
| `A2LaunchSession.startCurrentVersionWithCompletion:` | `A2LaunchSession.m:156` | `Air2/UI/Screens/Home/A2LauncherViewController.m:731`（启动按钮）、`Air2/App/A2AppDelegate.m:161`（重挂后自动继续）、`A2LaunchSession.m:246`（JIT 就绪后重入） |
| `A2LaunchChain` | `A2LaunchChain.m:23` | `A2LaunchSession.m:795` |
| `A2JITEnabler.isJITReadyNow` | `A2JITEnabler.m:811` | `A2LaunchSession.m:216` |
| `A2JITEnabler.isJITReadyNowWithReason:` | `A2JITEnabler.m:815`（→ `a2jit_ready_now` `:314`） | `A2LaunchSession.m:812` |
| `A2JITEnabler.ensureJITThen:` | `A2JITEnabler.m:867` | `A2LaunchSession.m:220` |
| `A2JITEnabler.openLegacyGateBeforeVMBuild:` | `A2JITEnabler.m:834` | `A2LaunchSession.m:837`（全工程唯一建 VM 处之前） |
| `a2jit_ready_now()`（安装源分支） | `A2JITEnabler.m:314` | `A2JITEnabler.m:817` |
| `a2jit_trollstore_ready()` | `A2JITEnabler.m:250` | `A2JITEnabler.m:319` |
| `A2LegacyJITGateReadyNow()` | `A2LegacyJITGate.m:616` | `A2JITEnabler.m:252`、`:321` |
| `A2LegacyJITGateOpen()` | `A2LegacyJITGate.m:661` | `A2JITEnabler.m:856` |
| `A2JITEnvironment.needsDebuggerMapping` | `A2JITEnvironment.m:900` | `A2LegacyJITGate.m:613` |
| `A2JITEnvironment.regionEvidence` / `lastRegionVerdict` | `.m:904` / `:908` | `A2JITEnvironmentProbe.m:85/89/91/97`（设置页） |
| `a2_jit_query_region_prot` | `A2JITEnvironment.m` | `A2LegacyJITGate.m:285` |
| `a2_jit_send_script_safe` | `A2JITEnvironment.m` | `A2LegacyJITGate.m:368`（Extension 下发） |
| `a2_launch_jvm_with_argv` | `a2_launch.m` | `A2LaunchRunner.m:408`（Bridge 唯一） |
| `a2_launch_runtime_enabled` | `a2_launch.m:70` | `A2LaunchRunner.m:166`；写点：`A2JITSettings.m:801`（`debug.rt_p1_runtime`，**键有写点 ⇒ 不是死开关**） |
| `A2LaunchFailure.jitvmLineWithStep:...` | `A2LaunchFailure.m` | `A2LaunchSession.m:179/799/817/853` |

---

## 8. 复核命令（删完必须逐条 0 命中）

```bash
cd D:/CTF/_510src/Air2_all
# F1-F4 整文件
rg -n "a2_failbanner|AMEJITRegionVerdict|NMToast" -g '!docs/**' ; echo "expect 0"
rg -n "A2JVMContext|A2JVMConfig" -g '!docs/**' -g '!scripts/gen_xcodeproj.py' ; echo "expect 0"
# S1-S14 符号
rg -n "waitReadyVerified|verifyWritableRegion|execProofObtained|userActionHint" -g '!docs/**' ; echo "expect 0"
rg -n "defaultProvidersWithFacts|displayNameForPrecondition|defaultGenerationBudget|defaultPairingFileMaxAge" ; echo "expect 0"
rg -n "setHostPolicy|streamToEndpoint|A2RPRSDTransportName|A2RPSRPServerTrace|foundDescriptions" ; echo "expect 0"
rg -n --fixed-strings "runtime.cancel" Air2/ ; rg -n --fixed-strings "jit.toast.ddiFetchOff" Air2/ ; echo "expect 0"
# 删完再跑
python scripts/check_imports.py   # 头文件引用完整性
make lint                          # 目录/分层规范
python scripts/gen_xcodeproj.py    # 重新生成 pbxproj（确认无缺失 fileRef）
```

> 每删一批单独提交（同类同源），不要混进功能改动。文档里提到已删符号的句子（尤其 `docs/ARCHITECTURE.md:219/221`、`gen_xcodeproj.py:646` 的注释）必须同一提交改掉。

---

## 9. 审计口径说明 / 未覆盖范围

- 本审计**只覆盖启动链**（Player + Context + Support + Renderer 的 gl bridge）。`Air2/UI`、`Air2/Core`、`Air2/Bridge` 只在"作为调用方"时被检索，未做它们自己的石山审计。
- 扫描曾报告 `A2DependencyResolver`、`A2ResourcePack`、`A2ResourceScanner`、`A2LoaderVersionSource`、`A2GlfwHost/View`、`A2TLSPskMbedTLSBackend` 不可达 —— 除 `A2TLSPskMbedTLSBackend`（实为 C 函数 `A2TLSPskMbedTLSEnsureRegistered()` 注册，`A2TLSPskTunnelBridge.m:34`、`A2JITAutoPairingEngineBridge.m:183` ⇒ **活**）外，其余**不在本次范围**，留给对应层的审计。
- `A2LaunchChain`/`A2LaunchSession`/`A2LaunchPlan`/`A2JavaRuntimeCatalog`/`A2ModLoaderSelection` 均确认有生产调用方（见 §7、`A2LaunchSession.m:359`），**不是死代码**。

# 渲染器系统重写方案

> 状态：调查完成，待实施
> 依据：逐行读完 `Core/Renderer/`（2325 行）与 `Player/Renderer/`（15746 行）后的实测结论
> 参考实现：ZL2 `zl2/.../game/renderer/`（1100 行）

---

## 0. 一句话结论

**现状是「两套并行的渲染器决策逻辑」，参考 ZL2 收敛成「一份不可变的 RendererPlan」。**

具体表现：选渲染器这件事，Air2 在 **JavaLauncher** 和 **egl_bridge** 两处各做了一遍，两处的 `auto` 解析语义还相反。加一个渲染器要改 2~4 个地方，漏一处就是某条启动路径黑屏。

---

## 1. 现状实测

### 1.1 真实数据流

```
设置页 A2RendererSettingsViewController
  ↓ 写
A2Settings.renderer（持久化，默认 "libmobileglues.dylib"）
  ↓ PLProfiles.m:98（resolveKey:@"renderer"）
  ↓ ⋯⋯ 到这里断了 ⋯⋯
  ↓
AMETHYST_RENDERER 环境变量
  ↓
  ├─→ JavaLauncher.m:2130  算出 -Dorg.lwjgl.opengl.libname（给 LWJGL 用）
  └─→ egl_bridge.m:277     选出 br_* 桥表 + EGL 来源（给 native GL 桥用）
```

### 1.2 断点：没人把设置写进环境变量

`main.m` 里**没有任何 setenv**。全工程写 `AMETHYST_RENDERER` 的地方只有：

| 位置 | 行为 |
|---|---|
| `JavaLauncher.m:2138` | 读到值后**再次** setenv |
| `egl_bridge.m:289,293,431,555,560` | 读到值后**再次** setenv |

全是「读到了再覆盖」，**没有第一手写入**。`PLProfiles` 只把值提供给 Java 层做 `Preferences` 查询，不进环境变量。

**后果**：若进程环境里没有 `AMETHYST_RENDERER`（默认情况），`JavaLauncher.m:2130` 的 `getenv` 返回 NULL，整个 `if (glLibName)` 块被跳过 → `-Dorg.lwjgl.opengl.libname` **根本不注入**；`egl_bridge` 侧所有 `isEqualToString:` 也不匹配 → 走 `:426` 兜底回落 ANGLE。

→ 详见 TODO T1（P0）。

### 1.3 两处 auto 语义相反

| 位置 | `auto` 解析成 |
|---|---|
| `JavaLauncher.m:2133-2137` | `RENDERER_NAME_MTL_ANGLE`（注释：对齐 Ynnyny，26.2 启动崩溃修复） |
| `egl_bridge.m:285-290` | `RENDERER_NAME_GL4ES` |

谁先跑谁说了算。`JavaLauncher` 会 setenv 成 ANGLE，所以 egl_bridge 之后读到的是 ANGLE —— 但这是**靠执行顺序偶然正确**，不是设计。

→ 详见 TODO T2（P0）。

### 1.4 渲染器全景（12 支）

`utils.h` 里定义了 14 个 `RENDERER_NAME_*` 常量，`Libraries/Frameworks/` 里实际有 13 个 dylib，
而实际能进 `egl_bridge` 分支的有 12 支：

| # | AMETHYST_RENDERER | 桥表 | EGL 来源 | 备注 |
|---|---|---|---|---|
| 1 | `auto` / `libgl4es_114.dylib` | GL | ANGLE | 会被改写成 gl4es |
| 2 | `libmobileglues.dylib` | GL | ANGLE + MG 前端覆盖 | 默认值 |
| 3 | `libtinygl4angle.dylib` | GL | 自身 | |
| 4 | `libltw.dylib` | GL | ANGLE + LTW 3 wrapper | 需先 RTLD_GLOBAL 加载 ANGLE |
| 5 | `libSimpleFPEWrapper.dylib` | GL | SFPEW → 回落 `AMETHYST_SFPEW_BACKEND` | |
| 6 | `libvgpu` / `libgl4eszl2` / `libnggl4es` | GL | ANGLE | MakeCurrent 尾要补 `initialize_gl4es()` |
| 7 | `libvirgl_test_server.dylib` | **OSM** | 不走 EGL | |
| 8 | `libmithril.dylib` | GL | 自身 | |
| 9 | `libMobileGL.dylib` / `-gles` | GL | 自身 | |
| 10 | 其它 `libOSMesa*` | **OSM** | 不走 EGL | `GALLIUM_DRIVER=zink` |
| 11 | `libMoltenVK.dylib` | GL | ANGLE | 分支内直接 `br_init()`，跳过公共尾 |
| 12 | 未命中 | GL | ANGLE 回落 | |

`libmetallum.dylib` 不进表：`JavaLauncher.m:1529-1533` 在启动前把它改写成 `auto`，只置 `AMETHYST_METAL=1`。

### 1.5 Core/Renderer 层是死代码

| 类 | 行数 | 实际状态 |
|---|---|---|
| `A2Renderer` / `A2Renderers` | 96+152 | **零引用** |
| `A2RendererRegistry` | 122+450 | 设置页 + precheck 在用，但只管「显示哪些渲染器」 |
| `A2RendererRegistry.prepareRendererForMCVersion:error:` | — | **零调用** |
| `A2RendererPlugin` / `Importer` / `LibraryLayout` | 159+86+72+347+44 | 插件导入在用 |
| `A2RendererLoader` | 98+238 | 需核实 |

结论：配置层（Registry）和运行时（JavaLauncher/egl_bridge）**之间没有连接**。Registry 知道哪些渲染器可用、支持哪个 MC 版本，但启动时没人问它。

---

## 2. 问题清单

### P0（会崩 / 会黑屏）

| # | 问题 | 位置 | 影响 |
|---|---|---|---|
| P0-1 | 无人写入 `AMETHYST_RENDERER` 初值 | `main.m` 无 setenv | 设置页选的渲染器可能完全不生效，静默回落 ANGLE |
| P0-2 | `auto` 两处语义相反 | `JavaLauncher.m:2133` vs `egl_bridge.m:285` | 结果依赖调用顺序 |
| P0-3 | `br_init` 返回值语义反向，且失败可无限重试 | `gl_bridge.m:1663`（true=成功）vs `egl_bridge.m:415,517`（`!br_init()` 当 0=成功） | 反复 dlopen + 新 surface 错配 |
| P0-4 | `br_init_context` 无 NULL 守卫 | `egl_bridge.m:1084`（对比 `:968,1043` 都有） | 桥表没选好时空指针崩 |
| P0-5 | `gl_terminate` 无 NULL 守卫 + 泄漏 | `gl_bridge.m:2068-2078` | 崩溃 + 重复启动泄漏 |
| P0-6 | context 失败泄漏 surface | `gl_bridge.m:1860,1911-1917` | 重试累积到 `EGL_BAD_ALLOC` |
| P0-7 | EGL 完整性检查漏 3 个符号 | `gl_bridge.m:1543-1547` | 缺符号也算成功，之后必崩 |

### P1（功能不对 / 卡顿 / 偶崩）

| # | 问题 | 位置 |
|---|---|---|
| P1-1 | Vulkan 分支是坏合并：`if (br_init==NULL)` 连写两遍，分支内直接 return 跳过公共尾 | `egl_bridge.m:405-416` |
| P1-2 | `g_ame48_layer_cf` 有 UAF 风险（CFRelease 后 block 仍持裸指针） | `gl_bridge.m:1113-1115` vs `:868,923,979` |
| P1-3 | `ame_es()` 失败永久熔断且无锁 | `gl_bridge.m:267-270` |
| P1-4 | realign 用 `dispatch_sync(main)` + 100ms 等待阻塞渲染线程 | `gl_bridge.m:483-498,545-698` |
| P1-5 | `assert(bundle->config)` 在 Release 被裁掉 | `gl_bridge.m:1730-1731`、`osm_bridge.m:38` |
| P1-6 | gl4es 引导用裸名 `RTLD_NOLOAD`，匹配不上则 `initialize_gl4es()` 永不执行 | `gl4es_family_boot.m:93,139-146` |

### P2（死代码 / 重复）

| # | 问题 | 位置 |
|---|---|---|
| P2-1 | `br_setup_window` 全链路死指针 | `bridge_tbl.h:63`、`egl_bridge.m:58` |
| P2-2 | `set_vk_bridge_tbl()` 零调用 → 整个 `vk_bridge` 不可达 | `vk_bridge.m:296` |
| P2-3 | `ame_gap_renderer_selected()` 无调用者，注释却说 egl_bridge 用它 | `gl4es_family_boot.m:126-129` |
| P2-4 | Task76/77 统计无人读，每帧白付 2 次 `clock_gettime` | `gl_bridge.m:94,150` |
| P2-5 | `Amethyst_SDL3SurfaceWantsPoints` 恒 NO 占位 | `gl_bridge.m:46-48` |
| P2-6 | `mg_init_gles` 双解析（第二次用 `RTLD_DEFAULT` 可能命中别的镜像） | `gl_bridge.m:1403` vs `:1944-1955` |
| P2-7 | 几何写入有 4 处实现，`resolutionScale` 是无同步全局 | `gl_bridge.m:1799,868,1013` + `SurfaceViewController.m:1143,1552` |
| P2-8 | `A2Renderer` / `A2Renderers` 零引用 | `Core/Renderer/A2Renderer.{h,m}` |
| P2-9 | `prepareRendererForMCVersion:error:` 零调用 | `A2RendererRegistry.m` |

### 与 JavaLauncher 重复/冲突的 6 处

| # | 冲突点 | 位置 |
|---|---|---|
| D-1 | `auto` 解析语义相反 | `JavaLauncher.m:2130` vs `egl_bridge.m:285` |
| D-2 | 回落链两套 | `JavaLauncher.m:1545-1574` vs `egl_bridge.m:426-433` |
| D-3 | RTLD 预载/glslang 隔离两套，排除表不一致 | `JavaLauncher.m:2609-2648` vs `egl_bridge.m:474-505` |
| D-4 | `MOBILEGL_BACKEND_TYPE` 三处写 | `JavaLauncher.m:1646`、`egl_bridge.m:360,441` |
| D-5 | `GALLIUM_DRIVER` 两处 | `egl_bridge.m:369` vs `ZinkConfig`/`JavaLauncher.m:1587` |
| D-6 | gap/VirGL 环境分两处 | `JavaLauncher.m:1613-1635` vs `egl_bridge.m:337-346` |

---

## 3. ZL2 参考架构

### 3.1 接口（`RendererInterface.kt`，120 行）

```kotlin
interface RendererInterface {
    fun getRendererId(): String                    // 稳定 ID
    fun getUniqueIdentifier(): String              // 唯一标识
    val mesaBased: Boolean                          // 是否 Mesa 系
    val needsZinkDriverOverride: Boolean            // 是否覆写 Zink 驱动
    fun supportsSfpewByDefault(): Boolean
    fun getRendererName(): String
    fun getRendererSummary(): String?
    fun getMinMCVersion(config): String?            // 可依配置变化
    fun getMaxMCVersion(config): String?
    fun getRendererEnv(): Lazy<Map<String, String>>  // 环境变量表
    fun getDlopenLibrary(): Lazy<List<String>>       // 要 dlopen 的库
    fun getRendererLibrary(): String                 // 主库名
    fun getRendererEGL(): String?                    // EGL 来源（可空）
}
```

### 3.2 注册表（`Renderers.kt`，129 行）

```kotlin
object Renderers {
    fun init(reset)
    fun getRenderers(): List<RendererInterface>
    fun getLegacyRendererIds(): Map<String, String>   // 旧 ID → 新 ID
    fun addRenderer(renderer): Boolean                // 按 uniqueIdentifier 去重
    fun setCurrentRenderer(id, retryToFirstOnFailure = true): RendererInterface
    fun getCurrentRenderer(): RendererInterface
    fun isCurrentRendererValid(): Boolean
}
```

### 3.3 四个关键设计

1. **每渲染器一个类**，实现同一接口。Air2 是两处 if-else 大分支。
2. **渲染器自报 env / dlopen 库 / EGL 来源**，调用方只消费。Air2 是散落在 JavaLauncher + egl_bridge。
3. **`setCurrentRenderer` 未命中回落列表首个**，结构上不可能出现「无渲染器」。Air2 是各自兜底 ANGLE。
4. **`getLegacyRendererIds()` 做旧 ID 迁移**。Air2 没有，旧配置直接失效。

---

## 4. Air2 目标架构

### 4.1 新增一个协议（替代 JavaLauncher + egl_bridge 的两处分支）

```objc
@protocol A2RendererBackend <NSObject>
- (NSString *)rendererId;                  // 稳定 ID
- (NSString *)uniqueIdentifier;
- (NSString *)displayName;
- (NSString *)summary;
- (BOOL)isMesaBased;
- (BOOL)needsZinkDriverOverride;
- (NSString *)minMCVersion;
- (NSString *)maxMCVersion;
- (NSDictionary<NSString *, NSString *> *)environment;
- (NSArray<NSString *> *)dlopenLibraries;   // 要 dlopen 的清单
- (NSString *)mainLibrary;                 // 主库（给 -Dorg.lwjgl.opengl.libname）
- (NSString *)eglSource;                   // nil 表示不走 EGL（OSMesa 系）
- (A2RendererBridgeKind)bridgeKind;        // GL / OSMesa / Vulkan
@end
```

### 4.2 一次性产出不可变计划

```objc
@interface A2RendererPlan : NSObject   // 不可变
@property (nonatomic, copy, readonly) NSString *rendererId;
@property (nonatomic, copy, readonly) NSString *mainLibrary;
@property (nonatomic, copy, readonly) NSString *lwjglBareName;   // 剥好前缀后缀
@property (nonatomic, copy, readonly) NSString *eglSource;
@property (nonatomic, assign, readonly) A2RendererBridgeKind bridgeKind;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, copy, readonly) NSArray<NSString *> *dlopenLibraries;
@property (nonatomic, copy, readonly) NSArray<NSString *> *warnings;  // 回落原因等
@end

// 唯一入口。JavaLauncher 和 egl_bridge 都只调它，不再自己判断。
+ (A2RendererPlan *)planForRenderer:(NSString *)rendererID
                          mcVersion:(NSString *)mcVersion
                            current:(NSString *)currentEnvValue;
```

### 4.3 迁移规则

- 现有 `A2Settings.renderer` 的值（`libxxx.dylib` 形式）当作 `uniqueIdentifier` 继续可读。
- `A2RendererPlan.warnings` 记录所有回落/降级，UI 与日志都从这里取，不再各打各的。

---

## 5. TODO

### 第 1 期：止血（不重构，先把确定的坑填了）

- [ ] **T1** 启动前把 `A2Settings.renderer` 写进 `AMETHYST_RENDERER`
      - 位置：`main.m` 或 `A2SceneDelegate` 早期
      - 验收：`shader_cap_probe.m:568` 的 `[SHADER-CAP] renderer=` 不再是 `<unset>`
- [ ] **T2** 统一 `auto` 语义（先按 ANGLE，与现有注释对齐）
      - 改 `egl_bridge.m:285`，删掉 `auto → gl4es` 分支
      - 验收：两处都解析成 ANGLE，且 egl_bridge 不再依赖 JavaLauncher 先跑
- [ ] **T3** 修 `br_init` 返回值语义，加一次性失败标志
      - `gl_bridge.m:1663` 改成 0=成功；`egl_bridge.m:415,517` 去掉 `!`
      - 验收：初始化失败后不再无限重试
- [ ] **T4** 补 `br_init_context` / `gl_terminate` 的 NULL 守卫
- [ ] **T5** 删掉 `egl_bridge.m:405-414` 重复的 NULL 检查，Vulkan 分支并入公共尾
- [ ] **T6** context 失败分支先 `destroySurface` 再返回
- [ ] **T7** EGL 符号完整性改成全字段遍历判空

### 第 2 期：收敛决策（核心重构）

- [ ] **T8** 加 `A2RendererBackend` 协议 + `A2RendererPlan`
- [ ] **T9** 把 12 支渲染器的参数从 `egl_bridge.m:277-519` 搬进各自的 backend 实现
      - 每支一个类：`A2BackendANGLE` / `A2BackendMobileGlues` / `A2BackendLTW` / `A2BackendSFPEW` / `A2BackendGL4ES` / `A2BackendMobileGL` / `A2BackendOSMesa` / `A2BackendVirGL` / `A2BackendMoltenVK` / `A2BackendMithril`
- [ ] **T10** 把 `JavaLauncher.m:2130-2230` 的分支换成「读 plan，注入 -D」
- [ ] **T11** 把 `egl_bridge.m:277-519` 换成「读 plan，装桥表」
- [ ] **T12** `A2RendererRegistry` 接上 `prepareRendererForMCVersion`，让 MC 版本兼容性真正参与启动决策
- [ ] **T13** 加 `legacyRendererIds` 迁移表（对照 ZL2 `getLegacyRendererIds`）
- [ ] **T14** 删死代码：`A2Renderer` / `A2Renderers` / `br_setup_window` / `set_vk_bridge_tbl` / `ame_gap_renderer_selected`
- [ ] **T15** 统一 `MOBILEGL_BACKEND_TYPE` / `GALLIUM_DRIVER` / RTLD 预载的写入点（消掉 D-3~D-6）

### 第 3 期：桥表 ABI

- [ ] **T16** 桥表所有函数指针统一返回 `int`（0=成功），每项调用前判空
- [ ] **T17** `gl_terminate` 可重复调用，一次性清空 scratch FBO / tex / CFRelease layer
- [ ] **T18** realign 改成异步状态机，不再 `dispatch_sync(main)` 阻塞渲染线程
- [ ] **T19** `g_ame48_layer_cf` 改成本线程快照，消除 UAF
- [ ] **T20** `ame_es()` 改 `dispatch_once` + 失败可重试

### 第 4 期：清理

- [ ] **T21** 几何补偿链收敛：只保留 Task60 对齐 + Task48 只读取证，其余默认关闭
- [ ] **T22** 抽 `AMERenderGeometry` 单一计算函数，主线程唯一写入口
- [ ] **T23** 诊断日志分级：错误用 `os_log`，诊断走 `AMETHYST_GLDIAG=1` 开关
- [ ] **T24** 删 Task76/77 统计（或接上真实心跳消费者）

### 第 5 期：验证

- [ ] **T25** 12 支渲染器逐支跑通「启动到首帧」，记录每支的实际 GL/GLES 版本
- [ ] **T26** 设置页选每支渲染器 → 杀进程重启 → 确认 `[SHADER-CAP] renderer=` 与实际选择一致
- [ ] **T27** 写一份 `docs/RENDERER_MATRIX.md`：渲染器 × MC 版本 × 实测结果

---

## 6. 重写时不要照搬的东西

1. **几何补偿链**（Task41/48/49/50/52/53/55/57/58/60/75/76/77/78，占 `gl_bridge.m` 一半以上）
   大多是在修一个已定案的常量写反 bug（`gl_bridge.m:736-747`）。重写时默认关闭，只保留 Task60 对齐与 Task48 的只读取证。
2. **77 处 `NSLog`**（`gl_bridge.m`）—— 诊断信息淹没真正错误，而关键 init 失败反而用 `NSDebugLog`（`:1656,1660`）在 release 被吞。
3. **`assert` 做运行期校验**（`:1730-1731`）—— release 下被裁掉，Debug/Release 行为分叉。
4. **`__thread currentBundle` 隐含的单线程假设**（`bridge_tbl.h:67`）—— `pojavGetCurrentContext()` 在非渲染线程返回 NULL，这个坑有注释但没人挡。

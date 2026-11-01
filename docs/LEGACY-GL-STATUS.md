# 老版本 / 渲染路线 现状记录（2026-10-25）

> 用途：跨会话交接。所有结论都来自真机 lastlog 或真跑证据，不是推测。新结论请追加，不要覆盖。

---

## 1. MC 1.7.10 + KW（NG-GL4ES）逐轮结论

| 轮次 | 包 | 配置 | 结果 |
|---|---|---|---|
| 1 | 4b671c3 | ES3 上下文（默认） | SIGBUS `gl::GLES1State::loadMatrix(angle::Mat4 const&)+0x58`（ANGLE） |
| 2 | 22acc4d.es1 | ES1 上下文 | 不崩，但 GL 只报 `OpenGL ES 1.1.0`，无 FBO/无 shader ⇒ MC `Game crashed` |
| 3 | 22acc4d.es2 | ES2 上下文 | 不崩、上下文建成、过 `GL caps init`，之后卡住（无首帧） |
| 4 | 22acc4d.env | ES3 + `LIBGL_ES=3/LIBGL_GL=21` | 无效，仍 SIGBUS 同一处 |
| 5 | 216baa3 | 对齐老 Air：`LIBGL_NOINTOVLHACK=1`/`NORMALIZE=1`、config=ES3_BIT(0x40)、surface=NULL、顺序 surface→context→makeCurrent→setGetProcAddress→initialize_gl4es | **不崩了**，但停在 `LWJGLX: GL caps init` 之后（卡住） |
| 6 | 77a8db0 | 加 GL 入口 trace（glGetString/glGetStringi/glGetIntegerv/glGetError） | trace 正常：KW 初始化成功（`Target OpenGL 3.1 / Krypton Wrapper Release 0.4.5`），桥附着成功；到 `Reloading ResourceManager: Default` 时又崩在同一处 `GLES1State::loadMatrix` |
| 7 | 08dcfe7 | 解析器对 GLES1 入口返回 NULL（让 KW 走自带 FPE） | 真机日志**没有出现任何“拒绝”行** ⇒ KW 从未向宿主讨过这些入口；崩溃照旧 |

**当前判断（第 7 轮后）**：崩的那次 `glLoadMatrix` 调用不是从 KW 走的，而是**全局符号解析**直接命中了 ANGLE：
- `libGLESv2`（ANGLE）以 `RTLD_GLOBAL` 加载（`a2_gl_bridge.m:578`），其 GLES1 导出对全进程可见
- MC/LWJGL 侧 `dlsym(RTLD_DEFAULT, "glLoadMatrixf")` 于是拿到 ANGLE 的实现（未初始化 GLES1 状态）⇒ SIGBUS

**第 8 轮（进行中）**：`4844eca` —— KW 后端时把 ANGLE 的 EGL/GLESv2 改为 `RTLD_LOCAL`，只让 KW 全局可见。判据行：`[A2-GL-BRIDGE] 依赖加载旗标：RTLD_LOCAL（…）`。

### 已确认的旁证
- KW 二进制：`libnggl4es_kw.dylib`，md5 `3b3df2b2200ab26b9b6c1eda23a866ec`（3,915,776 B，arm64，1328 个 gl* 导出）
- 老 Air 的 KW 二进制 md5 不同（`4258a341…`），编译宏一致
- 老 Air 的关键配置差异见 `docs/OLDAIR-LEGACY-GL.md`（P0：config 位、P1：两个 LIBGL_*、P2：surface/顺序）
- 老 Air 从不设 `LIBGL_ES`（靠编译期 `-DDEFAULT_ES=3`）；LTW 在老 Air 里**未启用**

---

## 2. ≤1.12 的另一条路：SWFPE（SimpleFPEWrapper）

详见 `docs/SWFPE-EVAL.md`。要点：
- 它是「GLES3 之上模拟固定管线」的纯 FPE 层，**不自带、不接管 EGL**（只透传+观测）
- iOS 硬坑：`backend/loader.cpp` 在 `__APPLE__` 下 `return nullptr` ⇒ 整库 no-op；需约 60 行 shim 替换（上游零改动）
- 覆盖度：MC 1.7.10 引用 166 处、1.12.2 引用 170 处；固定管线专属入口 100% 实现；仅 2 类别名缺口（降级不崩）
- 工程量：G0（产物+loader shim+能加载）≈10 人时即可判定成立与否；全量 ≈34 人时；体积 strip 后 8–11MB
- 构建硬性：`-DBUILD_TESTING=OFF`（否则 CMake 会去执行 arm64 测试二进制）

---

## 3. 渲染宿主：EAGL（设计稿）

详见 `docs/EAGL-FRAMEWORK-DESIGN.md`。要点：
- EAGL 定位为**通用 GL 宿主**：只给上下文/可绘制面/入口解析，不含渲染器语义
- iOS 系统 GLES **停在 ES 3.0**，deprecated 但**仍可用、未宣布移除**
- 后端可行性：SWFPE ✅；MG ⚠️（ES3.0 可跑，但 compute/SSBO 缺失，1.18+ 特性会降级）；KW ⚠️（要让它只当语义层）；metallum ❌
- P0 顺序：P0-1 验 EAGLContext(api=3) 可用 → P0-2 假 EGL 十函数 → P0-3 接 SWFPE → P1 进主菜单

---

## 4. MC 1.20.1 原生 Metal（P0 spike 已完成）

报告：`D:\CTF\_510src\m1201-spike\P0-REPORT.md`。结论：**机制成立，真机一帧未取得（设备未连接 + JIT 需人工）**。

- 注入面极小：只替换 `com.mojang.blaze3d.systems.RenderSystem` 两个静态方法
  - `clear(int mask, boolean)`：`0x4100` 接管为 Metal 清屏+三角形+present；`0x4000`（离屏 FBO）放行
  - `flipFrame(long)`：直接 return（GL 不再上屏）
- 已证：ASM 注入在真实 client.jar 生效（`clear(0x4100)` 被接管、`clear(0x4000)` 仍抛原异常、`flipFrame` 被拦）；Metal 侧同一段 MSL 在 macOS 无头探针出图（清屏像素 + 三角形 37,626 px）
- 产物：`Air2-m1201-649d5ed.ipa`（198MB，md5 `e358e3798f6e235b104222f30e8ba39c`）
- 顺手修了真 bug：`A2LaunchSession.m:676-698` 现在会读 `version.isolation.jvmArgs`（此前 UI 可写、启动链从不读）
- P1 估算（单人）：标题页+GUI **3–5 周**；能玩 **12–16 周**（最大不确定项 GLSL→SPIR-V→MSL，2–3 周）
- 已固化为技能 `minecraft-jar-render-hook-agent`

---

## 5. 待办顺序（建议）

1. 验证 `4844eca`（RTLD_LOCAL）：1.7.10 是否不再崩、能否过 `GL caps init`
2. 若仍崩：抓 `hs_err` 里的调用栈上层（谁在调用 `glLoadMatrix`），或临时把 KW 的 `glLoadMatrixf` 做成"有调用就打印并 abort" 的探针
3. 若 1.7.10 通了：把 KW 定为 ≤1.12 默认，继续 1.12.2 / 1.13.2
4. 并行：SWFPE G0（10 人时）作为备选/替代；EAGL P0-1 探针
5. 1.20.1 原生 Metal 属长期项，等真机与 JIT 条件具备再排

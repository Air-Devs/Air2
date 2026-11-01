# 自研固定管线层（GL2）交接文档 —— 1.12.2 与 1.13–1.16

> 一句话：**老版本的固定管线不再依赖第三方包装（SFPEW/gl4es），由我们自己的 GL2 层用 JNI 抢占
> `org.lwjgl.opengl.GL11` 的 native 入口，翻译成 GLES3 交给 MobileGlues。**
> 日期：2026-11-01 ｜ 分支：`feat/plugin-merge`

---

## 1. 范围

| MC 版本 | 固定管线情况 | 我们的方案 |
|---|---|---|
| ≤ 1.12.2 | 全固定管线：`glBegin/glEnd` 立即模式、矩阵栈、客户端顶点数组 | 自研 GL2 层 |
| 1.13 – 1.16 | 兼容profile，仍有立即模式/矩阵栈/雾/光照/纹理环境 | 自研 GL2 层（同一套） |
| 1.17 + | 已是 OpenGL 3.2 core，无固定管线 | **不接管**（保持现状，已验证可跑） |

> **铁律：不得影响已经跑通的 1.17+。** GL2 只在 `mcMinor <= 16` 时启用（见 §5）。

## 2. LWJGL 档位矩阵（本轮实测确定）

| MC | LWJGL | 目录 | 依据 |
|---|---|---|---|
| ≤ 1.12.2 | 2.9.3 | `libs/lwjgl-2` | 1.12.2 启动提示需要 LWJGL2 API |
| 1.13 – 1.18 | 3.3.3 | `libs/lwjgl-333` | Pojav 打过补丁（`lwjgl-opengl.jar` 的 `GL.class` 含 Pojav 上下文处理），版本贴近 1.16.5 自身声明 |
| 1.19 – 1.20 | 3.3.1 | `libs/lwjgl-331` | 1.19.2 调 `STBIIOCallbacks.mallocStack(MemoryStack)`，3.4.x 已删该方法 |
| 1.21+ / 26.x | 3.4.1 / 3.4.3 | `libs/lwjgl-341` / `-343` | 新版本按 3.4.x 声明 |

判据：启动日志里 `[A2-LWJGL] 档位=…` 与实际 MC 版本一致。

## 3. 为什么 SFPEW 不能当「GL 库（libname）」

曾尝试：兼容层开启时把 `-Dorg.lwjgl.opengl.libname` 指向 `libSimpleFPEWrapper.dylib`，让 MC 的 GL 入口全从 SFPEW 取。
真机结果（lastlog-143 / 144 / 145，3.4.1 与 3.3.3 两个版本都试过）：

```
 [A2-GLBRIDGE] 加载模式=RTLD_LOCAL(隔离)     ← 加载没问题
 [A2-GLBRIDGE] GL 桥附着 rc=0                ← 上下文我们自己建出来了
 Description: Initializing game
 java.lang.IllegalStateException: There is no OpenGL context current in the current thread.
   at org.lwjgl.opengl.GL.createCapabilities(GL.java:385)
```

结论：**这不是 LWJGL 版本问题，而是 libname 语义问题。**
LWJGL 的 `createCapabilities` 要求「这个 GL 库能报告当前上下文」；SFPEW 是包装层，自己**不持有 EGL 上下文**，
所以恒报「没有当前上下文」。换 3.3.3 / 3.4.1 都一样。

⇒ 因此 **libname 一律指渲染器本体**（MG/KW/…），固定管线入口改由我们自己的 GL2 层在 Java 侧抢占。

## 4. 自研 GL2 层设计

### 4.1 为什么必须用 JNI 抢占

```
 MC 的 org.lwjgl.opengl.GL11.glBegin 是 public static native
 实现位于 liblwjgl_opengl.dylib（Java_org_lwjgl_opengl_GL11_glBegin）
 该 dylib 零外部导入、不链 libGLESv2、无 dlsym ⇒ 进程里没有可供 dyld 抢占的 _glBegin 符号
 ⇒ 唯一确定的口子是 JNI 绑定本身：RegisterNatives
```

### 4.2 链路（现成，已接）

```
 A2Entry.main()
   └─ A2Gl2Gl11Bind.bind(loader)                        ← Java 侧唯一落点
        └─ native install(GL11, GL11C)                  ← a2_gl2_jni_bind.m
             ├─ 逐条 GetStaticMethodID 校验签名（不匹配就跳过该条，不整批失败）
             └─ RegisterNatives → gl2_* 实现（a2_gl2_shim.m）
                  └─ 翻译成 GLES3 调用，经 MG 后端执行
```

### 4.3 覆盖范围

- `a2_gl2_shim.m` 已实现 **58 个入口**：立即模式（glBegin/glEnd/glVertex*/glColor*/glNormal*/glTexCoord*）、
  矩阵栈（glMatrixMode/glLoadIdentity/glPushMatrix/glPopMatrix/glMultMatrixf/glOrtho/glFrustum/glRotatef/glScalef/glTranslatef）、
  状态（glEnable/glDisable/glShadeModel/glAlphaFunc/glTexEnv*/glTexParameter*）、
  客户端数组（glVertexPointer/glColorPointer/glNormalPointer/glTexCoordPointer/glEnableClientState/glDrawArrays/glDrawElements）。
- `a2_gl2_jni_bind.m` 的登记表**正在从 7 条扩到全量 58 条**（签名逐条用 javap 从两套 jar 核对）。

### 4.4 开关与判据

```
 环境变量 A2_GL2_SHIM=1 启用（1.12 及更早由启动链自动设置；1.13–1.16 逐步放开）
 判据：[A2-GL2] Java 侧抢占完成：已注册 N 条固定管线入口
       [A2-GL2] 已登记 N 条 / 跳过 M 条（跳过的逐条打印名字+原因）
 关闭：不设该变量 ⇒ 行为与接入前逐字节一致
```

## 5. 启用策略（不动已跑通的版本）

```
 mcMinor <= 16  → 允许 A2_GL2_SHIM
 mcMinor >= 17  → 永不启用（core profile，不需要固定管线）
 1.13–1.16 先观察 1.12.2 的实测结果，再逐版本放开
```

## 6. 验证矩阵

| # | 场景 | 判据 |
|---|------|------|
| 1 | 1.12.2 | `[A2-GL2] 已注册 N 条`；进标题界面；方块/物品栏/文字可见 |
| 2 | 1.16.5 | 同上（LWJGL 3.3.3 路径） |
| 3 | 1.13.2 | 同上 |
| 4 | 1.20.1 | 不受影响（GL2 未启用），画面正常 |
| 5 | 1.17+ | 不受影响 |

## 7. 已知风险

```
 风险 A：签名表与 jar 不一致 ⇒ 该条注册失败（已设计成逐条跳过 + 打印，不整批失败）
 风险 B：shim 未覆盖的入口仍走原实现 ⇒ 会在 LWJGL Checks 处抛 NPE（现象同 lastlog-143）
         ⇒ 处理：按崩溃栈补对应入口，不猜测
 风险 C：客户端数组与 VBO 混用时的状态泄漏 ⇒ 每次绘制后恢复默认状态
 风险 D：1.13–1.16 的渲染路径比 1.12.2 更依赖着色器 ⇒ 部分效果（雾、光照）可能缺失，属可接受降级
```

## 8. 相关文件

```
 Natives/Renderer/a2_gl2_shim.m / .h        固定管线 → GLES3 翻译实现（58 入口）
 Natives/Renderer/a2_gl2_jni_bind.m / .h    RegisterNatives 登记与签名校验
 Natives/Renderer/a2_gl2_jni_probe.m / .h   探针（调用计数/状态采样）
 JavaApp/src/.../A2Gl2Gl11Bind.java         Java 侧唯一落点
 JavaApp/src/.../A2Entry.java               调用点（追加类路径后、派发主类前）
 Air2/Player/A2LaunchSession.m              libname 指渲染器本体；mcMinor<=16 时置 A2_GL2_SHIM
 Natives/Renderer/a2_gl_bridge.m            加载模式开关（RTLD_LOCAL 隔离）
```

# 宿主图形后端：统一开发接口 + 26.x 的 graphicsApi 开关

> 2026-10-31 立稿。两个待实施项：① 补 `AMETHYST_GRAPHICS_API`（26.x 选 GL 渲染器的前提）；② 统一开发接口 `A2GlHostBackend`（native_gles / metal_angle）。
> 本文只描述方案与判据，**未实施**。

---

## 一、根因（已查实）

现象（lastlog / lastlog.old，包 24f7565）：
```
 26.2 + libmobileglues（源: 实例设置）  → 崩溃 + 90 秒看门狗
 26.2 + libeagl.dylib（源: 实例设置）   → 不崩、无画面
 两次 JRE 都是 java-25（26.2 的正确选择）
```

证据链：
```
 老 Air tree510/Natives/JavaLauncher.m:1772-1799
   每次启动都 setenv("AMETHYST_GRAPHICS_API", graphicsApi, 1)
   取值 default / prefer_opengl / prefer_vulkan
   MC 26.2+ 据此写/清 options.txt 的 graphicsApi → 决定走 GL 路径还是 Vulkan/Metal 路径

 Air2 全仓 grep "AMETHYST_GRAPHICS_API" = 0 命中
 ⇒ 选 GL 渲染器时 26.2 仍按 default 走 Metal/Vulkan 路径
 ⇒ MG / EAGL 根本没被调用
```

结论：**26.2 不是不能用 MG，而是我们没告诉 MC「这次要走 GL」。**

---

## 二、方案 A：补 `AMETHYST_GRAPHICS_API` + `options.txt`

### A1 环境变量（每次启动都设，不留旧值）

| 渲染器类别 | 取值 |
|---|---|
| GL 类：`libmobileglues` / `libeagl` / `libnggl4es_kw` / `libgl4es_114` / `libnggl4es` / `libtinygl4angle` | `prefer_opengl` |
| `libmetallum` | `prefer_vulkan` |
| 其它 / 未知 | `default` |

判据行：`[A2-GRAPHICS-API] AMETHYST_GRAPHICS_API=%@（渲染器=%@，glClass=%d）`

### A2 直接改实例 `options.txt`（不依赖 Java 侧）

老 Air 是让 Java 端去写；我们直接写文件更稳，且与 Java 侧不冲突（写同一个值）。

```
 prefer_opengl  → 写入/替换 graphicsApi:prefer_opengl
 prefer_vulkan  → 写入/替换 graphicsApi:prefer_vulkan
 default        → 删除该行
```

约束：
- 文件不存在则创建；保留其它行与换行风格
- 首次修改前备份 `options.txt.bak`
- 失败只记日志，不阻断启动

判据行：`[A2-GRAPHICS-API] options.txt: %@（路径=%@）`（写入 / 删除 / 未变化 / 失败）

---

## 三、方案 B：统一开发接口 `A2GlHostBackend`

### B1 目的

现在「宿主 GL 实现」分散在 bridge 里按渲染器名字判断；要给所有渲染器（MG / KW / gl4es / ANGLE / 未来后端）一个**统一开关**，只在设置里选一次。

### B2 取值

| 值 | 含义 | 实现 |
|---|---|---|
| `native_gles` | 系统 GLES（EAGL） | 已有「假 EGL → EAGL」层（`a2_eagl_egl_engage`） |
| `metal_angle` | Metal ANGLE | 现有 ANGLE `libEGL` + `libGLESv2` 路径 |

默认 **`metal_angle`**（保持现状，零回归）。

### B3 唯一 API（禁止散落判断）

```objc
typedef NS_ENUM(NSInteger, A2GlHostBackend) {
    A2GlHostBackendNativeGLES,   // native_gles
    A2GlHostBackendMetalANGLE,   // metal_angle
};
A2GlHostBackend A2GlHostBackendCurrent(void);          // 唯一读点（读 NSUserDefaults 键 a2gl.hostBackend）
NSString       *A2GlHostBackendName(A2GlHostBackend);  // "native_gles" / "metal_angle"
const char     *A2GlHostBackendDylib(A2GlHostBackend); // native_gles → libeagl.dylib；metal_angle → libtinygl4angle.dylib
```

接入点：`Natives/Renderer/a2_gl_bridge.m` 里选择 EGL/GLES 实现的地方**改调上述 API**，不得另行判断。

### B4 设置项

位置：运行环境 › 渲染 › **宿主图形后端**
控件：复用现有 `A2SettingsRow` + 选项弹窗（不新造 UI），两项：
```
 系统 GLES（EAGL）
 Metal ANGLE
```

### B5 日志

```
 [A2-GL-HOST] 宿主图形后端=%@（%s）源=设置|默认
 [A2-GL-HOST] bridge: EGL 源=… GL 源=…
```

---

## 四、两者关系（容易混）

```
 AMETHYST_GRAPHICS_API  → 告诉【MC 26.2+】走 GL 还是 Vulkan/Metal 路径（决定 MG/EAGL 有没有机会被调用）
 A2GlHostBackend        → 决定【我们】用系统 GLES 还是 Metal ANGLE 去实现 GL
 两者正交：
   26.2 + MG + prefer_opengl + metal_angle ⇒ MC 走 GL → MG 翻译 → ANGLE
   26.2 + MG + prefer_opengl + native_gles ⇒ MC 走 GL → MG 翻译 → EAGL
   metallum 与本开关无关（直连 Metal）
```

---

## 五、实施顺序与判据

| 步 | 内容 | 判据 |
|---|---|---|
| 1 | 方案 A（graphicsApi + options.txt） | 26.2 选 MG 后，日志出现 `[A2-GRAPHICS-API]`，且 options.txt 被改写；游戏不再 90s 看门狗 |
| 2 | 方案 B（A2GlHostBackend + 设置项） | 切换后日志 `[A2-GL-HOST] 宿主图形后端=…` 与 bridge 实际用的 EGL 源一致 |
| 3 | 组合验证 | 26.2+MG：metal_angle / native_gles 两种都能进游戏或至少进到 GL caps init |

---

## 六、风险

| 风险 | 说明 | 处置 |
|---|---|---|
| options.txt 被游戏覆盖 | MC 退出时会重写 options.txt | 每次启动前都写，不依赖上次结果 |
| Java 侧与我们同时写 | 老 Air 是 Java 端写 | 值相同则无冲突；若发现冲突，以环境变量为准，Java 侧逻辑关闭 |
| native_gles 覆盖不到 3.1 特性 | EAGL 只有 ES3.0，MG 走降级路径 | 文档 EAGL-P2-PLAN 已列能力缺口 |
| 26.x + 非 metallum 的历史认知错误 | 之前以为「26.x 只能 metallum」 | 已纠正：26.x 可用 GL 渲染器，前提是 prefer_opengl |

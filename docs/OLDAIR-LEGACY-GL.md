# 老 Air 是怎么让 MC 1.7.10 跑起来的（KW / NG-GL4ES 全链路取证）

> 目的：把「老 Air 用 KW 能进 1.7.10」这件事拆成**可核对的文件:行 + 关键代码**，再逐条对到 Air2 现状，
> 得出**最小改动清单**。本文只读，不改任何代码。
>
> 取证基线：
> - **老 Air** = `D:/CTF/_510src/tree510` 的 git 提交 **`926629869`**（`fix(renderer): 恢复 Krypton Wrapper（NG-GL4ES）渲染器接入`）。
>   为什么不用工作树：工作树 HEAD（`d9f8cb471`）与磁盘上的 `tree510_prebaseswap_20261006` **都已经把 KW 整支删掉了**
>   （`Natives/utils.h:58`、`Natives/ctxbridges/gl4es_family_boot.m:118` 等处均只剩 `★ [DROP-NGG4ES]` 注释）。
>   本文所有「老 Air」行号均为 `git show 926629869:<path>` 下的行号；`Natives/ctxbridges/gl_bridge.m` 在 926 与 HEAD 内容一致，行号可直接对照。
> - **Air2** = `D:/CTF/_510src/Air2_all` 当前工作树。
> - **KW 源码** = `D:/CTF/_510src/baseswap_work/ThirdParty/NG-GL4ES`（与 `926629869` 的 `ThirdParty/NG-GL4ES` 同源）。

---

## 0. TL;DR（一句话链路 + 一句话结论）

**链路**：KW（`libnggl4es.dylib`）**不提供 EGL**，它只是一层 GL 1.x/2.x → GLES3 的转译器；EGL 上下文由宿主
`Natives/ctxbridges/gl_bridge.m` 用**捆绑的 ANGLE**（`libEGL.framework` + `libGLESv2.framework`）建，参数是写死的三件套：

```
EGL_RENDERABLE_TYPE   = EGL_OPENGL_ES3_BIT   (0x40)   ← gl_bridge.m@926:1697
eglBindAPI            = EGL_OPENGL_ES_API             ← gl_bridge.m@926:1729
EGL_CONTEXT_CLIENT_VERSION = 3                        ← gl_bridge.m@926:1876
```

KW 自己的档位是**编译期 `-DDEFAULT_ES=3`**（`ThirdParty/NG-GL4ES/CMakeLists.txt:135`），且老 Air **从不设 `LIBGL_ES`**
⇒ 运行时落回 `DEFAULT_ES`=3（`src/gl/init.c:214-224`）。宿主在 `eglMakeCurrent` **成功之后**才
`set_getprocaddress(resolver)` → `initialize_gl4es()`（`gl4es_family_boot.m@926:69-102`，调用点在 `egl_bridge.m@926:973`）。
固定管线（`glBegin` / `glMatrixMode` / `glLoadMatrixf` …）由 KW 自己实现并导出，宿主**没有任何 FPE shim**。

**结论**：老 Air 让 KW 跑通的关键不是某个隐藏开关，而是**一整套「ES3 config + ES3 上下文 + DEFAULT_ES=3 + makeCurrent 后显式 init」的一致口径**。
Air2 目前的 KW 路径在这套口径里**有一处硬偏离**：EGL config 的 `RENDERABLE_TYPE` 写成了 `EGL_OPENGL_ES2_BIT (0x0004)`，
而老 Air 是 `EGL_OPENGL_ES3_BIT (0x40)`——这是本文列出的 **P0** 改动。

---

## 1. 老 Air 的完整链路（渲染器 → EGL → surface → gl4es 模式）

### 1.1 渲染器身份、位置、怎么被选中

| 事实 | 证据 |
|---|---|
| dylib 名 = `libnggl4es.dylib`（无 `_kw` 后缀） | `Natives/utils.h@926:72` `#define RENDERER_NAME_NGGL4ES "libnggl4es.dylib"` |
| 家族谓词 | `Natives/utils.h@926:156-158` `isNGGL4ESRenderer()`；`162-164` `isGL4ESFamilyRenderer()` 收敛为 `VGPU‖GL4ESZL2‖NGGL4ES` |
| 一等用户可见渲染器（不是 debug 隐藏项） | `Natives/LauncherPreferences.m@926:447-449` `@{@"key": RENDERER_NAME_NGGL4ES, @"name": localize(@"preference.title.renderer.debug.nggl4es"), @"file": RENDERER_NAME_NGGL4ES}` |
| **无条件**随包构建（不受 `RENDERER_GAP_EXTRAS` 开关控制） | `Makefile@926:54-56` 注释 + `Makefile@926:1092` payload 依赖里直接挂 `dep_nggl4es` |
| 构建目标（cmake，链接 dep_mg 出来的 glslang 静态库 + SPIRV-Cross impl） | `Makefile@926:1263-1302`，产出 `$(WORKINGDIR)/libnggl4es.dylib`，随 payload 的 `cp *.dylib` 进 `<App>/Frameworks/` |
| 装载方式 | LWJGL 按 `-Dorg.lwjgl.opengl.libname` dlopen（见 1.5） |

> ⚠ 老 Air **没有**「按 MC 版本自动选渲染器」的逻辑。`AMETHYST_RENDERER` 直接取偏好 `video.renderer`
> （`Natives/LauncherPreferences.m@926:458`），没设默认值。KW 能进 1.7.10 的前提是**用户在设置里选了它**，
> 或者 profile 里存了它。

### 1.2 EGL 上下文怎么建（`Natives/ctxbridges/gl_bridge.m@926`）

`gl_bridge.m` 是**唯一的 EGL 提供者**（`egl_bridge.m` 只是 JNI 外壳 + 分发）。KW 走的是 gl4es 家族分支，
`egl_bridge.m@926:288-294`：

```objc
} else if (isGL4ESFamilyRenderer(renderer.UTF8String)) {
    // ★ [RENDERER-GAP] VGPU / GL4ESZL2 / NG-GL4ES：gl4es 家族。导出全套桌面 GL API，
    // 运行时经 ANGLE 框架解析 EGL/GLES 后端 —— 与既有 holy gl4es 完全同链路。
    NSLog(@"[egl_bridge] [RENDERER-GAP] gl4es-family renderer: %@ (ANGLE host EGL)", renderer);
    set_gl_bridge_tbl();
}
```

→ 也就是**没有任何 KW 专属 EGL 处理**：它和 `libgl4es_114` 走完全相同的 `gl_bridge`。

`gl_init_context()` 的建面序列（顺序很重要）：

| 步 | 动作 | 行号 | 关键值 |
|---|---|---|---|
| 1 | `eglGetDisplay(EGL_DEFAULT_DISPLAY)` | 1632 | — |
| 2 | `eglInitialize` | 1637 | — |
| 3 | `eglChooseConfig` | 1690-1703 | 见下方 attribs |
| 4 | `eglBindAPI` | 1723-1730 | `desktopGL ? EGL_OPENGL_API : EGL_OPENGL_ES_API`；KW 命中 **ES** |
| 5 | 主线程对齐 layer（`drawableSize = bounds × scale`） | 1777-1826 | Task60 原生 scale |
| 6 | **`eglCreateWindowSurface`** | **1838** | gl4es 家族传 **`NULL` attribs** |
| 7 | **`eglCreateContext`** | **1875-1890** | `EGL_CONTEXT_CLIENT_VERSION, 3` |
| 8 | `eglMakeCurrent` | 1909 | — |
| 9 | `eglSwapInterval(0)`（按需） | 1945+ | — |
| 10 | `pojavMakeCurrent` 尾部 → `ame_gap_gl4es_family_boot()` | `egl_bridge.m@926:973` | 见 1.4 |

关键的 config 属性（`gl_bridge.m@926:1690-1699`）：

```c
const EGLint attribs[] = {
    EGL_RED_SIZE, 8,
    EGL_GREEN_SIZE, 8,
    EGL_BLUE_SIZE, 8,
    EGL_ALPHA_SIZE, 8,
    EGL_DEPTH_SIZE, 24,
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
    EGL_RENDERABLE_TYPE, desktopGL ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,   // ★ KW 走 0x40 ★
    EGL_NONE
};
```

`desktopGL` 的判定（`gl_bridge.m@926:1662-1664`）——KW 明确**不在** desktop 名单里：

```c
// ANGLE / Mithril / MobileGL 导出的都是 desktop OpenGL，走 EGL_OPENGL_BIT +
// eglBindAPI(EGL_OPENGL_API)；其余（gl4es / MobileGlues / LTW）是 OpenGL ES。
BOOL desktopGL = isDesktopGLRenderer(apiRenderer);   // utils.h:140-143：不含 gl4es 家族
```

上下文创建（`gl_bridge.m@926:1875-1890`）：

```c
const EGLint gles_ctx_attribs[] = {
    EGL_CONTEXT_CLIENT_VERSION, 3,      // ★ 写死 3，不按 MC 版本分档 ★
    EGL_NONE
};
...
bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config,
        share ? share->context : EGL_NO_CONTEXT,
        mobileGL ? desktop_ctx_attribs : gles_ctx_attribs);
```

surface 创建（`gl_bridge.m@926:1828-1841`）：

```c
// MobileGL 的 eglCreateWindowSurface 不会从 CALayer 推断尺寸，必须显式给出宽高；
// 其余渲染器从 layer 自行推断，传 NULL。
const EGLint mobileGLSurfaceAttribs[] = { EGL_WIDTH, ..., EGL_HEIGHT, ..., EGL_NONE };
bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config,
        (__bridge EGLNativeWindowType)layer, mobileGL ? mobileGLSurfaceAttribs : NULL);
```

> **结论**：老 Air 对 1.7.10 与 1.20 一视同仁地建 **ES3** 上下文；它**不做**「老版本给 ES2 / ES1」的版本分档。
> `EGL_OPENGL_ES3_BIT = 0x00000040`（`Natives/external/mesa/EGL/egl.h:301` 等头文件同值）。

### 1.3 gl4es 家族的运行时模式（KW 的 `DEFAULT_ES` / `LIBGL_*`）

**编译期**（`ThirdParty/NG-GL4ES/CMakeLists.txt:135`，老 Air `dep_nggl4es` 就用这条 CMake 树）：

```cmake
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fPIC -fvisibility=hidden -DNO_GBM -DDEFAULT_ES=3 -DNOX11 -DNOEGL -DNO_INIT_CONSTRUCTOR")
```

四个宏各自的语义（同文件 37-83 行的长注释 + 源码）：

| 宏 | 含义 | 对宿主的要求 |
|---|---|---|
| `DEFAULT_ES=3` | `LIBGL_ES` 未设/非法时用 ES3 后端 | 宿主必须给 **ES3** 上下文 |
| `NOEGL` | 删掉「临时 EGL 探测上下文」路径，硬件探测跑在**当前宿主上下文**上 | 宿主必须 `set_getprocaddress()` 交解析器，否则一个 GLES 入口都摸不到 |
| `NO_INIT_CONSTRUCTOR` | 构造器不跑 | 宿主必须**在真上下文 current 之后**显式 `initialize_gl4es()`（漏了不崩但黑屏） |
| `NOX11` / `NO_GBM` | 无 X11 / 无 DRI | — |

**运行期档位解析**（`ThirdParty/NG-GL4ES/src/gl/init.c:214-224`）：

```c
globals4es.es = ReturnEnvVarInt("LIBGL_ES");
switch (globals4es.es) {
case 1: case 2: case 3: break;
default:
    globals4es.es = DEFAULT_ES;      // ← 老 Air 走这里 ⇒ 3
    break;
}
```

```c
// init.c:228（__APPLE__ 分支，写死，不做运行时探测）
globals4es.esversion = 300;
// init.c:242-268
globals4es.gl = ReturnEnvVarInt("LIBGL_GL");
... default: globals4es.gl = (globals4es.es == 1) ? 15 : 31;   // ← es=3 ⇒ gl=31
```

```c
// init.c:95（initialize_ng_gl4es 里）
globals4es.enableANGLE = false;   // 不自己 dlopen libEGL_angle.so：EGL 归宿主
```

**环境变量**——老 Air 只设了这两个，**没有** `LIBGL_ES` / `LIBGL_GL` / `LIBGL_NOERROR`：

```objc
// Natives/JavaLauncher.m@926:469
setenv("LIBGL_NOINTOVLHACK", "1", 1);   // Disable overloaded functions hack
// Natives/JavaLauncher.m@926:472
setenv("LIBGL_NORMALIZE", "1", 1);      // Fix white color on banner and sheep (GL4ES 1.1.5+)
// Natives/JavaLauncher.m@926:602（被注释掉，未生效）
//setenv("LIBGL_MIPMAP", "3", 1);
```

另设 KW 专属的一个（只影响 config.json 查找，不影响渲染档位）：

```objc
// Natives/JavaLauncher.m@926:1538-1547
if ([renderer isEqualToString:@ RENDERER_NAME_NGGL4ES]) {
    const char *ngg_home = getenv("POJAV_HOME");
    if (ngg_home && *ngg_home) {
        char ngg_path[1024];
        snprintf(ngg_path, sizeof(ngg_path), "%s/ngg", ngg_home);
        setenv("NGG_DIR_PATH", ngg_path, 1);
    }
}
```

对应源码 `src/gl/init.c:113-117`：

```c
NGGDirectory = (char*)GetEnvVar("NGG_DIR_PATH");
if (!NGGDirectory || strlen(NGGDirectory) == 0) {
    NGGDirectory = malloc(strlen(DEFAULT_NGG_DIRECTORY_PATH) + 1);
    strcpy(NGGDirectory, DEFAULT_NGG_DIRECTORY_PATH);   // 上游 Android 口径：/sdcard/NGG
}
```

> `config_refresh()` 对缺失文件静默返回 ⇒ 不设也不崩，只是高级用户没法放 `config.json` 调参。

### 1.4 解析器注入 + `initialize_gl4es()` 的时机与参数

全文只有一处，`Natives/ctxbridges/gl4es_family_boot.m@926:69-102`：

```objc
static void ame_gap_gl4es_family_init(const char *dylib) {
    void *h = dlopen(dylib, RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL);   // ① 已加载 ⇒ 提为全局
    if (h == NULL) { NSLog(@"... initialize_gl4es NOT called"); return; }
    ame_gap_load_bundled_angle_egl();                                // ② dlopen ANGLE 的 libGLESv2 + libEGL，取 egpa
    int resolver = 0;
    if (ame_gap_gl4esEgpa != NULL) {
        void (*sgpa)(void *(*)(const char *)) = (void(*)(void*(*)(const char*)))dlsym(h, "set_getprocaddress");
        if (sgpa != NULL) { sgpa(ame_gap_gl4esProcResolver); resolver = 1; }   // ③ 注入解析器
    }
    // ④ 门：必须本线程已有 current 上下文
    if (ame_gap_gl4esEgl != NULL) {
        void *(*getCurCtx)(void) = dlsym(ame_gap_gl4esEgl, "eglGetCurrentContext");
        if (getCurCtx != NULL && getCurCtx() == NULL) {
            NSLog(@"[RENDERER-GAP] %s boot deferred -- no current EGL context on this thread", dylib);
            return;
        }
    }
    void (*init)(void) = dlsym(h, "initialize_gl4es");
    if (init == NULL) { ... return; }
    init();                                                          // ⑤ 无参数，无返回值
}
```

解析器本体（同文件 36-53 行），顺序是 **`eglGetProcAddress` 优先**，再回落 `dlsym(libGLESv2)`：

```objc
static void *ame_gap_gl4esProcResolver(const char *name) {
    if (name == NULL) return NULL;
    if (strncmp(name, "gl", 2) == 0) {
        if (ame_gap_gl4esEgpa != NULL) { void *p = ame_gap_gl4esEgpa(name); if (p) return p; }
        if (ame_gap_gl4esGles2 != NULL) { void *p = dlsym(ame_gap_gl4esGles2, name); if (p) return p; }
    }
    if (strncmp(name, "egl", 3) == 0 && ame_gap_gl4esEgl != NULL) { ... }
    return NULL;
}
```

ANGLE 句柄的取得（同文件 55-64 行），旗标是 `RTLD_NOW | RTLD_LOCAL`：

```objc
ame_gap_gl4esGles2 = dlopen("@executable_path/Frameworks/libGLESv2.framework/libGLESv2", RTLD_NOW | RTLD_LOCAL);
ame_gap_gl4esEgl   = dlopen("@executable_path/Frameworks/libEGL.framework/libEGL",           RTLD_NOW | RTLD_LOCAL);
ame_gap_gl4esEgpa  = dlsym(ame_gap_gl4esEgl, "eglGetProcAddress");
```

调用点（`Natives/egl_bridge.m@926:960-973`）严格在 **`br_make_current(window)` 之后**：

```objc
void pojavMakeCurrent(basic_render_window_t* window) {
    ...
    br_make_current(window);          // ← 真上下文在这里 current
    ame_gap_gl4es_family_boot();      // ← 之后才 set_getprocaddress + initialize_gl4es
}
```

**顺序契约**：`dlopen` →（`eglInitialize`/`eglChooseConfig`/`eglCreateContext`/`eglMakeCurrent` 由宿主完成）→
`set_getprocaddress(resolver)` → `initialize_gl4es()`。老 Air 把前两步都放在 makeCurrent **之后**，且 `initialize_gl4es`
**无参数、无返回值**（`include/gl4esinit.h:10`）。

### 1.5 `org.lwjgl.opengl.libname` 给的是什么

```objc
// Natives/JavaLauncher.m@926:2038-2039
NSString *openglLibBareName = lwjglBareLibName(openglLibName);
PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.opengl.libname=%s", openglLibBareName.UTF8String);
```

```objc
// Natives/JavaLauncher.m@926:1199-1210
static NSString *lwjglBareLibName(const char *fileName) {
    ...
    if (name.length > 9 && [name hasPrefix:@"lib"] && [name hasSuffix:@".dylib"])
        return [name substringWithRange:NSMakeRange(3, name.length - 9)];   // 去 lib 前缀 / .dylib 后缀
    return name;
}
```

⇒ KW 得到的值是 **`nggl4es`**。含义：LWJGL 自己负责 `dlopen("libnggl4es.dylib")`；
宿主 `gl_bridge.m` 只负责 EGL，**不替 LWJGL 装载 GL 实现**（这也解释了为什么 KW 必须导出全套 `gl*` 而不是只导出部分）。

> 顺带一个坑（老 Air 已踩过、注释在 `egl_bridge.m:117-155` / `JavaLauncher.m:2205-2228`）：裸名一定不匹配 LWJGL 的
> `DYLIB` 正则，于是统一走 `System.mapLibraryName` 补回 `lib…dylib`；直接传完整文件名反而会给
> `libMobileGL-gles.dylib` 这种带连字符的名字补成 `liblib…dylib.dylib`。

### 1.6 固定管线（GLES1 / GL 1.x immediate mode）有没有特殊处理？

**没有宿主侧 shim。** 固定管线由 KW 自身实现并导出：

- `src/gl/gl4es.c:297` `void APIENTRY_GL4ES gl4es_glBegin(GLenum mode)`，配合 `AliasExport(...)` 宏导出裸名 `glBegin`
- `src/gl/fpe.c:938` `void APIENTRY_GL4ES fpe_glMatrixMode(GLenum mode)`（FPE = fixed pipeline emulation，走 shader 模拟）
- `src/gl/directstate.c:64` `mat(glLoadMatrixf(m));`
- `src/gl/eval.c:142` `p_map(d, vertex3, glVertex3f, code);`
- `src/gl/gl4es.c:416-425` `gl4es_glVertex3fv` + `AliasExport(void, glVertex3fv, , (GLfloat * v))`

**二进制层面核对**（对 dylib 做字节扫描，确认导出名确实在）：

| 符号 | 老 Air 构建的 `libnggl4es.dylib`（Oct 7 产物） | Air2 的 `libnggl4es_kw.dylib` |
|---|---|---|
| `glBegin` / `glEnd` | ✅ | ✅ |
| `glMatrixMode` / `glLoadIdentity` / `glLoadMatrixf` | ✅ | ✅ |
| `glOrtho` / `glVertex3f` / `glTexCoord2f` | ✅ | ✅ |
| `glPushMatrix` / `glShadeModel` / `glAlphaFunc` | ✅ | ✅ |
| `glNewList` / `glCallList`（显示列表） | ✅ | ✅ |
| `initialize_gl4es` / `set_getprocaddress` | ✅ | ✅ |

⇒ **两支二进制在固定管线导出面上一致**，所以「Air2 缺 FPE 桥」这个假设不成立；问题不在固定管线入口。

### 1.7 LTW（`Natives/external/LTW/ltw`）在构建里到底有没有启用？

**有 cmake 目标，但没进包、也没进 Makefile 主流程 ⇒ 实际未启用。**

- CMake 目标存在：`Natives/CMakeLists.txt:198-247`（`LTW_DIR`、`LTW_INCLUDES`、`glsl_optimizer`、`add_library(ltw SHARED ...)`）
- **Makefile 里没有任何 `ltw` 相关目标**（`grep -n "ltw\|LTW" Makefile` 无输出）⇒ payload 不依赖它
- **`Natives/resources/Frameworks/` 里没有 `libltw.dylib`**（该目录只有 `libgl4es_114 / libEGL / libGLESv2 / libglslang* / …`）
- 因此设置页的 `renderer.debug.ltw` 候选会被 `availableRendererCandidates()` 的**存在性过滤**隐藏
  （`Natives/LauncherPreferences.m@926:484-497`）
- `egl_bridge.m@926:256-270` 里那段「LTW mode：先 `dlopen` ANGLE 再 `set_gl_bridge_tbl()`」是**留着但用不到**的分支

另外两个同类渲染器也没启用：`option(AME_RENDERER_GAP_VGPU ... OFF)`（`Natives/CMakeLists.txt:770`）、
`dep_virgl`（挂在 `RENDERER_GAP_PAYLOAD_DEPS := dep_gl4eszl2 dep_virgl`，`Makefile:56`，但仅 `RENDERER_GAP_EXTRAS=1` 时构建）。

### 1.8 「按版本切渲染器」的两处代码，在 1.7.10 + KW 这条路上**都是死路**（别照抄）

```objc
// Natives/JavaLauncher.m@926:1977-1986 —— auto 在 JVM 启动前就被换成 ANGLE
if (!strcmp(glLibName, "auto")) {
    glLibName = RENDERER_NAME_MTL_ANGLE;          // libtinygl4angle.dylib
    setenv("AMETHYST_RENDERER", glLibName, 1);
    NSLog(@"[JavaLauncher] Auto renderer resolved to %s (always ANGLE)", glLibName);
}
```

```objc
// Natives/egl_bridge.m@926:245-249 —— 只有字面量 "auto" 才会落到 gl4es；上面那步之后永远不成立
if (isAuto || [renderer isEqualToString:@ RENDERER_NAME_GL4ES]) {
    renderer = @ RENDERER_NAME_GL4ES;
    setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
```

```objc
// Natives/egl_bridge.m@926:473-485 —— GLFW 请求 major 1/2 时切 gl4es；同样因 "auto" 已被替换而不可达
}) && strcmp(getenv("AMETHYST_RENDERER"), "auto") == 0 && hint == GLFW_CONTEXT_VERSION_MAJOR) {
    switch (value) {
        case 1: case 2: setenv("AMETHYST_RENDERER", RENDERER_NAME_GL4ES, 1); ... break;
        default:        setenv("AMETHYST_RENDERER", RENDERER_NAME_MOBILEGLUES, 1); ... break;
    }
}
```

⇒ 老 Air 跑 1.7.10 时**既不会**被自动切成 `libgl4es_114`，**也不会**因为版本号去改上下文版本。
**「KW 是用户显式选的」+「上下文一律 ES3」** 才是真口径。

---

## 2. 与 Air2 现状的逐条差异表

> Air2 的 EGL 提供者已经不是 `gl_bridge.m`，而是自研的 `Natives/Renderer/a2_gl_bridge.m`（由
> `Air2/Bridge/A2LaunchRunner.m:151 / :317` 调 `a2_gl_bridge_attach`，并由 `Natives/OwnGlfw/a2_own_glfw_bridge.m:227`
> 与 `a2_glfw_overlay_bridge.m:604` 调 `a2_gl_bridge_make_current` 借给游戏线程）。所以对比是
> **老 `gl_bridge.m` ↔ Air2 `a2_gl_bridge.m`**。

| # | 维度 | 老 Air（926629869） | Air2 现状 | 判定 |
|---|---|---|---|---|
| 1 | **EGL config 的 `RENDERABLE_TYPE`** | `EGL_OPENGL_ES3_BIT` = **0x40**<br>`gl_bridge.m:1697` | `A2_EGL_OPENGL_ES2_BIT` = **0x0004**<br>`a2_gl_bridge.m:109`（定义）、`:568`（使用） | **★P0 硬偏离★**：ES3 上下文配 ES2-only config；ANGLE 对 ES3 client version 通常要求 config 声明 ES3 |
| 2 | 上下文 client version | `EGL_CONTEXT_CLIENT_VERSION, 3`（写死）<br>`gl_bridge.m:1876` | `wantVersion = 3`（`A2_KW_CONTEXT_MODE_DEFAULT 0`，`:47` → `:617`） | ✅ 默认等价；有 `A2KWContextMode` 三档覆盖（`:600-617`） |
| 3 | `eglBindAPI` | `EGL_OPENGL_ES_API`（KW 非 desktop）<br>`gl_bridge.m:1723-1730` | `A2_EGL_OPENGL_ES_API`，无条件<br>`a2_gl_bridge.m:563` | ✅ 一致 |
| 4 | **surface 属性** | gl4es 家族传 **`NULL`**<br>`gl_bridge.m:1838`（`mobileGL ? attrs : NULL`） | 先传 `EGL_WIDTH/EGL_HEIGHT`，失败再退 `NULL`<br>`a2_gl_bridge.m:646-657` | ⚠P2：多一次失败重试；ANGLE 对 window surface 的 `EGL_WIDTH/HEIGHT` 可能返回 `BAD_ATTRIBUTE`，日志会多一行「退到无属性重试」 |
| 5 | **建面顺序** | `display → initialize → config → bindAPI → layer → **surface** → **context** → makeCurrent` | `display → bindAPI → config → **context** → **surface** → makeCurrent` | ⚠P2：老 Air 是 **surface 先于 context**；Air2 反了 |
| 6 | config 其余属性 | `SURFACE_TYPE=WINDOW\|PBUFFER`、`RGBA8`、`DEPTH 24`（**无 STENCIL**）<br>`gl_bridge.m:1690-1698` | `SURFACE_TYPE=WINDOW`（无 PBUFFER）、`RGBA8`、`DEPTH 24`、**`STENCIL 8`**<br>`a2_gl_bridge.m:566-575` | P3：stencil 更宽松，一般无害 |
| 7 | `set_getprocaddress` 时机 | **makeCurrent 之后**、`initialize_gl4es` 之前<br>`gl4es_family_boot.m:79-83` | **`eglCreateContext` 之前**（dlopen 后立刻）<br>`a2_gl_bridge.m:505-519` | ✅ 等价（gl4es 只是存函数指针；真正的硬件探测在 init 里） |
| 8 | 解析器查找顺序 | `eglGetProcAddress` → `dlsym(libGLESv2)`；只解 `gl*`/`egl*` 前缀<br>`gl4es_family_boot.m:36-53` | `dlsym(GLESv2)` → `dlsym(libEGL)` → `eglGetProcAddress`；任意名字<br>`a2_gl_bridge.m:256-263` | ⚠P2：ANGLE 的非核心入口用 egpa 更稳；优先 `dlsym` 可能拿到 0 |
| 9 | `initialize_gl4es()` 调用点 | `pojavMakeCurrent` 尾部，`br_make_current` 成功后<br>`egl_bridge.m:973` | attach ⑥a，`eglMakeCurrent` 成功后<br>`a2_gl_bridge.m:682-698` | ✅ 一致（都有 `gKryptonInitedHandle` 幂等） |
| 10 | `LIBGL_ES` / `LIBGL_GL` | **从不设** ⇒ `DEFAULT_ES=3` / `gl=31`<br>（`JavaLauncher.m:469,472` 只有另两个变量） | 默认**不设**（`A2_KW_ENV_HINT_DEFAULT 0`，`:51`）；仅在编译期开时设 `LIBGL_ES=3 LIBGL_GL=21`（`:685-689`） | ✅ 默认等价（★D 包那组 hint 是**偏离**老 Air 的，注意别默认开★） |
| 11 | `LIBGL_NOINTOVLHACK` / `LIBGL_NORMALIZE` | `=1` / `=1`，**无条件全局设**<br>`JavaLauncher.m:469,472` | **完全没设**（全仓 grep 只有 `LIBGL_ES/GL` 两行） | **★P1 缺失★**：gl4es 家族的包装层与颜色归一化修正，KW 同样吃这两个开关 |
| 12 | `NGG_DIR_PATH` | 设成 `$POJAV_HOME/ngg`<br>`JavaLauncher.m:1538-1547` | **没设** ⇒ 落回 `DEFAULT_NGG_DIRECTORY_PATH`（Android 口径 `/sdcard/NGG`，iOS 必 `fopen` 失败） | P2：不崩，但 `config_refresh` 永远读不到配置 |
| 13 | `libname` | `nggl4es`（`libnggl4es.dylib` 去前后缀）<br>`JavaLauncher.m:2038` + `:1199-1210` | `nggl4es_kw`（`libnggl4es_kw.dylib` 去前后缀）<br>`A2LaunchSession.m:703-709` | ✅ 语义一致（各自对应自己的文件名） |
| 14 | 默认渲染器选择 | 无版本推导；用户选 / `auto`→ANGLE | `A2DefaultRendererForVersion()`：`1.x, minor<=12 ⇒ libnggl4es_kw.dylib`<br>`A2LaunchSession.m:83-91`，缺失时回退 `libgl4es_114`（`:309-321`） | ✅ Air2 更优（老 Air 的 auto 对 1.7.10 是**错的**） |
| 15 | **二进制来源** | `Makefile@926:1263-1302` cmake 构建 → `libnggl4es.dylib`<br>（磁盘上残留的老 Air 装机 payload `_p03chk/Payload/AngelAuraAmethyst.app/Frameworks/libnggl4es.dylib`，4,058,064 B，md5 `4258a341…`，内含 "NG-GL4ES" 字样） | 手写 clang 脚本 `build/ios/build_nggl4es.sh`（"Deliberately CMake-free"）+ iOS patch 集 10 文件 → `libnggl4es_kw.dylib`<br>（3,915,776 B，md5 `3b3df2b2…`，见 `docs/DEPENDENCIES.md:278`） | **★注意★：不是同一份二进制**。编译宏一致（`-DNO_GBM -DDEFAULT_ES=3 -DNOX11 -DNOEGL -DNO_INIT_CONSTRUCTOR`，`build_nggl4es.sh:53`），但 patch 集与链接方式不同 |
| 16 | dylib 装载者 | LWJGL（`opengl.libname`）；宿主只 `dlopen(RTLD_NOLOAD)` 取符号 | `a2_gl_bridge` 自己 `dlopen(RTLD_LAZY\|RTLD_GLOBAL)` 建面 + LWJGL 也按 libname 加载 | ✅ 各自自洽 |

### 2.1 一句话定位

老 Air 的 KW = **ES3 config + ES3 context + DEFAULT_ES=3 + 无 LIBGL_ES + makeCurrent 后 init + NULL surface attrs**。
Air2 的 KW = **ES2 config + ES3 context + DEFAULT_ES=3 + 无 LIBGL_ES + makeCurrent 后 init + 带尺寸 surface attrs + 缺两个 LIBGL 开关 + 缺 NGG_DIR_PATH**。
**唯一「硬」不一致是 #1（config 的 RENDERABLE_TYPE），其余是可解释的软差异。**

---

## 3. 可直接照搬的改动清单（按优先级，只列改动点，不写实现细节）

### P0 — 只改一处就能把口径对齐老 Air

**P0-1｜KW 的 EGL config 用 `EGL_OPENGL_ES3_BIT (0x40)`，不要 `ES2_BIT`**

- 位置：`Natives/Renderer/a2_gl_bridge.m:109`（常量表）+ `:566-576`（`cfgAttribs`）
- 做法：补 `#define A2_EGL_OPENGL_ES3_BIT 0x00000040`；在 `cfgAttribs` 里按 `a2_gl_bridge_is_krypton()` 选值：
  `A2_EGL_RENDERABLE_TYPE, isKrypton ? A2_EGL_OPENGL_ES3_BIT : A2_EGL_OPENGL_ES2_BIT`
- 老 Air 依据：`gl_bridge.m@926:1697`
- 判据（真机 grep）：`A2-RENDERER] NG-GL4ES 上下文就绪：请求 client version=ES3 实得=ES3` —— **`实得` 必须是 ES3**；
  若出现「ES3 被拒 ⇒ 退 ES2 重试」说明 config 仍不认 ES3。

### P1 — 补齐老 Air 无条件设置的运行时开关

**P1-1｜补 `LIBGL_NOINTOVLHACK=1` 与 `LIBGL_NORMALIZE=1`**（无条件，别只给 KW）

- 位置：Air2 的 native 环境初始化处（对应老 `JavaLauncher.m:469,472`；Air2 全仓无此二键）
- 语义：前者关掉 gl4es 的「重载函数 hook」路径（1.17+ 才需要关，老版本保持关也无害）；后者修 GL4ES 1.1.5+ 的
  banner/羊的白色偏差。KW 是 gl4es 血统，两个开关同样生效。
- 注意：**不要**顺手加 `LIBGL_ES` / `LIBGL_GL`——老 Air 从不设，`DEFAULT_ES=3` 已经是正确档位；
  Air2 的 `A2_KW_ENV_HINT_DEFAULT`（`a2_gl_bridge.m:51`）保持 `0`。

**P1-2｜`NGG_DIR_PATH` 指向可写目录**

- 位置：`a2_gl_bridge.m` 的 KW 分支（`initialize_gl4es` 之前，紧邻 `:682-689`）
- 值：`<App>/Documents/ngg` 或 `NSTemporaryDirectory()/ngg`（老 Air 用 `$POJAV_HOME/ngg`）
- 理由：`src/gl/init.c:113-117` 的兜底是 Android 的 `/sdcard/NGG`；缺目录不崩但 `config_refresh()` 永远空转。

### P2 — 贴近已验证路径（有收益，但优先级低于 P0/P1）

**P2-1｜KW 的 window surface 先按 `NULL` attribs 建**（`a2_gl_bridge.m:646-657`）
老 Air 对 gl4es 家族就是 `NULL`（`gl_bridge.m:1838`）；Air2 先传 `EGL_WIDTH/HEIGHT` 只是多一次可能的失败重试。

**P2-2｜解析器改成 `eglGetProcAddress` 优先**（`a2_gl_bridge.m:256-263`）
老 Air 口径：`egpa → dlsym(libGLESv2)`。ANGLE 的非核心入口（`glGenVertexArrays` 等）走 egpa 更可靠。

**P2-3｜surface 先于 context**（`a2_gl_bridge.m:620` vs `:651`）
严格对齐老 Air（`gl_bridge.m:1838` 在建 context 的 `:1875` 之前）。这条优先级最低——EGL 不要求此顺序，
但既然老 Air 是这条顺序且已被验证，排障时应先复刻。

### P3 — 可选

- config 加 `EGL_PBUFFER_BIT`（老 Air `1696`）；`STENCIL 8` 保留亦可。
- 若最终确认 `A2KWContextMode` / `A2KWUseES1` 两键都是死开关（`docs/LAUNCHCHAIN-DEADCODE.md:119-120` 已标），
  按仓库守则应清理，不要留着当「A/B 探针」。

### 不要照搬的三件事

1. **不要**把「context version major ≤ 2 ⇒ 切 gl4es」移植过来（`egl_bridge.m@926:473-485`）：老 Air 里它因 `auto`
   早被替换而不可达，是 upstream 遗留死代码。
2. **不要**给 KW 建 ES1/ES2 上下文。KW 是 `DEFAULT_ES=3` 编的，ES2/ES1 是它**没测过的第三态**（Air2 自己的注释
   `a2_gl_bridge.m:598-599` 已记录真机史：ES3→崩、ES1→MC 拒启）。
3. **不要**加固定管线 shim。KW 自身导出全套 FPE 入口（§1.6 的二进制核对），宿主加 shim 只会掩盖真问题。

---

## 4. 无法确认的点（以及为什么）

| # | 无法确认的结论 | 为什么无法确认 | 怎么才能确认 |
|---|---|---|---|
| 1 | 老 Air 真机上 KW + 1.7.10 **确实启动成功**的日志 | 仓库内没有任何该组合的 `latestlog`；`grep -rn "nggl4es\|NG-GL4ES" tree510/ci-logs/` 无命中；老 Air 的 KW 代码只存在于 git 提交里（工作树已删），没有配套的设备日志 | 需要老 Air 装机包的一份 `latestlog.txt`，grep `[RENDERER-GAP] … initialize_gl4es() called post-MakeCurrent` 与 `EGL 就绪` |
| 2 | ANGLE 是否**严格**拒绝「ES2 config + client version 3」 | 无 iOS 设备/无法在本机跑 arm64 dylib；Air2 代码自带「被拒 ⇒ 换版本重试」的回退（`a2_gl_bridge.m:621-631`），会把该差异**掩盖**成「上下文就绪但版本不对」 | 真机日志看 `[A2-RENDERER] NG-GL4ES 上下文就绪：请求… 实得…`；`实得≠请求` 即命中 |
| 3 | Air2 的 `libnggl4es_kw.dylib`（md5 `3b3df2b2…`）与老 Air 的 CMake 产物（md5 `4258a341…`）**行为是否等价** | 两者构建方式不同（手写 clang vs cmake）、patch 集不同（10 文件 iOS patch vs 上游树）、且本机无法执行 arm64 Mach-O | 两台设备各跑一次同一版本 + 同一份 minimal 日志，比对 `GL_VERSION`/`GL_EXTENSIONS`/`initialize_gl4es` 后首帧 |
| 4 | 1.7.10 在 Air 家族里到底走 **LWJGL2 还是 LWJGL3 的建面路径** | `tree510` 只有 `lwjgl-lib/3.3.3-lwgjl` 与 `3.4.1-lwgjl`，无 lwjgl2 原生桥；而 1.7.10 是 LWJGL 2.9.1（`docs/MC-VERSION-BOUNDARIES.md:31`）⇒ 中间必有一层 LWJGL2→3 兼容，但该兼容层不在本树、本次未深挖 | 看 `docs/LEGACY.md:25` 的 `requiresLWJGL2Compat` 实现在 Air2 侧从哪来，再确认 `org.lwjgl.opengl.Display` 是否映射到同一 `gl_init_context` |
| 5 | KW 在 1.7.10 下报的 `GL_VERSION` 字符串 | `globals4es.esversion=300`（`init.c:228`，`__APPLE__` 写死）与 `globals4es.gl=31`（`init.c:266`）的组合如何拼成版本串，取决于 `glGetString` 的实现分支，本次未逐行追 | 真机 `glxinfo` 式打印或 Air2 的 `GL.createCapabilities` 日志 |
| 6 | 老 Air 的 `auto` 默认 + 1.7.10 是否本来就走不通 | 逻辑上 `auto → libtinygl4angle`（`JavaLauncher.m@926:1984`），ANGLE 是 ES 语义、无固定管线 ⇒ 1.7.10 应该起不来；但**没有实测**记录 | 老 Air 装 1.7.10、渲染器留 `(default)` 跑一次 |

---

## 附：本文引用行号速查

| 文件 | 行 | 内容 |
|---|---|---|
| `Natives/utils.h@926` | 72 | `RENDERER_NAME_NGGL4ES "libnggl4es.dylib"` |
| `Natives/utils.h@926` | 156-164 | `isNGGL4ESRenderer` / `isGL4ESFamilyRenderer` |
| `Natives/LauncherPreferences.m@926` | 447-449 | KW 候选表项 |
| `Natives/egl_bridge.m@926` | 288-294 | gl4es 家族 → `set_gl_bridge_tbl()`（无 KW 专属处理） |
| `Natives/egl_bridge.m@926` | 960-973 | `pojavMakeCurrent` → `ame_gap_gl4es_family_boot()` |
| `Natives/ctxbridges/gl_bridge.m@926` | 1662-1664 | `desktopGL` 判定（KW = ES） |
| `Natives/ctxbridges/gl_bridge.m@926` | 1690-1703 | config attribs，`RENDERABLE_TYPE = EGL_OPENGL_ES3_BIT` |
| `Natives/ctxbridges/gl_bridge.m@926` | 1723-1730 | `eglBindAPI(EGL_OPENGL_ES_API)` |
| `Natives/ctxbridges/gl_bridge.m@926` | 1838 | `eglCreateWindowSurface(..., NULL)` |
| `Natives/ctxbridges/gl_bridge.m@926` | 1875-1890 | `EGL_CONTEXT_CLIENT_VERSION, 3` |
| `Natives/ctxbridges/gl_bridge.m@926` | 1909 | `eglMakeCurrent` |
| `Natives/ctxbridges/gl4es_family_boot.m@926` | 69-102 | `set_getprocaddress` + `initialize_gl4es`（makeCurrent 之后） |
| `Natives/ctxbridges/gl4es_family_boot.m@926` | 119-124 | `RENDERER_NAME_NGGL4ES` 引导分支 |
| `Natives/JavaLauncher.m@926` | 469 / 472 | `LIBGL_NOINTOVLHACK=1` / `LIBGL_NORMALIZE=1` |
| `Natives/JavaLauncher.m@926` | 1538-1547 | `NGG_DIR_PATH` |
| `Natives/JavaLauncher.m@926` | 1977-1986 | `auto → libtinygl4angle`（使 1.8 的两处版本切换变死路） |
| `Natives/JavaLauncher.m@926` | 2038-2039 / 1199-1210 | `-Dorg.lwjgl.opengl.libname` + 裸名转换 |
| `Makefile@926` | 54-56 / 1092 / 1263-1302 | KW 无条件随包 + `dep_nggl4es` 构建 |
| `ThirdParty/NG-GL4ES/CMakeLists.txt` | 135 | `-DDEFAULT_ES=3 -DNOX11 -DNOEGL -DNO_INIT_CONSTRUCTOR` |
| `ThirdParty/NG-GL4ES/src/gl/init.c` | 95 / 113-117 / 214-224 / 228 / 242-268 | `enableANGLE=false` / `NGG_DIR_PATH` / ES 档位 / `esversion=300` / GL 档位 |
| `ThirdParty/NG-GL4ES/src/gl/gl4es.c` | 297 / 416-425 | `gl4es_glBegin` / `glVertex3fv` + `AliasExport` |
| `ThirdParty/NG-GL4ES/src/gl/fpe.c` | 938 | `fpe_glMatrixMode` |
| `Natives/CMakeLists.txt`（老 Air） | 198-247 / 770 | LTW 目标存在 / VGPU 默认 OFF |
| **Air2** `Natives/Renderer/a2_gl_bridge.m` | 47 / 51 | `A2_KW_CONTEXT_MODE_DEFAULT=0`（ES3）/ `A2_KW_ENV_HINT_DEFAULT=0` |
| | 109 / 568 | `A2_EGL_OPENGL_ES2_BIT` 定义 / 使用 ← **P0** |
| | 256-263 | 解析器顺序（`dlsym` 优先） |
| | 505-519 | `set_getprocaddress` 注入（建 context 之前） |
| | 566-576 | config attribs |
| | 617-640 | `wantVersion` + 失败回退 |
| | 646-657 | surface（先带尺寸，失败退 `NULL`） |
| | 682-698 | `initialize_gl4es`（makeCurrent 之后） |
| **Air2** `Air2/Player/A2LaunchSession.m` | 83-91 / 309-321 / 703-709 | ≤1.12 默认 KW / 缺失回退 gl4es / `libname=nggl4es_kw` |

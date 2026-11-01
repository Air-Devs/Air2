# SFPEW（SimpleFPEWrapper）交接文档

> 状态：**已接入代码、可编译；未上真机验证；未打包验证过 ≤1.16 实际画面。**
> 版本：2026-11-01，基于 Air2 `feat/eagl-default` 分支（提交 `bb49b1b`）。

---

## 1. 这是什么，为什么需要它

iOS 上只有 OpenGL ES / Metal，没有桌面 OpenGL。Minecraft 老版本（≤1.12 纯固定管线，1.13–1.16 固定管线 + 少量着色器）依赖 `glBegin/glVertex*/矩阵栈/光照/纹理环境` 这类**固定管线 API**，GLES 里根本不存在。

- **MobileGlues（MG）**：只做 GL→GLES 的**调用翻译**，不模拟固定管线。
- **gl4es / KW / NG-GL4ES**：**自带**固定管线模拟（这就是它们存在的意义）。
- **SimpleFPEWrapper（SFPEW）**：把固定管线状态翻译成生成的 GLSL 程序，再把结果交给后端 GLES。它**不创建上下文**，只接管 GL 符号解析与 `eglMakeCurrent`/`eglSwapBuffers`。

所以 SFPEW 的定位是**兼容层**，叠在"自身没有固定管线模拟"的渲染器上：

| 渲染器 | 能否叠 SFPEW | 原因 |
|---|---|---|
| MG（MobileGlues，core profile 路径） | 可以 | 自身无 FPE |
| metallum（26.x Metal） | 可以 | 自身无 FPE |
| gl4es / KW / libnggl4es_kw | **禁止** | 自带 FPE，叠了两层翻译互相打架 |
| 自研 GL2 层（≤1.12，本次另一条线） | **禁止** | 它本身就是 FPE |

> 这条判定目前**只写在文档里，代码尚未实现**（见第 7 节）。

---

## 2. 已交付的代码

### 2.1 原生库（LGPLv3，随包分发）

```
Libraries/Frameworks/sfpew/libSimpleFPEWrapper.dylib   6,564,488 B
  md5 fe84ab42240b3616d83bad1ef3dd03a8
  Mach-O arm64 / platform ios / sdk 26.2 / minos 14.0
  依赖：libc++、libSystem（无 X11/GL/GLX/EGL 外部依赖）
  导出：eglGetProcAddress ×1；gl* 包装 567 个；egl* 包装 46 个
Libraries/Frameworks/sfpew/COPYING
Libraries/Frameworks/sfpew/COPYING.LESSER
Libraries/Frameworks/sfpew/LICENSE
Libraries/Frameworks/sfpew/README.md（来源 commit、构建命令、踩坑记录）
Libraries/Frameworks/sfpew/build/tc-ios-sfpew.cmake（工具链）
Libraries/Frameworks/sfpew/build/patch_ios.py（对上游 CMakeLists 的三处幂等改动）
Libraries/Frameworks/sfpew/build/sfpew_ios_format_shim.cpp（to_chars 垫片）
```

来源：`MobileGL-Dev/SimpleFPEWrapper` main @ `5474e473018f07e9624a0805683ed3c3e32ee6a2`（2026-10-31），子模块 glm `e8642318`、glslang `cb30230f`、SPIRV-Cross `6c09849f`。

### 2.2 接入代码

```
Natives/Renderer/a2_sfpew_host.h    170 行
Natives/Renderer/a2_sfpew_host.m    266 行
Natives/Renderer/a2_gl_bridge.m     +约 60 行（仅在 gSfpewTier 为真时走新分支）
Natives/Renderer/a2_renderer.m      +6 行（SFPEW 本层不 dlopen，只做存在性校验）
Air2/Core/Renderer/A2RendererCatalog.{h,m}  新增 A2RendererSFPEWDylibName + 候选表 + 诊断只判文件
Air2/Player/A2LaunchSession.m       档位判定：major==1 && minor<=16 && 实例显式选 SFPEW
Air2/Player/A2RuntimeStrings.m      四语文案
```

### 2.3 关键实现点（改这块的人必须知道）

1. **加载**：`dlopen(.., RTLD_LAZY|RTLD_LOCAL)`，绝不 RTLD_GLOBAL —— 它会把 567 个 gl* 推进 flat namespace，污染整个进程。
2. **后端**：`setenv("SFPEW_EGL", <包内 ANGLE libEGL 路径>)`，SFPEW 内部靠这个找后端 EGL。全仓 setenv 只有一处（`a2_sfpew_host.m:206`）。
3. **入口**：从 SFPEW 句柄取 `eglGetProcAddress`、`eglMakeCurrent`、`eglSwapBuffers`；GL 符号一律经 SFPEW 的 resolver 取，不能混用系统解析的 `glBegin`（否则状态追踪断裂）。
4. **上下文仍由宿主建**：display/config/surface/context 走我们现有的 ANGLE EGL；SFPEW 不参与。
5. **隔离**：`gSfpewTier` 为全局开关，teardown 复位；未选中该档位时所有新代码不可达（`a2_gl_bridge.m:451/1410/2083/2254/2367/2443/2542/2566`）。
6. **打包必须显式带上**：现有 staging 只 glob `Libraries/Renderers/*.dylib` 与 `Libraries/Frameworks/lib*`，**`Frameworks/sfpew/` 子目录不会被自动带入**。打包脚本要加：
   ```
   cp Libraries/Frameworks/sfpew/libSimpleFPEWrapper.dylib  <app>/Frameworks/
   cp Libraries/Frameworks/sfpew/COPYING* <app>/Frameworks/   # LGPL 义务
   ```
   缺件时启动会打 `包内缺 Frameworks/libSimpleFPEWrapper.dylib` 并阻断。

---

## 3. 编译与验证（已做）

```
构建机：Ubuntu 192.168.3.172（/build/air2），clang-17 + iPhoneOS.sdk 26.2 + ld64.lld
cmake -S . -B build/cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios-linux.cmake -DiOS_SDK=/build/iossdk/iPhoneOS.sdk -DCMAKE_BUILD_TYPE=Release
cmake --build build/cmake -j8
结果：BUILD_RC=0，error 计数=0，二进制 5,253,560 B（arm64 Mach-O iOS）
llvm-nm 可见 a2_sfpew_host_* 全部符号
llvm-otool -L 无 SFPEW 依赖 ⇒ 纯 dlopen（LGPL 动态链接成立）
```

---

## 4. 真机验证步骤（尚未执行）

1. 打包（带 2.6 的两个 cp）。
2. 装 1.12.2 或 1.16.5 实例，渲染器选「SFPEW（固定管线 · ≤1.16）· 实验」。
3. 日志按序确认：
   ```
   [A2-SFPEW] 后端 EGL=…（SFPEW_EGL）
   [A2-SFPEW] 已加载 path=… 符号 gl=567 egl=46
   [A2-SFPEW] ★隔离档位启用★ MC 1.x
   [A2-GLBRIDGE] EGL 就绪
   ```
4. 反向验证：1.20.1 实例选 SFPEW ⇒ 应出现 `⛔ 档位不适用`；不选 SFPEW 启动 1.20.1/26.3 ⇒ 日志里不该出现任何 `[A2-SFPEW]` 行。

---

## 5. 已知风险（未验证，别当结论）

1. **假 EGL 抢符号**：主二进制导出了整套假 EGL（`a2_eagl_egl.m`，23 个 `egl*` 全局符号）。如果 SFPEW 内部用 `dlsym(RTLD_DEFAULT, "eglCreateContext")` 而不是自己 dlopen 的句柄，会先命中我们的假 EGL。
   → 真机若见 EGL 初始化失败，第一个看 `[A2-SFPEW] 后端 EGL=` 那行，再看这条。
2. **私有/惰性绑定**：SFPEW 的 makeCurrent/swap 接管是否覆盖 LWJGL 的惰性槽，需要真机日志才算证明。
3. **minOS 14 但 sdk 26.2 构建**：SFPEW 用了 `std::format`，我们打了 9 个 `to_chars` 垫片绕开 iOS 16.3 的可用性限制；低版本真机没验过。
4. **1.13–1.16 与 1.12 的差异**：1.13+ 混用 GLSL，SFPEW 有 shader 翻译路径但覆盖面未验证。

---

## 6. 与 ZalithLauncher2 的对照（参考实现）

ZL2 的 `feat/version_sfpew_settings` 分支做法：

```
SimpleFPEWrapper.kt（72 行）：
  getSfpewLibraryPath() = <native lib 目录>/libSimpleFPEWrapper.so
  isSfpewConfiguredFor(renderer, version)：
      renderer 是插件 → version.isSfpewPluginLayerEnabled()
      否则          → renderer.supportsSfpewByDefault()
  detectFpeEmulatorMods(mods)：mod id 命中 angelica / actinium ⇒ 禁用兼容层
  isSfpewEnabledFor = !存在FPE模拟模组 && isSfpewConfiguredFor(...)
renderer/config/ 五个文件：
  RendererConfigSpec（fixedEnv + switch/choice/number/text，target=Environment|JsonField）
  RendererConfigDsl（构建 spec 的 DSL）
  RendererConfigStore（按版本存）/ Session（编辑态）/ Resolver（启动时解析成 env）
  ConfigurableRenderer.getRendererEnv() = resolveRendererConfig(id, spec).environment
```

**注意：ZL2 也没有公开"实际接管 eglGetProcAddress"的代码**——那一层在它的 native/启动层，开源分支里看不到。

---

## 7. 未做 / 下一步

1. **打包脚本没加那两个 cp**（当前 ipa 里没有 SFPEW 的 dylib）。
2. **"禁止叠加"判定未实现**：目前只按版本（≤1.16）+ 用户选择，未检查渲染器是否自带 FPE（gl4es/KW/自研 GL2 必须排除）。
3. **FPE 模组检测未实现**（angelica / actinium）。
4. **开关形态未定**：现在是"独立渲染器档位"；按 ZL2 模型应改为"叠加在渲染器之上的开关"。用户已明确指示先别动，保持现状。
5. 真机一次都没跑过。

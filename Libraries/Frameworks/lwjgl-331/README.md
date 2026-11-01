# lwjgl-331 —— 供 MC 1.19.2 使用的 LWJGL 原生库（iOS / arm64）

## 为什么需要这份

MC 1.19.2 自带 LWJGL 3.3.1 的 **Java jar**。原生库必须与 Java jar 同一代，否则：

- 用 3.4.x 原生库 → `UnsatisfiedLinkError: org.lwjgl.system.ThreadLocalUtil.nsetupEnvData(int)`
  （3.4 系把这套 JNI 改名了，`GL.createCapabilities` 第一步就炸）
- 反过来只换 3.4.1 的 Java jar → `NoSuchMethodError: STBIIOCallbacks.mallocStack(MemoryStack)`
  （3.4 删了该方法，MC 1.19.2 仍在调）

所以 1.19.2 必须 **Java jar 3.3.1 + 原生库 3.3 系**。本目录是与 3.3.1 jar 配套的那套原生库。

## 来源

取自 `Air-5.0.0-metal-v381-clean.ipa` 的
`Payload/AngelAuraAmethyst.app/Frameworks/`（同内容也出现在 v429-slim / v466 / v467 等包里）。
不是本次从源码新编的产物，是先前的 iOS 构建，已 strip。

## 版本判定（不是猜的）

用 `llvm-objdump --macho --exports-trie` 取导出符号，与各版本 `lwjgl-*-natives-linux.jar`
里的官方 `.so` 做集合比对：

- `org.lwjgl.system.JNI` 的导出符号与 **3.3.3** 的 jar 声明**完全一致**（1605/1605，无多余），
  与 3.3.1 双向不一致（多 389 / 缺 398）。
- ⇒ 这套原生库是 **LWJGL 3.3.x（3.3.3 代）** 的 iOS 构建，`LC_BUILD_VERSION: platform ios, minos 14.0`。

## 与 3.3.1 Java jar 的匹配度（按 3.3.1 jar 实际引用 + 官方 .so 导出为准）

| 库 | 3.3.1 会调用且官方导出的 native | 本目录缺失 | 结论 |
|---|---|---|---|
| `liblwjgl_opengl.dylib` | 1530 | **0** | 完全匹配 |
| `liblwjgl_stb.dylib` | 203 | 11（全是 `STBImageResize.*`） | 原版 MC 不用该类，可用 |
| `liblwjgl.dylib` | 684 | 140 | 137 个是 `org.lwjgl.system.linux.*`（iOS 无关），真实缺口见下 |

`liblwjgl.dylib` 的真实缺口只有 3 个，且都在 MC 路径之外：

- `JNI.invokePP(JSZJ)J` —— 仅 `org.lwjgl.system.macosx.CoreGraphics` 自己引用
- `JNI.invokePPPPZ(JJJBJJ)Z` —— 仅 `org.lwjgl.system.macosx.ObjCRuntime` 自己引用
- `LibCStdio.sprintf()J` —— 仅 `LibCStdio` 同类内部引用

`STBImageResize` 的 11 个缺失是 3.3.x 后期改了该模块的 C 函数签名所致（3.3.3 用新名）。
若某 mod 真的调 `STBImageResize`，会 `UnsatisfiedLinkError`；需要时应改配真 3.3.1 构建。

## 验收（重要方法学）

这些 dylib 被 **strip 过**：`LC_SYMTAB` 里 `nextdefsym = 0`，所以

```
llvm-nm -g --defined-only liblwjgl.dylib     # 输出 0 行，不代表没有符号
```

要用导出表查：

```
llvm-objdump --macho --exports-trie liblwjgl.dylib | grep -c Java_org_lwjgl_system_ThreadLocalUtil_nsetupEnvData   # 1
llvm-objdump --macho --exports-trie liblwjgl_opengl.dylib | grep -c Java_org_lwjgl_opengl_GL11_                   # 274
```

## 文件

| 文件 | 字节 | md5 |
|---|---|---|
| liblwjgl.dylib | 306448 | 06985a4c47cc0b9ac90c98f4442c81f9 |
| liblwjgl_opengl.dylib | 163648 | 9c66d7be68ced1a484da7e90b18e91a3 |
| liblwjgl_stb.dylib | 408592 | df1c0512c5be200aa316c97a99a0864e |
| liblwjgl_tinyfd.dylib | 137040 | ae2567664814c05d5b7491ea967a8340 |

`liblwjgl_tinyfd.dylib` 一并放在这里：`org.lwjgl.util.tinyfd.*` 的 native 全在它里面（10 个），
core 库里没有。MC 用不到，但缺了它任何 tinyfd 调用都会炸，留着对齐整套。

均为 `Mach-O 64-bit arm64 dynamically linked shared library`，install_name 仍是
`bin/libs/native/macos/arm64/org/lwjgl/...`（打包时的装载名以启动器实际 dylib 路径为准）。

## 共存

`Libraries/Frameworks/` 根目录下的 3.4.x 版 `liblwjgl*.dylib` **未改动**。
选哪套由启动器按 MC 版本决定，不要同时把两套放进同一个 app 的 Frameworks（同名会覆盖）。

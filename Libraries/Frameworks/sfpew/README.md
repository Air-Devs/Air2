# SimpleFPEWrapper（iOS arm64 预编译件）

固定管线（fixed-function）模拟层：把 `glBegin`/矩阵栈/光照/纹理环境等老 GL 调用翻译成
GLSL，再交给后端 EGL/GLES（系统 GLES 或 MobileGlues）。用于替代 Minecraft ≤1.17 上的
gl4es/KW 路线。

本目录只放**编好的产物与可复现构建脚本**，尚未接入启动链（本体代码里没有任何引用）。

## 许可（重要）

上游是 **LGPL-3.0-only**（`LICENSE` 声明 + 源文件头 `SPDX-License-Identifier: LGPL-3.0-only`）。

- `COPYING` = GPLv3 全文，`COPYING.LESSER` = LGPLv3 全文，二者必须**随包分发**。
- 本目录的 `libSimpleFPEWrapper.dylib` 是**动态库**，Air2 只 `dlopen` 它、不静态链接，
  满足 LGPLv3 §4 的「动态链接即可替换」要求；不得改为静态链接入库。
- 分发包内需给出源码获取方式，本文件「上游与复现」一节即是。
- 若改动上游源码（本目录 `build/` 下三处补丁属于构建期改动），按 §4 需一并提供
  修改后的源文件——补丁脚本 + 新增源文件已随本目录提供。

## 上游与复现

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/MobileGL-Dev/SimpleFPEWrapper |
| 分支/commit | `main` @ `5474e473018f07e9624a0805683ed3c3e32ee6a2`（2026-10-31） |
| 源码包 | `https://codeload.github.com/MobileGL-Dev/SimpleFPEWrapper/tar.gz/5474e473018f07e9624a0805683ed3c3e32ee6a2` |
| 子模块 | `3rdparty/glm` @ `e8642318`、`3rdparty/glslang` @ `cb30230f`、`3rdparty/SPIRV-Cross` @ `6c09849f`、`3rdparty/googletest` @ `52eb8108`（本次构建关闭用例，不用它） |
| 工具链 | Ubuntu 22.04.5 宿主 + `clang-17`（`/usr/lib/llvm-17/bin/`）+ `ld64.lld` + iPhoneOS.sdk 26.2 |

产物：

```
Libraries/Frameworks/sfpew/libSimpleFPEWrapper.dylib
  6,564,488 字节
  md5    fe84ab42240b3616d83bad1ef3dd03a8
  sha256 d03fb6c50ad1091c7456a6439d2f8608e3b7946dc0d7a90051263aafaa2f94a5
```

验收（构建机上实测，命令见下）：

```
$ file libSimpleFPEWrapper.dylib
Mach-O 64-bit arm64 dynamically linked shared library, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|…>

$ llvm-otool -L libSimpleFPEWrapper.dylib
  @rpath/libSimpleFPEWrapper.dylib
  /usr/lib/libc++.1.dylib
  /usr/lib/libSystem.B.dylib                      ← 无 X11 / GL / GLX / EGL 外部依赖

$ llvm-objdump --macho --private-headers | grep -A6 LC_BUILD_VERSION
  platform ios / sdk 26.2 / minos 14.0            ← 与主工程 IPHONEOS_DEPLOYMENT_TARGET 一致

$ llvm-objdump --macho --exports-trie | grep -c eglGetProcAddress
1
$ … | grep -Eo ' _gl[A-Za-z0-9_]+$' | wc -l       → 567   （gl 包装符号）
$ … | grep -Eo ' _egl[A-Za-z0-9_]+$' | wc -l      →  46   （egl 包装符号）
$ llvm-nm -u | wc -l                              → 208   （全部来自 libc++ / libSystem）
```

## 构建步骤（Linux 宿主，无 Xcode）

```sh
# 1) 源码 + 子模块（GitHub 直连 clone 会挂，用 codeload；子模块 SHA 走 API 拿）
curl -sL -o sfpew.tar.gz https://codeload.github.com/MobileGL-Dev/SimpleFPEWrapper/tar.gz/5474e473018f07e9624a0805683ed3c3e32ee6a2
tar xzf sfpew.tar.gz && mv SimpleFPEWrapper-5474e4* src

# 2) 构建期补丁（幂等，见 build/patch_ios.py 与 build/sfpew_ios_format_shim.cpp）
cp build/sfpew_ios_format_shim.cpp src/ios/sfpew_ios_format_shim.cpp   # 先 mkdir -p src/ios
python3 build/patch_ios.py                                             # 改 src/CMakeLists.txt 三处

# 3) 配置 + 构建
cmake -S src -B build-ios -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=$PWD/build/tc-ios-sfpew.cmake \
      -DSFPEW_BUILD_TESTS=OFF -DSFPEW_LTO=ON -DCMAKE_BUILD_TYPE=Release
ninja -C build-ios        # 8 核约 80 秒
```

构建后的三处源码改动（`build/patch_ios.py` 内容）：

1. **加 `SFPEW_BUILD_TESTS` 开关**（默认 ON）。上游把 gtest 套件无条件接在 `if(NOT ANDROID)`
   里，且用 `gtest_discover_tests`，而它要在**构建后执行产物**做用例发现——iOS 交叉编译跑不了。
2. **iOS 专用 `_LIBCPP_DISABLE_AVAILABILITY` + 浮点 `to_chars` 自带实现**。SDK 26.2 的 libc++
   把浮点 `std::to_chars` 标成「iOS 16.3 起可用」，而 `std::format` 会无条件实例化浮点格式化
   路径（哪怕只格式化整数/字符串）；本库要支持 iOS 14.0，故关掉可用性注解，并把这三个
   `to_chars` 重载实现在 dylib 内（`build/sfpew_ios_format_shim.cpp`），产物因此没有 16.3 的
   运行时依赖（`llvm-nm -u | grep -c to_chars` = 0）。
3. **`-install_name @rpath/libSimpleFPEWrapper.dylib`**（在 `tc-ios-sfpew.cmake` 里，非源码改动），
   否则安装名会写死成构建机绝对路径。

## 踩过的坑

| 现象 | 原因/做法 |
|---|---|
| `git clone` 90 秒无进展 | GitHub 直连不通；用 codeload tar.gz。子模块 SHA 用 `api.github.com/.../contents/3rdparty/<name>` 取（`submodule_git_url` + `sha`），再 `codeload/.../tar.gz/<sha>` 拉 |
| `3rdparty/*` 全空 | tarball 不含子模块；glm/glslang/SPIRV-Cross/googletest 必须补（前三者参与编译，googletest 在关掉用例后不参与） |
| `CMAKE_SYSTEM_NAME=Generic` 时 SHARED 被降级成 STATIC | Generic 平台不支持动态库；必须用 `CMAKE_SYSTEM_NAME=iOS`（Linux 上可用，`APPLE=1`，产物 `LC_BUILD_VERSION platform ios`） |
| 沿用 Generic 还会多出 `-Wl,--no-undefined` | 上游 `if(NOT APPLE)` 分支，ld64.lld 不认；用 iOS 平台即自动走 APPLE 分支，同时拿到 `-stdlib=libc++` |
| `'to_chars' is unavailable: introduced in iOS 16.3` | 见上文第 2 条；`-Wno-availability` **不能**降级该错误（是硬错，不是警告） |
| clang 提示 `argument unused: -fuse-ld=ld64.lld` | 编译阶段正常；链接阶段生效。若真要强制，可再给 `CMAKE_LINKER` 指向 `ld64.lld` |
| LTO | `-flto=thin` + `ld64.lld` 可跑通（工具链里把 `CMAKE_AR/RANLIB` 指到 `llvm-ar/llvm-ranlib`，避免宿主的 `ar` 认不出 bitcode） |

## 接入时要先知道的（本轮不做）

- `backend/loader.cpp` 里后端 EGL 库默认名是 **`libEGL.so`**（Android 口径）。iOS 上
  `dlopen("libEGL.so")` 必然失败，接入时必须传入自定义后端路径（Air2 侧即
  `Frameworks/libEGL.framework/libEGL` 或 MobileGlues 的 dylib）。
- 库按绝对路径 `dlopen(RTLD_LAZY|RTLD_GLOBAL)` 加载即可，`@rpath` 安装名只是为了将来被
  其它 dylib 依赖时不出构建机路径。
- 侧载/签名流程与其它 `Libraries/Renderers/*.dylib` 一致：拷进 `.app/Frameworks/`
  （或 renderers 目录）后随包重新签。

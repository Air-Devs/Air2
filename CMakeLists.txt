# ============================================================================
# Air2 — 根 CMake 工程（产出 Air2.app + 可选 Air2.ipa）
#
# ★与 Air2.xcodeproj 并存★：本文件不读、不改、不生成 xcodeproj；
#   `make package` / scripts/package_ipa.sh / CI 仍走 xcodebuild，互不影响。
#
# 用法（在 macOS 上，装好 Xcode + cmake）：
#   cmake -S . -B build/cmake \
#     -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios.cmake \
#     -DCMAKE_BUILD_TYPE=Debug
#   cmake --build build/cmake -j8
#   cmake --build build/cmake --target a2-ipa     # 出 artifacts/Air2.ipa（ldid 签名）
#
# 源清单不在这里手写：见 scripts/gen_cmake_sources.py（真源头是 gen_xcodeproj.py）。
# ============================================================================
cmake_minimum_required(VERSION 3.20)

# 没有 toolchain 就是在宿主上按 macOS 编 ⇒ 一堆 UIKit 缺失的噪声错误。
# 在 project() 之前硬拦，直接给出正确命令行（静默跑错平台是最费时间的坑）。
if(NOT CMAKE_TOOLCHAIN_FILE)
    message(FATAL_ERROR
        "请显式传 iOS toolchain：\n"
        "  cmake -S . -B build/cmake -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios.cmake -DCMAKE_BUILD_TYPE=Debug\n"
        "（Air2 是 iOS 应用，不支持在宿主 macOS 上直接构建）")
endif()

project(Air2 LANGUAGES C CXX OBJC)

# 源清单 / -I / 公共编译选项（与 Natives/CMakeLists.txt 共用同一份引导）
include(${CMAKE_SOURCE_DIR}/cmake/a2_sources_bootstrap.cmake)
# 系统 framework + 第三方静态库 + 弱符号放行
include(${CMAKE_SOURCE_DIR}/cmake/a2_frameworks.cmake)

# 原生层（Natives/）：OBJECT 库 ⇒ 所有 .o 一律进最终链接。
# ★为什么不是 STATIC★：Xcode 工程把 Natives 与 Air2 放在同一个 target 的 Sources
# 阶段，未引用的 .o 也进镜像（配合 DEAD_CODE_STRIPPING=NO，启动链入口不会因
# 「暂时没人调用」被剥掉）。STATIC 库会按需只拉被引用的 .o，语义就变了。
add_subdirectory(Natives)

# 应用主体（Air2/）：与 xcodeproj 的 target sources 同口径 = 全部 .m 都在这一层
add_executable(Air2 MACOSX_BUNDLE ${A2_APP_SOURCES})
target_link_libraries(Air2 PRIVATE a2_compile_settings a2_native)

# 链接：framework → mbedTLS 静态库（被依赖者在后）→ 弱符号放行
target_link_libraries(Air2 PRIVATE
    ${A2_FRAMEWORK_PATHS}
    ${A2_MBEDTLS_STATIC_LIBS})
target_link_options(Air2 PRIVATE ${A2_UNDEFINED_LINK_OPTIONS} ${A2_RUNPATH_OPTIONS})

# bundle 元信息：与 gen_xcodeproj.py 的常量/Info.plist 对齐。
# 注意：CMake 生成的 Info.plist 只是占位 —— 真正随包的那份由
# scripts/package_ipa_cmake.sh 用 Air2/Info.plist 替换（Xcode 的 $(VAR) 语法
# 只能在那一步展开，CMake 认的是 @VAR@）。
set_target_properties(Air2 PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "${A2_GEN_PROJECT_NAME}"
    MACOSX_BUNDLE_EXECUTABLE_NAME "${A2_GEN_PROJECT_NAME}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${A2_GEN_BUNDLE_ID}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${A2_GEN_BUILD_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${A2_GEN_MARKETING_VERSION}"
    # 产物目录固定为 build/cmake/Air2.app/Air2（CMake 在 iOS 平台会自动包 .app）
    OUTPUT_NAME "${A2_GEN_PROJECT_NAME}")

# ---------------------------------------------------------------------------
# a2-ipa：调 scripts/package_ipa_cmake.sh（资源清单复用 gen_xcodeproj 的
# runtime_stage_script()，不另写一份）。这是脚本的唯一自动调用点。
#
# ★app 目录怎么取★ 两个宿主不一样，所以按宿主分两支，Mac 那一支逐字不变：
#   · Apple 宿主（Xcode 的 cmake）：Air2 是 bundle 目标 ⇒ $<TARGET_BUNDLE_DIR:Air2>
#   · Linux 宿主（交叉编译）：CMAKE_SYSTEM_NAME=Generic 下目标不是 bundle，
#     CMake 生成期就报「TARGET_BUNDLE_DIR is allowed only for Bundle targets」
#     ⇒ 改用 $<TARGET_FILE_DIR:Air2>（产物就落在 Air2.app/ 里，见本文件上方 OUTPUT_NAME）
# ---------------------------------------------------------------------------
if(CMAKE_HOST_APPLE)
    set(A2_IPA_APP_DIR_GENEX "$<TARGET_BUNDLE_DIR:Air2>")
else()
    set(A2_IPA_APP_DIR_GENEX "$<TARGET_FILE_DIR:Air2>")
endif()
add_custom_target(a2-ipa
    COMMAND "${CMAKE_COMMAND}" -E echo "==> 打包 IPA（cmake 产物 + ldid）"
    COMMAND /bin/bash "${CMAKE_SOURCE_DIR}/scripts/package_ipa_cmake.sh"
            --app-dir "${A2_IPA_APP_DIR_GENEX}"
            --out "${CMAKE_SOURCE_DIR}/artifacts"
    DEPENDS Air2
    COMMENT "package_ipa_cmake.sh → artifacts/Air2-cmake.ipa"
    VERBATIM)

# ---------------------------------------------------------------------------
# ★Linux 交叉链接垫片★（只在非 Apple 宿主上生效）
#   __isPlatformVersionAtLeast 在 Apple 上由 compiler-rt 提供；Linux 的 clang
#   没有这份 runtime ⇒ 显式把垫片并进可执行目标。Mac 上不加：那里由 compiler-rt
#   提供同名符号，再加一份就是重复定义。
#   为什么不用源扫描清单：scan_sources() 只收 .m/.mm，本文件是 .c；
#   而且它只属于「Linux 宿主」这一种构建，不该出现在任何平台的通用清单里。
# ---------------------------------------------------------------------------
if(NOT CMAKE_HOST_APPLE)
    target_sources(Air2 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Natives/a2_platform_version_shim.c)
endif()

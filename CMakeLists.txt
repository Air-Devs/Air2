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

# ★内建 JIT 的扩展（appex）★：进程不能 attach 自己 ⇒ 必须有个独立进程去 attach 主 App。
#   由 cmake/Air2JITHelper.cmake 里的 a2_jit_helper_embed 在 POST_BUILD 阶段编出来并塞进
#   <App>/PlugIns/Air2JITHelper.appex。主 App 侧由 Air2/Bridge/A2JITHelperBridge.m 拉起。
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/Air2JITHelper.cmake)
a2_jit_helper_embed(Air2)
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

# ---------------------------------------------------------------------------
# ★内建 JIT：StikJIT.framework（MPL-2.0，来自 Henge.ipa）★
#
# 由谁用：Natives/StikJIT/A2StikJITBridge.swift（唯一 import 点）
#         ← Air2/Player/A2StikJITProvider.m ← A2JITEnabler 的内建钩子。
#
# 三件事，缺一条真机就用不了：
#   ① **框架整包**进 <App>/Frameworks/StikJIT.framework（含 Info.plist 与
#      legacy.js/universal.js —— 框架按 CFBundle 路径找脚本，缺了会在运行时报
#      scriptUnavailable）。ldid 伪签在 scripts/package_ipa_cmake.sh 里做。
#   ② **链接**：-F<Natives/StikJIT> -weak_framework StikJIT。
#      ★为什么是 weak★：框架 minos=17.4 ⇒ iOS 14–17.3 上它加载不了；
#      weak 链接保证主程序照样能起（能不能真用由 A2StikJITProvider 运行时 dlopen 判）。
#   ③ **Swift 桥**：本仓没有 Swift 源、也不开 Xcode 工程，所以两步手编：
#      · StikJIT.swift（接口桩）→ 只 -emit-module 出 .swiftmodule（框架不随包 Modules/）
#      · A2StikJITBridge.swift → -emit-object 出 .o 直接进 Air2 target
#      链接还需要两条 -L：<SDK>/usr/lib/swift 与 <工具链>/usr/lib/swift/iphoneos
#      （Swift 运行时不随包，iOS 12.2+ 自带）。
# ---------------------------------------------------------------------------
set(A2_STIKJIT_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Natives/StikJIT")
set(A2_STIKJIT_FW_DIR "${A2_STIKJIT_SRC_DIR}/StikJIT.framework")
set(A2_STIKJIT_TRIPLET "arm64-apple-ios17.4")   # ★必须匹配框架自带 Modules 的最低部署目标★
#   框架 minos=17.4；用 14.0 编桥会报 "module StikJIT has a minimum deployment target of iOS 17.4"。
#   主 App 仍是 14.0，Swift 桥在运行时由 A2StikJITProvider 的 @available 判定后才可用。

if(NOT EXISTS "${A2_STIKJIT_FW_DIR}/StikJIT")
    message(FATAL_ERROR
        "缺少内建 JIT 引擎：${A2_STIKJIT_FW_DIR}/StikJIT\n"
        "  该框架随仓（Natives/StikJIT/StikJIT.framework，MPL-2.0）；缺失说明工作树不完整。\n"
        "  详见 docs/JIT-BUILTIN-STIKJIT.md §2。")
endif()

# swiftc：Apple 宿主走 xcrun（Xcode 不一定在 /usr/bin 里带 swiftc）
if(NOT A2_SWIFTC)
    find_program(A2_SWIFTC swiftc)
endif()
if(NOT A2_SWIFTC AND A2_XCRUN)
    execute_process(COMMAND "${A2_XCRUN}" -f swiftc
        OUTPUT_VARIABLE _a2_swiftc OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_a2_swiftc AND EXISTS "${_a2_swiftc}")
        set(A2_SWIFTC "${_a2_swiftc}")
    endif()
endif()
if(NOT A2_SWIFTC)
    message(FATAL_ERROR
        "找不到 swiftc（内建 JIT 的桥是 Swift 写的）。\n"
        "  macOS：装 Xcode 或 Command Line Tools；或 -DA2_SWIFTC=/path/to/swiftc。")
endif()
# swift 运行时库目录（iPhoneOS 变体）在工具链里：<swiftc dir>/../lib/swift/iphoneos
get_filename_component(_a2_swiftc_dir "${A2_SWIFTC}" DIRECTORY)
if(NOT A2_SWIFT_TC_LIB_DIR)
    get_filename_component(A2_SWIFT_TC_LIB_DIR "${_a2_swiftc_dir}/../lib/swift/iphoneos" ABSOLUTE)
endif()
message(STATUS "[a2-stikjit] swiftc = ${A2_SWIFTC}")
message(STATUS "[a2-stikjit] swift ios 运行时 = ${A2_SWIFT_TC_LIB_DIR}")

set(A2_STIKJIT_MODULE_DIR "${CMAKE_BINARY_DIR}/stikjit-module")
set(A2_STIKJIT_OBJ "${CMAKE_BINARY_DIR}/stikjit/A2StikJITBridge.o")

add_custom_command(
    OUTPUT "${A2_STIKJIT_MODULE_DIR}/StikJIT.swiftmodule" "${A2_STIKJIT_OBJ}"
    # ① 接口桩 → .swiftmodule（模块名必须逐字 = StikJIT，mangled 前缀 $s7StikJIT 才对得上）
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${A2_STIKJIT_MODULE_DIR}" "${CMAKE_BINARY_DIR}/stikjit"
    # ② 桥 → .o（-I 指到刚产出的模块；-parse-as-library 不生成 main）
    COMMAND "${A2_SWIFTC}" -emit-object -parse-as-library -module-name A2StikJITBridge
            -target "${A2_STIKJIT_TRIPLET}" -sdk "${CMAKE_OSX_SYSROOT}"
            -I "${A2_STIKJIT_FW_DIR}/Modules"
            "${A2_STIKJIT_SRC_DIR}/A2StikJITBridge.swift"
            -o "${A2_STIKJIT_OBJ}"
    DEPENDS "${A2_STIKJIT_FW_DIR}/Modules/StikJIT.swiftmodule" "${A2_STIKJIT_SRC_DIR}/A2StikJITBridge.swift"
    COMMENT "内建 JIT：编 Swift 桥（StikJIT 接口桩 → module；桥 → object）"
    VERBATIM)

add_custom_target(a2-stikjit DEPENDS "${A2_STIKJIT_OBJ}")
add_dependencies(Air2 a2-stikjit)
target_sources(Air2 PRIVATE "${A2_STIKJIT_OBJ}")

# 链接：框架搜索路径 + weak framework + Swift 运行时两条 -L
target_link_directories(Air2 PRIVATE
    "${A2_STIKJIT_SRC_DIR}"
    "${CMAKE_OSX_SYSROOT}/usr/lib/swift"
    "${A2_SWIFT_TC_LIB_DIR}")
target_link_options(Air2 PRIVATE
    "-F${A2_STIKJIT_SRC_DIR}"
    "-Wl,-weak_framework,StikJIT"
    "-L${CMAKE_OSX_SYSROOT}/usr/lib/swift"
    "-L${A2_SWIFT_TC_LIB_DIR}")

# 框架整包随 App（Xcode 侧由 gen_xcodeproj 的 embed 阶段做；CMake 侧在这里做）
add_custom_command(TARGET Air2 POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory
            "$<TARGET_FILE_DIR:Air2>/Frameworks"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
            "${A2_STIKJIT_FW_DIR}"
            "$<TARGET_FILE_DIR:Air2>/Frameworks/StikJIT.framework"
    COMMENT "内建 JIT：Embed StikJIT.framework → Air2.app/Frameworks"
    VERBATIM)

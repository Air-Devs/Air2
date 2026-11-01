# ============================================================================
# Air2 — 原生层（Natives/）：启动链 / 渲染 / 输入 / JVM 装载
#
# 两种进入方式（都要能跑）：
#   ① 根工程 add_subdirectory(Natives)          —— CMakeLists.txt:38
#      CMake: cmake -S . -B build/cmake -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios.cmake
#   ② 独立配置（Makefile:58 的 `make natives`）—— cmake -S Natives -B Natives/build
#      独立模式必须自带 project() 和 toolchain 检查（否则会按宿主 macOS 编，
#      UIKit 一缺失就报一片噪声错误）。
#
# 产出：OBJECT 库 a2_native（不是 STATIC，见根 CMakeLists.txt:36-41 的说明）
# ============================================================================

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    cmake_minimum_required(VERSION 3.20)
    if(NOT CMAKE_TOOLCHAIN_FILE)
        message(FATAL_ERROR
            "独立编译 Natives/ 也必须指定 iOS toolchain：\n"
            "  cmake -S Natives -B Natives/build \\\n"
            "    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../cmake/toolchain-ios.cmake \\\n"
            "    -DCMAKE_BUILD_TYPE=Debug\n"
            "（`make natives` 已自动带上这个参数，见 Makefile）")
    endif()
    project(Air2Natives LANGUAGES C CXX OBJC)
endif()

# 源清单（Air2/ 与 Natives/ 一起扫的那一份；这里只取 Natives/ 部分）+ -I + 编译选项
include(${CMAKE_CURRENT_SOURCE_DIR}/../cmake/a2_sources_bootstrap.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../cmake/a2_frameworks.cmake)

add_library(a2_native OBJECT ${A2_NATIVE_SOURCES})
target_link_libraries(a2_native PRIVATE a2_compile_settings)

# OBJECT 库不能真正「链接」，但使用需求（-I / 宏）必须传给上层的 Air2 目标；
# 这里把 framework 也挂上，独立模式（make natives）时语义与随包一致。
target_link_libraries(a2_native PUBLIC ${A2_FRAMEWORK_PATHS} ${A2_MBEDTLS_STATIC_LIBS})

# 独立模式没有上层可执行文件 ⇒ 明确告诉调用者「这里只做编译验证」，
# 不要让人误以为 Natives/build/liba2_native.a 能直接拿去用。
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    message(STATUS
        "[a2] 独立模式：只编 Natives/（${_a2_n_native} 个单元），不产出 .app；"
        "出包请用根工程 + target a2-ipa")
endif()

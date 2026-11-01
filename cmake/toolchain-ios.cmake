# ============================================================================
# Air2 — iOS 交叉编译 toolchain（CMake + clang，不经 xcodebuild）
#
# 调用点（谁传它）：
#   Makefile:68                          make natives → -DCMAKE_TOOLCHAIN_FILE=...
#   根工程构建命令（本文件头「用法」）    cmake -S . -B build/cmake -DCMAKE_TOOLCHAIN_FILE=...
#   CMakeLists.txt:17                    没传就 FATAL_ERROR（防按宿主 macOS 编）
#
# 用法：
#   cmake -S . -B build/cmake \
#     -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios.cmake \
#     -DCMAKE_BUILD_TYPE=Debug
#   （SDK 缺省用 xcrun 探测；显式指定就加 -DiOS_SDK=/path/to/iPhoneOS.sdk）
#
# 与 Xcode 工程并存：本文件只影响 CMake 构建，不读也不写 Air2.xcodeproj。
#
# ★为什么每个语言都要 -target arm64-apple-ios14.0★
#   Intel 宿主上 clang 的缺省 target 是 x86_64-apple-darwin ⇒ 生成的 .o 是
#   x86_64-macos，链接期报 "building for iOS, but linking in object file built
#   for macOS"。CMake 的 CMAKE_OSX_ARCHITECTURES 只影响 Xcode generator，
#   对 Makefile/Ninja generator 不会自动加 -target（PoC 实测），必须显式写。
# ============================================================================

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

# 只编真机（与 pbxproj 的 SUPPORTED_PLATFORMS=iphoneos 一致）
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "iOS 真机架构")

# 部署目标：与 scripts/gen_xcodeproj.py 的 DEPLOYMENT_TARGET 对齐。
# 根 CMakeLists.txt 会用生成源清单里的 A2_GEN_DEPLOYMENT_TARGET 校验这一项，
# 两边不一致直接 FATAL_ERROR（避免「工程 14.0 / CMake 12.0」这种静默分叉）。
if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "iOS 最低版本")
endif()

# ---------------------------------------------------------------- SDK 定位
# 缺省走 xcrun；显式 -DiOS_SDK=... 时直接用（离线/多 Xcode 并存场景）。
if(NOT iOS_SDK)
    find_program(A2_XCRUN xcrun)
    if(NOT A2_XCRUN)
        message(FATAL_ERROR
            "找不到 xcrun：iOS 构建必须在装了 Xcode 的 macOS 上跑。\n"
            "  也可以用 -DiOS_SDK=/path/to/iPhoneOS.sdk 显式指定 SDK。")
    endif()
    execute_process(
        COMMAND "${A2_XCRUN}" --sdk iphoneos --show-sdk-path
        OUTPUT_VARIABLE _a2_sdk
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_VARIABLE _a2_sdk_err)
    if(NOT _a2_sdk OR NOT IS_DIRECTORY "${_a2_sdk}")
        message(FATAL_ERROR "xcrun 未能给出 iPhoneOS SDK：${_a2_sdk_err}")
    endif()
    set(iOS_SDK "${_a2_sdk}")
endif()
message(STATUS "[a2-toolchain] iOS_SDK = ${iOS_SDK}")

set(CMAKE_OSX_SYSROOT "${iOS_SDK}" CACHE PATH "iPhoneOS SDK")

# 编译器也走 xcrun（app store 渠道装的 Xcode 不一定在 /usr/bin 里）
if(NOT CMAKE_C_COMPILER)
    execute_process(COMMAND "${A2_XCRUN}" -f clang
        OUTPUT_VARIABLE _a2_clang OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT _a2_clang)
        message(FATAL_ERROR "xcrun -f clang 失败：找不到 clang")
    endif()
    set(CMAKE_C_COMPILER   "${_a2_clang}")
    set(CMAKE_CXX_COMPILER "${_a2_clang}")
    set(CMAKE_OBJC_COMPILER "${_a2_clang}")
endif()

# -target 三元组（★关键，见文件头说明★）
set(_a2_triplet "arm64-apple-ios${CMAKE_OSX_DEPLOYMENT_TARGET}")
set(CMAKE_C_FLAGS_INIT    "-target ${_a2_triplet}")
set(CMAKE_CXX_FLAGS_INIT  "-target ${_a2_triplet}")
set(CMAKE_OBJC_FLAGS_INIT "-target ${_a2_triplet}")

# 交叉编译时不能拿宿主可执行文件做可行性测试（会去跑 arm64 二进制）⇒ 用静态库探测
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# find_* 在 SDK 里找头/库；宿主工具（如 python3）仍走宿主路径
set(CMAKE_FIND_ROOT_PATH "${iOS_SDK}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

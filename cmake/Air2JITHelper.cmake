# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# Air2 — 内建 JIT helper appex 的 CMake 片段（★独立文件，不改根 CMakeLists 正文★）
#
# 用法：在根 CMakeLists.txt 的 `add_executable(Air2 MACOSX_BUNDLE …)` 之后加两行
#   include(${CMAKE_SOURCE_DIR}/cmake/Air2JITHelper.cmake)
#   a2_jit_helper_embed(Air2)
#
# 为什么是独立片段：根 CMakeLists.txt 属于另一条改动线（内建 StikJIT 引擎 / Natives 层），
# 本片段只做一件事 —— 把 Air2JITHelper.appex 编出来并放进 Air2.app/PlugIns。
# 删掉这两行就完全回到原状，不会留下半截状态。
#
# ★谁用它★
#   根 CMakeLists.txt（唯一 include 点）→ a2_jit_helper_embed(Air2)
#   产物被 Air2/Bridge/A2JITHelperBridge.m `+helperIdentifier` 按
#   PlugIns/Air2JITHelper.appex 找到（再取它现成的 bundle id）。
#
# ★为什么不在这里登记 A2JITHelperBridge.m★
#   源清单的唯一真源头是 scripts/gen_xcodeproj.py 的 scan_sources()（递归收 Air2/**/*.m），
#   CMake 与 Xcode 两条路都会自动带上；这里再 target_sources 一次等于同一份源写两处。
#
# ★编译期常量★
#   appex 的 -target 固定 arm64-apple-ios26.0（NSExtension/ExtensionFoundation 那套
#   API 只在 iOS 26+ 存在），与主 App 的 14.0 无关；故不传 CMAKE_OSX_DEPLOYMENT_TARGET。
# ============================================================================
include_guard(GLOBAL)

set(A2_JIT_HELPER_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/../Air2JITHelper/build-appex.sh")

# 把 helper appex 嵌进 <target> 的 bundle（PlugIns/Air2JITHelper.appex）。
# 调用点：根 CMakeLists.txt（见文件头用法）。
function(a2_jit_helper_embed target)
    if(NOT EXISTS "${A2_JIT_HELPER_SCRIPT}")
        message(FATAL_ERROR
            "缺少 appex 构建脚本：${A2_JIT_HELPER_SCRIPT}\n"
            "  该脚本随仓（Air2JITHelper/build-appex.sh），缺失说明工作树不完整。")
    endif()

    if(NOT CMAKE_HOST_APPLE)
        # Linux 交叉编译只产 .app 骨架，没有 swiftc + iPhoneOS SDK ⇒ 明确跳过而不是假失败。
        message(STATUS
            "[a2-jit-helper] 非 Apple 宿主 ⇒ 跳过 Air2JITHelper.appex"
            "（内建 JIT 只在 iOS 真机上需要）")
        return()
    endif()

    set(_a2_jit_helper_args --out "$<TARGET_FILE_DIR:${target}>/PlugIns")
    # ★不转发 CMAKE_OSX_SYSROOT★：主 App 的 sysroot 就是 iPhoneOS.sdk 没错，但把 sysroot
    # 传进来会让「用 macOS 宿主靶子验证本片段」时拿 macOS SDK 去编 iOS appex 而失败；
    # 脚本自己走 `xcrun --sdk iphoneos --show-sdk-path`，这对任何 Xcode 都是唯一正确的 SDK。
    if(A2_SWIFTC)
        list(APPEND _a2_jit_helper_args --swiftc "${A2_SWIFTC}")
    endif()

    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E env SWIFT_TC_LIB_DIR="${A2_SWIFT_TC_LIB_DIR}"
                /bin/bash "${A2_JIT_HELPER_SCRIPT}" ${_a2_jit_helper_args}
        COMMENT "内建 JIT：编 Air2JITHelper.appex → $<TARGET_FILE_DIR:${target}>/PlugIns"
        VERBATIM)
endfunction()

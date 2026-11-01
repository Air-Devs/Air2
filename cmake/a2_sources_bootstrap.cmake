# ============================================================================
# Air2 — 共享构建引导（源清单 / 头搜索路径 / 公共编译选项）
#
# 调用点（谁 include 它）：
#   CMakeLists.txt:30            （根工程，产出 Air2.app）
#   Natives/CMakeLists.txt:28    （独立模式 `cmake -S Natives`，即 make natives）
#
# 为什么抽成一个文件：两种进入方式必须用**同一份**源清单、同一份 -I、同一份
# 编译选项；各写一份就是石山的起点（Xcode 与 CMake 分叉正是这么产生的）。
# include_guard(GLOBAL) 保证被两边各自 include 时只执行一次。
# ============================================================================
include_guard(GLOBAL)

if(NOT A2_ROOT_DIR)
    get_filename_component(A2_ROOT_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
endif()

# ---------------------------------------------------------------------------
# ① 源清单：唯一真源头是 scripts/gen_xcodeproj.py 的 scan_sources()
# ---------------------------------------------------------------------------
set(A2_GEN_FILE "${CMAKE_BINARY_DIR}/a2_sources.cmake")

find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
    execute_process(
        COMMAND "${Python3_EXECUTABLE}" "${A2_ROOT_DIR}/scripts/gen_cmake_sources.py"
                --output "${A2_GEN_FILE}"
        RESULT_VARIABLE _a2_gen_rc
        OUTPUT_VARIABLE _a2_gen_out
        ERROR_VARIABLE _a2_gen_err)
    if(NOT _a2_gen_rc EQUAL 0)
        message(FATAL_ERROR
            "源清单生成失败（scripts/gen_cmake_sources.py rc=${_a2_gen_rc}）\n"
            "${_a2_gen_out}${_a2_gen_err}")
    endif()
    # 生成器把计数行写到 stderr（约定见脚本 docstring），这里原样转成 -- 信息
    string(STRIP "${_a2_gen_err}" _a2_gen_err)
    if(_a2_gen_err)
        message(STATUS "${_a2_gen_err}")
    endif()
    include(${A2_GEN_FILE})
else()
    # ★兜底★：没有 python3 时按 scan_sources() 的同一口径 glob（Air2/ + Natives/，
    #   只取 .m/.mm）。会告警，因为这条路径少了 basename 唯一性校验。
    message(WARNING
        "[a2] 未找到 python3 ⇒ 回退为 file(GLOB_RECURSE) 收集源文件。"
        "推荐装 python3 走 scripts/gen_cmake_sources.py（含同名头校验）。")
    file(GLOB_RECURSE A2_APP_SOURCES "${A2_ROOT_DIR}/Air2/*.m" "${A2_ROOT_DIR}/Air2/*.mm")
    file(GLOB_RECURSE A2_NATIVE_SOURCES "${A2_ROOT_DIR}/Natives/*.m" "${A2_ROOT_DIR}/Natives/*.mm")
    list(SORT A2_APP_SOURCES)
    list(SORT A2_NATIVE_SOURCES)
    file(GLOB_RECURSE _a2_headers "${A2_ROOT_DIR}/Air2/*.h" "${A2_ROOT_DIR}/Natives/*.h")
    set(A2_INCLUDE_DIRS "${A2_ROOT_DIR}")
    foreach(_h IN LISTS _a2_headers)
        get_filename_component(_d "${_h}" DIRECTORY)
        list(APPEND A2_INCLUDE_DIRS "${_d}")
    endforeach()
    list(REMOVE_DUPLICATES A2_INCLUDE_DIRS)
    set(A2_UNDEFINED_SYMS "")
    set(A2_MBEDTLS_LIB_DIR "${A2_ROOT_DIR}/Libraries/ThirdParty/mbedtls/lib")
    set(A2_MBEDTLS_LIBS mbedtls mbedx509 mbedcrypto)
    set(A2_RESOURCE_PATHS "")
    set(A2_GEN_DEPLOYMENT_TARGET "14.0")
    set(A2_GEN_BUNDLE_ID "dev.airdevs.air2")
    set(A2_GEN_BUILD_VERSION "0")
    set(A2_GEN_MARKETING_VERSION "0.1.0")
endif()

# ---------------------------------------------------------------------------
# ② 相对路径 → 绝对路径（生成的清单写成仓库相对路径，便于 diff 阅读；
#    CMake 里相对路径会按 CMAKE_CURRENT_SOURCE_DIR 解析 ⇒ 独立模式会错位）
# ---------------------------------------------------------------------------
macro(_a2_absolutize var)
    set(_a2_tmp "")
    foreach(_a2_f IN LISTS ${var})
        if(IS_ABSOLUTE "${_a2_f}")
            list(APPEND _a2_tmp "${_a2_f}")
        else()
            list(APPEND _a2_tmp "${A2_ROOT_DIR}/${_a2_f}")
        endif()
    endforeach()
    set(${var} ${_a2_tmp})
    unset(_a2_tmp)
endmacro()

_a2_absolutize(A2_APP_SOURCES)
_a2_absolutize(A2_NATIVE_SOURCES)
_a2_absolutize(A2_INCLUDE_DIRS)
_a2_absolutize(A2_RESOURCE_PATHS)
if(A2_MBEDTLS_LIB_DIR AND NOT IS_ABSOLUTE "${A2_MBEDTLS_LIB_DIR}")
    set(A2_MBEDTLS_LIB_DIR "${A2_ROOT_DIR}/${A2_MBEDTLS_LIB_DIR}")
endif()

list(LENGTH A2_APP_SOURCES _a2_n_app)
list(LENGTH A2_NATIVE_SOURCES _a2_n_native)
if(_a2_n_native EQUAL 0)
    message(FATAL_ERROR "[a2] Natives/ 下没有编译单元 —— 清单生成异常，拒绝静默产出空原生层。")
endif()
math(EXPR _a2_n_total "${_a2_n_app} + ${_a2_n_native}")
list(LENGTH A2_INCLUDE_DIRS _a2_n_inc)
message(STATUS "[a2] 编译单元 ${_a2_n_total}（Air2/ ${_a2_n_app} + Natives/ ${_a2_n_native}），"
               "-I 目录 ${_a2_n_inc} 个")

# ---------------------------------------------------------------------------
# ③ 部署目标一致性：CMake 与 Xcode 工程不许各说各话
# ---------------------------------------------------------------------------
if(CMAKE_OSX_DEPLOYMENT_TARGET AND
   NOT "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "${A2_GEN_DEPLOYMENT_TARGET}")
    message(FATAL_ERROR
        "部署目标不一致：CMake=${CMAKE_OSX_DEPLOYMENT_TARGET}，"
        "scripts/gen_xcodeproj.py=${A2_GEN_DEPLOYMENT_TARGET}。\n"
        "请用 -DCMAKE_OSX_DEPLOYMENT_TARGET=${A2_GEN_DEPLOYMENT_TARGET} 或先统一两边。")
endif()

# ---------------------------------------------------------------------------
# ④ 公共编译设置（INTERFACE 目标，两个 target 共用）
#    逐条对应 pbxproj 的项目级 buildSettings，见注释里的 Xcode 变量名。
# ---------------------------------------------------------------------------
if(NOT TARGET a2_compile_settings)
    add_library(a2_compile_settings INTERFACE)
    target_include_directories(a2_compile_settings INTERFACE ${A2_INCLUDE_DIRS})

    target_compile_options(a2_compile_settings INTERFACE
        $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>   # CLANG_ENABLE_OBJC_ARC=YES
        -fno-common                                     # GCC_NO_COMMON_BLOCKS=YES
        -Wall
        -Wundeclared-selector                           # GCC_WARN_UNDECLARED_SELECTOR
        -Wbool-conversion                               # CLANG_WARN_BOOL_CONVERSION
        -Wenum-conversion                               # CLANG_WARN_ENUM_CONVERSION
        -Wint-conversion                                # CLANG_WARN_INT_CONVERSION
        -Wunreachable-code                              # CLANG_WARN_UNREACHABLE_CODE
        -Wempty-body                                    # CLANG_WARN_EMPTY_BODY
        # 不用 -Werror：与 Xcode 工程保持一致（警告即可，不阻断构建）。
    )

    target_compile_definitions(a2_compile_settings INTERFACE
        $<$<CONFIG:Debug>:DEBUG=1>
        $<$<NOT:$<CONFIG:Debug>>:NDEBUG=1>)            # ENABLE_NS_ASSERTIONS=NO
endif()

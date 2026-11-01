# ============================================================================
# Air2 — 链接依赖（系统 framework / 系统库 / 仓库内第三方静态库）
#
# 调用点（谁 include 它）：
#   CMakeLists.txt:32            根工程链接 Air2 可执行文件
#   Natives/CMakeLists.txt:29    独立模式给 OBJECT 库挂 usage requirements
#
# ★为什么必须显式列 framework★
#   Xcode 工程里 PBXFrameworksBuildPhase 是空的 —— 它靠 CLANG_ENABLE_MODULES=YES
#   的模块自动链接（#import <UIKit/UIKit.h> 会带出 -framework UIKit）。
#   CMake 走的是纯 clang -I 编译（不开 -fmodules），没有 autolink ⇒ 不列就会
#   在链接期报一堆 _OBJC_CLASS_$_xxx 未定义。
#
# 清单来源：`grep -rhoE '#import <X/...>' Air2 Natives` 的实际结果（不是猜的）。
#   Foundation 134 处 / UIKit 73 / Security 8 / UniformTypeIdentifiers 4 /
#   Network 4 / UserNotifications 1 / SafariServices 1 / QuartzCore 1 /
#   ImageIO 1 / BackgroundTasks 1 / AVFAudio（属 AVFoundation）/ Metal 18 处。
#   ★MetalKit 在源码里 0 处引用 ⇒ 不列（避免「为保险起见都加上」的石山）★。
# 增补规则：链接期报 _OBJC_CLASS_$_<X> / _<sym> 未定义且确属某 framework 时，
#   才把该 framework 加进 A2_SYSTEM_FRAMEWORKS。
# ============================================================================
include_guard(GLOBAL)

set(A2_SYSTEM_FRAMEWORKS
    Foundation
    UIKit
    QuartzCore          # CALayer / CAMetalLayer（Renderer 层）
    OpenGLES            # 兼容底 GL 后端
    Metal               # Metal 渲染后端
    AVFoundation        # AVFAudio（音频后端）
    CoreAudio           # AudioUnit / AudioSession
    CoreGraphics
    CoreText
    Security            # Keychain、SecRandom、CommonCrypto 所在 framework
    SystemConfiguration # 网络可达性
    Network             # NWPathMonitor（下载引擎）
    UniformTypeIdentifiers
    UserNotifications
    SafariServices
    ImageIO
    BackgroundTasks     # BGTaskScheduler（配对保活）
)

set(A2_FRAMEWORK_PATHS "")
foreach(_fw IN LISTS A2_SYSTEM_FRAMEWORKS)
    find_library(A2_FW_${_fw} ${_fw})
    if(NOT A2_FW_${_fw})
        # ★Linux 宿主分支★ 非 Apple 宿主上 find_library 不认 .framework，改为显式检查 + -framework 链接
        # （Linux 交叉编译 .app 用的那条路；Mac 宿主永远走上面的 find_library，行为不变）
        set(_fwbin "${CMAKE_OSX_SYSROOT}/System/Library/Frameworks/${_fw}.framework/${_fw}")
        if(NOT EXISTS "${_fwbin}")
            set(_fwtbd "${CMAKE_OSX_SYSROOT}/System/Library/Frameworks/${_fw}.framework/${_fw}.tbd")
            if(NOT EXISTS "${_fwtbd}")
                message(FATAL_ERROR
                    "找不到系统 framework ${_fw}（SDK=${CMAKE_OSX_SYSROOT}）。\n"
                    "若确实是 iOS SDK 缺这个 framework，请从 A2_SYSTEM_FRAMEWORKS 里删掉并说明原因。")
            endif()
        endif()
        set(A2_FW_${_fw} "-Wl,-framework,${_fw}")
    endif()
    list(APPEND A2_FRAMEWORK_PATHS "${A2_FW_${_fw}}")
endforeach()

# 系统库：zlib（A2ZipReader / A2DownloadEngine 用 <zlib.h>）
find_library(A2_LIB_z z)
if(NOT A2_LIB_z)
    # ★Linux 宿主分支★ 同上：直接从 SDK 里取 libz.tbd / libz.dylib
    set(A2_LIB_z "${CMAKE_OSX_SYSROOT}/usr/lib/libz.tbd")
    if(NOT EXISTS "${A2_LIB_z}")
        set(A2_LIB_z "${CMAKE_OSX_SYSROOT}/usr/lib/libz.dylib")
    endif()
    if(NOT EXISTS "${A2_LIB_z}")
        message(FATAL_ERROR "找不到 libz（SDK=${CMAKE_OSX_SYSROOT}/usr/lib）")
    endif()
endif()
list(APPEND A2_FRAMEWORK_PATHS "${A2_LIB_z}")

# ---------------------------------------------------------------------------
# 仓库内第三方静态库：mbedTLS（TLS-PSK 隧道后端）
# 路径/库名/顺序全部来自生成变量（源头是 gen_xcodeproj.py 的 MBEDTLS_LDFLAGS），
# 不在这里另抄一份。
# ---------------------------------------------------------------------------
set(A2_MBEDTLS_STATIC_LIBS "")
if(A2_MBEDTLS_LIB_DIR)
    foreach(_ml IN LISTS A2_MBEDTLS_LIBS)
        set(_mp "${A2_MBEDTLS_LIB_DIR}/lib${_ml}.a")
        if(NOT EXISTS "${_mp}")
            message(FATAL_ERROR
                "缺少 ${_mp}\n"
                "  该静态库随仓（Libraries/ThirdParty/mbedtls/lib）；缺失时先跑\n"
                "  scripts/build_mbedtls_ios.sh 在 Mac 上重建。")
        endif()
        list(APPEND A2_MBEDTLS_STATIC_LIBS "${_mp}")
    endforeach()
endif()

# ---------------------------------------------------------------------------
# 可选二进制依赖 libterracotta：工程内没有它的 .a，A2Multiplayer.m 用
# __attribute__((weak)) 声明 C ABI。现代 ld64 对「任何库都不提供」的符号
# 即便 weak 也不放行 ⇒ 逐个 -Wl,-U 放行（与 pbxproj 的 OTHER_LDFLAGS 一致，
# 符号表来自生成变量，源头是 gen_xcodeproj.TERRACOTTA_UNDEFINED_SYMS）。
# ---------------------------------------------------------------------------
set(A2_UNDEFINED_LINK_OPTIONS "")
foreach(_sym IN LISTS A2_UNDEFINED_SYMS)
    list(APPEND A2_UNDEFINED_LINK_OPTIONS "-Wl,-U,${_sym}")
endforeach()

# LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks（dlopen 渲染器要用）
set(A2_RUNPATH_OPTIONS "-Wl,-rpath,@executable_path/Frameworks")

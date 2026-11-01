# Linux 宿主 iOS 交叉编译 toolchain
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_C_COMPILER   /usr/bin/clang-17)
set(CMAKE_CXX_COMPILER /usr/bin/clang++-17)
set(CMAKE_OBJC_COMPILER /usr/bin/clang-17)
# SDK 路径：允许 -DiOS_SDK 覆盖，但在 try_compile 子工程里也要有值 ⇒ 这里给默认
if(NOT iOS_SDK)
  set(iOS_SDK "/build/iossdk/iPhoneOS.sdk")
endif()
set(CMAKE_OSX_SYSROOT "${iOS_SDK}" CACHE PATH "iPhoneOS SDK")
set(_t "arm64-apple-ios14.0")
# ★SDK 的 SubFrameworks★：UIKit 头文件 include <UIUtilities/UIDefines.h>，该 framework 在 System/Library/SubFrameworks 下，必须显式 -iframework。
set(_a2_ifw "-iframework ${iOS_SDK}/System/Library/Frameworks -iframework ${iOS_SDK}/System/Library/SubFrameworks")
set(CMAKE_C_FLAGS_INIT    "-target ${_t} -isysroot ${iOS_SDK} ${_a2_ifw}")
set(CMAKE_CXX_FLAGS_INIT  "-target ${_t} -isysroot ${iOS_SDK} ${_a2_ifw}")
set(CMAKE_OBJC_FLAGS_INIT "-target ${_t} -isysroot ${iOS_SDK} ${_a2_ifw}")
set(CMAKE_CXX_FLAGS  "-target ${_t} -isysroot ${iOS_SDK} ${_a2_ifw}" CACHE STRING "" FORCE)
set(CMAKE_OBJC_FLAGS "-target ${_t} -isysroot ${iOS_SDK} ${_a2_ifw}" CACHE STRING "" FORCE)

# ★Mach-O 链接器★ Linux 的 GNU ld 不能产出 Mach-O，必须用 LLVM 的 ld64.lld
set(CMAKE_C_LINKER_FLAGS    "-fuse-ld=/usr/lib/llvm-17/bin/ld64.lld" CACHE STRING "" FORCE)

# ld64.lld 需要显式 -arch / -platform_version / syslibroot
set(CMAKE_EXE_LINKER_FLAGS "-target ${_t} -isysroot ${iOS_SDK} -fuse-ld=/usr/lib/llvm-17/bin/ld64.lld -Wl,-arch,arm64 -Wl,-platform_version,ios,14.0,26.2 -Wl,-syslibroot,${iOS_SDK}" CACHE STRING "" FORCE)
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS}" CACHE STRING "" FORCE)

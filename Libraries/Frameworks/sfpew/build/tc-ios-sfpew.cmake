# SimpleFPEWrapper / iOS arm64 交叉编译工具链（Linux 宿主，无 Xcode）
# 关键点见 ios-cmake-cross-build 技能：Generic 平台不支持动态库，必须用 iOS 平台；
# 链接器是 ld64.lld，链接参数必须自带 -arch/-platform_version/-syslibroot。
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT /build/iossdk/iPhoneOS.sdk)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)

set(SFPEW_SDK /build/iossdk/iPhoneOS.sdk)
set(SFPEW_TRIPLE arm64-apple-ios14.0)
set(SFPEW_LLVM /usr/lib/llvm-17/bin)

set(CMAKE_C_COMPILER   ${SFPEW_LLVM}/clang)
set(CMAKE_CXX_COMPILER ${SFPEW_LLVM}/clang++)
set(CMAKE_OBJC_COMPILER ${SFPEW_LLVM}/clang)
set(CMAKE_AR     ${SFPEW_LLVM}/llvm-ar)
set(CMAKE_RANLIB ${SFPEW_LLVM}/llvm-ranlib)
set(CMAKE_INSTALL_NAME_TOOL ${SFPEW_LLVM}/llvm-install-name-tool)

# 配置阶段不能链接裸可执行文件（iOS 无法在本机运行）
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(SFPEW_COMMON_FLAGS "-target ${SFPEW_TRIPLE} -isysroot ${SFPEW_SDK} -fuse-ld=${SFPEW_LLVM}/ld64.lld")
set(CMAKE_C_FLAGS_INIT   "${SFPEW_COMMON_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${SFPEW_COMMON_FLAGS}")
set(CMAKE_OBJC_FLAGS_INIT "${SFPEW_COMMON_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${SFPEW_COMMON_FLAGS} \
  -Wl,-arch,arm64 -Wl,-platform_version,ios,14.0,26.2 -Wl,-syslibroot,${SFPEW_SDK} \n  -Wl,-install_name,@rpath/libSimpleFPEWrapper.dylib")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${CMAKE_SHARED_LINKER_FLAGS_INIT}")

set(CMAKE_FIND_ROOT_PATH ${SFPEW_SDK})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

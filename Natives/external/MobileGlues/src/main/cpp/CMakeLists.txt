cmake_minimum_required(VERSION 3.22.1)

project("mobileglues")

enable_language(CXX)

set(CMAKE_CXX_STANDARD 20)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(MACOS)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -w -fvisibility=default -funwind-tables -g -D_THREAD_SAFE -fPIC -stdlib=libc++")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -w -g -std=gnu99 -funwind-tables -O3 -fvisibility=hidden")
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static-libstdc++")
else()
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -w -fvisibility=hidden -funwind-tables -g -D_THREAD_SAFE -fPIC")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -w -g -std=gnu99 -funwind-tables -O3 -fvisibility=hidden")
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static-libstdc++")
        set(CMAKE_ANDROID_STL_TYPE c++_static)
endif()

#set(CMAKE_BUILD_TYPE Release)

# ---------------------------------------------------------------------------
# glslang 从源码构建（对齐 Air Task 45/46）
#
# iOS 分支此前链接 libraries/ios/ 下的预编译 .a，二进制里固化的是未打补丁的
# glslang。MC 26.3 的 position_color 顶点着色器会走到
# TParseContext::lValueErrorCheck 的 swizzle 选择器解引用链
# (getAsAggregate() -> getSequence() -> getConstArray()[0])，读到被堆回收字节
# 污染的 constArray 指针（+0xd8）即 SIGSEGV，拖垮整个进程。
#
# 从源码构建后，3rdparty/glslang 上已应用两个防护补丁：
#   * glslang-lvalue-nullguard.patch          —— 解引用前空判 + 越界判
#   * glslang-pool-zero-and-size-guards.patch —— 池块零填充 + constArray 尺寸判
# 解析失败降级为“单个 shader 的 GLSL 错误”，而不是进程死亡。
#
# 仅 iOS：Android 分支继续用 libraries/${ANDROID_ABI}/ 下的预编译 .a，行为不变。
# ---------------------------------------------------------------------------
if(MACOS)
        set(ENABLE_RTTI             ON  CACHE BOOL "Enables RTTI (will be took by glslang)" FORCE)
        set(ENABLE_HLSL             OFF CACHE BOOL "Disable HLSL input for glslang" FORCE)
        set(BUILD_EXTERNAL          OFF CACHE BOOL "Disable build external dependencies for glslang" FORCE)
        set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "Disable glslangValidator/spirv-remap" FORCE)
        set(ENABLE_OPT              OFF CACHE BOOL "Disable SPIRV-Tools opt usage in glslang" FORCE)
        set(GLSLANG_TESTS           OFF CACHE BOOL "Disable glslang tests (needs googletest)" FORCE)
        set(GLSLANG_ENABLE_INSTALL  OFF CACHE BOOL "Disable glslang install rules" FORCE)
        add_subdirectory(3rdparty/glslang)
        # -------------------------------------------------------------------
        # SPIRV-Cross 从源码构建 + 静态链接（对齐参考仓库）
        #
        # iOS 分支此前链接 libraries/ios/ 下预编译的 libspirv-cross-c-shared.dylib：
        # 那份二进制与从源码构建的 glslang 不同源（glslang 已按本仓库 vendored 版本
        # 重建并打上 nullguard / pool-zero 补丁，SPIRV-Cross 却是另一份来历的预编译
        # 产物）。MC 26.3 走 SPIR-V 管线后，MG 内部链路是
        #   glslang 解析 GLSL330 -> SPIR-V -> SPIRV-Cross 生成 ESSL300
        # 两端版本/ABI 不一致会在资源重载阶段把进程拖死：无 .ips、无 hs_err，表现为
        # 静默闪退。参考仓库对该目录 add_subdirectory 并链接静态目标 spirv-cross-c，
        # 两端同源同版本，且不产出共享库（也就不会与 spvc 垫片同名）。
        #
        # 仅 iOS：Android 分支继续用 libraries/${ANDROID_ABI}/ 下的预编译 .so。
        # -------------------------------------------------------------------
        set(SPIRV_CROSS_ENABLE_C_API   ON  CACHE BOOL "Enable C API" FORCE)
        set(SPIRV_CROSS_ENABLE_GLSL    ON  CACHE BOOL "Enable GLSL backend" FORCE)
        set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "Disable reflect" FORCE)
        set(SPIRV_CROSS_ENABLE_HLSL    OFF CACHE BOOL "Disable HLSL backend" FORCE)
        set(SPIRV_CROSS_ENABLE_MSL     OFF CACHE BOOL "Disable MSL backend" FORCE)
        set(SPIRV_CROSS_ENABLE_CPP     OFF CACHE BOOL "Disable C++ API target" FORCE)
        set(SPIRV_CROSS_CLI            OFF CACHE BOOL "Disable CLI binary" FORCE)
        set(SPIRV_CROSS_STATIC         ON  CACHE BOOL "Prefer static libs" FORCE)
        set(SPIRV_CROSS_ENABLE_UTIL    OFF CACHE BOOL "Disable util" FORCE)
        add_subdirectory(3rdparty/SPIRV-Cross)
endif()

set(PROFILING OFF)

find_library(GLSLANG_LIB glslang PATHS ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/)

add_library(${CMAKE_PROJECT_NAME} SHARED
        init.cpp
        main.cpp
        gl/gl_stub.cpp
        gl/gl_native.cpp
        gl/gl.cpp
        gl/envvars.cpp
        gl/log.cpp
        gl/program.cpp
        gl/shader.cpp
        gl/framebuffer.cpp
        gl/texture.cpp
        gl/drawing.cpp
        gl/multidraw.cpp
        gl/mg.cpp
        gl/buffer.cpp
        gl/getter.cpp
        gl/pixel.cpp
        gl/ExtWrappers/DSAWrapper.cpp
        gl/ExtWrappers/MultiBindWrapper.cpp
        gl/glsl/glsl_for_es.cpp
        gl/glsl/cache.cpp
        gl/FSR1/FSR1.cpp
        
        gl/vertexattrib.cpp
        glx/lookup.cpp
        egl/egl.cpp
        egl/loader.cpp
        gles/loader.cpp
        config/cJSON.c
        config/config.cpp
        config/gpu_utils.cpp
        config/settings.cpp
        gl/enable.cpp
        gl/restart.cpp
        gl/transfer.cpp
        gl/random_string_gen.cpp
        egl/context.cpp
        config/stats.cpp
)

target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
        ./includes
        ./3rdparty/glm
        ./3rdparty/xxhash)
target_include_directories(${CMAKE_PROJECT_NAME} PUBLIC ${CMAKE_SOURCE_DIR}/include)

if(MACOS)
        # iOS
        set(iOS_LIB_DIR ${CMAKE_SOURCE_DIR}/libraries/ios)
        target_link_libraries(${CMAKE_PROJECT_NAME}
                glslang::glslang
                spirv-cross-c
                "-F${CMAKE_SOURCE_DIR}/external"
                "-framework libEGL"
                "-framework libGLESv2"
                "-framework Metal"
                "-framework Foundation"
                "-framework QuartzCore"
        )
else()
        # Android
        find_library(GLSLANG_LIB glslang PATHS ${CMAKE_SOURCE_DIR}/libraries/arm64-v8a/)
        target_link_libraries(${CMAKE_PROJECT_NAME}
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libglslang.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libspirv-cross-c-shared.so
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libGenericCodeGen.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libglslang-default-resource-limits.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libMachineIndependent.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libOSDependent.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV-Tools-diff.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV-Tools-link.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV-Tools-lint.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV-Tools-opt.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV-Tools-reduce.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV-Tools.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPIRV.a
                ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libSPVRemapper.a
                android
                log
        )
endif()

if(ANDROID)
    add_custom_command(TARGET ${CMAKE_PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_SOURCE_DIR}/libraries/${ANDROID_ABI}/libspirv-cross-c-shared.so
            $<TARGET_FILE_DIR:${CMAKE_PROJECT_NAME}>
    )
endif()

if (PROFILING)
        find_package(Threads)
        include_directories(${CMAKE_SOURCE_DIR}/3rdparty/perfetto/sdk)
        add_library(perfetto STATIC ${CMAKE_SOURCE_DIR}/3rdparty/perfetto/sdk/perfetto.cc)
        target_link_libraries(${CMAKE_PROJECT_NAME} perfetto ${CMAKE_THREAD_LIBS_INIT})
        target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC PROFILING=1)
endif()

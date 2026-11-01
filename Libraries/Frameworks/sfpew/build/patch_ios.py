# 把上游 CMakeLists 改成可交叉编译到 iOS 的最小三处改动（幂等：先断言再替换）
import io
import sys

# 用法：python3 patch_ios.py <SimpleFPEWrapper 源码根>/CMakeLists.txt
p = sys.argv[1] if len(sys.argv) > 1 else "CMakeLists.txt"
s = io.open(p, encoding="utf-8").read()
orig_len = len(s)

# ① 用例开关：iOS 交叉编译不能在构建后执行产物做 gtest 发现
old_gt = '''set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
add_subdirectory(3rdparty/googletest EXCLUDE_FROM_ALL)
include(GoogleTest)'''
new_gt = '''# 交叉编译（iOS）时没有能运行产物的主机：gtest 的用例发现要在构建后执行二进制，
# 而 iOS 产物只能上真机。这里加开关，宿主构建默认保持原样（全量构建用例）。
option(SFPEW_BUILD_TESTS "Build the GoogleTest suites" ON)
if(SFPEW_BUILD_TESTS)
set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
add_subdirectory(3rdparty/googletest EXCLUDE_FROM_ALL)
include(GoogleTest)
endif()'''
assert s.count(old_gt) == 1
s = s.replace(old_gt, new_gt)

old_if = "\nif(NOT ANDROID)\n"
new_if = "\nif(NOT ANDROID AND SFPEW_BUILD_TESTS)\n"
assert s.count(old_if) == 1
s = s.replace(old_if, new_if)

# ② iOS：libc++ 浮点 to_chars 自 iOS 16.3 起可用，与本仓库的 14.0 部署目标冲突
old_link = '''target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE
        Threads::Threads
        glslang glslang-default-resource-limits SPIRV spirv-cross-glsl spirv-cross-core)'''
new_link = old_link + '''
# iOS：SDK 里 libc++ 的浮点 std::to_chars 自 iOS 16.3 起可用，而本仓库部署目标是 14.0。
# std::format 会无条件实例化浮点格式化路径，所以必须关掉可用性注解，并让该符号由
# ios/sfpew_ios_format_shim.cpp 自带实现，产物在 iOS 14 上才没有 16.3 的运行时依赖。
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE _LIBCPP_DISABLE_AVAILABILITY=1)
        target_sources(${CMAKE_PROJECT_NAME} PRIVATE
                ${CMAKE_SOURCE_DIR}/ios/sfpew_ios_format_shim.cpp)
endif()'''
assert s.count(old_link) == 1
s = s.replace(old_link, new_link)

io.open(p, "w", encoding="utf-8").write(s)
print("patched CMakeLists, delta bytes", len(s) - orig_len)

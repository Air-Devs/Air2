// ============================================================================
//  Air2 —— Linux 交叉链接垫片（只有非 Apple 宿主编时才进目标；Mac 上不进）
// ----------------------------------------------------------------------------
//  为什么需要：clang 为 @available / #available 生成对 __isPlatformVersionAtLeast
//  的调用，该符号在 Apple 平台上由 compiler-rt（libclang_rt.ios.a）提供；用 Linux
//  的 clang 交叉编译到 iOS 时没有这份 runtime，链接会报
//  undefined symbol: ___isPlatformVersionAtLeast。
//
//  语义：参数是 (platform, major, minor, subminor)，返回「当前系统是否 >= 该版本」。
//  我们的部署目标是固定的 iOS 14.0，且所有调用点都是对更高版本 API 的可用性判断；
//  这里按「目标最低版本」如实返回：仅当请求版本 <= 14.0 时为真。
//
//  调用点（谁编译它）：CMakeLists.txt 末尾的 target_sources —— 条件是
//  `NOT CMAKE_HOST_APPLE`，所以 Mac 上的 xcodebuild / CMake 构建**看不到**本文件
//  （那里由 compiler-rt 提供同名符号，重复定义会链接失败）。
// ============================================================================
#include <stdint.h>

int __isPlatformVersionAtLeast(uint32_t platform, uint32_t major,
                               uint32_t minor, uint32_t subminor) {
    (void)platform;
    if (major < 14u) return 1;
    if (major > 14u) return 0;
    if (minor > 0u) return 0;
    return subminor == 0u;
}

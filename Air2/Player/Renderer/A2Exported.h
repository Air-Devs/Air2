/*
 *  A2Exported.h
 *  Air2
 *
 *  主可执行文件对外导出的符号声明。
 *
 *  ★ 为什么需要这个头文件 ★
 *
 *  Java 侧的 GLFW.java：
 *      private static final SharedLibrary GLFW =
 *          new MacOSXLibraryDL(<宿主可执行文件名>, RTLD_DEFAULT);
 *      Init          = apiGetFunctionAddress(GLFW, "pojavInit"),
 *      CreateContext = apiGetFunctionAddress(GLFW, "pojavCreateContext"),
 *      ...
 *
 *  它从宿主主二进制的【动态符号表】里解析这些 pojav* 符号。解析不到就是 NULL，
 *  LWJGL 初始化直接抛：
 *
 *      java.lang.NullPointerException: A required function is missing: pojavInit
 *        at org.lwjgl.glfw.GLFW$Functions.<clinit>(GLFW.java:597)
 *        at org.lwjgl.glfw.GLFW.glfwInit(GLFW.java:794)
 *        at com.mojang.blaze3d.platform.GLX._initGlfw(GLX.java:58)
 *
 *  ★ 为什么 -exported_symbols_list 不够 ★
 *
 *  Xcode 默认开 GCC_SYMBOLS_PRIVATE_EXTERN=YES，即 -fvisibility=hidden：
 *  所有全局符号默认是 hidden（n_type 带 N_PEXT）。此时
 *  -Wl,-exported_symbols_list 只能"点名放行"已经是外部符号的条目，
 *  对 hidden 符号无效 —— 链接器不会把它变成 N_EXT。
 *
 *  实测：加上 -exported_symbols_list 后，主二进制 nm -gU 只剩
 *      0000000100000000 T __mh_execute_header
 *      0000000100006580 T _main
 *  全部 pojav* 都不在动态符号表里（_main 能进是因为 main.m 里显式写了
 *  __attribute__((visibility("default")))）。
 *
 *  所以这些函数必须【逐个】标注 visibility("default")，让编译器把它们
 *  变成外部符号；-exported_symbols_list 再负责把它们放进导出表。
 *
 *  ⚠️ 不要改成 -export_dynamic：那会把【所有】全局符号一并变成启动期强引用，
 *  包括 shaderc_impl_glue.c 引用的 glslang 运行期符号，dyld 启动阶段就报：
 *      symbol not found in flat namespace '_glslang_finalize_process'
 *  App 一启动就闪退。这个坑踩过一次。
 */

#ifndef A2_EXPORTED_H
#define A2_EXPORTED_H

#if defined(__GNUC__) || defined(__clang__)
#define A2_EXPORT __attribute__((visibility("default")))
#else
#define A2_EXPORT
#endif

#endif /* A2_EXPORTED_H */

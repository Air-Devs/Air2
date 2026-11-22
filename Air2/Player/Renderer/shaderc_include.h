//
//  shaderc_include.h
//  Air2
//
//  RenderPearl 26.3 的 #include 文本展开器。
//
//  ## 为什么需要
//
//  MC 26.3 起，RenderPearl（原 Sodium 的光影扩展）允许着色器写
//  `#include <minecraft:colortex0>` 这类伪 include —— 由编译器侧
//  在送进 glslang 之前，先把这些行的内容【文本替换】进来。
//
//  glslang / shaderc 本身不支持这种 include 形式（它只处理标准
//  `#include "file"`，而且需要 resolver 回调）。所以我们在垫片层
//  自己做一遍纯文本展开。
//
//  ## 设计要点
//
//    · 纯 C、只依赖 libc —— 可以在任何线程、任何进程里跑
//    · 不抛异常、不退出：失败一律返回 NULL，由调用方回退到原文
//    · 有深度上限（防递归 include 炸栈）与总量上限（防内存爆）
//    · 保留行号：展开后行数尽量与原文件对齐，编译报错的行号才准
//
//  ## 与 shaderc_shim.c 的关系
//
//    ame_source_has_include()  快速判断要不要走展开（避免每次都扫全文）
//    ame_include_expand()      真正展开，返回 malloc 出来的新 buffer
//

#ifndef AME_SHADERC_INCLUDE_H
#define AME_SHADERC_INCLUDE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// include 解析回调：给定 include 名（如 "minecraft:colortex0"），
/// 返回该 include 的文本内容（malloc 分配的 buffer），失败返回 NULL。
/// 调用方负责用 releaser 释放。
typedef char *(*ame_include_resolver_fn)(void *user_data,
                                         const char *name,
                                         size_t *out_size);

/// 释放 resolver 返回的 buffer
typedef void (*ame_include_releaser_fn)(void *user_data, char *buffer);

/// 快速扫描：源码里是否出现了本模块要处理的 include。
///
/// 只做一次线性扫描，不分配内存。用于在热路径上避免
/// 「没有 include 也去跑一遍完整展开」的开销。
///
/// @param source  源码
/// @param size    长度
/// @return 1 = 有（需要展开），0 = 没有
int ame_source_has_include(const char *source, size_t size);

/// 展开源码里的 include。
///
/// 支持两种写法：
///     #include <name>       （RenderPearl 伪 include）
///     #include "name"       （标准形式，同样交给 resolver 试一次）
///
/// 展开失败（resolver 返回 NULL、超深、超量）的那一行**保留原样**，
/// 让下游 glslang 给出与展开前一致的诊断 —— 绝不静默吞错。
///
/// @param source        原始源码
/// @param source_size   原始长度
/// @param input_file    用于错误信息的文件名（可为 NULL）
/// @param resolver      include 解析回调（必须非 NULL）
/// @param resolver_ud   resolver 用户数据
/// @param releaser      释放回调（可为 NULL）
/// @param releaser_ud   releaser 用户数据
/// @param out_size      输出长度
/// @return 展开后的 buffer（malloc，调用方 free），失败返回 NULL
char *ame_include_expand(const char *source,
                         size_t source_size,
                         const char *input_file,
                         ame_include_resolver_fn resolver,
                         void *resolver_ud,
                         ame_include_releaser_fn releaser,
                         void *releaser_ud,
                         size_t *out_size);

#ifdef __cplusplus
}
#endif

#endif /* AME_SHADERC_INCLUDE_H */

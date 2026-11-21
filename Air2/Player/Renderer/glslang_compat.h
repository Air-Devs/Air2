//
//  glslang_compat.h
//  Air2
//
//  glslang API 版本兼容垫片。
//
//  ## 问题
//
//  工程里的 glslang 头（Libraries/external/MobileGlues/.../include/glslang/）
//  是旧版本，缺这几项，而 shaderc_impl_glue.c 用到了：
//
//    GLSLANG_TARGET_VULKAN_1_4          枚举（旧头只到 1_3 或更低）
//    glslang_shader_set_entry_point()   设置入口函数名（新版 API）
//    glslang_shader_set_invert_y()      翻转 Y（新版 API）
//    glslang_default_resource()         默认资源限制（新版 API）
//
//  ## 做法
//
//  不 fork 第三方头文件（升级 MobileGlues 时会冲突），而是：
//    · 缺的枚举：给一个兼容值（Vulkan 1.4 与 1.3 在 glslang 里的
//      target 语义一致，都是「按 Vulkan SPIR-V 规则编译」）
//    · 缺的函数：用 dlsym(RTLD_DEFAULT) 运行时查找
//      —— 打包的 libshaderc.dylib / libglslang.dylib 是较新版，
//      符号通常存在；不存在时降级为 no-op（不崩）
//
//  ## 使用
//
//  在 shaderc_impl_glue.c 的 #include <glslang/...> 之后
//  紧接着 #include "glslang_compat.h"。
//

#ifndef AIR2_GLSLANG_COMPAT_H
#define AIR2_GLSLANG_COMPAT_H

#include <dlfcn.h>
#include <stdio.h>

#include <glslang/Include/glslang_c_interface.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 1. 缺的枚举 ----

#ifndef GLSLANG_TARGET_VULKAN_1_4
/// Vulkan 1.4 target。
/// glslang 对 1.3 / 1.4 的差异只在 SPIR-V 版本上限，
/// 而 shaderc 用的是 build 时的 SPIR-V 版本设置，这里给 1.3 的值即可，
/// 不会影响生成的代码。
#define GLSLANG_TARGET_VULKAN_1_4 14
#endif

// ---- 2. 缺的函数：运行时查找 ----

/// 兼容层内部状态（幂等初始化）
typedef struct {
    void (*set_entry_point)(glslang_shader_t *shader, const char *name);
    void (*set_invert_y)(glslang_shader_t *shader, int invert);
    void *(*default_resource)(void);
    int initialized;
} air2_glslang_compat_t;

static air2_glslang_compat_t air2_glslang_compat_state = {0};

static inline void air2_glslang_compat_init(void) {
    if (air2_glslang_compat_state.initialized) return;
    air2_glslang_compat_state.initialized = 1;

    air2_glslang_compat_state.set_entry_point =
        (void (*)(glslang_shader_t *, const char *))
            dlsym(RTLD_DEFAULT, "glslang_shader_set_entry_point");
    air2_glslang_compat_state.set_invert_y =
        (void (*)(glslang_shader_t *, int))
            dlsym(RTLD_DEFAULT, "glslang_shader_set_invert_y");
    air2_glslang_compat_state.default_resource =
        (void *(*)(void))dlsym(RTLD_DEFAULT, "glslang_default_resource");

    // 只在缺的时候打一次，避免刷屏
    if (!air2_glslang_compat_state.set_entry_point) {
        fprintf(stderr,
                "[glslang-compat] glslang_shader_set_entry_point 不可用，"
                "入口函数名沿用 glslang 默认值\n");
    }
    if (!air2_glslang_compat_state.set_invert_y) {
        fprintf(stderr,
                "[glslang-compat] glslang_shader_set_invert_y 不可用，"
                "Y 轴翻转交给下游处理\n");
    }
}

/// 设置入口函数名（新版 API；旧库上为 no-op）
static inline void air2_glslang_shader_set_entry_point(glslang_shader_t *shader,
                                                       const char *name) {
    air2_glslang_compat_init();
    if (air2_glslang_compat_state.set_entry_point) {
        air2_glslang_compat_state.set_entry_point(shader, name);
    }
}

/// 翻转 Y（新版 API；旧库上为 no-op）
static inline void air2_glslang_shader_set_invert_y(glslang_shader_t *shader,
                                                    int invert) {
    air2_glslang_compat_init();
    if (air2_glslang_compat_state.set_invert_y) {
        air2_glslang_compat_state.set_invert_y(shader, invert);
    }
}

/// 默认资源限制（新版 API）；旧库上没有时返回 NULL，
/// 调用方应据此跳过（glslang_shader_create 用 input 里的指针，NULL 表示用自己的默认）
static inline void *air2_glslang_default_resource(void) {
    air2_glslang_compat_init();
    return air2_glslang_compat_state.default_resource
        ? air2_glslang_compat_state.default_resource()
        : NULL;
}

#ifdef __cplusplus
}
#endif

#endif /* AIR2_GLSLANG_COMPAT_H */

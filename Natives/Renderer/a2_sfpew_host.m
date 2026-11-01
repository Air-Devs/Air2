// ============================================================================
//  Natives/Renderer/a2_sfpew_host.m
//  Air2 —— ★[A2-SFPEW] SimpleFPEWrapper 宿主接入面实现（见同名头文件）★
// ----------------------------------------------------------------------------
//  实现要点（逐条对应上游接入契约，见头文件）：
//    · 只 `dlopen`/`dlsym`，不链接 SFPEW（LGPL-3.0：随包动态库即可替换）；
//    · 只取三枚 EGL 入口 —— `eglGetProcAddress` / `eglMakeCurrent` / `eglSwapBuffers`，
//      少了任何一枚就**阻断**（半套接管比不接管更难定位）；
//    · 不做任何「初始化 SFPEW」的动作：它的状态靠上下文 current 后的首次 `gl*` 调用建立；
//    · 符号计数读的是**已加载镜像的导出表**（LC_DYLD_INFO_ONLY / LC_DYLD_EXPORTS_Trie 的
//      导出 trie），因此日志里的 `gl=`/`egl=` 是这份二进制的真实导出数，不是我们的白名单长度。
//
//  ★失败一律只记日志 + 返回码★（不 abort / 不抛异常），由 `a2_gl_bridge_attach` 如实阻断。
// ============================================================================
#import "a2_sfpew_host.h"
#import "a2_log.h"

#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/dyld.h>      // _dyld_image_count / _dyld_get_image_header / _dyld_get_image_name
#include <mach-o/loader.h>    // struct mach_header_64 / load_command / linkedit_data_command

// 导出 trie 的独立命令号（ld64 / ld64.lld 的公开常量）。部分 SDK 的 <mach-o/loader.h>
// 不带这条定义（本次构建机上就没有），但它是**命令行号**、与 SDK 版本无关 ⇒ 缺了就自己给。
#ifndef LC_DYLD_EXPORTS_Trie
#define LC_DYLD_EXPORTS_Trie 0x80000033
#endif

const char *const A2SFPEWHostDylibName         = "libSimpleFPEWrapper.dylib";
const char *const A2SFPEWHostBackendEglRelPath = "libEGL.framework/libEGL";
const char *const A2SFPEWHostEnvKey            = "SFPEW_EGL";

// ---------------------------------------------------------------------------
//  SFPEW 接管的 EGL 入口（Khronos 公开 ABI 的最小签名；本层不 import EGL 头）
// ---------------------------------------------------------------------------
typedef void *       (*A2SFPEWeglGetProcAddress)(const char *procname);
typedef unsigned int (*A2SFPEWeglMakeCurrent)(void *dpy, void *draw, void *read, void *ctx);
typedef unsigned int (*A2SFPEWeglSwapBuffers)(void *dpy, void *surface);

static void                     *gSfpewHandle         = NULL;   // 唯一产地：a2_sfpew_host_load
static A2SFPEWeglGetProcAddress  gSfpewGetProcAddress = NULL;
static A2SFPEWeglMakeCurrent     gSfpewMakeCurrent    = NULL;
static A2SFPEWeglSwapBuffers     gSfpewSwapBuffers    = NULL;

/// ★[A2-SFPEW] 兼容层开关★（默认 0 = 关）。唯一写点：`a2_sfpew_host_set_compat_layer`。
/// 读点只有两个：本文件的 `a2_sfpew_host_compat_layer_enabled`，以及 GL 桥 ①d 的那个判据。
static int                       gSfpewCompatLayer    = 0;

/// ★延迟加载（2026-11-01 真机证据：1.16.5 + SFPEW 时 JNI_CreateJavaVM rc=-12）★
///   attach 阶段在建 VM 之前 dlopen 6.5MB 的 SFPEW（含 libc++）会挤掉 libjvm 的
///   64MB debug JIT 映射 ⇒ ENOMEM。⇒ 这里只"登记待载"，第一次真正解析 GL 符号
///   （发生在 VM 建好之后）才 dlopen。
static int                       gSfpewPending        = 0;   // 1 = 已登记，尚未加载
static int                       gSfpewPendingFailed  = 0;   // 1 = 尝试过且失败，不再重试
static int                       gSfpewPendingCompat  = 0;
static NSString                 *gSfpewPendingFrameworks = nil;
static NSString                 *gSfpewPendingBackendPath = nil;

/// 加载实现（两个公开入口共用）：`backendEglPath` 空 ⇒ 包内 ANGLE（独立档位口径）。
static int a2_sfpew_host_perform_load(NSString *frameworksPath, NSString *backendEglPath, int compat);

// ---------------------------------------------------------------------------
//  导出符号计数（只为判据行服务：证明「真的加载了、导出面还是那一套」）
// ---------------------------------------------------------------------------
//  ★为什么不用 dlsym 探测★：SFPEW 导出 567 个 `gl*` + 46 个 `egl*`，逐个 dlsym 需要一张
//  与上游版本绑定的名字表（改一版就过期）。这里直接读镜像自己的导出 trie：
//  名字来自二进制事实，不来自我们的假设。

/// ULEB128（导出 trie 里所有整数都是这个编码）。
static uint64_t a2_sfpew_uleb128(const uint8_t **cursor, const uint8_t *end) {
    uint64_t value = 0;
    int shift = 0;
    const uint8_t *p = *cursor;
    while (p < end && shift <= 63) {
        uint8_t byte = *p++;
        value |= (uint64_t)(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) break;
        shift += 7;
    }
    *cursor = p;
    return value;
}

/// 一条导出名归入哪一档：0 = 不相关，1 = `gl*`，2 = `egl*`。
/// ★导出名带 C 前缀下划线★（`_glBegin`）⇒ 先跳过一位再判前缀。
static int a2_sfpew_export_kind(const char *name) {
    if (name == NULL) return 0;
    if (name[0] == '_') name++;
    if (name[0] == 'e' && name[1] == 'g' && name[2] == 'l' &&
        name[3] >= 'A' && name[3] <= 'Z') return 2;
    if (name[0] == 'g' && name[1] == 'l' && name[2] >= 'A' && name[2] <= 'Z') return 1;
    return 0;
}

/// 递归遍历导出 trie 的一个结点（`prefix` 是已累积的边）。
/// 深度上限 = 64：trie 的最大深度是符号名长度，超过它只可能是数据坏了。
static void a2_sfpew_trie_walk(const uint8_t *trie, const uint8_t *end, uint64_t nodeOffset,
                               const char *prefix, size_t prefixLen,
                               int *glCount, int *eglCount, int depth) {
    if (depth > 64 || nodeOffset >= (uint64_t)(end - trie)) return;
    const uint8_t *p = trie + nodeOffset;

    uint64_t terminalSize = a2_sfpew_uleb128(&p, end);
    if (terminalSize > 0) {
        // 终端负载 = flags[+address][+other]；本函数只关心「这里有一条导出」。
        if (p + terminalSize > end) return;
        char name[192];
        size_t copy = (prefixLen < sizeof(name) - 1) ? prefixLen : sizeof(name) - 1;
        memcpy(name, prefix, copy);
        name[copy] = '\0';
        int kind = a2_sfpew_export_kind(name);
        if (kind == 1 && glCount != NULL) ++(*glCount);
        if (kind == 2 && eglCount != NULL) ++(*eglCount);
        p += terminalSize;
    }
    if (p >= end) return;

    uint8_t childCount = *p++;
    char childPrefix[192];
    for (uint8_t i = 0; i < childCount && p < end; i++) {
        const uint8_t *edge = p;
        while (p < end && *p != '\0') p++;
        if (p >= end) return;
        size_t edgeLen = (size_t)(p - edge);
        p++;                                        // 跳过 NUL
        uint64_t childOffset = a2_sfpew_uleb128(&p, end);

        // 前缀过长 ⇒ 名字必然也超长（trie 的子名恒以父名为前缀）⇒ 既不可能是 gl*/egl*，跳过。
        if (prefixLen + edgeLen + 1 >= sizeof(childPrefix)) continue;
        memcpy(childPrefix, prefix, prefixLen);
        memcpy(childPrefix + prefixLen, edge, edgeLen);
        childPrefix[prefixLen + edgeLen] = '\0';
        a2_sfpew_trie_walk(trie, end, childOffset, childPrefix, prefixLen + edgeLen,
                           glCount, eglCount, depth + 1);
    }
}

/// 已加载镜像的 mach header（按加载路径精确匹配；找不到 ⇒ NULL，不猜）。
static const struct mach_header_64 *a2_sfpew_image_header(const char *imagePath) {
    if (imagePath == NULL) return NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name != NULL && strcmp(name, imagePath) == 0) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

/// 取该镜像的导出 trie 区间。
/// ★两种表示都要认★：`LC_DYLD_EXPORTS_Trie`（独立段）与 `LC_DYLD_INFO_ONLY.export_off/size`
/// （本仓库编出来的 SFPEW 就是后者，见 Libraries/Frameworks/sfpew/README.md 的验收段）。
static int a2_sfpew_export_trie(const struct mach_header_64 *header,
                                const uint8_t **outStart, const uint8_t **outEnd) {
    if (header == NULL) return 0;
    const uint8_t *base = (const uint8_t *)header;
    const uint8_t *cursor = base + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize == 0) return 0;
        if (cmd->cmd == LC_DYLD_EXPORTS_Trie) {
            const struct linkedit_data_command *trie = (const struct linkedit_data_command *)cursor;
            *outStart = base + trie->dataoff;
            *outEnd   = *outStart + trie->datasize;
            return 1;
        }
        if (cmd->cmd == LC_DYLD_INFO_ONLY) {
            const struct dyld_info_command *info = (const struct dyld_info_command *)cursor;
            if (info->export_size > 0) {
                *outStart = base + info->export_off;
                *outEnd   = *outStart + info->export_size;
                return 1;
            }
        }
        cursor += cmd->cmdsize;
    }
    return 0;
}

/// 统计已加载镜像的 `gl*` / `egl*` 导出数；取不到 ⇒ 两个计数都写 -1（★不编数字★）。
static void a2_sfpew_count_exports(const char *imagePath, int *glCount, int *eglCount) {
    if (glCount != NULL) *glCount = -1;
    if (eglCount != NULL) *eglCount = -1;
    const uint8_t *start = NULL;
    const uint8_t *end = NULL;
    if (!a2_sfpew_export_trie(a2_sfpew_image_header(imagePath), &start, &end)) return;
    if (start == NULL || end <= start) return;
    int gl = 0, egl = 0;
    a2_sfpew_trie_walk(start, end, 0, "", 0, &gl, &egl, 0);
    if (glCount != NULL) *glCount = gl;
    if (eglCount != NULL) *eglCount = egl;
}

// ---------------------------------------------------------------------------
//  对外 API（头文件登记了每个符号的唯一调用点）
// ---------------------------------------------------------------------------
int a2_sfpew_host_is_identifier(const char *rendererName) {
    if (rendererName == NULL || rendererName[0] == '\0') return 0;
    return strcmp(rendererName, A2SFPEWHostDylibName) == 0 ? 1 : 0;
}

int a2_sfpew_host_compat_layer_enabled(void) {
    return gSfpewCompatLayer;
}

void a2_sfpew_host_set_compat_layer(int enabled) {
    // ★只登记开关、不做任何副作用★：加载/SFPEW_EGL 全在 ①d 真的要叠加时才发生
    //   ⇒ 关的时候连 env 都不写（与接入前逐位一致）。
    gSfpewCompatLayer = (enabled != 0) ? 1 : 0;
}

/// 登记待载（不 dlopen）：真正加载推迟到 `a2_sfpew_host_ensure_loaded`。
static int a2_sfpew_host_load_impl(NSString *frameworksPath, NSString *backendEglPath, int compat) {
    if (gSfpewHandle != NULL) return 0;                 // 已加载 ⇒ 幂等
    if (gSfpewPendingFailed) return -2;                 // 试过且失败 ⇒ 不反复重试
    if (frameworksPath.length == 0) {
        a2_log_criterion(@"[A2-SFPEW] ★阻断★：frameworksPath 为空 ⇒ 定位不到 %s",
                         A2SFPEWHostDylibName);
        return -1;
    }
    gSfpewPendingFrameworks   = [frameworksPath copy];
    gSfpewPendingBackendPath  = [backendEglPath copy];
    gSfpewPendingCompat       = compat;
    gSfpewPending             = 1;
    a2_log_criterion(@"[A2-SFPEW] 延迟加载已登记（role=%s）⇒ 首次解析 GL 符号时才 dlopen（避开建 VM 前的地址空间竞争）",
                     compat ? "兼容层" : "档位");
    return 0;
}

/// 首次使用时真正 dlopen；失败只记一次，不反复重试、不阻断。
static void a2_sfpew_host_ensure_loaded(void) {
    if (gSfpewHandle != NULL) return;
    if (!gSfpewPending || gSfpewPendingFailed) return;
    int rc = a2_sfpew_host_perform_load(gSfpewPendingFrameworks, gSfpewPendingBackendPath,
                                        gSfpewPendingCompat);
    gSfpewPending = 0;
    if (rc != 0) {
        gSfpewPendingFailed = 1;
        a2_log_criterion(@"[A2-SFPEW] 延迟加载失败 rc=%d ⇒ 本次启动按原渲染路径继续", rc);
    }
}

int a2_sfpew_host_load(NSString *frameworksPath) {
    return a2_sfpew_host_load_impl(frameworksPath, nil, 0);
}

int a2_sfpew_host_load_compat(NSString *frameworksPath, NSString *backendDylibPath) {
    return a2_sfpew_host_load_impl(frameworksPath, backendDylibPath, 1);
}

static int a2_sfpew_host_perform_load(NSString *frameworksPath, NSString *backendEglPath, int compat) {
    // 判据行统一带角色词：真机 grep `[A2-SFPEW]` 后一眼分清是「档位」还是「兼容层」。
    NSString *role = compat ? @"兼容层" : @"档位";
    if (gSfpewHandle != NULL) {
        // ★幂等★：表面改绑会再次 attach；同一进程里这就是同一个镜像，不重复 dlopen / 不重复 setenv。
        a2_log_criterion(@"[A2-SFPEW] %@已在载（复用句柄=%p；不重复 dlopen）", role, gSfpewHandle);
        return 0;
    }
    if (frameworksPath.length == 0) {
        a2_log_criterion(@"[A2-SFPEW] %@★阻断★：frameworksPath 为空 ⇒ 定位不到 %s 与后端 EGL（SFPEW_EGL）",
                         role, A2SFPEWHostDylibName);
        return -1;
    }

    NSString *sfpewPath = [frameworksPath stringByAppendingPathComponent:
                           [NSString stringWithUTF8String:A2SFPEWHostDylibName]];
    // 后端 EGL 的两个来源（★同一份 env、同一个 setenv 写点★）：
    //   · 独立档位：包内 ANGLE（本档位的建面也由宿主用它做）；
    //   · 兼容层  ：传入的**已选渲染器 dylib**（SFPEW 叠在它上面，GL 必须落到同一份实现）。
    NSString *eglPath   = backendEglPath.length
        ? backendEglPath
        : [frameworksPath stringByAppendingPathComponent:
           [NSString stringWithUTF8String:A2SFPEWHostBackendEglRelPath]];

    // 契约⑤：后端 EGL 库名由 `SFPEW_EGL` 给出（上游默认是 Android 的 libEGL.so）。
    // ★写点只在这里★，且只有「本档位/兼容层真的要加载」才会执行到 —— 不开 ⇒ 进程环境一字不动。
    setenv(A2SFPEWHostEnvKey, eglPath.UTF8String, 1);
    a2_log_criterion(@"[A2-SFPEW] %@后端 EGL=%s（SFPEW_EGL）", role, eglPath.UTF8String);

    // 契约②：★RTLD_LOCAL★ —— 它的 `gl*` 不许进 flat namespace（否则会和兼容底的解析抢符号）。
    void *handle = dlopen(sfpewPath.UTF8String, RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        const char *err = dlerror();
        a2_log_criterion(@"[A2-SFPEW] %@★阻断★：dlopen 失败 %s（%s）",
                         role, sfpewPath.UTF8String, err ? err : "(dlerror 无输出)");
        return -2;
    }

    A2SFPEWeglGetProcAddress getProcAddress =
        (A2SFPEWeglGetProcAddress)dlsym(handle, "eglGetProcAddress");
    A2SFPEWeglMakeCurrent makeCurrent =
        (A2SFPEWeglMakeCurrent)dlsym(handle, "eglMakeCurrent");
    A2SFPEWeglSwapBuffers swapBuffers =
        (A2SFPEWeglSwapBuffers)dlsym(handle, "eglSwapBuffers");
    if (getProcAddress == NULL || makeCurrent == NULL || swapBuffers == NULL) {
        a2_log_criterion(@"[A2-SFPEW] %@★阻断★：缺入口（eglGetProcAddress=%d eglMakeCurrent=%d "
                         @"eglSwapBuffers=%d）⇒ %s 不是预期的 SFPEW 构建",
                         role,
                         getProcAddress != NULL ? 1 : 0,
                         makeCurrent != NULL ? 1 : 0,
                         swapBuffers != NULL ? 1 : 0,
                         sfpewPath.UTF8String);
        dlclose(handle);   // 半成品不留：句柄与符号都不落地
        return -3;
    }

    gSfpewGetProcAddress = getProcAddress;
    gSfpewMakeCurrent    = makeCurrent;
    gSfpewSwapBuffers    = swapBuffers;
    gSfpewHandle         = handle;

    int glCount = -1, eglCount = -1;
    a2_sfpew_count_exports(sfpewPath.UTF8String, &glCount, &eglCount);
    a2_log_criterion(@"[A2-SFPEW] %@已加载 path=%s 符号 gl=%d egl=%d",
                     role, sfpewPath.UTF8String, glCount, eglCount);
    return 0;
}

void *a2_sfpew_host_handle(void) {
    a2_sfpew_host_ensure_loaded();
    return gSfpewHandle;
}

void *a2_sfpew_host_getprocaddress(const char *name) {
    a2_sfpew_host_ensure_loaded();
    if (name == NULL || gSfpewHandle == NULL) return NULL;
    void *symbol = (gSfpewGetProcAddress != NULL) ? gSfpewGetProcAddress(name) : NULL;
    if (symbol == NULL) symbol = dlsym(gSfpewHandle, name);
    return symbol;
}

unsigned int a2_sfpew_host_egl_make_current(void *dpy, void *draw, void *read, void *ctx) {
    a2_sfpew_host_ensure_loaded();
    if (gSfpewMakeCurrent == NULL) return 0;
    return gSfpewMakeCurrent(dpy, draw, read, ctx);
}

unsigned int a2_sfpew_host_egl_swap_buffers(void *dpy, void *surf) {
    a2_sfpew_host_ensure_loaded();
    if (gSfpewSwapBuffers == NULL) return 0;
    return gSfpewSwapBuffers(dpy, surf);
}

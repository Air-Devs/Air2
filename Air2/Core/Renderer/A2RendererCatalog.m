//
//  A2RendererCatalog.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件（候选表 + 存在性判定）。★只用 Foundation★（Core 不得 import UIKit）。
//
//  候选表的「来源」逐条登记在 docs/ARCHITECTURE.md 的 [RENDER-SEL] 一节：
//    · libmetallum.dylib      —— 随仓 `Libraries/Renderers/`（Air2 自研，GPL-3.0）
//    · libgl4es_114.dylib     —— 复用老线 `runtime_native`（GPL-3.0，同一家族血统）
//    · 其余为**未内置**保留入口（源码在本机老线 `ThirdParty/`，本仓未随包）
//
//  ★为什么「未内置」的候选也留在这里★：用户要的是「看得见全表、选到没用要如实报」，
//  不是「悄悄从列表里消失」。是否内置由 `+isBundled:frameworksPath:` 现算（不缓存），
//  UI 用它打「未内置」标记，启动链用它做阻断判据。
//

#import "A2RendererCatalog.h"

#include <dlfcn.h>   // ★内置判定 = 文件存在 + 能 dlopen★（与 a2_renderer_load_named 同一口径）

@implementation A2RendererCatalog

NSString *const A2RendererNGGL4ESKWDylibName = @"libnggl4es_kw.dylib";
NSString *const A2RendererHostEGLDylibName  = @"libeagl.dylib";

+ (NSArray<A2Renderer *> *)allCandidates {
    // ★顺序即 UI 顺序★：主推（按默认优先级） → 兼容底 → 实验（未内置）。
    static NSArray<A2Renderer *> *candidates = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        candidates = @[
            [[A2Renderer alloc] initWithIdentifier:@"libmetallum.dylib"
                                       displayName:@"Metal (metallum)"
                                         dylibName:@"libmetallum.dylib"
                                             notes:@"recommended"],
            // ★系统 GLES 3.0（EAGL）★ —— 1.17+ 的**临时默认项**（2026-10-31 决定）：
            //   EGL = 本二进制里的假 EGL（宿主提供），GL 层 = MobileGlues。
            //   ★不是包内的 dylib★：标识只是「选择了哪条链路」的稳定值，
            //   包内存在性由 +bundleDiagnosisForCandidate: 落到 GL 层上判（见那里的说明）。
            [[A2Renderer alloc] initWithIdentifier:A2RendererHostEGLDylibName
                                       displayName:@"系统 GLES 3.0 (EAGL)"
                                         dylibName:A2RendererHostEGLDylibName
                                             notes:@"recommended"],
            [[A2Renderer alloc] initWithIdentifier:@"libgl4es_114.dylib"
                                       displayName:@"GL4ES"
                                         dylibName:@"libgl4es_114.dylib"
                                             notes:@"compat"],
            // ★NG-GL4ES / KW★（Krypton Wrapper）—— ≤1.12.2 的默认固定管线后端。
            //   与上面那只老线 GL4ES 并列「兼容底」：两支都能接 GL 1.x/2.x，但这一只
            //   要求宿主显式初始化（见头文件注释），所以是**独立标识**而不是替换。
            [[A2Renderer alloc] initWithIdentifier:A2RendererNGGL4ESKWDylibName
                                       displayName:@"NG-GL4ES / KW"
                                         dylibName:A2RendererNGGL4ESKWDylibName
                                             notes:@"compat"],
            [[A2Renderer alloc] initWithIdentifier:@"libmobileglues.dylib"
                                       displayName:@"MobileGlues"
                                         dylibName:@"libmobileglues.dylib"
                                             notes:@"experimental"],
            [[A2Renderer alloc] initWithIdentifier:@"libnggl4es.dylib"
                                       displayName:@"NG-GL4ES"
                                         dylibName:@"libnggl4es.dylib"
                                             notes:@"experimental"],
            [[A2Renderer alloc] initWithIdentifier:@"libMoltenVK.dylib"
                                       displayName:@"MoltenVK"
                                         dylibName:@"libMoltenVK.dylib"
                                             notes:@"experimental"],
            [[A2Renderer alloc] initWithIdentifier:@"libtinygl4angle.dylib"
                                       displayName:@"ANGLE (tinygl4)"
                                         dylibName:@"libtinygl4angle.dylib"
                                             notes:@"experimental"],
        ];
    });
    return candidates;
}

+ (A2Renderer *)defaultCandidate {
    // 主推 = 表首（自研 Metal）。★默认项要合理★：它是包内一定随仓的那一个。
    return [self allCandidates].firstObject;
}

+ (nullable A2Renderer *)candidateForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    for (A2Renderer *r in [self allCandidates]) {
        if ([r.identifier isEqualToString:identifier]) return r;
    }
    return nil;
}

+ (A2RendererTier)tierForIdentifier:(NSString *)identifier {
    A2Renderer *r = [self candidateForIdentifier:identifier];
    if (r == nil) return A2RendererTierExperimental;   // 没登记的（如版本级覆盖的旧值）不猜成主推
    if ([r.notes isEqualToString:@"recommended"]) return A2RendererTierRecommended;
    if ([r.notes isEqualToString:@"compat"])      return A2RendererTierCompat;
    return A2RendererTierExperimental;
}

+ (NSString *)tierLocalizationKeyForTier:(A2RendererTier)tier {
    switch (tier) {
        case A2RendererTierRecommended:  return @"runtime.tier.recommended";
        case A2RendererTierCompat:       return @"runtime.tier.compat";
        case A2RendererTierExperimental: return @"runtime.tier.experimental";
    }
    return @"runtime.tier.experimental";
}

+ (NSString *)nameLocalizationKeyForIdentifier:(NSString *)identifier {
    // 稳定的 key（与 identifier 一一对应）：libgl4es_114.dylib → runtime.renderer.gl4es_114
    // 归一化规则固定（小写 + 非 [a-z0-9] 折成下划线 + 去掉 lib 前缀与扩展名），
    // 由 tests/Runtime 断言「每个候选的 key 在四语表里都存在」。
    if (identifier.length == 0) return @"";
    NSString *s = identifier.lowercaseString;
    if ([s hasPrefix:@"lib"]) s = [s substringFromIndex:3];
    if ([s hasSuffix:@".dylib"]) s = [s substringToIndex:s.length - 6];
    NSMutableString *slug = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        [slug appendString:alnum ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return [@"runtime.renderer." stringByAppendingString:slug];
}

+ (A2RendererGLClass)glClassForIdentifier:(NSString *)identifier {
    // ★按标识的稳定词根判定（与 A2LegacyProfile.rendererSupportsFixedPipeline: 同一套词根口径）★
    if (identifier.length == 0) return A2RendererGLClassNotGL;
    NSString *lower = identifier.lowercaseString;

    // ★宿主 EGL 后端（系统 GLES 3.0 / EAGL）★：对 MC 而言它是「GL 3.2+」档 ——
    //   宿主那一侧只有 ES 3.0，但 GL 层是 MobileGlues（对外报 GL 4.5）⇒ 归「现代」
    //   这一档（固定管线/非 GL 两档都不适用）。显式列出，不靠下面那条兜底默认。
    if ([identifier isEqualToString:A2RendererHostEGLDylibName]) return A2RendererGLClassModern;

    // MoltenVK = Vulkan ICD：导出 vkGetInstanceProcAddr 一族，**没有 EGL、也没有 gl\***。
    // 把它当 GL 库下发 ⇒ LWJGL 取 gl* 符号必失败（闪退）；它也永远不可能进 EGL 白名单。
    if ([lower containsString:@"moltenvk"]) return A2RendererGLClassNotGL;

    // gl4es 家族（libgl4es_114 / libnggl4es）= GL 1.x/2.x → GLES 的固定管线翻译层：
    //   对外报的 GL_VERSION 上限是 2.1，拿不到 1.13+ 要的 3.2 core（core profile 语义也没有）。
    if ([lower containsString:@"gl4es"]) return A2RendererGLClassFixedOnly;

    // metallum（Metal 直通，靠 agent 换 GpuBackend）/ mobileglues（GL 4.5）。
    // ★libtinygl4angle 不在此列做硬判据★：矩阵只到「[静态-能力] ANGLE 只报 ES 语义」，
    //   没有实测上限，硬拦会误杀；它的风险由 26.3 宿主表面那条（⑦）与真机日志处理。
    return A2RendererGLClassModern;
}

+ (NSInteger)requiredJavaMajorForIdentifier:(NSString *)identifier
                                  versionID:(NSString *)versionID
                                    mcMajor:(NSInteger)mcMajor
                                    mcMinor:(NSInteger)mcMinor {
    // ★只对 metallum 有硬下限★（类集主版本写死在 jar 里，是二进制事实，不是配置）：
    //   java-17 × 26.x ⇒ premain 的 MetallumAgent(65) 加载失败 ⇒ 建 VM 失败；
    //   java-21 × 26.x ⇒ agent 起得来、classes26x(69) 一个也 define 不上 ⇒ 黑屏。
    if (identifier.length == 0) return 0;
    if (![identifier.lowercaseString containsString:@"metallum"]) return 0;

    if (mcMajor >= 26) return 25;
    // 1.21.11 是唯一有类集（65）的 1.21.x 档位 ⇒ 下限 21；其它 1.21.x 无类集（另由告警处理）。
    if (mcMajor == 1 && mcMinor == 21 && [versionID hasPrefix:@"1.21.11"]) return 21;
    return 0;
}

+ (nullable NSString *)bundleDiagnosisForCandidate:(A2Renderer *)candidate
                                    frameworksPath:(nullable NSString *)frameworksPath {
    // 未内置 = 包内 Frameworks 里没有这个文件 / 有了也 dlopen 不起来。frameworksPath 为空时**不猜**。
    if (candidate == nil || frameworksPath.length == 0) return @"包内未解析出 Frameworks 路径";
    NSString *name = candidate.dylibName ?: candidate.identifier;
    if (name.length == 0) return @"候选没有 dylib 文件名";

    // ★宿主 EGL 后端★：EGL 那一半在本二进制里（没有、也不需要 `Frameworks/libeagl.dylib` 这个文件），
    //   但它的 **GL 层是 MobileGlues** —— 少了 GL 层照样跑不起来。
    //   ⇒ 判据落在 GL 层候选上（同一套「文件在 + 能 dlopen」口径，不另造一套），
    //     原因串前面加一句「宿主 EGL 的 GL 层不可用」，让阻断文案说清缺的是哪一半。
    if ([candidate.identifier isEqualToString:A2RendererHostEGLDylibName]) {
        A2Renderer *glLayer = [self candidateForIdentifier:@"libmobileglues.dylib"];
        if (glLayer == nil) return @"宿主 EGL 的 GL 层候选未登记";
        NSString *why = [self bundleDiagnosisForCandidate:glLayer frameworksPath:frameworksPath];
        return why ? [@"宿主 EGL 的 GL 层不可用：" stringByAppendingString:why] : nil;
    }

    NSString *path = [frameworksPath stringByAppendingPathComponent:name];

    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || isDir) {
        return [NSString stringWithFormat:@"包内缺 Frameworks/%@", name];
    }

    // ★判据与真正的加载处同一口径★（a2_renderer_load_named 用 RTLD_LAZY|RTLD_GLOBAL）：
    //   能 dlopen 才算「内置」——「文件在、依赖缺」正是 GL4ES 那种「入了也不合格」的形态。
    //   包内文件只读 ⇒ 结果按路径缓存（避免设置页每行都真的 dlopen 一次）。
    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSString *cached = cache[path];
        if (cached != nil) return cached.length > 0 ? cached : nil;
    }

    NSString *reason = nil;
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle == NULL) {
        const char *err = dlerror();
        reason = [NSString stringWithFormat:@"dlopen 失败：%s", err ? err : "(dlerror 无输出)"];
    } else {
        dlclose(handle);   // 只做判定；真正加载由 Natives/Renderer 负责（不在这里留句柄）
    }
    @synchronized (cache) {
        cache[path] = reason ?: @"";
    }
    return reason;
}

+ (BOOL)isBundled:(A2Renderer *)candidate frameworksPath:(nullable NSString *)frameworksPath {
    return [self bundleDiagnosisForCandidate:candidate frameworksPath:frameworksPath] == nil;
}

+ (void)registerAllCandidatesIntoRegistry:(A2Renderers *)registry {
    if (registry == nil) return;
    for (A2Renderer *r in [self allCandidates]) {
        [registry registerRenderer:r];   // 同标识重复登记返回 NO，幂等
    }
}

@end

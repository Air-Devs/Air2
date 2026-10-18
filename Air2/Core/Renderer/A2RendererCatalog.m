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

@implementation A2RendererCatalog

+ (NSArray<A2Renderer *> *)allCandidates {
    // ★顺序即 UI 顺序★：主推 → 兼容底 → 实验（未内置）。
    static NSArray<A2Renderer *> *candidates = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        candidates = @[
            [[A2Renderer alloc] initWithIdentifier:@"libmetallum.dylib"
                                       displayName:@"Metal (metallum)"
                                         dylibName:@"libmetallum.dylib"
                                             notes:@"recommended"],
            [[A2Renderer alloc] initWithIdentifier:@"libgl4es_114.dylib"
                                       displayName:@"GL4ES"
                                         dylibName:@"libgl4es_114.dylib"
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
            [[A2Renderer alloc] initWithIdentifier:@"libOSMesa.8.dylib"
                                       displayName:@"OSMesa (Zink)"
                                         dylibName:@"libOSMesa.8.dylib"
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
    // ★2026-10-18 实验★ 临时改用 gl4es：GL 桥只负责 EGL/GL 系渲染器，
    //   选 metallum(Metal) 时桥"按设计跳过"⇒ 没有 EGL 上下文 ⇒ MC 报
    //   "There is no OpenGL context current in the current thread"。
    //   先用 gl4es 验证能否出画面，之后再把 metallum 接回来。
    for (A2Renderer *r in [self allCandidates]) {
        if ([r.identifier isEqualToString:@"libgl4es_114.dylib"]) return r;
    }
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

+ (BOOL)isBundled:(A2Renderer *)candidate frameworksPath:(nullable NSString *)frameworksPath {
    // 未内置 = 包内 Frameworks 里没有这个文件。frameworksPath 为空时**不猜**（回 NO）。
    if (candidate == nil || frameworksPath.length == 0) return NO;
    NSString *name = candidate.dylibName ?: candidate.identifier;
    if (name.length == 0) return NO;
    NSString *path = [frameworksPath stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return exists && !isDir;
}

+ (void)registerAllCandidatesIntoRegistry:(A2Renderers *)registry {
    if (registry == nil) return;
    for (A2Renderer *r in [self allCandidates]) {
        [registry registerRenderer:r];   // 同标识重复登记返回 NO，幂等
    }
}

@end

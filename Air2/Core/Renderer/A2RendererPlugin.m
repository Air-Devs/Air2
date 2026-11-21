//
//  A2RendererPlugin.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2RendererPlugin.m
//  Air2
//

#import "A2RendererPlugin.h"
#import "A2RendererLibraryLayout.h"
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import "A2Logger.h"
#include <string.h>

#pragma mark - 环境变量规格

@implementation A2RendererEnvSpec

- (NSString *)resolvedValueWithUserSettings:(NSDictionary<NSString *, id> *)settings {
    switch (self.type) {
        case A2RendererEnvTypeNormal:
            return self.value;

        case A2RendererEnvTypeToggleable: {
            // 用户没设置过就用默认值
            NSNumber *saved = settings[[self.key stringByAppendingString:@".enabled"]];
            BOOL on = saved ? saved.boolValue : self.defaultOn;
            return on ? self.value : nil;
        }

        case A2RendererEnvTypeSelectable: {
            NSString *v = settings[self.key];
            return v.length ? v : self.defaultValue;
        }

        case A2RendererEnvTypeCustomizable: {
            NSString *v = settings[self.key];
            if (v.length) return v;
            return self.customDefault.length ? self.customDefault : nil;
        }
    }
    return nil;
}

+ (instancetype)fromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2RendererEnvSpec *spec = [A2RendererEnvSpec new];
    spec.key = json[@"key"] ?: @"";
    if (spec.key.length == 0) return nil;

    NSString *type = json[@"type"];
    if ([type isEqualToString:@"ToggleableEnv"]) {
        spec.type = A2RendererEnvTypeToggleable;
        spec.value = json[@"value"];
        spec.title = json[@"title"];
        spec.defaultOn = [json[@"toggle"] boolValue];
    } else if ([type isEqualToString:@"SelectableEnv"]) {
        spec.type = A2RendererEnvTypeSelectable;
        spec.title = json[@"title"];
        NSDictionary *items = json[@"items"];
        if ([items isKindOfClass:NSDictionary.class]) {
            spec.defaultValue = items[@"defaultValue"];
            spec.selectableValues = [items[@"values"] isKindOfClass:NSArray.class]
                ? items[@"values"] : @[];
        }
    } else if ([type isEqualToString:@"CustomizableEnv"]) {
        spec.type = A2RendererEnvTypeCustomizable;
        spec.title = json[@"title"];
        spec.customDefault = json[@"defaultValue"];
    } else {
        // NormalEnv 或省略 type（按 FCL 的语义，缺省就是固定值）
        spec.type = A2RendererEnvTypeNormal;
        spec.value = json[@"value"];
    }

    return spec;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<Env %@ type=%ld>", self.key, (long)self.type];
}

@end

#pragma mark - 渲染器插件

@interface A2RendererPlugin ()
@property (nonatomic, copy, readwrite) NSString *installPath;
@property (nonatomic, assign, readwrite) A2RendererAvailability availability;
@property (nonatomic, copy, nullable, readwrite) NSString *unavailableReason;
@property (nonatomic, copy, nullable, readwrite) NSString *iconPath;
@property (nonatomic, assign, readwrite, getter=isImported) BOOL imported;
@end

@implementation A2RendererPlugin

+ (instancetype)pluginWithManifest:(NSDictionary *)json installPath:(NSString *)installPath {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    if (![installPath isKindOfClass:NSString.class]) return nil;

    A2RendererPlugin *p = [A2RendererPlugin new];
    p.installPath = installPath;
    p.imported = YES;

    p.formatVersion = [json[@"formatVersion"] integerValue];
    p.rendererID = json[@"rendererId"] ?: @"";
    p.displayName = json[@"displayName"] ?: p.rendererID;
    p.pluginDescription = [json[@"description"] isKindOfClass:NSString.class] ? json[@"description"] : nil;
    p.version = [json[@"version"] isKindOfClass:NSString.class] ? json[@"version"] : nil;
    p.author = [json[@"author"] isKindOfClass:NSString.class] ? json[@"author"] : nil;
    p.homepage = [json[@"homepage"] isKindOfClass:NSString.class] ? json[@"homepage"] : nil;

    p.rendererGLPath = json[@"rendererGLPath"] ?: @"";
    p.rendererEGLPath = json[@"rendererEGLPath"] ?: @"";

    // 库布局：优先读显式声明，否则按路径推断
    //
    // 推断规则：
    //   eglPath 为空                         → combined（不需要单独 EGL）
    //   eglPath == glPath                    → combined（同一个文件）
    //   两个路径都非空且不同                  → separate
    //
    // 注意「eglPath 为空」推断成 combined 而不是 glOnly ——
    // 因为实际遇到的（MobileGlues / NG-GL4ES）都是合并库，
    // glOnly 是少见情况，应该显式声明。
    NSString *layout = json[@"libraryLayout"];
    if ([layout isEqualToString:@"separate"]) {
        p.libraryLayout = A2RendererLibraryLayoutSeparate;
    } else if ([layout isEqualToString:@"glOnly"] ||
               [layout isEqualToString:@"gl-only"]) {
        p.libraryLayout = A2RendererLibraryLayoutGLOny;
    } else if ([layout isEqualToString:@"combined"]) {
        p.libraryLayout = A2RendererLibraryLayoutCombined;
    } else {
        // 未声明 → 推断
        if (p.rendererEGLPath.length == 0 ||
            [p.rendererEGLPath isEqualToString:p.rendererGLPath]) {
            p.libraryLayout = A2RendererLibraryLayoutCombined;
        } else {
            p.libraryLayout = A2RendererLibraryLayoutSeparate;
        }
    }
    p.dlopenLibPaths = [json[@"dlopenLibPaths"] isKindOfClass:NSArray.class]
        ? json[@"dlopenLibPaths"] : @[];
    p.minMCVer = [json[@"minMCVer"] isKindOfClass:NSString.class] ? json[@"minMCVer"] : nil;
    p.maxMCVer = [json[@"maxMCVer"] isKindOfClass:NSString.class] ? json[@"maxMCVer"] : nil;

    // env 列表
    NSMutableArray<A2RendererEnvSpec *> *specs = [NSMutableArray array];
    if ([json[@"env"] isKindOfClass:NSArray.class]) {
        for (NSDictionary *e in json[@"env"]) {
            A2RendererEnvSpec *spec = [A2RendererEnvSpec fromJSON:e];
            if (spec) [specs addObject:spec];
        }
    }
    p.envSpecs = specs;

    // iOS 扩展块
    NSDictionary *ios = json[@"ios"];
    if ([ios isKindOfClass:NSDictionary.class]) {
        p.minSystemVersion = ios[@"minSystemVersion"];
        p.requiresJIT = [ios[@"requiresJIT"] boolValue];
        p.iosNotes = ios[@"notes"];
    }

    // 必填校验
    if (p.rendererID.length == 0 || p.rendererGLPath.length == 0) {
        [A2Logger warning:@"A2RendererPlugin"
                  message:[NSString stringWithFormat:
                           @"manifest 缺必填字段（rendererId/rendererGLPath），跳过 %@", installPath]];
        return nil;
    }
    if (p.formatVersion != 1) {
        [A2Logger warning:@"A2RendererPlugin"
                  message:[NSString stringWithFormat:
                           @"不认识的 formatVersion=%ld，仍尝试按 v1 解析", (long)p.formatVersion]];
    }

    return p;
}

#pragma mark - 路径

- (NSString *)absoluteGLPath {
    if (self.rendererGLPath.length == 0) return @"";
    if ([self.rendererGLPath hasPrefix:@"/"]) return self.rendererGLPath;
    return [self.installPath stringByAppendingPathComponent:self.rendererGLPath];
}

- (NSString *)absoluteEGLPath {
    // 合并库：EGL 就在 GL 那个文件里
    if (self.libraryLayout == A2RendererLibraryLayoutCombined ||
        self.libraryLayout == A2RendererLibraryLayoutGLOny) {
        return self.rendererEGLPath.length ? [self resolvePath:self.rendererEGLPath] : nil;
    }

    if (self.rendererEGLPath.length == 0) return nil;
    return [self resolvePath:self.rendererEGLPath];
}

- (NSString *)resolvePath:(NSString *)rel {
    if ([rel hasPrefix:@"/"]) return rel;
    return [self.installPath stringByAppendingPathComponent:rel];
}

#pragma mark - 校验

- (void)validate {
    // 1. 图标
    NSString *icon = [self.installPath stringByAppendingPathComponent:@"icon.png"];
    if ([NSFileManager.defaultManager fileExistsAtPath:icon]) {
        self.iconPath = icon;
    }

    // 2. 文件存在性
    NSString *gl = self.absoluteGLPath;
    if (![NSFileManager.defaultManager fileExistsAtPath:gl]) {
        self.availability = A2RendererAvailabilityMissingLib;
        self.unavailableReason = [NSString stringWithFormat:
            @"找不到 GL 库：%@", self.rendererGLPath];
        return;
    }

    // 只有分离库才需要单独检查 EGL 文件
    if (A2RendererLayoutHasSeparateEGL(self.libraryLayout)) {
        NSString *egl = self.absoluteEGLPath;
        if (egl.length == 0) {
            self.availability = A2RendererAvailabilityMissingLib;
            self.unavailableReason = @"声明为分离库（separate），但没有指定 rendererEGLPath";
            return;
        }
        if (![NSFileManager.defaultManager fileExistsAtPath:egl]) {
            self.availability = A2RendererAvailabilityMissingLib;
            self.unavailableReason = [NSString stringWithFormat:
                @"找不到 EGL 库：%@", self.rendererEGLPath];
            return;
        }
    }

    // 3. 架构检查（避免 dlopen 时报难懂的错误）
    NSString *archError = nil;
    if (![A2RendererPlugin isArm64MachO:gl error:&archError]) {
        self.availability = A2RendererAvailabilityArchitectureMismatch;
        self.unavailableReason = archError ?: @"库的架构不是 arm64";
        return;
    }

    // 4. ⚠️ 不做 dlopen 探测
    //
    // 这里曾经调 dlopen 来"验证能否加载"，结果导入时直接闪退：
    //
    //   libMobileGlues.dylib  init_target_egl + 336
    //   libMobileGlues.dylib  proc_init + 124       ← 构造函数
    //   dyld                  findAndRunAllInitializers
    //
    // 【根因】dlopen 会真的执行库的 __attribute__((constructor))。
    // MobileGlues 的 proc_init 在初始化时调 init_target_egl，
    // 它假设 EGL 上下文已就绪 —— 但我们只是"探测"，没有 EGL 环境，
    // 于是 SIGSEGV。
    //
    // 【结论】导入阶段的校验只能是【静态的】：
    //   文件存在 + 架构正确 + 声明的符号存在（读 Mach-O 符号表）。
    // 真正的加载放到启动游戏时，那时才有完整的 EGL 环境。
    //
    // 这是 iOS 上容易踩的坑：dlopen 不是"检查文件"的轻量操作。

    // 检查必需符号是否在导出表里（不执行代码）
    NSString *missing = nil;
    if (![A2RendererPlugin machO:gl exportsSymbol:"glGetString" missing:&missing]) {
        self.availability = A2RendererAvailabilityMissingDependency;
        self.unavailableReason = missing ?: @"库中没有 glGetString 导出符号";
        return;
    }

    self.availability = A2RendererAvailabilityAvailable;
    self.unavailableReason = nil;
}

/// 检查是不是 arm64 的 Mach-O。
///
/// 提前查这个的理由：如果是 x86 或 Android 的 .so，
/// dlopen 只会给一个含糊的 "not a mach-o file"，
/// 用户不知道是「拿错了平台的文件」。这里给出明确提示。
+ (BOOL)isArm64MachO:(NSString *)path error:(NSString **)error {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) {
        if (error) *error = @"文件无法读取";
        return NO;
    }

    NSData *head = [fh readDataOfLength:8];
    [fh closeFile];
    if (head.length < 8) {
        if (error) *error = @"文件太小，不是有效的动态库";
        return NO;
    }

    const uint8_t *b = head.bytes;

    // Mach-O 64 位小端：0xCF 0xFA 0xED 0xFE
    BOOL isMachO64LE = (b[0] == 0xCF && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE);
    // Mach-O 32 位小端：0xCE 0xFA 0xED 0xFE
    BOOL isMachO32LE = (b[0] == 0xCE && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE);
    // FAT 二进制：0xCA 0xFE 0xBA 0xBE
    BOOL isFat = (b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && b[3] == 0xBE);

    // ELF（Android 的 .so）：0x7F 'E' 'L' 'F'
    BOOL isELF = (b[0] == 0x7F && b[1] == 'E' && b[2] == 'L' && b[3] == 'F');

    if (isELF) {
        if (error) *error = @"这是 Android 的 .so 文件，iOS 不能加载（需要重新编译成 .dylib）";
        return NO;
    }
    if (isMachO32LE) {
        if (error) *error = @"这是 32 位库，当前设备需要 64 位";
        return NO;
    }
    if (isFat) {
        // 包含多个架构，交给 dlopen 自己选
        return YES;
    }
    if (!isMachO64LE) {
        if (error) *error = @"不是有效的 Mach-O 动态库";
        return NO;
    }
    return YES;
}

/// 检查 Mach-O 是否导出指定符号 —— **纯静态，不执行任何库代码**。
///
/// 为什么不用 dlopen：
///   dlopen 会执行库的 constructor（__attribute__((constructor))）。
///   很多 GL 库的 constructor 假设 EGL 上下文已就绪 ——
///   检查阶段没有那个环境，直接 SIGSEGV。
///   （实测：导入 MobileGlues 时崩在 init_target_egl）
///
/// 实现：解析 Mach-O 的 LC_SYMTAB 与 LC_DYSYMTAB，
/// 在前两者的导出符号里找名字。
///
/// @param missing 失败时填具体原因
+ (BOOL)machO:(NSString *)path
    exportsSymbol:(const char *)symbolName
          missing:(NSString **)missing {

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (!data || data.length < 32) {
        if (missing) *missing = @"文件无法读取或太小";
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;

    // ---- 解析 mach_header_64 ----
    // magic 0xFEEDFACF（小端读作 0xCFFAEDFE）
    uint32_t magic = 0;
    memcpy(&magic, bytes, 4);
    if (magic != 0xFEEDFACF) {
        if (missing) *missing = @"不是 64 位 Mach-O";
        return NO;
    }

    uint32_t ncmds = 0;
    memcpy(&ncmds, bytes + 16, 4);

    NSUInteger offset = 32;   // mach_header_64 大小
    uint32_t symtabOff = 0, nsyms = 0, strtabOff = 0, strtabSize = 0;
    BOOL foundSymtab = NO;

    for (uint32_t i = 0; i < ncmds && offset + 8 <= len; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        memcpy(&cmd, bytes + offset, 4);
        memcpy(&cmdsize, bytes + offset + 4, 4);
        if (cmdsize < 8 || offset + cmdsize > len) break;

        if (cmd == LC_SYMTAB && offset + 24 <= len) {
            memcpy(&symtabOff, bytes + offset + 8, 4);
            memcpy(&nsyms, bytes + offset + 12, 4);
            memcpy(&strtabOff, bytes + offset + 16, 4);
            memcpy(&strtabSize, bytes + offset + 20, 4);
            foundSymtab = YES;
        }
        offset += cmdsize;
    }

    if (!foundSymtab) {
        if (missing) *missing = @"Mach-O 里没有符号表";
        return NO;
    }

    if (symtabOff + (NSUInteger)nsyms * 16 > len || strtabOff + strtabSize > len) {
        if (missing) *missing = @"符号表越界（文件可能损坏）";
        return NO;
    }

    // ---- 遍历 nlist_64，找匹配的导出符号 ----
    size_t wantLen = strlen(symbolName);
    for (uint32_t i = 0; i < nsyms; i++) {
        NSUInteger entry = symtabOff + (NSUInteger)i * 16;

        uint32_t strx = 0;
        uint8_t type = 0;
        memcpy(&strx, bytes + entry, 4);
        memcpy(&type, bytes + entry + 4, 1);

        // N_EXT（0x01）= 外部符号，N_TYPE 为 N_SECT 表示定义在本文件
        if (!(type & 0x01)) continue;           // 只要外部可见的

        NSUInteger nameOff = strtabOff + strx;
        if (nameOff >= len) continue;

        // 读到   为止
        const char *name = (const char *)(bytes + nameOff);
        NSUInteger maxRead = MIN(strtabSize - strx, (uint32_t)(len - nameOff));
        size_t actual = strnlen(name, maxRead);

        // Mach-O 的 C 符号带下划线前缀
        if (actual == wantLen + 1 && name[0] == '_' &&
            memcmp(name + 1, symbolName, wantLen) == 0) {
            return YES;
        }
        // 也接受不带前缀的（某些编译配置）
        if (actual == wantLen && memcmp(name, symbolName, wantLen) == 0) {
            return YES;
        }
    }

    if (missing) {
        *missing = [NSString stringWithFormat:
            @"库中没有导出 %s 符号 —— 可能不是 GL 实现库，或符号被 strip 掉了",
            symbolName];
    }
    return NO;
}


@end

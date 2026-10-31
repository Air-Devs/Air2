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
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach-o/nlist.h>
#include <string.h>
#import "A2Log.h"

/// CPU 类型 arm64：`<mach/machine.h>` 的 `CPU_TYPE_ARM64`，
/// 按 `CPU_ARCH_ABI64(0x01000000) | CPU_TYPE_ARM(12)` 展开成常量，
/// 免得为一个定义把 mach/machine.h 拖进来（那套宏在各 SDK 里名字不完全一致）。
static const uint32_t A2CPUTypeARM64 = 0x0100000C;

/// 大端 32 位读（fat 头与 fat_arch 全是大端，不管宿主）
static uint32_t A2ReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | ((uint32_t)p[3]);
}

#pragma mark - Mach-O 头解析（架构判定与符号扫描共用）

/// 校验一段「64 位 Mach-O 切片」的头：必须是 arm64；requireDylib 时还必须是 MH_DYLIB。
static BOOL A2CheckArm64SliceHeader(const uint8_t *slice,
                                    NSUInteger sliceLen,
                                    BOOL requireDylib,
                                    NSString * _Nullable * _Nullable error) {
    if (sliceLen < 32) {
        if (error) *error = @"Mach-O 头不完整（文件可能被截断）";
        return NO;
    }
    // 小端 64 位 magic：CF FA ED FE
    if (!(slice[0] == 0xCF && slice[1] == 0xFA && slice[2] == 0xED && slice[3] == 0xFE)) {
        if (error) *error = @"该切片不是 64 位 Mach-O（可能是 32 位或已损坏）";
        return NO;
    }
    uint32_t cputype = 0;
    memcpy(&cputype, slice + 4, 4);
    if (cputype != A2CPUTypeARM64) {
        if (error) {
            *error = [NSString stringWithFormat:
                      @"架构不是 arm64（cputype=0x%08x）—— iOS 设备加载不了", cputype];
        }
        return NO;
    }
    if (!requireDylib) return YES;

    uint32_t filetype = 0;
    memcpy(&filetype, slice + 12, 4);
    if (filetype != MH_DYLIB) {
        if (error) {
            *error = [NSString stringWithFormat:
                      @"这不是 .dylib（Mach-O filetype=%u：1=目标文件 2=可执行 8=bundle）",
                      filetype];
        }
        return NO;
    }
    return YES;
}

/// 在 Mach-O 文件里定位「arm64 切片」的字节区间。
///
/// thin arm64 ⇒ (0, data.length)；fat ⇒ 遍历 fat_arch 找 CPU_TYPE_ARM64 那一项。
///
/// ★这一份解析同时服务三件事★：架构闸门（isIOSArm64DylibAtPath:）、
/// 符号扫描（machO:exportsSymbol:）。旧实现是一份 thin-only 的 magic 判定
/// 加快一份独立的符号表解析 —— 于是 fat 包永远走「交给 dlopen 自己选」，
/// 符号扫描也直接对着整份文件算偏移。合成一份之后只有一个地方需要维护。
static BOOL A2MachOArm64Slice(NSData *data,
                              NSUInteger *outOffset,
                              NSUInteger *outLength,
                              BOOL requireDylib,
                              NSString * _Nullable * _Nullable error) {
    const uint8_t *b = data.bytes;
    NSUInteger len = data.length;
    if (b == NULL || len < 8) {
        if (error) *error = @"文件太小，不是有效的动态库";
        return NO;
    }

    // Android 的 .so：7F 45 4C 46
    if (b[0] == 0x7F && b[1] == 'E' && b[2] == 'L' && b[3] == 'F') {
        if (error) *error = @"这是 Android 的 .so 文件，iOS 不能加载（需要重新编译成 .dylib）";
        return NO;
    }
    // 32 位 Mach-O（小端）：CE FA ED FE
    if (b[0] == 0xCE && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE) {
        if (error) *error = @"这是 32 位库，当前设备需要 64 位";
        return NO;
    }

    // thin 64 位（小端）：CF FA ED FE
    if (b[0] == 0xCF && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE) {
        if (!A2CheckArm64SliceHeader(b, len, requireDylib, error)) return NO;
        *outOffset = 0;
        *outLength = len;
        return YES;
    }

    // fat（大端头）：CA FE BA BE
    if (!(b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && b[3] == 0xBE)) {
        if (error) *error = @"不是有效的 Mach-O 动态库";
        return NO;
    }
    if (len < 8) {
        if (error) *error = @"fat 头不完整";
        return NO;
    }

    uint32_t nfat = A2ReadBE32(b + 4);
    if (nfat == 0 || nfat > 32) {
        if (error) *error = @"fat 头损坏（架构数量不合理）";
        return NO;
    }
    NSUInteger tableEnd = 8 + (NSUInteger)nfat * 20;   // fat_arch = 20 字节
    if (tableEnd > len) {
        if (error) *error = @"fat 架构表越界（文件可能损坏）";
        return NO;
    }

    for (uint32_t i = 0; i < nfat; i++) {
        const uint8_t *entry = b + 8 + (NSUInteger)i * 20;
        uint32_t cputype = A2ReadBE32(entry);
        uint32_t offset  = A2ReadBE32(entry + 8);
        uint32_t size    = A2ReadBE32(entry + 12);
        if (cputype != A2CPUTypeARM64) continue;
        if (offset == 0 || size == 0 || (NSUInteger)offset + (NSUInteger)size > len) {
            if (error) *error = @"arm64 切片越界（文件可能损坏）";
            return NO;
        }
        if (!A2CheckArm64SliceHeader(b + offset, size, requireDylib, error)) return NO;
        *outOffset = offset;
        *outLength = size;
        return YES;
    }

    if (error) *error = @"fat 包里没有 arm64 切片（可能只编了 x86_64）";
    return NO;
}

#pragma mark - 环境变量规格

@implementation A2RendererEnvSpec

+ (instancetype)specWithJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    NSString *key = json[@"key"];
    if (![key isKindOfClass:NSString.class] || key.length == 0) return nil;

    A2RendererEnvSpec *spec = [A2RendererEnvSpec new];
    spec.key = key;

    NSString *type = [json[@"type"] isKindOfClass:NSString.class] ? json[@"type"] : nil;
    if ([type isEqualToString:@"ToggleableEnv"]) {
        spec.type = A2RendererEnvTypeToggleable;
        spec.value = [json[@"value"] isKindOfClass:NSString.class] ? json[@"value"] : nil;
        spec.title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        spec.defaultOn = [json[@"toggle"] boolValue];
    } else if ([type isEqualToString:@"SelectableEnv"]) {
        spec.type = A2RendererEnvTypeSelectable;
        spec.title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        NSDictionary *items = [json[@"items"] isKindOfClass:NSDictionary.class] ? json[@"items"] : nil;
        if (items) {
            spec.defaultValue = [items[@"defaultValue"] isKindOfClass:NSString.class]
                ? items[@"defaultValue"] : nil;
            spec.selectableValues = [items[@"values"] isKindOfClass:NSArray.class]
                ? items[@"values"] : @[];
        } else {
            spec.selectableValues = @[];
        }
    } else if ([type isEqualToString:@"CustomizableEnv"]) {
        spec.type = A2RendererEnvTypeCustomizable;
        spec.title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        spec.customDefault = [json[@"defaultValue"] isKindOfClass:NSString.class]
            ? json[@"defaultValue"] : nil;
    } else {
        // NormalEnv，或省略 type（FCL 语义：缺省就是固定值）
        spec.type = A2RendererEnvTypeNormal;
        spec.value = [json[@"value"] isKindOfClass:NSString.class] ? json[@"value"] : nil;
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
@property (nonatomic, copy, nullable, readwrite) NSString *sourceFileName;
@end

@implementation A2RendererPlugin

#pragma mark 构造

+ (instancetype)pluginWithManifest:(NSDictionary *)json
                       installPath:(NSString *)installPath {
    return [self pluginWithManifest:json installPath:installPath error:NULL];
}

+ (instancetype)pluginWithManifest:(NSDictionary *)json
                       installPath:(NSString *)installPath
                             error:(NSString * _Nullable * _Nullable)error {
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"manifest 不是一个 JSON 对象";
        return nil;
    }
    if (![installPath isKindOfClass:NSString.class] || installPath.length == 0) {
        if (error) *error = @"内部错误：安装目录为空";
        return nil;
    }

    // ---- formatVersion：只认 1 ----
    // ★宁可拒装，不要猜★：将来 v2 加了新字段时，按 v1 硬读会装出一个
    // 「字段都在、语义全错」的插件 —— 那种失败在启动时才暴露，比装不上难查得多。
    id fv = json[@"formatVersion"];
    if (![fv isKindOfClass:NSNumber.class]) {
        if (error) *error = @"manifest 缺必填字段 formatVersion";
        return nil;
    }
    NSInteger formatVersion = [fv integerValue];
    if (formatVersion != 1) {
        if (error) {
            *error = [NSString stringWithFormat:
                      @"formatVersion=%ld 不认识（本版本只支持 1）", (long)formatVersion];
        }
        return nil;
    }

    // ---- 必填字符串 ----
    NSString *(^requiredString)(NSString *) = ^NSString *(NSString *key) {
        id v = json[key];
        if (![v isKindOfClass:NSString.class] || [v length] == 0) return nil;
        return (NSString *)v;
    };
    NSString *(^optionalString)(NSString *) = ^NSString *(NSString *key) {
        id v = json[key];
        return [v isKindOfClass:NSString.class] && [v length] > 0 ? (NSString *)v : nil;
    };

    NSString *rendererID = requiredString(@"rendererId");
    if (rendererID.length == 0) {
        if (error) *error = @"manifest 缺必填字段 rendererId";
        return nil;
    }
    if (![self isSafeRendererID:rendererID]) {
        if (error) {
            *error = [NSString stringWithFormat:
                      @"rendererId 不合法（只允许字母/数字/._-，≤64 字符，不能以点开头）：%@",
                      rendererID];
        }
        return nil;
    }

    NSString *displayName = requiredString(@"displayName");
    if (displayName.length == 0) {
        if (error) *error = @"manifest 缺必填字段 displayName";
        return nil;
    }

    NSString *glPath = requiredString(@"rendererGLPath");
    if (glPath.length == 0) {
        if (error) *error = @"manifest 缺必填字段 rendererGLPath";
        return nil;
    }
    if (![self isSafePackageRelativePath:glPath]) {
        if (error) {
            *error = [NSString stringWithFormat:
                      @"rendererGLPath 不是合法的包内相对路径（不能绝对路径 / 含 .. / 反斜杠）：%@",
                      glPath];
        }
        return nil;
    }

    NSString *eglPath = optionalString(@"rendererEGLPath");
    if (eglPath.length > 0 && ![self isSafePackageRelativePath:eglPath]) {
        if (error) {
            *error = [NSString stringWithFormat:
                      @"rendererEGLPath 不是合法的包内相对路径（不能绝对路径 / 含 .. / 反斜杠）：%@",
                      eglPath];
        }
        return nil;
    }

    A2RendererPlugin *p = [[self alloc] init];
    p.installPath = installPath;
    p.imported = YES;
    p.formatVersion = formatVersion;
    p.rendererID = rendererID;
    p.displayName = displayName;
    p.pluginDescription = optionalString(@"description");
    p.version = optionalString(@"version");
    p.author = optionalString(@"author");
    p.homepage = optionalString(@"homepage");
    p.rendererGLPath = glPath;
    p.rendererEGLPath = eglPath ?: @"";
    p.minMCVer = optionalString(@"minMCVer");
    p.maxMCVer = optionalString(@"maxMCVer");

    // ---- 库布局：优先读显式声明，否则按路径推断 ----
    //
    // 推断规则（见 docs/RENDERER_PLUGIN_SPEC.md 3.1.1）：
    //   eglPath 为空        → combined（不需要单独 EGL）
    //   eglPath == glPath   → combined（同一个文件）
    //   两个都非空且不同     → separate
    //
    // 「eglPath 为空」推断成 combined 而不是 glOnly —— 因为实际遇到的
    // （MobileGlues / NG-GL4ES）都是合并库，glOnly 少见，应显式声明。
    NSString *layout = [json[@"libraryLayout"] isKindOfClass:NSString.class]
        ? json[@"libraryLayout"] : nil;
    if ([layout isEqualToString:@"separate"]) {
        p.libraryLayout = A2RendererLibraryLayoutSeparate;
    } else if ([layout isEqualToString:@"glOnly"] || [layout isEqualToString:@"gl-only"]) {
        p.libraryLayout = A2RendererLibraryLayoutGLOny;
    } else if ([layout isEqualToString:@"combined"]) {
        p.libraryLayout = A2RendererLibraryLayoutCombined;
    } else {
        if (layout.length > 0) {
            [A2Log log:@"renderer-plugin: 未知 libraryLayout=%@，按路径推断", layout];
        }
        if (eglPath.length == 0 || [eglPath isEqualToString:glPath]) {
            p.libraryLayout = A2RendererLibraryLayoutCombined;
        } else {
            p.libraryLayout = A2RendererLibraryLayoutSeparate;
        }
    }
    if (A2RendererLayoutHasSeparateEGL(p.libraryLayout) && p.rendererEGLPath.length == 0) {
        if (error) *error = @"libraryLayout 为 separate 时必须给 rendererEGLPath";
        return nil;
    }

    // ---- 预加载依赖库 ----
    NSMutableArray<NSString *> *deps = [NSMutableArray array];
    if (json[@"dlopenLibPaths"] != nil) {
        if (![json[@"dlopenLibPaths"] isKindOfClass:NSArray.class]) {
            if (error) *error = @"dlopenLibPaths 必须是字符串数组";
            return nil;
        }
        for (id item in json[@"dlopenLibPaths"]) {
            if (![item isKindOfClass:NSString.class] ||
                ![self isSafePackageRelativePath:(NSString *)item]) {
                if (error) {
                    *error = [NSString stringWithFormat:
                              @"dlopenLibPaths 里有不合法的路径：%@", item];
                }
                return nil;
            }
            [deps addObject:item];
        }
    }
    p.dlopenLibPaths = deps;

    // ---- env ----
    NSMutableArray<A2RendererEnvSpec *> *specs = [NSMutableArray array];
    if ([json[@"env"] isKindOfClass:NSArray.class]) {
        for (id e in json[@"env"]) {
            A2RendererEnvSpec *spec = [A2RendererEnvSpec specWithJSON:e];
            if (spec) {
                [specs addObject:spec];
            } else {
                [A2Log log:@"renderer-plugin: env 条目缺 key，已跳过"];
            }
        }
    }
    p.envSpecs = specs;

    // ---- ios 扩展块 ----
    if ([json[@"ios"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *ios = json[@"ios"];
        p.minSystemVersion = [ios[@"minSystemVersion"] isKindOfClass:NSString.class]
            ? ios[@"minSystemVersion"] : nil;
        p.requiresJIT = [ios[@"requiresJIT"] boolValue];
        p.iosNotes = [ios[@"notes"] isKindOfClass:NSString.class] ? ios[@"notes"] : nil;
    }

    return p;
}

- (void)attachSourceFileName:(NSString *)sourceFileName {
    self.sourceFileName = sourceFileName;
}

#pragma mark 路径

- (NSString *)absoluteGLPath {
    if (self.rendererGLPath.length == 0) return @"";
    return [self resolvePath:self.rendererGLPath];
}

- (NSString *)absoluteEGLPath {
    // 合并库 / 仅 GL：EGL 要么就在 GL 那个文件里，要么根本不需要。
    // glOnly 且显式给了 EGL 路径时仍然返回它（调用方自己按布局决定用不用）。
    if (self.rendererEGLPath.length == 0) return nil;
    return [self resolvePath:self.rendererEGLPath];
}

- (NSString *)resolvePath:(NSString *)rel {
    // 构造阶段已拒掉绝对路径与 `..`；这里只做拼接，不再重复校验
    // （唯一判据在 isSafePackageRelativePath:，两处各写一份就会漂移）。
    return [self.installPath stringByAppendingPathComponent:rel];
}

#pragma mark 校验

/// 一个库文件的问题描述（nil = 没问题），同时给出应该落到哪个 availability。
+ (nullable NSString *)problemForLibraryAtPath:(NSString *)path
                                   installPath:(NSString *)installPath
                                      relative:(NSString *)relative
                                         label:(NSString *)label
                                  availability:(A2RendererAvailability *)availability {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSDictionary<NSFileAttributeKey, id> *attrs =
        [fm attributesOfItemAtPath:path error:nil];
    if (attrs == nil) {
        *availability = A2RendererAvailabilityMissingLib;
        return [NSString stringWithFormat:@"找不到 %@ 库：%@", label, relative];
    }

    NSString *type = attrs[NSFileType];
    // ★拒绝符号链接★：链接能让「安在插件目录里的文件」实际指向任意位置
    // （越权读 + 卸载时删错东西），导入口径是硬拒，不当成可用。
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        *availability = A2RendererAvailabilityMissingLib;
        return [NSString stringWithFormat:@"%@ 库是符号链接，拒绝加载：%@", label, relative];
    }
    if (![type isEqualToString:NSFileTypeRegular]) {
        *availability = A2RendererAvailabilityMissingLib;
        return [NSString stringWithFormat:@"%@ 库不是普通文件：%@", label, relative];
    }

    // 复核落盘位置：镜像里的路径必须真的在插件目录内（防链接 / 防拼接出错）
    NSString *root = installPath.stringByResolvingSymlinksInPath;
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    if (![resolved hasPrefix:[root stringByAppendingString:@"/"]]) {
        *availability = A2RendererAvailabilityMissingLib;
        return [NSString stringWithFormat:@"%@ 库跑到插件目录外了：%@", label, relative];
    }

    NSString *archProblem = nil;
    if (![self isIOSArm64DylibAtPath:path error:&archProblem]) {
        *availability = A2RendererAvailabilityArchitectureMismatch;
        return [NSString stringWithFormat:@"%@ 库不可用：%@（%@）",
                label, archProblem ?: @"不是 iOS dylib", relative];
    }

    *availability = A2RendererAvailabilityAvailable;
    return nil;
}

- (void)validate {
    // 1. 图标（可选）
    NSString *icon = [self.installPath stringByAppendingPathComponent:@"icon.png"];
    self.iconPath = [NSFileManager.defaultManager fileExistsAtPath:icon] ? icon : nil;

    A2RendererAvailability code = A2RendererAvailabilityAvailable;

    // 2. GL 库
    NSString *problem = [A2RendererPlugin problemForLibraryAtPath:self.absoluteGLPath
                                                     installPath:self.installPath
                                                        relative:self.rendererGLPath
                                                           label:@"GL"
                                                    availability:&code];
    if (problem) {
        self.availability = code;
        self.unavailableReason = problem;
        return;
    }

    // 3. EGL 库（只有分离库才需要单独文件）
    if (A2RendererLayoutHasSeparateEGL(self.libraryLayout)) {
        NSString *egl = self.absoluteEGLPath;
        problem = [A2RendererPlugin problemForLibraryAtPath:egl
                                               installPath:self.installPath
                                                  relative:self.rendererEGLPath
                                                     label:@"EGL"
                                              availability:&code];
        if (problem) {
            self.availability = code;
            self.unavailableReason = problem;
            return;
        }
    }

    // 4. 预加载依赖库
    for (NSString *rel in self.dlopenLibPaths) {
        problem = [A2RendererPlugin problemForLibraryAtPath:[self resolvePath:rel]
                                               installPath:self.installPath
                                                  relative:rel
                                                     label:@"依赖"
                                              availability:&code];
        if (problem) {
            self.availability = code;
            self.unavailableReason = problem;
            return;
        }
    }

    // 5. ⚠️ 不做 dlopen 探测
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
    //   文件存在 + 架构正确 + 声明的符号在导出表里（读 Mach-O 符号表）。
    // 真正的加载放到启动游戏时，那时才有完整的 EGL 环境。
    //
    // 这是 iOS 上容易踩的坑：dlopen 不是"检查文件"的轻量操作。
    NSString *missing = nil;
    if (![A2RendererPlugin machO:self.absoluteGLPath exportsSymbol:"glGetString" missing:&missing]) {
        self.availability = A2RendererAvailabilityMissingDependency;
        self.unavailableReason = missing ?: @"库中没有 glGetString 导出符号";
        return;
    }

    self.availability = A2RendererAvailabilityAvailable;
    self.unavailableReason = nil;
}

#pragma mark 路径判据

+ (BOOL)isSafePackageRelativePath:(NSString *)path {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    if (path.length > 512) return NO;
    if ([path hasPrefix:@"/"]) return NO;               // 绝对路径
    if ([path containsString:@"\\"]) return NO;         // 反斜杠（Windows 打的包）
    for (NSUInteger i = 0; i < path.length; i++) {
        unichar c = [path characterAtIndex:i];
        if (c < 0x20 || c == 0x7F) return NO;           // 控制字符
        if (c == 0xFF0E || c == 0xFF0F) return NO;      // 全角.与/：换个长相绕过滤器
    }
    for (NSString *seg in [path componentsSeparatedByString:@"/"]) {
        if (seg.length == 0) return NO;                 // "a//b"、"/a"、结尾斜杠
        if ([seg isEqualToString:@"."] || [seg isEqualToString:@".."]) return NO;
        if ([seg hasSuffix:@"."] || [seg hasSuffix:@" "]) return NO;
    }
    return YES;
}

+ (BOOL)isSafeRendererID:(NSString *)rendererID {
    if (![rendererID isKindOfClass:NSString.class]) return NO;
    if (rendererID.length == 0 || rendererID.length > 64) return NO;
    if ([rendererID hasPrefix:@"."]) return NO;         // 隐藏目录 / 上跳的变体
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [rendererID rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

#pragma mark Mach-O

+ (BOOL)isIOSArm64DylibAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)error {
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data == nil) {
        if (error) *error = @"文件无法读取";
        return NO;
    }
    NSUInteger offset = 0, length = 0;
    return A2MachOArm64Slice(data, &offset, &length, YES, error);
}

+ (BOOL)machO:(NSString *)path
    exportsSymbol:(const char *)symbolName
          missing:(NSString * _Nullable * _Nullable)missing {
    if (symbolName == NULL || symbolName[0] == '\0') {
        if (missing) *missing = @"内部错误：符号名为空";
        return NO;
    }

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data == nil) {
        if (missing) *missing = @"文件无法读取";
        return NO;
    }

    // 先定位 arm64 切片：fat 包里符号表偏移是相对**切片**的，不是相对文件的。
    // （旧实现对整份文件按 thin 解析 ⇒ fat 包一律「没有符号表」。）
    NSUInteger sliceOffset = 0, sliceLength = 0;
    NSString *why = nil;
    if (!A2MachOArm64Slice(data, &sliceOffset, &sliceLength, NO, &why)) {
        if (missing) *missing = why ?: @"不是 64 位 Mach-O";
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes + sliceOffset;
    const NSUInteger len = sliceLength;
    if (len < 32) {
        if (missing) *missing = @"Mach-O 头不完整";
        return NO;
    }

    uint32_t ncmds = 0;
    memcpy(&ncmds, bytes + 16, 4);

    NSUInteger cursor = 32;              // mach_header_64 大小
    uint32_t symtabOff = 0, nsyms = 0, strtabOff = 0, strtabSize = 0;
    BOOL foundSymtab = NO;

    for (uint32_t i = 0; i < ncmds && cursor + 8 <= len; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        memcpy(&cmd, bytes + cursor, 4);
        memcpy(&cmdsize, bytes + cursor + 4, 4);
        if (cmdsize < 8 || cursor + cmdsize > len) break;

        if (cmd == LC_SYMTAB) {
            if (cursor + 24 > len) break;
            memcpy(&symtabOff, bytes + cursor + 8, 4);
            memcpy(&nsyms, bytes + cursor + 12, 4);
            memcpy(&strtabOff, bytes + cursor + 16, 4);
            memcpy(&strtabSize, bytes + cursor + 20, 4);
            foundSymtab = YES;
        }
        cursor += cmdsize;
    }

    if (!foundSymtab) {
        if (missing) *missing = @"Mach-O 里没有符号表（可能被完全 strip）";
        return NO;
    }

    uint64_t symEnd = (uint64_t)symtabOff + (uint64_t)nsyms * 16;   // nlist_64 = 16 字节
    uint64_t strEnd = (uint64_t)strtabOff + (uint64_t)strtabSize;
    if (symEnd > len || strEnd > len) {
        if (missing) *missing = @"符号表越界（文件可能损坏）";
        return NO;
    }

    const size_t wantLen = strlen(symbolName);
    for (uint32_t i = 0; i < nsyms; i++) {
        NSUInteger entry = (NSUInteger)symtabOff + (NSUInteger)i * 16;
        uint32_t strx = 0;
        uint8_t type = 0;
        memcpy(&strx, bytes + entry, 4);
        memcpy(&type, bytes + entry + 4, 1);

        // ★必须「外部可见 + 定义在本文件（N_SECT）」★
        // 只看 N_EXT 会把「只是 import 了 glGetString 的壳」也当成 GL 实现 ——
        // 那正是「能装上、一启动就缺符号」的假通过。
        if (!(type & N_EXT)) continue;
        if ((type & N_TYPE) != N_SECT) continue;

        if (strx >= strtabSize) continue;
        NSUInteger nameOff = (NSUInteger)strtabOff + strx;
        if (nameOff >= len) continue;

        const char *name = (const char *)(bytes + nameOff);
        NSUInteger maxRead = MIN((NSUInteger)strtabSize - strx, len - nameOff);
        size_t actual = strnlen(name, maxRead);

        // Mach-O 的 C 符号带下划线前缀
        if (actual == wantLen + 1 && name[0] == '_' &&
            memcmp(name + 1, symbolName, wantLen) == 0) {
            return YES;
        }
        if (actual == wantLen && memcmp(name, symbolName, wantLen) == 0) {
            return YES;
        }
    }

    if (missing) {
        *missing = [NSString stringWithFormat:
            @"库没有导出 %s（可能不是 GL 实现库，或符号被 strip）", symbolName];
    }
    return NO;
}

@end

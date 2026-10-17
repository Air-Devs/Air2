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

    // 4. 实际 dlopen 探测
    NSString *reason = nil;
    A2RendererAvailability result = [A2RendererPlugin probeLoadabilityOfPath:gl reason:&reason];
    self.availability = result;
    self.unavailableReason = reason;
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

/// 尝试 dlopen 探测。
///
/// 不保留句柄 —— 只判断「能不能加载」。
/// 真正的加载在启动游戏时进行（那时才知道要设置哪些环境变量）。
+ (A2RendererAvailability)probeLoadabilityOfPath:(NSString *)path
                                          reason:(NSString * _Nullable * _Nullable)reason {

    // 注意：这里必须真的 dlopen 一次 —— 签名校验只有在实际加载时才做。
    // RTLD_LAZY 让符号解析推迟，避免因缺符号而误判为加载失败。
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);

    if (handle) {
        dlclose(handle);
        if (reason) *reason = nil;
        return A2RendererAvailabilityAvailable;
    }

    const char *err = dlerror();
    NSString *errStr = err ? [NSString stringWithUTF8String:err] : @"未知错误";

    if (reason) {
        // 把系统的错误翻译成用户能理解的话
        if ([errStr containsString:@"code signature"] ||
            [errStr containsString:@"Code Signature"] ||
            [errStr containsString:@"invalid"] ) {
            *reason = @"代码签名无效。iOS 要求动态库与 App 使用相同签名 —— "
                       "TrollStore/越狱环境可直接使用，其他环境需重新签名。";
        } else if ([errStr containsString:@"not found"] ||
                   [errStr containsString:@"image not found"]) {
            *reason = [NSString stringWithFormat:@"缺少依赖库：%@", errStr];
        } else {
            *reason = errStr;
        }
    }

    if ([errStr containsString:@"code signature"] || [errStr containsString:@"invalid"]) {
        return A2RendererAvailabilitySignatureInvalid;
    }
    if ([errStr containsString:@"not found"] || [errStr containsString:@"image not found"]) {
        return A2RendererAvailabilityMissingDependency;
    }
    return A2RendererAvailabilityUnknown;
}

@end

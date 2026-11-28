//
//  A2RendererDiscovery.m
//  Air2
//

#import "A2RendererDiscovery.h"
#import "A2Logger.h"
#import <dlfcn.h>

/// dylib 内嵌 manifest 的导出符号名。
///
/// 渲染器作者在源码里写上：
///
///     __attribute__((visibility("default")))
///     const char *air2RendererManifestJSON(void) {
///         return "{\"formatVersion\":1,\"rendererID\":\"com.example.mygl\",...}";
///     }
///
/// 编出来的 dylib 就能被自动识别，不需要额外 .json 文件。
/// 不用这个符号也不影响使用 —— 会退化成「未识别」，用户仍可手动选用。
static const char *const kA2RendererManifestSymbol = "air2RendererManifestJSON";

/// 只读探测用的标记字符串。
///
/// 在 dlopen 之前先按字节搜这个标记：搜不到就说明这大概率不是 Air2 渲染器，
/// 不去 dlopen 它 —— dlopen 会执行 dylib 的 constructor，等于给未知文件
/// 一次任意代码执行机会。搜得到才进入第 2 级。
static const char *const kA2RendererMagicMarker = "AIR2RENDERER";

/// 目录里 dylib 的扫描深度上限。用户可能把渲染器放在子目录里（比如
/// 一个包里带主库 + 若干依赖），允许一层子目录，但不无限递归。
static const NSInteger kA2DiscoveryMaxDepth = 2;


// 属性在 .h 里是 readonly（发现结果不该被外部改写），
// 但本文件需要写它们，所以在这里重声明为 readwrite。
// 直接写 item->_xxx 会因为「跨类的私有 ivar」编译失败：
//     error: instance variable '_libraryPath' is private
@interface A2DiscoveredRenderer ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *displayName;
@property (nonatomic, copy, readwrite, nullable) NSString *summary;
@property (nonatomic, copy, readwrite) NSString *libraryPath;
@property (nonatomic, copy, readwrite) NSString *sourceName;
@property (nonatomic, assign, readwrite) BOOL hasManifest;
@property (nonatomic, copy, readwrite, nullable) NSDictionary *manifest;
@property (nonatomic, copy, readwrite, nullable) NSString *minMCVersion;
@property (nonatomic, copy, readwrite, nullable) NSString *maxMCVersion;
@end

@implementation A2DiscoveredRenderer
@end


@implementation A2RendererDiscovery {
    NSTimeInterval _lastScanDuration;
    NSArray<NSString *> *_scannedDirectories;
}

+ (instancetype)shared {
    static A2RendererDiscovery *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [A2RendererDiscovery new]; });
    return s;
}

- (NSTimeInterval)lastScanDuration { return _lastScanDuration; }
- (NSArray<NSString *> *)scannedDirectories { return _scannedDirectories ?: @[]; }

#pragma mark - 扫描

- (NSArray<A2DiscoveredRenderer *> *)scan {
    return [self scanSkippingLibraryPaths:nil];
}

- (NSArray<A2DiscoveredRenderer *> *)scanSkippingLibraryPaths:(NSSet<NSString *> *)skipLibraryPaths {
    NSTimeInterval start = [NSDate.date timeIntervalSince1970];

    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *bundleFrameworks = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks"];
    if (bundleFrameworks) [dirs addObject:bundleFrameworks];

    NSString *docsRenderers = [self userRendererDirectory];
    if (docsRenderers) [dirs addObject:docsRenderers];

    // 越狱共享目录：任何 App 都能往这里放，多个启动器可共用同一份渲染器。
    // 不存在就跳过（非越狱设备或用户没建过）。
    NSString *shared = @"/var/jb/usr/lib/air2-renderers";
    if ([NSFileManager.defaultManager fileExistsAtPath:shared]) [dirs addObject:shared];

    _scannedDirectories = [dirs copy];

    NSMutableArray<A2DiscoveredRenderer *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];

    for (NSUInteger i = 0; i < dirs.count; i++) {
        NSString *dir = dirs[i];
        // 第 1 个目录是内置，其余算用户来源
        NSString *source = (i == 0) ? @"内置" : ((dir == shared) ? @"越狱共享目录" : @"用户导入");

        NSArray<NSString *> *files = [self dylibPathsUnderDirectory:dir depth:0];
        for (NSString *path in files) {
            // 已知库（内置已登记）直接跳过，不读文件
            if ([skipLibraryPaths containsObject:path]) continue;
            A2DiscoveredRenderer *item = [self inspectLibraryAtPath:path source:source];
            if (!item) continue;
            // 按 identifier 去重：内置先扫，所以同名时内置赢，外部文件不会把内置顶掉
            if ([seenIdentifiers containsObject:item.identifier]) continue;
            [seenIdentifiers addObject:item.identifier];
            [result addObject:item];
        }
    }

    // ---- 3. 已安装 App（等价于安卓的 APK 插件）----
    //
    // 安卓的渲染器插件是独立 APK，靠 AndroidManifest 的 <meta-data name="fclPlugin">
    // 自我声明，FCL 用 queryIntentActivities 全局扫一遍就发现（见
    // fcl/FCL/src/main/java/com/mio/plugin/PluginManager.kt:140）。
    //
    // iOS 没有包注册表，但**越狱**环境下可以枚举 /var/containers/Bundle/Application/，
    // 读每个 .app 的 Info.plist。约定一个键 `Air2RendererPlugin`：
    //   · 字符串 → .app bundle 内 manifest json 的相对路径
    //   · 字典   → 直接就是 manifest
    // 非越狱设备读不到该目录，本步自然为空，不影响其它来源。
    for (A2DiscoveredRenderer *item in [self scanInstalledApplications]) {
        if ([seenIdentifiers containsObject:item.identifier]) continue;
        [seenIdentifiers addObject:item.identifier];
        [result addObject:item];
    }

    _lastScanDuration = [NSDate.date timeIntervalSince1970] - start;
    [A2Logger info:@"A2RendererDiscovery"
           message:[NSString stringWithFormat:@"扫描完成：%lu 个候选，耗时 %.0f ms，目录 %lu 个",
                    (unsigned long)result.count,
                    _lastScanDuration * 1000.0,
                    (unsigned long)dirs.count]];
    return result;
}

- (NSString *)userRendererDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return nil;
    return [paths.firstObject stringByAppendingPathComponent:@"Air2/Renderers"];
}

- (NSArray<NSString *> *)dylibPathsUnderDirectory:(NSString *)dir depth:(NSInteger)depth {
    if (depth > kA2DiscoveryMaxDepth) return @[];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (!entries) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;

        if (isDir) {
            [out addObjectsFromArray:[self dylibPathsUnderDirectory:full depth:depth + 1]];
            continue;
        }
        if (![name.pathExtension isEqualToString:@"dylib"]) continue;
        // 明显不是渲染器的框架库跳过，避免把 libc++ / libz 之类列进列表
        if ([self isExcludedLibraryName:name]) continue;
        [out addObject:full];
    }
    return out;
}

- (BOOL)isExcludedLibraryName:(NSString *)name {
    static NSSet<NSString *> *excluded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = [NSSet setWithArray:@[
            @"libc++.dylib", @"libz.dylib", @"libsqlite3.dylib",
            @"libcompression.dylib", @"libbz2.dylib", @"libiconv.dylib",
            @"libicucore.dylib", @"libxml2.dylib", @"libcrypto.dylib", @"libssl.dylib",
        ]];
    });
    return [excluded containsObject:name];
}

#pragma mark - 单库检查（三级）

- (nullable A2DiscoveredRenderer *)inspectLibraryAtPath:(NSString *)path source:(NSString *)source {
    NSString *identifier = [self identifierFromLibraryPath:path];

    // ---- 第 1 级：同目录同名 .json 侧车文件（最安全，不碰 dylib）----
    NSDictionary *manifest = [self manifestBesideLibraryAtPath:path];

    // ---- 第 2 级：dylib 里有 AIR2RENDERER 标记才 dlopen 取符号 ----
    if (!manifest && [self libraryContainsMarker:path]) {
        manifest = [self manifestFromLibrarySymbol:path];
    }

    // ---- 第 3 级：都没拿到，登记成「未识别」----
    BOOL hasManifest = (manifest != nil);

    A2DiscoveredRenderer *item = [A2DiscoveredRenderer new];
    item.libraryPath = [path copy];
    item.sourceName = [source copy];
    item.hasManifest = hasManifest;
    item.manifest = [manifest copy];

    NSString *manifestID = [self stringIn:manifest key:@"rendererID"];
    item.identifier = manifestID.length ? manifestID : identifier;
    item.displayName = [self stringIn:manifest key:@"displayName"] ?:
                         [self displayNameFromLibraryPath:path];
    item.summary = [self stringIn:manifest key:@"description"] ?:
                     (hasManifest ? nil : @"未提供 manifest，按默认参数使用");
    item.minMCVersion = [self stringIn:manifest key:@"minMCVer"];
    item.maxMCVersion = [self stringIn:manifest key:@"maxMCVer"];
    return item;
}

- (NSString *)identifierFromLibraryPath:(NSString *)path {
    return path.lastPathComponent;
}

- (NSString *)displayNameFromLibraryPath:(NSString *)path {
    NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
    if ([name hasPrefix:@"lib"]) name = [name substringFromIndex:3];
    return name.length ? name : path.lastPathComponent;
}

- (nullable NSString *)stringIn:(NSDictionary *)dict key:(NSString *)key {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    id v = dict[key];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

/// 同目录下 `<dylib 文件名去掉 .dylib>.json`。
- (nullable NSDictionary *)manifestBesideLibraryAtPath:(NSString *)path {
    NSString *sidecar = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:sidecar]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:sidecar];
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

/// 按字节搜标记，**不 dlopen**。
- (BOOL)libraryContainsMarker:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    @try {
        // 只读前 256KB —— manifest 标记通常在 __cstring 段靠前位置，
        // 读全量对大 dylib（几十 MB）不划算。
        NSData *head = [fh readDataOfLength:256 * 1024];
        [fh closeFile];
        if (head.length == 0) return NO;
        NSData *marker = [NSData dataWithBytes:kA2RendererMagicMarker
                                        length:strlen(kA2RendererMagicMarker)];
        return [head rangeOfData:marker options:0 range:NSMakeRange(0, head.length)].location
               != NSNotFound;
    } @catch (NSException *e) {
        return NO;
    }
}

/// 已经确认有标记，才 dlopen 取符号，读完立刻 dlclose。
- (nullable NSDictionary *)manifestFromLibrarySymbol:(NSString *)path {
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        [A2Logger debug:@"A2RendererDiscovery"
                message:[NSString stringWithFormat:@"dlopen 失败 %@: %s",
                         path.lastPathComponent, dlerror() ?: "?"]];
        return nil;
    }
    NSDictionary *result = nil;
    @try {
        const char *(*fn)(void) = (const char *(*)(void))dlsym(handle, kA2RendererManifestSymbol);
        if (fn) {
            const char *json = fn();
            if (json && strlen(json) > 0) {
                NSData *data = [NSData dataWithBytes:json length:strlen(json)];
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([obj isKindOfClass:NSDictionary.class]) result = obj;
            }
        }
    } @catch (NSException *e) {
        result = nil;
    }
    dlclose(handle);
    return result;
}

#pragma mark - 已安装 App 扫描（越狱）

/// Info.plist 里声明本 App 提供 Air2 渲染器的键。
static NSString *const kA2PluginInfoPlistKey = @"Air2RendererPlugin";

- (NSArray<A2DiscoveredRenderer *> *)scanInstalledApplications {
    static NSString *const kAppContainer = @"/var/containers/Bundle/Application";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:kAppContainer error:NULL];
    if (!uuids) {
        // 非越狱设备到这里就是 nil，静默跳过
        [A2Logger debug:@"A2RendererDiscovery" message:@"非越狱环境，跳过已安装 App 扫描"];
        return @[];
    }

    NSMutableArray<A2DiscoveredRenderer *> *out = [NSMutableArray array];
    NSString *selfBundlePath = NSBundle.mainBundle.bundlePath;

    for (NSString *uuid in uuids) {
        if ([uuid hasPrefix:@"."]) continue;
        NSString *appDir = [kAppContainer stringByAppendingPathComponent:uuid];
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:appDir error:NULL];
        for (NSString *entry in entries) {
            if (![entry.pathExtension isEqualToString:@"app"]) continue;
            NSString *bundlePath = [appDir stringByAppendingPathComponent:entry];
            if ([bundlePath isEqualToString:selfBundlePath]) continue;  // 跳过自己

            NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (![info isKindOfClass:NSDictionary.class]) continue;

            id decl = info[kA2PluginInfoPlistKey];
            if (!decl) continue;

            NSDictionary *manifest = nil;
            if ([decl isKindOfClass:NSDictionary.class]) {
                manifest = decl;
            } else if ([decl isKindOfClass:NSString.class]) {
                NSString *jsonPath = [bundlePath stringByAppendingPathComponent:decl];
                NSData *data = [NSData dataWithContentsOfFile:jsonPath];
                if (data) {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                    if ([json isKindOfClass:NSDictionary.class]) manifest = json;
                }
            }
            if (!manifest) {
                [A2Logger info:@"A2RendererDiscovery"
                       message:[NSString stringWithFormat:@"%@ 声明了 Air2RendererPlugin 但 manifest 无效",
                                entry]];
                continue;
            }

            // manifest 里的主库路径相对 .app bundle 解析
            NSString *libRel = [self stringIn:manifest key:@"rendererGLPath"];
            if (!libRel.length) libRel = [self stringIn:manifest key:@"mainLibrary"];
            NSString *libPath = libRel.length
                ? [bundlePath stringByAppendingPathComponent:libRel] : nil;
            if (libPath && ![fm fileExistsAtPath:libPath]) {
                [A2Logger info:@"A2RendererDiscovery"
                       message:[NSString stringWithFormat:@"%@ 的渲染器库不存在: %@", entry, libRel]];
                libPath = nil;
            }

            A2DiscoveredRenderer *item = [A2DiscoveredRenderer new];
            item.libraryPath = libPath ?: bundlePath;
            item.sourceName = @"已安装 App";
            item.hasManifest = YES;
            item.manifest = [manifest copy];
            NSString *mid = [manifest[@"rendererID"] isKindOfClass:NSString.class]
                          ? manifest[@"rendererID"] : nil;
            item.identifier = mid.length ? mid : entry;
            NSString *dn = [manifest[@"displayName"] isKindOfClass:NSString.class]
                         ? manifest[@"displayName"] : nil;
            item.displayName = dn.length ? dn
                : [info[@"CFBundleDisplayName"] isKindOfClass:NSString.class]
                    ? info[@"CFBundleDisplayName"] : entry;
            item.summary = [manifest[@"description"] isKindOfClass:NSString.class]
                           ? manifest[@"description"] : @"来自已安装的渲染器插件 App";
            item.minMCVersion = [manifest[@"minMCVer"] isKindOfClass:NSString.class]
                                ? manifest[@"minMCVer"] : nil;
            item.maxMCVersion = [manifest[@"maxMCVer"] isKindOfClass:NSString.class]
                                ? manifest[@"maxMCVer"] : nil;
            [out addObject:item];

            [A2Logger info:@"A2RendererDiscovery"
                   message:[NSString stringWithFormat:@"发现插件 App: %@ (%@)", entry, item.identifier]];
        }
    }
    return out;
}

@end

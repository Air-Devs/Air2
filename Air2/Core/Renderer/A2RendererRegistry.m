//
//  A2RendererRegistry.m
//  Air2
//

#import "A2RendererRegistry.h"
#import "A2RendererImporter.h"
#import "A2Logger.h"

static NSString *const kSelectedRendererKey = @"A2SelectedRendererID";

@implementation A2RendererEntry

- (A2RendererAvailability)availability {
    return self.plugin ? self.plugin.availability : A2RendererAvailabilityAvailable;
}

- (NSString *)unavailableReason {
    return self.plugin.unavailableReason;
}

- (BOOL)hasConfigurableOptions {
    if (!self.plugin) return NO;
    for (A2RendererEnvSpec *spec in self.plugin.envSpecs) {
        if (spec.type != A2RendererEnvTypeNormal) return YES;
    }
    return NO;
}

@end

@interface A2RendererRegistry ()
@property (nonatomic, copy) NSArray<A2RendererEntry *> *allRenderers;
@end

@implementation A2RendererRegistry

+ (instancetype)shared {
    static A2RendererRegistry *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2RendererRegistry alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _allRenderers = @[];
    [self reload];
    return self;
}

#pragma mark - 扫描

- (void)reload {
    NSMutableArray<A2RendererEntry *> *list = [NSMutableArray array];

    // ---- 1. 内置渲染器 ----
    // 这些是编译进 IPA 的，与 Air1 的做法一致。
    // 实际的库路径在启动时由 CMake 产物决定，这里只登记元信息。
    [list addObjectsFromArray:[self builtinRenderers]];

    // ---- 2. 导入的插件 ----
    NSArray<A2RendererPlugin *> *plugins = [A2RendererImporter.shared installedPlugins];
    for (A2RendererPlugin *p in plugins) {
        A2RendererEntry *e = [A2RendererEntry new];
        e.identifier = p.rendererID;
        e.displayName = p.displayName;
        e.summary = p.pluginDescription;
        e.builtin = NO;
        e.sourceName = p.author ?: @"导入插件";
        e.plugin = p;
        e.minMCVer = p.minMCVer;
        e.maxMCVer = p.maxMCVer;
        [list addObject:e];
    }

    self.allRenderers = list;

    [A2Logger info:@"A2RendererRegistry"
           message:[NSString stringWithFormat:@"共 %lu 个渲染器（内置 %lu + 插件 %lu）",
                    (unsigned long)list.count,
                    (unsigned long)[self builtinRenderers].count,
                    (unsigned long)plugins.count]];
}

/// 内置渲染器。
///
/// 与 FCL 的 RendererManager.init() 对应 —— 也是硬编码的列表。
/// 差别在于：iOS 上库是 .dylib 且在 bundle 的 Frameworks/ 下，
/// 而不是 .so 在 APK 的 lib/ 下。
- (NSArray<A2RendererEntry *> *)builtinRenderers {
    NSMutableArray<A2RendererEntry *> *list = [NSMutableArray array];

    struct {
        const char *ident;
        const char *name;
        const char *summary;
        const char *minMC;
    } builtins[] = {
        { "builtin.nggl4es",  "NG-GL4ES",  "GL4ES 增强版，兼容性最好，适合大多数设备", "1.16.5" },
        { "builtin.zink",     "Zink",      "Vulkan 后端，通过 MoltenVK 转 Metal",     "1.17" },
        { "builtin.mobilegl", "MobileGlues","Metal 原生 GL 转译，性能最优",            "1.17" },
        { "builtin.virgl",    "VirGL",     "虚拟化 GL，兼容老版本",                    "1.7" },
    };

    for (size_t i = 0; i < sizeof(builtins) / sizeof(builtins[0]); i++) {
        A2RendererEntry *e = [A2RendererEntry new];
        e.identifier = [NSString stringWithUTF8String:builtins[i].ident];
        e.displayName = [NSString stringWithUTF8String:builtins[i].name];
        e.summary = [NSString stringWithUTF8String:builtins[i].summary];
        e.builtin = YES;
        e.minMCVer = [NSString stringWithUTF8String:builtins[i].minMC];
        [list addObject:e];
    }
    return list;
}

#pragma mark - 查询

- (NSArray<A2RendererEntry *> *)availableRenderers {
    NSMutableArray *out = [NSMutableArray array];
    for (A2RendererEntry *e in self.allRenderers) {
        if (e.availability == A2RendererAvailabilityAvailable) [out addObject:e];
    }
    return out;
}

- (A2RendererEntry *)rendererWithIdentifier:(NSString *)identifier {
    for (A2RendererEntry *e in self.allRenderers) {
        if ([e.identifier isEqualToString:identifier]) return e;
    }
    return nil;
}

- (NSString *)selectedIdentifier {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kSelectedRendererKey];
    if (saved.length > 0) return saved;
    // 默认选第一个可用的
    return self.availableRenderers.firstObject.identifier;
}

- (void)setSelectedIdentifier:(NSString *)selectedIdentifier {
    [NSUserDefaults.standardUserDefaults setObject:selectedIdentifier
                                            forKey:kSelectedRendererKey];
}

#pragma mark - 版本兼容

/// 简单的版本比较：把 "1.21.4" 拆成数字元组。
/// 不追求语义化版本的完整语义 —— MC 版本就是三段数字。
- (BOOL)renderer:(A2RendererEntry *)renderer supportsMCVersion:(NSString *)version {
    if (version.length == 0) return YES;
    if (renderer.minMCVer.length == 0 && renderer.maxMCVer.length == 0) return YES;

    if (renderer.minMCVer.length &&
        [self compareVersion:version to:renderer.minMCVer] == NSOrderedAscending) {
        return NO;
    }
    if (renderer.maxMCVer.length &&
        [self compareVersion:version to:renderer.maxMCVer] == NSOrderedDescending) {
        return NO;
    }
    return YES;
}

- (NSComparisonResult)compareVersion:(NSString *)a to:(NSString *)b {
    NSArray *pa = [a componentsSeparatedByString:@"."];
    NSArray *pb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger va = (i < pa.count) ? [pa[i] integerValue] : 0;
        NSInteger vb = (i < pb.count) ? [pb[i] integerValue] : 0;
        if (va < vb) return NSOrderedAscending;
        if (va > vb) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

#pragma mark - 环境变量

/// 把 manifest 里的 env 规约 + 用户设置，展开成实际要设的环境变量。
///
/// 这是「配置驱动」的核心：渲染器作者只写声明，
/// 用户的选择存在 UserDefaults，启动时在这里合成。
- (NSDictionary<NSString *, NSString *> *)environmentForRenderer:(A2RendererEntry *)renderer {
    NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionary];

    if (!renderer.plugin) return env;   // 内置渲染器的 env 写死在启动逻辑里

    // 读该插件的用户设置
    NSString *prefix = [NSString stringWithFormat:@"RenderEnv.%@.", renderer.identifier];
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    NSMutableDictionary<NSString *, id> *mine = [NSMutableDictionary dictionary];
    for (NSString *key in all) {
        if (![key hasPrefix:prefix]) continue;
        mine[[key substringFromIndex:prefix.length]] = all[key];
    }

    for (A2RendererEnvSpec *spec in renderer.plugin.envSpecs) {
        NSString *v = [spec resolvedValueWithUserSettings:mine];
        if (v.length) env[spec.key] = v;
    }

    return env;
}

@end

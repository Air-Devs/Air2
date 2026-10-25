//
//  A2ModLoaderSelection.m
//  Air2
//

#import "A2ModLoaderSelection.h"
#import "A2Log.h"

/// 版本描述里只认这一个方法：模型自己声明的版本号取值器。
/// 用协议而不是 performSelector: —— 后者返回 id，ARC 下会报
/// 「may cause a leak because its selector is unknown」。
@protocol A2ModLoaderVersionCarrier <NSObject>
- (NSString *)version;
@end

@implementation A2ModLoaderSelection

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _versions = [NSMutableDictionary dictionary];
    return self;
}

#pragma mark - 配对关系

/// API 模组 → 它需要的主加载器
+ (NSNumber *)primaryLoaderForAPI:(A2ModLoaderType)apiType {
    switch (apiType) {
        case A2ModLoaderTypeFabricAPI:       return @(A2ModLoaderTypeFabric);
        case A2ModLoaderTypeQuiltAPI:        return @(A2ModLoaderTypeQuilt);
        case A2ModLoaderTypeLegacyFabricAPI: return @(A2ModLoaderTypeLegacyFabric);
        case A2ModLoaderTypeBabricAPI:       return @(A2ModLoaderTypeBabric);
        default:                             return nil;
    }
}

+ (NSNumber *)apiForPrimaryLoader:(A2ModLoaderType)loaderType {
    switch (loaderType) {
        case A2ModLoaderTypeFabric:       return @(A2ModLoaderTypeFabricAPI);
        case A2ModLoaderTypeQuilt:        return @(A2ModLoaderTypeQuiltAPI);
        case A2ModLoaderTypeLegacyFabric: return @(A2ModLoaderTypeLegacyFabricAPI);
        case A2ModLoaderTypeBabric:       return @(A2ModLoaderTypeBabricAPI);
        default:                          return nil;
    }
}

+ (NSArray<NSNumber *> *)allPrimaryLoaders {
    return @[
        @(A2ModLoaderTypeOptiFine),
        @(A2ModLoaderTypeForge),
        @(A2ModLoaderTypeNeoForge),
        @(A2ModLoaderTypeFabric),
        @(A2ModLoaderTypeQuilt),
        @(A2ModLoaderTypeLegacyFabric),
        @(A2ModLoaderTypeBabric),
        @(A2ModLoaderTypeCleanroom),
    ];
}

+ (NSArray<NSNumber *> *)allAPIMods {
    return @[
        @(A2ModLoaderTypeFabricAPI),
        @(A2ModLoaderTypeQuiltAPI),
        @(A2ModLoaderTypeLegacyFabricAPI),
        @(A2ModLoaderTypeBabricAPI),
    ];
}

#pragma mark - 互斥判定

/// 两个类型是否互斥 —— 对照 ZL2 的 areMutuallyExclusive。
///
/// 规则：
///   1. 两个主加载器 → 互斥（Forge 与 Fabric 都要接管启动流程），
///      例外是 OptiFine 与 Forge/NeoForge 可以共存（OptiFine 当模组用）
///   2. 主加载器 vs API → 只有配对的才不互斥
///   3. API vs API → 同属一个主加载器才不互斥
///   4. 其余（如 API 与不相关的主加载器）→ 不互斥
- (BOOL)typesAreMutuallyExclusive:(A2ModLoaderType)a other:(A2ModLoaderType)b {
    if (a == b) return NO;

    BOOL aIsLoader = A2ModLoaderIsLoader(a);
    BOOL bIsLoader = A2ModLoaderIsLoader(b);
    BOOL aIsAPI = A2ModLoaderIsAPIMod(a);
    BOOL bIsAPI = A2ModLoaderIsAPIMod(b);

    // 两个主加载器：正常互斥（选了新的就顶掉旧的），
    // 但 OptiFine 是叠加项 —— 它可以作为 Forge / NeoForge 的模组共存。
    if (aIsLoader && bIsLoader) {
        BOOL optifineWithForgeFamily =
            (a == A2ModLoaderTypeOptiFine &&
                (b == A2ModLoaderTypeForge || b == A2ModLoaderTypeNeoForge)) ||
            (b == A2ModLoaderTypeOptiFine &&
                (a == A2ModLoaderTypeForge || a == A2ModLoaderTypeNeoForge));
        return !optifineWithForgeFamily;
    }

    // 主加载器 vs API
    if (aIsLoader && bIsAPI) {
        NSNumber *required = [A2ModLoaderSelection primaryLoaderForAPI:b];
        return required.integerValue != (NSInteger)a;
    }
    if (aIsAPI && bIsLoader) {
        NSNumber *required = [A2ModLoaderSelection primaryLoaderForAPI:a];
        return required.integerValue != (NSInteger)b;
    }

    // API vs API
    if (aIsAPI && bIsAPI) {
        NSNumber *ra = [A2ModLoaderSelection primaryLoaderForAPI:a];
        NSNumber *rb = [A2ModLoaderSelection primaryLoaderForAPI:b];
        return ra.integerValue != rb.integerValue;
    }

    return NO;
}

#pragma mark - 版本规整

+ (NSString *)versionStringFrom:(id)value {
    if (value == nil) return nil;
    if ([value isKindOfClass:NSNull.class]) return nil;

    if ([value isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)value;
        return s.length > 0 ? s : nil;
    }

    // 数字形态（有的调用方会把版本号放 NSNumber）—— 只在这个位置容忍
    if ([value isKindOfClass:NSNumber.class]) {
        return [(NSNumber *)value stringValue];
    }

    // 模型对象（A2ModLoaderVersion 及同类）：取它自己的版本号
    if ([value respondsToSelector:@selector(version)]) {
        id inner = [(id<A2ModLoaderVersionCarrier>)value version];
        if ([inner isKindOfClass:NSString.class] && ((NSString *)inner).length > 0) {
            return (NSString *)inner;
        }
        if ([inner isKindOfClass:NSNumber.class]) {
            return [(NSNumber *)inner stringValue];
        }
        return nil;
    }

    return nil;
}

#pragma mark - 选择

- (void)selectType:(A2ModLoaderType)type version:(id)version {
    // 入口防御：类型必须是我们认识的加载器或前置模组。
    // 越界值静默返回 —— 越界值去查互斥表只会得出错误结论。
    if (!A2ModLoaderIsLoader(type) && !A2ModLoaderIsAPIMod(type)) {
        [A2Log log:@"[A2-LOADER] 忽略未知 type=%ld（不在加载器/前置模组表内）",
            (long)type];
        return;
    }

    // 无论调用方给的是字符串还是模型对象，这里一律先规整成字符串。
    // 原先形参声明成 NSString *，UI 层把 A2ModLoaderVersion 对象递进来，
    // 下面第一句 version.length 就发到模型上 ⇒ unrecognized selector 闪退。
    NSString *versionString = [A2ModLoaderSelection versionStringFrom:version];

    [A2Log log:@"[A2-LOADER] 选择 type=%@ version=%@",
        [A2ModLoaderAPI displayNameForType:type],
        versionString ?: @"(无/取消)"];

    [self.versions removeObjectForKey:@(type)];
    if (versionString.length == 0) {
        // 取消一个主加载器时，连带取消它对应的 API 模组 ——
        // Fabric 都没了，Fabric API 留着没有意义。
        if (A2ModLoaderIsLoader(type)) {
            NSNumber *api = [A2ModLoaderSelection apiForPrimaryLoader:type];
            if (api) [self.versions removeObjectForKey:api];
        }
        return;
    }

    // 清掉与之互斥的已选项
    NSArray<NSNumber *> *keys = self.versions.allKeys;
    for (NSNumber *key in keys) {
        if ([self typesAreMutuallyExclusive:type other:(A2ModLoaderType)key.integerValue]) {
            [self.versions removeObjectForKey:key];
            // 被清掉的若是个主加载器，它的 API 也要跟着走
            if (A2ModLoaderIsLoader((A2ModLoaderType)key.integerValue)) {
                NSNumber *api = [A2ModLoaderSelection apiForPrimaryLoader:
                                 (A2ModLoaderType)key.integerValue];
                if (api) [self.versions removeObjectForKey:api];
            }
        }
    }

    self.versions[@(type)] = versionString;
}

- (NSNumber *)selectedLoaderType {
    for (NSNumber *key in self.versions) {
        if (A2ModLoaderIsLoader((A2ModLoaderType)key.integerValue)) return key;
    }
    return nil;
}

- (NSNumber *)selectedAPIType {
    for (NSNumber *key in self.versions) {
        if (A2ModLoaderIsAPIMod((A2ModLoaderType)key.integerValue)) return key;
    }
    return nil;
}

- (BOOL)canSelectType:(A2ModLoaderType)type {
    for (NSNumber *key in self.versions) {
        if ([self typesAreMutuallyExclusive:type
                                       other:(A2ModLoaderType)key.integerValue]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)isConflictingType:(A2ModLoaderType)type {
    return ![self canSelectType:type] && self.versions[@(type)] == nil;
}

@end

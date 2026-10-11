//
//  A2LaunchPlan.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  启动计划产出实现。规格：D:\CTF\_AIR2_LAUNCH_PATH.md §①/§②；
//  Java 侧消费者：JavaApp/src/launcher/dev/airdevs/air2/launch/A2LaunchPlan.java（schema=1）。
//
//  ★本文件刻意只做「版本 JSON 语义 + 账号取值」这件业务★：
//    · 不解析 .class 文件、不下载、不碰 UI；
//    · 不拼 classpath 字符串（那是 Natives R4 的唯一单点，见 a2_resourcepaths.h）；
//    · 不建 VM、不调 JNI（那是 Natives/Context）。
//

#import "A2LaunchPlan.h"
#import "A2LaunchContract.h"   // 契约常量（入口主类名 / --plan / 类加载器名 / schema）
#import "A2Log.h"

static NSString *const A2LaunchPlanErrorDomain = @"A2LaunchPlan";

static NSError *A2PlanError(NSString *message) {
    return [NSError errorWithDomain:A2LaunchPlanErrorDomain
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

// ---------------------------------------------------------------------------
// MC 版本 JSON 的 rules 求值（子集）
// ---------------------------------------------------------------------------
// 语义与官方 LaunchRules 的【常用子集】一致：**最后一条命中的规则决定结果**；
// 规则表为空 ⇒ 允许。未实现的维度（features 求解器、os.version 正则）一律
// **保守判为不命中**（宁可少加载一个库，也不把不该加载的加载进来）。
static BOOL A2PlanRulesAllow(id rulesObject) {
    if (![rulesObject isKindOfClass:NSArray.class]) return YES;   // 无 rules ⇒ 允许
    NSArray *rules = (NSArray *)rulesObject;
    if (rules.count == 0) return YES;

    BOOL allowed = NO;   // 有规则但一条都没命中 ⇒ 不允许（官方语义）
    for (id item in rules) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *rule = (NSDictionary *)item;

        BOOL matched = YES;
        NSDictionary *os = rule[@"os"];
        if ([os isKindOfClass:NSDictionary.class]) {
            id name = os[@"name"];
            if ([name isKindOfClass:NSString.class]) {
                // iOS 的 os.name 是 Darwin，但 MC 的库规则按 "osx" 描述 macOS 系。
                NSString *n = (NSString *)name;
                if (![n isEqualToString:@"osx"] && ![n isEqualToString:@"darwin"]) matched = NO;
            }
            id arch = os[@"arch"];
            if ([arch isKindOfClass:NSString.class]) {
#if defined(__aarch64__) || defined(__arm64__) || defined(A2_PLAN_ARCH_ARM64)
                NSString *host = @"arm64";
#elif defined(__x86_64__)
                NSString *host = @"x86_64";
#else
                NSString *host = @"arm64";
#endif
                if (![(NSString *)arch isEqualToString:host]) matched = NO;
            }
            // os.version：官方用正则；iOS 上无法保证对齐 ⇒ 保守判为不命中
            if ([os[@"version"] isKindOfClass:NSString.class]) matched = NO;
        }
        if ([rule[@"features"] isKindOfClass:NSDictionary.class]) matched = NO;

        if (matched) {
            id action = rule[@"action"];
            if ([action isKindOfClass:NSString.class]) {
                allowed = [(NSString *)action isEqualToString:@"allow"];
            }
        }
    }
    return allowed;
}

// `${…}` 占位符替换（一次替换全部已知键；未知占位符原样保留，便于真机一眼看出漏了哪个）。
static NSString *A2PlanSubstitute(NSString *text, NSDictionary<NSString *, NSString *> *table) {
    if ([text rangeOfString:@"${"].location == NSNotFound) return text;
    NSMutableString *out = [NSMutableString stringWithString:text];
    for (NSString *key in table) {
        NSString *token = [NSString stringWithFormat:@"${%@}", key];
        [out replaceOccurrencesOfString:token
                             withString:(table[key] ?: @"")
                                options:0
                                  range:NSMakeRange(0, out.length)];
    }
    return out;
}

static NSString *A2PlanString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

// `group:artifact:version` ⇒ Maven 相对路径（downloads.artifact.path 缺失时的兜底）。
static NSString *A2PlanMavenRelativePath(NSString *mavenName) {
    NSArray<NSString *> *parts = [mavenName componentsSeparatedByString:@":"];
    if (parts.count < 3) return nil;
    NSArray<NSString *> *groupId = [parts[0] componentsSeparatedByString:@"."];
    NSString *artifact = parts[1];
    NSString *version = parts[2];
    return [NSString stringWithFormat:@"%@/%@/%@/%@-%@.jar",
            [groupId componentsJoinedByString:@"/"], artifact, version, artifact, version];
}

@interface A2LaunchPlan ()

@property (nonatomic, copy, readwrite) NSString *versionID;
@property (nonatomic, copy, readwrite) NSString *mainClass;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *arguments;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *properties;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *classpath;
@property (nonatomic, copy, readwrite, nullable) NSString *nativeLibrary;

@end

@implementation A2LaunchPlan

#pragma mark - 合并 inheritsFrom

+ (nullable NSDictionary *)mergedVersionJSONFromDirectory:(NSString *)versionDir
                                                versionID:(NSString *)versionID
                                                    error:(NSError *_Nullable *_Nullable)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *chain = [NSMutableArray array];   // 父在前
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *current = versionID;

    for (NSInteger depth = 0; depth < 8 && current.length > 0; depth++) {
        if ([seen containsObject:current]) {
            if (error) *error = A2PlanError([NSString stringWithFormat:@"版本继承成环：%@", current]);
            return nil;
        }
        [seen addObject:current];

        NSString *path = [versionDir stringByAppendingPathComponent:
                          [current stringByAppendingPathExtension:@"json"]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length == 0) {
            if (error) *error = A2PlanError([NSString stringWithFormat:@"版本 json 不存在：%@", path]);
            return nil;
        }
        NSError *parseError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (![object isKindOfClass:NSDictionary.class]) {
            if (error) *error = A2PlanError([NSString stringWithFormat:@"版本 json 解析失败：%@（%@）",
                                             path, parseError.localizedDescription ?: @"非对象"]);
            return nil;
        }
        [chain insertObject:(NSDictionary *)object atIndex:0];

        id parent = ((NSDictionary *)object)[@"inheritsFrom"];
        current = [parent isKindOfClass:NSString.class] ? (NSString *)parent : nil;
    }

    if (chain.count == 0) {
        if (error) *error = A2PlanError(@"版本继承链为空");
        return nil;
    }

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSMutableArray *libraries = [NSMutableArray array];
    NSMutableArray *gameArgs = [NSMutableArray array];
    NSMutableArray *jvmArgs = [NSMutableArray array];

    for (NSDictionary *node in chain) {
        for (NSString *key in node) {
            if ([key isEqualToString:@"libraries"] ||
                [key isEqualToString:@"arguments"] ||
                [key isEqualToString:@"minecraftArguments"]) {
                continue;   // 三者单独合并（追加语义）
            }
            merged[key] = node[key];
        }
        if ([node[@"libraries"] isKindOfClass:NSArray.class]) {
            [libraries addObjectsFromArray:(NSArray *)node[@"libraries"]];
        }
        id args = node[@"arguments"];
        if ([args isKindOfClass:NSDictionary.class]) {
            id game = ((NSDictionary *)args)[@"game"];
            if ([game isKindOfClass:NSArray.class]) [gameArgs addObjectsFromArray:(NSArray *)game];
            id jvm = ((NSDictionary *)args)[@"jvm"];
            if ([jvm isKindOfClass:NSArray.class]) [jvmArgs addObjectsFromArray:(NSArray *)jvm];
        } else if ([args isKindOfClass:NSArray.class]) {
            [gameArgs addObjectsFromArray:(NSArray *)args];   // 极老格式
        }
        // legacy：minecraftArguments 是空格分隔的单串（子节点覆盖父节点）
        if ([node[@"minecraftArguments"] isKindOfClass:NSString.class]) {
            merged[@"minecraftArguments"] = node[@"minecraftArguments"];
        }
    }

    if (libraries.count > 0) merged[@"libraries"] = libraries;
    NSMutableDictionary *arguments = [NSMutableDictionary dictionary];
    if (jvmArgs.count > 0)  arguments[@"jvm"]  = jvmArgs;
    if (gameArgs.count > 0) arguments[@"game"] = gameArgs;
    if (arguments.count > 0) merged[@"arguments"] = arguments;

    return merged;
}

#pragma mark - 产出计划

+ (nullable instancetype)planForVersionDirectory:(NSString *)versionDir
                                       versionID:(NSString *)versionID
                                     accountDict:(NSDictionary<NSString *, NSString *> *)account
                                         gameDir:(NSString *)gameDir
                                       assetsDir:(NSString *)assetsDir
                                    librariesDir:(NSString *)librariesDir
                                  versionJarPath:(nullable NSString *)versionJarPath
                                           error:(NSError *_Nullable *_Nullable)error {
    NSDictionary *json = [self mergedVersionJSONFromDirectory:versionDir
                                                   versionID:versionID
                                                       error:error];
    if (!json) return nil;
    return [self planFromVersionJSON:json
                           versionID:versionID
                         accountDict:account
                             gameDir:gameDir
                           assetsDir:assetsDir
                        librariesDir:librariesDir
                      versionJarPath:versionJarPath
                               error:error];
}

+ (nullable instancetype)planFromVersionJSON:(NSDictionary *)json
                                   versionID:(NSString *)versionID
                                 accountDict:(NSDictionary<NSString *, NSString *> *)account
                                     gameDir:(NSString *)gameDir
                                   assetsDir:(NSString *)assetsDir
                                librariesDir:(NSString *)librariesDir
                              versionJarPath:(nullable NSString *)versionJarPath
                                       error:(NSError *_Nullable *_Nullable)error {
    NSString *mainClass = A2PlanString(json[@"mainClass"]);
    if (mainClass.length == 0) {
        if (error) *error = A2PlanError(@"版本 JSON 缺 mainClass（无法产出启动计划）");
        return nil;
    }

    // ---- classpath：版本客户端 jar + 允许加载的 libraries（显式路径，无通配）----
    NSMutableArray<NSString *> *classpath = [NSMutableArray array];
    if (versionJarPath.length > 0) [classpath addObject:versionJarPath];

    NSArray *libraries = [json[@"libraries"] isKindOfClass:NSArray.class] ? (NSArray *)json[@"libraries"] : @[];
    for (id item in libraries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *library = (NSDictionary *)item;
        if (!A2PlanRulesAllow(library[@"rules"])) continue;

        NSString *relative = nil;
        NSDictionary *downloads = library[@"downloads"];
        if ([downloads isKindOfClass:NSDictionary.class]) {
            NSDictionary *artifact = ((NSDictionary *)downloads)[@"artifact"];
            if ([artifact isKindOfClass:NSDictionary.class]) {
                NSString *path = A2PlanString(((NSDictionary *)artifact)[@"path"]);
                if (path.length > 0) relative = path;
            }
        }
        if (relative.length == 0) {
            NSString *name = A2PlanString(library[@"name"]);
            if (name.length > 0) relative = A2PlanMavenRelativePath(name);
        }
        if (relative.length > 0) {
            [classpath addObject:[librariesDir stringByAppendingPathComponent:relative]];
        }
    }

    // ---- arguments：替换占位符（账号 / 目录 / 版本）----
    NSString *assetsIndexName = A2PlanString(json[@"assetIndex"]);
    if (assetsIndexName.length == 0) assetsIndexName = A2PlanString(json[@"assets"]);

    NSDictionary<NSString *, NSString *> *table = @{
        @"auth_player_name"  : (account[@"username"]    ?: @""),
        @"auth_uuid"         : (account[@"uuid"]        ?: @""),
        @"auth_access_token" : (account[@"accessToken"] ?: @""),
        @"auth_session"      : (account[@"accessToken"] ?: @""),
        @"user_type"         : (account[@"userType"]    ?: @"legacy"),
        @"version_name"      : (versionID ?: @""),
        @"version_type"      : A2PlanString(json[@"type"]).length ? A2PlanString(json[@"type"]) : @"release",
        @"game_directory"    : (gameDir ?: @""),
        @"assets_root"       : (assetsDir ?: @""),
        @"assets_index_name" : assetsIndexName,
        @"game_assets"       : (assetsDir ?: @""),
        @"resolution_width"  : @"1280",
        @"resolution_height" : @"720",
        @"clientid"          : @"air2",
        @"auth_xuid"         : @"",
    };

    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    NSMutableArray *gameList = nil;
    id args = json[@"arguments"];
    if ([args isKindOfClass:NSDictionary.class]) {
        id game = ((NSDictionary *)args)[@"game"];
        if ([game isKindOfClass:NSArray.class]) gameList = (NSMutableArray *)game;
    } else if ([args isKindOfClass:NSArray.class]) {
        gameList = (NSMutableArray *)args;
    } else if ([json[@"minecraftArguments"] isKindOfClass:NSString.class]) {
        // legacy：单串按空白切分
        NSString *legacy = (NSString *)json[@"minecraftArguments"];
        gameList = [NSMutableArray arrayWithArray:[legacy componentsSeparatedByString:@" "]];
    }
    for (id item in (gameList ?: @[])) {
        if ([item isKindOfClass:NSString.class]) {
            [arguments addObject:A2PlanSubstitute((NSString *)item, table)];
        } else if ([item isKindOfClass:NSDictionary.class]) {
            NSDictionary *entry = (NSDictionary *)item;
            if (!A2PlanRulesAllow(entry[@"rules"])) continue;
            id value = entry[@"value"];
            if ([value isKindOfClass:NSString.class]) {
                [arguments addObject:A2PlanSubstitute((NSString *)value, table)];
            } else if ([value isKindOfClass:NSArray.class]) {
                for (id v in (NSArray *)value) {
                    if ([v isKindOfClass:NSString.class]) {
                        [arguments addObject:A2PlanSubstitute((NSString *)v, table)];
                    }
                }
            }
        }
    }

    // ---- properties：需要「在 MC / LWJGL 任何类加载之前」落下的系统属性 ----
    // ★只放能给出真值的条目★：渲染器/后端相关的属性取值依赖 Core/Renderer 的选择，
    //   本单未接线 ⇒ 这里保持空表，宁可让 Java 侧什么都不设，也不写一个猜的值。
    NSDictionary<NSString *, NSString *> *properties = @{};

    A2LaunchPlan *plan = [[A2LaunchPlan alloc] init];
    plan.versionID = versionID ?: @"";
    plan.mainClass = mainClass;
    plan.arguments = arguments;
    plan.properties = properties;
    plan.classpath = classpath;
    plan.nativeLibrary = NSBundle.mainBundle.executablePath;
    return plan;
}

#pragma mark - 输出

- (NSDictionary *)JSONObject {
    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    object[@"schema"] = @(A2LaunchPlanSchema);
    object[@"mainClass"] = self.mainClass;
    object[@"arguments"] = self.arguments;
    object[@"properties"] = self.properties;
    object[@"classpath"] = self.classpath;
    if (self.nativeLibrary.length > 0) object[@"nativeLibrary"] = self.nativeLibrary;
    return object;
}

- (BOOL)writeToFile:(NSString *)path error:(NSError *_Nullable *_Nullable)error {
    NSError *serializeError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self JSONObject]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&serializeError];
    if (data.length == 0) {
        if (error) *error = serializeError ?: A2PlanError(@"启动计划序列化失败");
        return NO;
    }
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:error];
    if (ok) {
        [A2Log log:@"[A2-PLAN] 启动计划写盘 %@（主类=%@，参数=%lu 条，库=%lu 条）",
         path.lastPathComponent, self.mainClass,
         (unsigned long)self.arguments.count, (unsigned long)self.classpath.count];
    }
    return ok;
}

- (NSArray<NSString *> *)jvmOptionsWithMemoryMB:(NSInteger)memoryMB {
    NSMutableArray<NSString *> *options = [NSMutableArray array];
    if (memoryMB > 0) {
        [options addObject:[NSString stringWithFormat:@"-Xmx%ldM", (long)memoryMB]];
    }
    // ★追加类路径的唯一可行方式（Java 9+）：必须带，否则 A2Entry 追加 MC 库时被模块系统挡下。
    [options addObject:[NSString stringWithFormat:@"-Djava.system.class.loader=%@", A2LaunchGameClassLoaderName]];
    return options;
}

- (NSArray<NSString *> *)programArgumentsWithPlanPath:(NSString *)planPath {
    if (planPath.length == 0) return @[];
    return @[ A2LaunchPlanFlag, planPath ];
}

@end

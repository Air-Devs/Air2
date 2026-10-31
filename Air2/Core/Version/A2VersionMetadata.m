//
//  A2VersionMetadata.m
//  Air2
//

#import "A2VersionMetadata.h"
#import "A2Logger.h"
#import "A2Settings.h"

@implementation A2VersionMetadata

+ (nullable NSDictionary *)launchTargetForVersion:(NSString *)versionName
                                         gameHome:(NSString *)gameHome {
    if (versionName.length == 0 || gameHome.length == 0) return nil;

    NSString *dir = [gameHome stringByAppendingPathComponent:@"versions"];
    NSString *path = [[dir stringByAppendingPathComponent:versionName]
                      stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@.json", versionName]];

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [A2Logger error:@"VersionMeta"
                 message:[NSString stringWithFormat:@"版本 JSON 不存在：%@", path]];
        return nil;
    }

    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        [A2Logger error:@"VersionMeta"
                 message:[NSString stringWithFormat:@"版本 JSON 格式错误：%@", path]];
        return nil;
    }

    NSMutableDictionary *json = [parsed mutableCopy];

    // ---- 1. 继承合并 ----
    // 加载器版（Fabric/Forge）只有 {id, inheritsFrom, libraries}，
    // 客户端 jar / 资源 / 大部分依赖都在父版本里。
    NSString *parentID = json[@"inheritsFrom"];
    if ([parentID isKindOfClass:NSString.class] && parentID.length > 0) {
        NSString *parentPath = [[dir stringByAppendingPathComponent:parentID]
                                stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.json", parentID]];
        NSData *pdata = [NSData dataWithContentsOfFile:parentPath];
        id pparsed = pdata ? [NSJSONSerialization JSONObjectWithData:pdata options:0 error:nil] : nil;

        if ([pparsed isKindOfClass:NSDictionary.class]) {
            // 本版本额外声明的库（Fabric loader jar 等）要保留
            NSArray *ownLibs = json[@"libraries"];

            json = [pparsed mutableCopy];
            if ([ownLibs isKindOfClass:NSArray.class] && ownLibs.count > 0) {
                NSMutableArray *libs = [json[@"libraries"] isKindOfClass:NSArray.class]
                    ? [json[@"libraries"] mutableCopy] : [NSMutableArray array];
                [libs addObjectsFromArray:ownLibs];
                json[@"libraries"] = libs;
            }

            // id 用加载器版的（决定 versions/<id>/<id>.jar 的路径与账户文件）
            json[@"id"] = versionName;
            json[@"inheritsFrom"] = parentID;

            [A2Logger info:@"VersionMeta"
                   message:[NSString stringWithFormat:@"%@ 继承自 %@，已合并", versionName, parentID]];
        } else {
            [A2Logger error:@"VersionMeta"
                    message:[NSString stringWithFormat:@"父版本 JSON 缺失：%@", parentPath]];
            return nil;
        }
    }

    // ---- 2~7. iOS 适配 ----
    [self tweakVersionJson:json gameHome:gameHome];

    // ---- 启动器需要的补充键 ----
    json[@"id"] = json[@"id"] ?: versionName;
    json[@"gameHome"] = gameHome;

    // javaVersion 原样保留（launchMinecraft 会读 majorVersion）
    [A2Logger info:@"VersionMeta"
           message:[NSString stringWithFormat:
                    @"%@ 就绪：javaVersion=%@ libraries=%lu jvm_processed=%lu",
                    versionName,
                    json[@"javaVersion"] ?: @"(无)",
                    (unsigned long)[json[@"libraries"] count],
                    (unsigned long)[json[@"arguments"][@"jvm_processed"] count]]];

    return json;
}

#pragma mark - iOS 适配（对照 Air1 的 tweakVersionJson）

+ (void)tweakVersionJson:(NSMutableDictionary *)json gameHome:(NSString *)gameHome {
    NSFileManager *fm = NSFileManager.defaultManager;

    // ---- 库处理 ----
    NSArray *rawLibs = json[@"libraries"];
    NSMutableArray *libs = [NSMutableArray array];

    for (id item in rawLibs) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *lib = [item mutableCopy];
        NSString *name = lib[@"name"];

        // 1) 打 skip：natives 与 org.lwjgl 由启动器自带的 dylib 提供
        BOOL isnatives = (lib[@"natives"] != nil);
        BOOL isLwjgl = [name hasPrefix:@"org.lwjgl"];
        BOOL isClassifiers = (lib[@"downloads"][@"classifiers"] != nil);
        lib[@"skip"] = @(isnatives || isLwjgl || isClassifiers);

        NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
        if (parts.count < 3) {
            [libs addObject:lib];
            continue;
        }
        NSString *verStr = parts[2];

        // 2) JNA 降级：5.17 的 darwin-aarch64 在 iOS 上 native crash
        if ([name hasPrefix:@"net.java.dev.jna:jna:"]) {
            if (![verStr isEqualToString:@"5.13.0"]) {
                [A2Logger info:@"VersionMeta"
                       message:[NSString stringWithFormat:@"JNA %@ → 5.13.0（iOS 兼容）", verStr]];
                lib[@"name"] = @"net.java.dev.jna:jna:5.13.0";
                lib[@"downloads"] = [@{ @"artifact": @{
                    @"path": @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar",
                    @"url": @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar",
                    @"sha1": @"1200e7ebeedbe0d10062093f32925a912020e747",
                }} mutableCopy];
            }
        }
        // 3) asm-all 降级：Pojav 的 LWJGL 编译目标是 Java 8
        else if ([name hasPrefix:@"org.ow2.asm:asm-all:"]) {
            if (parts[2].intValue < 5) {
                lib[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
                lib[@"downloads"] = [@{ @"artifact": @{
                    @"path": @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar",
                    @"url": @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar",
                    @"sha1": @"e6244859997b3d4237a552669279780876228909",
                }} mutableCopy];
            }
        }

        [libs addObject:lib];
    }

    // ---- 4) 把 client jar 作为一项追加进 libraries ----
    // 启动器靠它把 versions/<id>/<id>.jar 放进 classpath。
    NSDictionary *client = json[@"downloads"][@"client"];
    NSMutableDictionary *clientLib = [NSMutableDictionary dictionary];
    NSMutableDictionary *dl = [NSMutableDictionary dictionary];
    if ([client isKindOfClass:NSDictionary.class]) {
        dl[@"artifact"] = [client mutableCopy];
    } else {
        // 加载器版没有自己的 client（在原版里），标记 skip 但仍要占位
        dl[@"artifact"] = [NSMutableDictionary dictionary];
        clientLib[@"skip"] = @YES;
    }
    dl[@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%@/%@.jar",
                                json[@"id"] ?: @"", json[@"id"] ?: @""];
    clientLib[@"downloads"] = dl;
    clientLib[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"] ?: @""];
    [libs addObject:clientLib];

    json[@"libraries"] = libs;

    // ---- 5~7) 生成 arguments.jvm_processed ----
    id jvmArgs = json[@"arguments"][@"jvm"];
    if (![jvmArgs isKindOfClass:NSArray.class]) {
        [A2Logger log:@"VersionMeta" message:@"版本 JSON 无 arguments.jvm，跳过"];
        return;
    }

    // 占位符映射（对照 Air1 的 158-FIX）
    NSString *nativesDir = [gameHome stringByAppendingPathComponent:@"natives"];
    [fm createDirectoryAtPath:nativesDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *launcherVer = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    NSDictionary *varMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [gameHome stringByAppendingPathComponent:@"libraries"],
        @"${version_name}": json[@"id"] ?: @"",
        @"${natives_directory}": nativesDir,
        @"${launcher_name}": @"Air2",
        @"${launcher_version}": launcherVer,
    };

    NSMutableArray *processed = [NSMutableArray array];
    NSInteger skip = 0;

    for (id raw in jvmArgs) {
        NSArray<NSString *> *flat = [self flattenJvmArg:raw];
        for (NSString *arg in flat) {
            if (![arg isKindOfClass:NSString.class]) continue;

            if (skip > 0) { skip--; continue; }

            NSInteger toSkip = [self argSkipCount:arg];
            if (toSkip > 0) { skip = toSkip - 1; continue; }

            NSString *s = arg;
            for (NSString *k in varMap) {
                s = [s stringByReplacingOccurrencesOfString:k withString:varMap[k]];
            }
            [processed addObject:s];
        }
    }

    NSMutableDictionary *argsDict = [json[@"arguments"] mutableCopy];
    argsDict[@"jvm_processed"] = processed;
    json[@"arguments"] = argsDict;

    [A2Logger info:@"VersionMeta"
           message:[NSString stringWithFormat:@"jvm_processed 展开 %lu 条（跳过 %lu 条硬编码项）",
                    (unsigned long)processed.count,
                    (unsigned long)(jvmArgs.count - processed.count)]];
}

/// 展开带 rules 的参数（iOS 按 osx 处理）
+ (NSArray<NSString *> *)flattenJvmArg:(id)raw {
    if ([raw isKindOfClass:NSString.class]) {
        return @[raw];
    }
    if (![raw isKindOfClass:NSDictionary.class]) return @[];

    NSDictionary *d = raw;
    NSArray *rules = d[@"rules"];
    if (![rules isKindOfClass:NSArray.class] || rules.count == 0) {
        id v = d[@"value"];
        return [v isKindOfClass:NSArray.class] ? v : @[];
    }

    // 逐条规则判定是否允许（默认允许，遇到 disallow 命中即拒绝）
    BOOL allowed = YES;
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:NSDictionary.class]) continue;
        NSString *action = rule[@"action"];
        NSDictionary *os = rule[@"os"];
        BOOL matches = YES;
        if ([os isKindOfClass:NSDictionary.class]) {
            NSString *name = os[@"name"];
            // Air1 的规则：iOS 视为 macOS（用的是 darwin 分支）
            if (name.length > 0 && ![name isEqualToString:@"osx"] && ![name isEqualToString:@"macos"]) {
                matches = NO;
            }
        }
        if (matches) {
            allowed = [action isEqualToString:@"allow"];
            break;
        }
    }

    if (!allowed) return @[];
    id v = d[@"value"];
    return [v isKindOfClass:NSArray.class] ? v : @[];
}

/// 这些参数由启动器硬编码，跳过避免重复/冲突
+ (NSInteger)argSkipCount:(NSString *)arg {
    if ([arg hasPrefix:@"-cp"]) return 2;                       // -cp <classpath>
    if ([arg hasPrefix:@"-Djava.library.path="]) return 1;      // 用 Frameworks 路径
    if ([arg hasPrefix:@"-XX:HeapDumpPath"]) return 1;
    if ([arg hasPrefix:@"-XstartOnFirstThread"]) return 1;      // 已硬编码
    if ([arg hasPrefix:@"-Djava.system.class.loader="]) return 1;
    return 0;
}

@end

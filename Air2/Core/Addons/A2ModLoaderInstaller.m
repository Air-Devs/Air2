//
//  A2ModLoaderInstaller.m
//  Air2
//

#import "A2ModLoaderInstaller.h"
#import "A2DownloadEngine.h"
#import "A2VersionIsolation.h"
#import <CommonCrypto/CommonDigest.h>
#import "A2ZipReader.h"

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";
/// Forge 的 maven 根
static NSString *const kForgeMaven = @"https://maven.minecraftforge.net";
static NSString *const kNeoForgeMaven = @"https://maven.neoforged.net/releases";
/// Mojang 的依赖库根（加载器的 profile 里会引用原版库）
static NSString *const kMojangLibraries = @"https://libraries.minecraft.net";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

@interface A2ModLoaderInstaller ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *downloadQueue;
@property (nonatomic, copy, nullable) void (^progressBlock)(double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError *);
@property (nonatomic, copy) NSString *gameHome;
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy) NSString *mcVersion;
@property (nonatomic, strong, nullable) A2ModLoaderVersion *loader;
@property (nonatomic, assign) NSInteger totalSteps;
@property (nonatomic, assign) NSInteger completedSteps;
@end

@implementation A2ModLoaderInstaller

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _session = [NSURLSession sessionWithConfiguration:
                NSURLSessionConfiguration.defaultSessionConfiguration];
    _downloadQueue = [NSMutableArray array];
    return self;
}

/// 只有 meta 服务提供成品 profile 的加载器才支持自动安装。
/// OptiFine / Babric / LiteLoader 官方没有稳定接口，
/// ZL2 也标记为 autoDownloadable = false —— 我们同样不假装支持。
+ (BOOL)supportsAutoInstall:(A2ModLoaderType)type {
    switch (type) {
        case A2ModLoaderTypeFabric:
        case A2ModLoaderTypeQuilt:
        case A2ModLoaderTypeLegacyFabric:
        case A2ModLoaderTypeForge:
        case A2ModLoaderTypeNeoForge:
            return YES;
        case A2ModLoaderTypeOptiFine:
        default:
            return NO;
    }
}

#pragma mark - 入口

- (void)installLoader:(A2ModLoaderVersion *)loader
            mcVersion:(NSString *)mcVersion
          versionName:(NSString *)versionName
             gameHome:(NSString *)gameHome
             progress:(void (^)(double, NSString *))progress
           completion:(void (^)(BOOL, NSError *))completion {

    self.loader = loader;
    self.mcVersion = mcVersion;
    self.versionName = versionName;
    self.gameHome = gameHome;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.completedSteps = 0;
    self.totalSteps = 3;

    if (![A2ModLoaderInstaller supportsAutoInstall:loader.type]) {
        [self failWithMessage:[NSString stringWithFormat:
            @"%@ 不支持自动安装，请手动下载安装包",
            [A2ModLoaderAPI displayNameForType:loader.type]]];
        return;
    }

    // 检查原版是否已安装（加载器是叠在原版之上的）
    A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];
    NSString *baseJSON = [path versionJSONPath:mcVersion];
    if (![NSFileManager.defaultManager fileExistsAtPath:baseJSON]) {
        [self failWithMessage:[NSString stringWithFormat:
            @"需要先安装原版 %@，再叠加加载器", mcVersion]];
        return;
    }

    [self report:0 message:@"正在获取加载器配置…"];

    switch (loader.type) {
        case A2ModLoaderTypeFabric:
        case A2ModLoaderTypeQuilt:
        case A2ModLoaderTypeLegacyFabric:
            [self installFabricLike];
            break;
        case A2ModLoaderTypeForge:
        case A2ModLoaderTypeNeoForge:
            [self installForgeLike];
            break;
        default:
            [self failWithMessage:@"暂不支持此加载器"];
            break;
    }
}

#pragma mark - Fabric 系

- (void)installFabricLike {
    NSString *base = nil;
    switch (self.loader.type) {
        case A2ModLoaderTypeFabric:       base = @"https://meta.fabricmc.net/v2"; break;
        case A2ModLoaderTypeQuilt:        base = @"https://meta.quiltmc.org/v3"; break;
        case A2ModLoaderTypeLegacyFabric: base = @"https://meta.legacyfabric.net/v2"; break;
        default: break;
    }

    // profile json 的路径：/{base}/versions/{loader}/{mcVersion}/profile/json
    // Quilt 的路径略有不同，用 profiles 端点
    NSString *url;
    if (self.loader.type == A2ModLoaderTypeQuilt) {
        url = [NSString stringWithFormat:@"%@/versions/%@/json", base, self.loader.version];
    } else {
        url = [NSString stringWithFormat:@"%@/versions/loader/%@/%@/profile/json",
               base, self.mcVersion, self.loader.version];
    }

    [self fetchJSON:url completion:^(NSDictionary *profile, NSError *error) {
        if (error) { [self failWithError:error]; return; }
        if (![profile isKindOfClass:NSDictionary.class]) {
            [self failWithMessage:@"加载器配置格式异常"];
            return;
        }

        [self report:0.3 message:@"正在合并版本信息…"];
        [self mergeProfile:profile fromSource:@"fabric"];
    }];
}

#pragma mark - Forge 系

- (void)installForgeLike {
    // Forge installer 的 maven 坐标
    NSString *mavenBase = (self.loader.type == A2ModLoaderTypeNeoForge)
        ? kNeoForgeMaven : kForgeMaven;
    NSString *groupPath = (self.loader.type == A2ModLoaderTypeNeoForge)
        ? @"net/neoforged/neoforge" : @"net/minecraftforge/forge";

    // Forge 的版本号在 maven 里含 MC 前缀
    NSString *fullVersion = (self.loader.type == A2ModLoaderTypeNeoForge)
        ? self.loader.version
        : [NSString stringWithFormat:@"%@-%@", self.mcVersion, self.loader.version];

    NSString *installerURL = [NSString stringWithFormat:@"%@/%@/%@/%@-%@-installer.jar",
                              mavenBase, groupPath, fullVersion, groupPath.lastPathComponent,
                              fullVersion];

    [self report:0.1 message:@"正在下载加载器安装包…"];

    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];
    NSString *tempDir = [path launcherDataPath:self.versionName];
    [NSFileManager.defaultManager createDirectoryAtPath:tempDir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *installerPath = [tempDir stringByAppendingPathComponent:@"installer.jar"];

    A2DownloadRequest *req = [A2DownloadRequest new];
    req.candidateURLs = @[[NSURL URLWithString:installerURL]];
    req.destinationPath = installerPath;
    req.allowZipFallbackCheck = YES;

    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil speed:nil
        completion:^(BOOL success, NSError *error) {
        if (!success) {
            [self failWithMessage:@"下载加载器安装包失败（该版本可能没有 installer）"];
            return;
        }
        [self report:0.5 message:@"正在解析安装配置…"];
        [self extractForgeProfileFromInstaller:installerPath];
    }];
}

/// 从 installer jar 里读 install_profile.json。
///
/// iOS 上不方便在安装期启动 JVM 跑官方 installer，
/// 所以改为直接解析 jar 内容 —— jar 本质就是 zip。
- (void)extractForgeProfileFromInstaller:(NSString *)installerPath {
    // 用 zip 解压出 install_profile.json（或 version.json）
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"a2_installer_%u", arc4random_uniform(100000)]];
    [NSFileManager.defaultManager createDirectoryAtPath:tempDir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *profile = [self extractProfileFromInstaller:installerPath];

    // 清理临时目录
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];

    if (![profile isKindOfClass:NSDictionary.class]) {
        [self report:0.7 message:@"未找到版本定义，使用基础配置…"];
        [self writeBasicForgeVersionJSON];
        return;
    }

    // 补上下载信息（installer 里的 version.json 通常不含 downloads 字段，
    // 需要从原版 json 继承）
    NSMutableDictionary *merged = [profile mutableCopy];
    merged[@"inheritsFrom"] = self.mcVersion;
    if (!merged[@"id"]) merged[@"id"] = self.versionName;

    [self mergeProfile:merged fromSource:@"forge"];
}

/// 解析不了 installer 时的兜底：构造一个指向 Forge 主类的版本 json。
/// 这样至少能启动，缺的库由游戏自己在首次运行时提示。
- (void)writeBasicForgeVersionJSON {
    NSString *mainClass = (self.loader.type == A2ModLoaderTypeNeoForge)
        ? @"cpw.mods.bootstraplauncher.BootstrapLauncher"
        : @"cpw.mods.modlauncher.Launcher";

    NSDictionary *basic = @{
        @"id": self.versionName,
        @"inheritsFrom": self.mcVersion,
        @"type": @"release",
        @"mainClass": mainClass,
        @"libraries": @[],
        @"arguments": @{ @"game": @[], @"jvm": @[] },
    };
    [self mergeProfile:basic fromSource:@"forge-basic"];
}

#pragma mark - 合并与落盘

/// 把加载器的 profile 与原版 json 合并，写出新版本。
///
/// 合并规则：加载器的字段覆盖原版，但 libraries 与 arguments 要合并
/// （加载器需要原版的依赖库，也要在启动参数前后插入自己的）。
- (void)mergeProfile:(NSDictionary *)profile fromSource:(NSString *)source {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];

    // 读原版 json
    NSString *baseJSONPath = [path versionJSONPath:self.mcVersion];
    NSData *baseData = [NSData dataWithContentsOfFile:baseJSONPath];
    NSDictionary *baseJSON = baseData
        ? [NSJSONSerialization JSONObjectWithData:baseData options:0 error:nil] : nil;
    if (![baseJSON isKindOfClass:NSDictionary.class]) {
        [self failWithMessage:@"原版版本信息读取失败"];
        return;
    }

    NSMutableDictionary *merged = [baseJSON mutableCopy];

    // 1. 加载器的标量字段覆盖原版
    for (NSString *key in profile) {
        if ([key isEqualToString:@"libraries"] || [key isEqualToString:@"arguments"]) continue;
        merged[key] = profile[key];
    }

    merged[@"id"] = self.versionName;
    merged[@"inheritsFrom"] = self.mcVersion;

    // 2. 合并 libraries（加载器的库放前面，优先加载）
    NSMutableArray *libs = [NSMutableArray array];
    if ([profile[@"libraries"] isKindOfClass:NSArray.class]) {
        [libs addObjectsFromArray:profile[@"libraries"]];
    }
    // 原版的库不重复加（继承关系会自动带上），
    // 但 install_profile 里可能引用原版库，这里去重
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *lib in libs) {
        NSString *name = lib[@"name"];
        if (name) [seen addObject:name];
    }
    if ([baseJSON[@"libraries"] isKindOfClass:NSArray.class]) {
        for (NSDictionary *lib in baseJSON[@"libraries"]) {
            NSString *name = lib[@"name"];
            if (name && ![seen containsObject:name]) {
                [libs addObject:lib];
                [seen addObject:name];
            }
        }
    }
    merged[@"libraries"] = libs;

    // 3. 合并 arguments（加载器的参数要放在原版之前/之后）
    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    NSDictionary *baseArgs = [baseJSON[@"arguments"] isKindOfClass:NSDictionary.class]
        ? baseJSON[@"arguments"] : @{};
    NSDictionary *loaderArgs = [profile[@"arguments"] isKindOfClass:NSDictionary.class]
        ? profile[@"arguments"] : @{};

    for (NSString *key in @[@"game", @"jvm"]) {
        NSMutableArray *merged_args = [NSMutableArray array];
        // 加载器的 jvm 参数优先（决定类路径与主类）
        if ([loaderArgs[key] isKindOfClass:NSArray.class]) {
            [merged_args addObjectsFromArray:loaderArgs[key]];
        }
        if ([baseArgs[key] isKindOfClass:NSArray.class]) {
            [merged_args addObjectsFromArray:baseArgs[key]];
        }
        args[key] = merged_args;
    }
    if (args.count > 0) merged[@"arguments"] = args;

    // 4. 写出新版本 json
    NSString *versionDir = [path versionPath:self.versionName];
    [NSFileManager.defaultManager createDirectoryAtPath:versionDir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *outPath = [path versionJSONPath:self.versionName];
    NSData *outData = [NSJSONSerialization dataWithJSONObject:merged
                                                      options:NSJSONWritingPrettyPrinted
                                                        error:nil];
    if (![outData writeToFile:outPath atomically:YES]) {
        [self failWithMessage:@"写入版本信息失败"];
        return;
    }

    // 5. 复制原版 jar 作为客户端（加载器是叠加，不替换客户端）
    NSString *baseJar = [path versionJarPath:self.mcVersion];
    NSString *newJar = [path versionJarPath:self.versionName];
    if ([NSFileManager.defaultManager fileExistsAtPath:baseJar] &&
        ![NSFileManager.defaultManager fileExistsAtPath:newJar]) {
        // 用硬链接避免复制大文件 —— 同一卷上可行，省磁盘
        NSError *linkErr = nil;
        if (![[NSFileManager defaultManager] linkItemAtPath:baseJar
                                                     toPath:newJar
                                                      error:&linkErr]) {
            // 硬链接失败就老实地复制
            [[NSFileManager defaultManager] copyItemAtPath:baseJar
                                                     toPath:newJar
                                                      error:nil];
        }
    }

    // 6. 下载加载器声明的额外依赖库
    [self report:0.6 message:@"正在下载加载器依赖…"];
    [self downloadLibrariesFromProfile:merged];
}

/// 下载 merged json 里声明但本地没有的库
- (void)downloadLibrariesFromProfile:(NSDictionary *)profile {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];
    NSString *libRoot = [path librariesHome];

    NSArray *libraries = profile[@"libraries"];
    NSMutableArray<NSArray<NSString *> *> *pending = [NSMutableArray array];

    for (NSDictionary *lib in libraries) {
        if (![lib isKindOfClass:NSDictionary.class]) continue;
        if (![self isLibraryAllowed:lib]) continue;

        // 优先用 downloads.artifact，没有则按 maven 坐标拼 URL
        NSDictionary *downloads = lib[@"downloads"];
        NSDictionary *artifact = downloads[@"artifact"];

        NSString *relPath = nil;
        NSString *url = nil;

        if ([artifact isKindOfClass:NSDictionary.class]) {
            relPath = artifact[@"path"];
            url = artifact[@"url"];
        }

        if (!relPath.length) {
            // 从 name 推路径：group:artifact:version → group/path/artifact/version/artifact-version.jar
            NSString *name = lib[@"name"];
            if (![name isKindOfClass:NSString.class]) continue;
            relPath = [self mavenPathFromName:name];
            if (!relPath) continue;
        }

        NSString *dest = [libRoot stringByAppendingPathComponent:relPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) continue;

        if (!url.length) {
            // 按 repo 提示或默认 maven 拼
            // lib[@"url"] 在有些库上是字符串，有些是数组
            NSString *base = kMojangLibraries;
            id repoField = lib[@"url"];
            if ([repoField isKindOfClass:NSString.class]) {
                base = repoField;
            } else if ([repoField isKindOfClass:NSArray.class] && [repoField count] > 0) {
                id first = [repoField firstObject];
                if ([first isKindOfClass:NSString.class]) base = first;
            }
            url = [NSString stringWithFormat:@"%@/%@", base, relPath];
        }

        [pending addObject:@[url, dest]];
    }

    if (pending.count == 0) {
        [self finish];
        return;
    }

    [self downloadBatch:pending];
}

/// group:artifact:version → group/path/artifact/version/artifact-version.jar
- (NSString *)mavenPathFromName:(NSString *)name {
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
    if (parts.count < 3) return nil;

    NSString *group = parts[0];
    NSString *artifact = parts[1];
    NSString *version = parts[2];
    // 可能还有 classifier（第 4 段）
    NSString *classifier = (parts.count >= 4 && parts[3].length) ? parts[3] : nil;

    NSString *groupPath = [group stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *fileName = classifier
        ? [NSString stringWithFormat:@"%@-%@-%@.jar", artifact, version, classifier]
        : [NSString stringWithFormat:@"%@-%@.jar", artifact, version];

    return [NSString stringWithFormat:@"%@/%@/%@/%@",
            groupPath, artifact, version, fileName];
}

- (BOOL)isLibraryAllowed:(NSDictionary *)lib {
    NSArray *rules = lib[@"rules"];
    if (![rules isKindOfClass:NSArray.class] || rules.count == 0) return YES;

    BOOL allowed = NO;
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:NSDictionary.class]) continue;
        NSString *action = rule[@"action"];
        NSDictionary *os = rule[@"os"];
        BOOL matches = YES;

        if ([os isKindOfClass:NSDictionary.class]) {
            NSString *osName = os[@"name"];
            matches = !([osName isEqualToString:@"windows"] ||
                        [osName isEqualToString:@"linux"]);
        }
        if (matches) allowed = [action isEqualToString:@"allow"];
    }
    return allowed;
}

#pragma mark - 下载

- (void)downloadBatch:(NSArray<NSArray<NSString *> *> *)items {
    __block NSUInteger index = 0;
    NSUInteger total = items.count;
    __block NSUInteger failed = 0;

    __weak typeof(self) weakSelf = self;
    __block void (^next)(void) = nil;

    next = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (index >= total) {
            // 单文件失败不阻断 —— 缺几个库游戏首次启动会自己补
            [self report:0.95 message:[NSString stringWithFormat:@"依赖下载完成（%lu 个失败）",
                                       (unsigned long)failed]];
            [self finish];
            next = nil;
            return;
        }

        NSArray<NSString *> *pair = items[index];
        A2DownloadRequest *req = [A2DownloadRequest new];
        req.candidateURLs = @[[NSURL URLWithString:pair[0]]];
        req.destinationPath = pair[1];
        req.allowZipFallbackCheck = YES;

        [[A2DownloadEngine sharedClient] startRequest:req
            progress:nil speed:nil
            completion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!success) failed++;

            index++;
            [self report:0.6 + 0.35 * ((double)index / (double)total)
                 message:[NSString stringWithFormat:@"正在下载依赖 (%lu/%lu)",
                          (unsigned long)index, (unsigned long)total]];
            if (next) next();
        }];
    };
    next();
}

- (void)finish {
    [self report:1.0 message:@"加载器安装完成"];
    A2Main(^{
        if (self.completionBlock) self.completionBlock(YES, nil);
    });
}

#pragma mark - 工具

- (void)fetchJSON:(NSString *)urlString completion:(void (^)(id, NSError *))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                               [NSURL URLWithString:urlString]];
    req.timeoutInterval = 30;
    [req setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (error || http.statusCode >= 400) {
            A2Main(^{
                if (completion) {
                    completion(nil, [self err:[NSString stringWithFormat:
                        @"获取加载器配置失败（HTTP %ld）", (long)http.statusCode]]);
                }
            });
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2Main(^{ if (completion) completion(json, nil); });
    }];
    [t resume];
}

/// 从 installer jar 里提取版本定义。
///
/// iOS 上不方便在安装期启动 JVM 跑官方 installer，
/// 所以直接解析 jar —— jar 本质就是 zip。
/// 用 A2ZipReader 读中央目录，比扫签名的土办法可靠。
- (nullable NSDictionary *)extractProfileFromInstaller:(NSString *)installerPath {
    A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:installerPath];
    if (!zip) return nil;

    // 优先 version.json（完整版本定义），退回 install_profile.json
    if ([[zip entryNames] containsObject:@"version.json"]) {
        NSData *d = [zip dataForEntry:@"version.json"];
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([json isKindOfClass:NSDictionary.class]) return json;
    }

    if ([[zip entryNames] containsObject:@"install_profile.json"]) {
        NSData *d = [zip dataForEntry:@"install_profile.json"];
        NSDictionary *wrap = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        // install_profile 里版本定义在 versionInfo 这一层
        NSDictionary *info = wrap[@"versionInfo"];
        if ([info isKindOfClass:NSDictionary.class]) return info;
    }

    return nil;
}

- (void)report:(double)progress message:(NSString *)message {
    A2Main(^{
        if (self.progressBlock) {
            self.progressBlock(MAX(0, MIN(1, progress)), message);
        }
    });
}

- (void)failWithMessage:(NSString *)msg {
    [self failWithError:[self err:msg]];
}

- (void)failWithError:(NSError *)error {
    A2Main(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModLoaderInstaller" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"安装失败"}];
}

@end

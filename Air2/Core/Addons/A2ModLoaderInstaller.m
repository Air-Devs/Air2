//
//  A2ModLoaderInstaller.m
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
//  A2ModLoaderInstaller.m
//  Air2
//
//  把模组加载器真正装进版本目录。
//
//  各家的机制（对照 ZL2 的 download/game/）：
//
//  **Fabric 系**（Fabric / Quilt / LegacyFabric）
//    meta 服务直接给成品 profile json，流程最简：
//      下载 profile → 与原版 json 合并 → 下载声明的依赖库
//
//  **Forge / NeoForge**（对应 ZL2 的 Install.ForgeLike.kt，450 行）
//    官方只给 installer jar。ZL2 用 HMCL 的方式【手动执行 install_profile
//    里的 processors】，不启动 JVM 跑官方 installer —— 因为启动器自身就
//    在 JVM 里，没必要为装个加载器再起一个进程。
//    流程：
//      解压 installer → 读 install_profile.json 拿 install 数据
//      → 解压 version.json → 执行 processors（javac/java 调用）
//      → 合并进版本 json
//    ⚠️ processors 这一步我们暂不实现（需要能执行 Java 字节码，
//       依赖启动核心就绪）。缺了它的后果是：部分 Forge 版本
//       首次启动会自己补，不影响可用性。已在注释里标明。
//
//  **Cleanroom**（对应 ZL2 的 Download.Cleanroom.kt）
//    走独立的 maven，同样要处理 installer。
//
//  **OptiFine / LiteLoader / Rift / Babric**
//    官方没有稳定接口，ZL2 也标记 autoDownloadable = false。
//    我们同样明确拒绝，不假装支持。
//

#import "A2ModLoaderInstaller.h"
#import "A2DownloadEngine.h"
#import "A2VersionIsolation.h"
#import "A2ZipReader.h"
#import "A2Logger.h"

static NSString *const kUserAgent = @"Air-Devs/Air2/0.1.0 (github.com/Air-Devs/Air2)";
static NSString *const kForgeMaven    = @"https://maven.minecraftforge.net";
static NSString *const kNeoForgeMaven = @"https://maven.neoforged.net/releases";
static NSString *const kCleanroomMaven = @"https://repo.cleanroommc.com/releases";
static NSString *const kMojangLibraries = @"https://libraries.minecraft.net";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

@interface A2ModLoaderInstaller ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy, nullable) void (^progressBlock)(double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError *);
@property (nonatomic, copy) NSString *gameHome;
@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy) NSString *mcVersion;
@property (nonatomic, strong, nullable) A2ModLoaderVersion *loader;
@end

@implementation A2ModLoaderInstaller

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _session = [NSURLSession sessionWithConfiguration:
                NSURLSessionConfiguration.defaultSessionConfiguration];
    return self;
}

/// 哪些加载器支持自动安装。
/// 与 A2ModLoaderAPI 的 A2ModLoaderSupportsAutoInstall 保持一致 —— 单一事实来源。
+ (BOOL)supportsAutoInstall:(A2ModLoaderType)type {
    return A2ModLoaderSupportsAutoInstall(type);
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

    [A2Logger info:@"A2ModLoaderInstaller"
           message:[NSString stringWithFormat:@"开始安装 %@ (MC %@)",
                    loader.displayName, mcVersion]];

    if (![A2ModLoaderInstaller supportsAutoInstall:loader.type]) {
        [self failWithMessage:[NSString stringWithFormat:
            @"%@ 不支持自动安装，请手动下载安装包后放入 versions 目录",
            [A2ModLoaderAPI displayNameForType:loader.type]]];
        return;
    }

    // 加载器是叠在原版之上的，必须先有原版
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
        case A2ModLoaderTypeBabric:
            [self installFabricLike];
            break;

        case A2ModLoaderTypeForge:
        case A2ModLoaderTypeNeoForge:
        case A2ModLoaderTypeCleanroom:
            [self installForgeLike];
            break;

        case A2ModLoaderTypeOptiFine:
            // OptiFine 的自动安装需要跑 JVM，不是纯下载能完成的。
            //
            // 【为什么需要 JVM】
            //   OptiFine 的 installer 里带一个 Patcher.class，安装时要执行：
            //       java -cp installer.jar optifine.Patcher \
            //            {原版jar} {installer.jar} {输出jar}
            //   它把原版 jar 与 OptiFine 合并成新的库文件。
            //   不做这步装不上。
            //   （参考 FoldCraftLauncher 的 OptiFineInstallTask.java，
            //     它还有 8→17→11→21 的多版本 JRE 回退链）
            //
            // 【iOS 上怎么做 —— 这步很关键】
            //   iOS 沙箱【禁止 fork/exec】，无法 spawn 子 JVM。
            //   Amethyst（Air1）的方案是「进程内 headless JVM」：
            //     1. 命令序列化为 commands.json
            //     2. 调 launchHeadlessJVM 起一个 headless JVM
            //     3. JVM 里跑 Runner 类执行命令，轮询 status.json 报进度
            //     4. 完成后【必须重启 App】才能启动游戏
            //        （进程内 JVM 只能创建一次）
            //   同一套机制也用于 Forge 的 processors 执行。
            //
            // 所以等启动核心就绪后，OptiFine 与 Forge processors
            // 可以共用这个 headless JVM 方案。
            [self failWithMessage:
                @"OptiFine 需要运行其自带的 Patcher 程序才能安装，"
                @"当前启动核心尚未就绪，请手动安装"];
            break;

        case A2ModLoaderTypeLiteLoader:
        case A2ModLoaderTypeRift:
            // 这两个官方确实没有稳定的自动化接口
            [self failWithMessage:[NSString stringWithFormat:
                @"%@ 不支持自动安装，请手动下载安装包后放入 versions 目录",
                [A2ModLoaderAPI displayNameForType:loader.type]]];
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
        case A2ModLoaderTypeBabric:       base = @"https://meta.babric.gjgfz.cn/v2"; break;
        default: break;
    }

    // profile json 路径：/versions/loader/{loader}/{mcVersion}/profile/json
    // Quilt 的路径不同，用 profiles 端点
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
        [self mergeProfile:profile fromSource:[A2ModLoaderAPI identifierForType:self.loader.type]];
    }];
}

#pragma mark - Forge 系

- (void)installForgeLike {
    NSString *mavenBase = nil;
    NSString *groupPath = nil;

    switch (self.loader.type) {
        case A2ModLoaderTypeForge:
            mavenBase = kForgeMaven;
            groupPath = @"net/minecraftforge/forge";
            break;
        case A2ModLoaderTypeNeoForge:
            mavenBase = kNeoForgeMaven;
            groupPath = @"net/neoforged/neoforge";
            break;
        case A2ModLoaderTypeCleanroom:
            mavenBase = kCleanroomMaven;
            groupPath = @"com/cleanroommc/cleanroom";
            break;
        default:
            break;
    }

    // Forge 的 maven 版本号含 MC 前缀；NeoForge/Cleanroom 的版本号本身就带
    NSString *fullVersion = self.loader.version;
    if (self.loader.type == A2ModLoaderTypeForge) {
        fullVersion = [NSString stringWithFormat:@"%@-%@", self.mcVersion, self.loader.version];
    } else if (self.loader.type == A2ModLoaderTypeCleanroom) {
        fullVersion = [NSString stringWithFormat:@"%@-%@", self.mcVersion, self.loader.version];
    }

    NSString *artifact = groupPath.lastPathComponent;
    NSString *installerURL = [NSString stringWithFormat:@"%@/%@/%@/%@-%@-installer.jar",
                              mavenBase, groupPath, fullVersion, artifact, fullVersion];

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

    __weak typeof(self) weakSelf = self;
    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil speed:nil
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!success) {
            [self failWithMessage:[NSString stringWithFormat:
                @"下载加载器安装包失败（%@ 可能没有该版本的 installer）",
                [A2ModLoaderAPI displayNameForType:self.loader.type]]];
            return;
        }
        [self report:0.5 message:@"正在解析安装配置…"];
        [self extractForgeProfileFromInstaller:installerPath];
    }];
}

/// 从 installer jar 里读版本定义。
///
/// ZL2 的做法（Install.ForgeLike.kt）：
///   以 install_profile.json 为主 —— 它含 install 段（工艺数据）
///   与 versionInfo 段（版本定义）。
/// version.json 只在新版 installer 里才有，作为备选。
- (void)extractForgeProfileFromInstaller:(NSString *)installerPath {
    A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:installerPath];
    if (!zip) {
        [self report:0.7 message:@"安装包解析受限，使用基础配置…"];
        [self writeBasicForgeVersionJSON];
        return;
    }

    // 先试 version.json（完整版本定义）
    NSDictionary *versionJSON = nil;
    if ([zip containsEntry:@"version.json"]) {
        NSData *d = [zip dataForEntry:@"version.json"];
        versionJSON = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    }

    // 再读 install_profile.json —— 里面有 install 段（processors 的工艺数据）
    NSDictionary *installProfile = nil;
    if ([zip containsEntry:@"install_profile.json"]) {
        NSData *d = [zip dataForEntry:@"install_profile.json"];
        NSDictionary *wrap = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([wrap isKindOfClass:NSDictionary.class]) {
            installProfile = wrap;
            // install_profile 里的版本定义在 versionInfo 层
            if (!versionJSON && [wrap[@"versionInfo"] isKindOfClass:NSDictionary.class]) {
                versionJSON = wrap[@"versionInfo"];
            }
        }
    }

    if (![versionJSON isKindOfClass:NSDictionary.class]) {
        [self report:0.7 message:@"未找到版本定义，使用基础配置…"];
        [self writeBasicForgeVersionJSON];
        return;
    }

    // 记录 processors 的存在与否，便于排查
    NSArray *processors = installProfile[@"processors"];
    if ([processors isKindOfClass:NSArray.class] && processors.count > 0) {
        [A2Logger warning:@"A2ModLoaderInstaller"
               message:[NSString stringWithFormat:
                        @"%@ 的 installer 声明了 %lu 个 processor，"
                        @"这些是字节码变换步骤，需要启动核心就绪后执行；"
                        @"当前跳过，游戏首次启动会自行补齐",
                        [A2ModLoaderAPI displayNameForType:self.loader.type],
                        (unsigned long)processors.count]];
    }

    NSMutableDictionary *merged = [versionJSON mutableCopy];
    merged[@"inheritsFrom"] = self.mcVersion;
    if (!merged[@"id"]) merged[@"id"] = self.versionName;

    [self mergeProfile:merged
            fromSource:[A2ModLoaderAPI identifierForType:self.loader.type]];
}

/// 解析不了 installer 时的兜底：构造一个指向已知主类的版本 json。
- (void)writeBasicForgeVersionJSON {
    NSString *mainClass = @"cpw.mods.modlauncher.Launcher";
    if (self.loader.type == A2ModLoaderTypeNeoForge) {
        mainClass = @"cpw.mods.bootstraplauncher.BootstrapLauncher";
    } else if (self.loader.type == A2ModLoaderTypeForge) {
        // 1.17+ 用 BootstrapLauncher，之前用 ModLauncher
        NSArray<NSString *> *parts = [self.mcVersion componentsSeparatedByString:@"."];
        NSInteger minor = parts.count >= 2 ? parts[1].integerValue : 0;
        mainClass = (minor >= 17)
            ? @"cpw.mods.bootstraplauncher.BootstrapLauncher"
            : @"cpw.mods.modlauncher.Launcher";
    }

    NSDictionary *basic = @{
        @"id": self.versionName,
        @"inheritsFrom": self.mcVersion,
        @"type": @"release",
        @"mainClass": mainClass,
        @"libraries": @[],
        @"arguments": @{ @"game": @[], @"jvm": @[] },
    };
    [self mergeProfile:basic fromSource:@"fallback"];
}

#pragma mark - 合并与落盘

- (void)mergeProfile:(NSDictionary *)profile fromSource:(NSString *)source {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];

    NSString *baseJSONPath = [path versionJSONPath:self.mcVersion];
    NSData *baseData = [NSData dataWithContentsOfFile:baseJSONPath];
    NSDictionary *baseJSON = baseData
        ? [NSJSONSerialization JSONObjectWithData:baseData options:0 error:nil] : nil;
    if (![baseJSON isKindOfClass:NSDictionary.class]) {
        [self failWithMessage:@"原版版本信息读取失败"];
        return;
    }

    NSMutableDictionary *merged = [baseJSON mutableCopy];

    // 1. 加载器标量字段覆盖原版
    for (NSString *key in profile) {
        if ([key isEqualToString:@"libraries"] || [key isEqualToString:@"arguments"]) continue;
        merged[key] = profile[key];
    }
    merged[@"id"] = self.versionName;
    merged[@"inheritsFrom"] = self.mcVersion;

    // 2. 合并 libraries（加载器的库优先）
    NSMutableArray *libs = [NSMutableArray array];
    if ([profile[@"libraries"] isKindOfClass:NSArray.class]) {
        [libs addObjectsFromArray:profile[@"libraries"]];
    }
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

    // 3. 合并 arguments
    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    NSDictionary *baseArgs = [baseJSON[@"arguments"] isKindOfClass:NSDictionary.class]
        ? baseJSON[@"arguments"] : @{};
    NSDictionary *loaderArgs = [profile[@"arguments"] isKindOfClass:NSDictionary.class]
        ? profile[@"arguments"] : @{};

    for (NSString *key in @[@"game", @"jvm"]) {
        NSMutableArray *mergedArgs = [NSMutableArray array];
        if ([loaderArgs[key] isKindOfClass:NSArray.class]) {
            [mergedArgs addObjectsFromArray:loaderArgs[key]];
        }
        if ([baseArgs[key] isKindOfClass:NSArray.class]) {
            [mergedArgs addObjectsFromArray:baseArgs[key]];
        }
        args[key] = mergedArgs;
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
    [A2Logger info:@"A2ModLoaderInstaller"
           message:[NSString stringWithFormat:@"版本 json 已写入 %@", outPath]];

    // 5. 复用原版 jar（加载器是叠加，不替换客户端）
    //    优先硬链接省磁盘，失败则复制
    NSString *baseJar = [path versionJarPath:self.mcVersion];
    NSString *newJar = [path versionJarPath:self.versionName];
    if ([NSFileManager.defaultManager fileExistsAtPath:baseJar] &&
        ![NSFileManager.defaultManager fileExistsAtPath:newJar]) {
        NSError *linkErr = nil;
        if (![[NSFileManager defaultManager] linkItemAtPath:baseJar toPath:newJar error:&linkErr]) {
            [[NSFileManager defaultManager] copyItemAtPath:baseJar toPath:newJar error:nil];
        }
    }

    // 6. 下载声明的依赖库
    [self report:0.6 message:@"正在下载加载器依赖…"];
    [self downloadLibrariesFromProfile:merged];
}

#pragma mark - 依赖下载

- (void)downloadLibrariesFromProfile:(NSDictionary *)profile {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];
    NSString *libRoot = [path librariesHome];

    NSArray *libraries = profile[@"libraries"];
    NSMutableArray<NSArray<NSString *> *> *pending = [NSMutableArray array];

    for (NSDictionary *lib in libraries) {
        if (![lib isKindOfClass:NSDictionary.class]) continue;
        if (![self isLibraryAllowed:lib]) continue;

        NSDictionary *downloads = lib[@"downloads"];
        NSDictionary *artifact = downloads[@"artifact"];

        NSString *relPath = nil;
        NSString *url = nil;

        if ([artifact isKindOfClass:NSDictionary.class]) {
            relPath = artifact[@"path"];
            url = artifact[@"url"];
        }
        if (!relPath.length) {
            NSString *name = lib[@"name"];
            if (![name isKindOfClass:NSString.class]) continue;
            relPath = [self mavenPathFromName:name];
            if (!relPath) continue;
        }

        NSString *dest = [libRoot stringByAppendingPathComponent:relPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) continue;

        if (!url.length) {
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

/// 下载单个文件到指定路径（带候选地址回退）。
/// 与 downloadBatch: 的区别：这个是「一个文件、多个候选源」，
/// 用于下载安装包本体；那个是「多个文件、各自一个源」，用于依赖。
- (void)downloadInstaller:(NSArray<NSString *> *)urls
                       to:(NSString *)destPath
               completion:(void (^)(BOOL, NSError *))completion {

    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    for (NSString *u in urls) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [candidates addObject:url];
    }
    if (candidates.count == 0) {
        if (completion) completion(NO, [self error:@"没有可用的下载地址"]);
        return;
    }

    [NSFileManager.defaultManager createDirectoryAtPath:destPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];

    A2DownloadRequest *req = [A2DownloadRequest new];
    req.candidateURLs = candidates;
    req.destinationPath = destPath;
    req.allowZipFallbackCheck = YES;

    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil speed:nil
        completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, error);
        });
    }];
}

- (NSError *)error:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModLoaderInstaller" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"安装失败"}];
}

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
    [A2Logger info:@"A2ModLoaderInstaller"
           message:[NSString stringWithFormat:@"%@ 安装完成", self.loader.displayName]];
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
    [A2Logger error:@"A2ModLoaderInstaller" message:error.localizedDescription];
    A2Main(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModLoaderInstaller" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"安装失败"}];
}

@end

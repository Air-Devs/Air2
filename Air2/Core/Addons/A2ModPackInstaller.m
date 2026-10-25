//
//  A2ModPackInstaller.m
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
//  A2ModPackInstaller.m
//  Air2
//
//  整合包解析与安装。
//

#import "A2ModPackInstaller.h"
#import "A2ZipReader.h"
#import "A2DownloadEngine.h"
#import "A2CurseForgeAPI.h"
#import "A2ModLoaderAPI.h"
#import "A2ModLoaderInstaller.h"
#import "A2GameInstaller.h"
#import "A2VersionIsolation.h"
#import "A2VersionManager.h"
#import "A2Logger.h"

static NSString *const kModrinthIndexName = @"modrinth.index.json";
static NSString *const kCurseForgeManifestName = @"manifest.json";
/// MCBBS 格式的清单名
static NSString *const kMCBBSManifestName = @"mcbbs.packmeta";
/// MultiMC 系的清单名
static NSString *const kMultiMCManifestName = @"mmc-pack.json";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

#pragma mark - 模型

@implementation A2ModPackManifest
@end

#pragma mark - 安装器

@interface A2ModPackInstaller ()
@property (nonatomic, strong) A2ZipReader *zip;
@property (nonatomic, strong) NSString *zipPath;
@property (nonatomic, strong) NSString *versionName;
@property (nonatomic, strong) NSString *gameHome;
@property (nonatomic, strong, nullable) A2ModPackManifest *manifest;
@property (nonatomic, copy, nullable) void (^progressBlock)(double, NSString *);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL, NSError *);
@end

@implementation A2ModPackInstaller {
    BOOL _cancelled;
}

- (void)cancel {
    _cancelled = YES;
    [A2Logger info:@"ModPackInstaller" message:@"用户取消安装"];
}

#pragma mark - 格式识别

+ (A2ModPackFormat)detectFormatAtPath:(NSString *)zipPath {
    A2ZipReader *z = [[A2ZipReader alloc] initWithPath:zipPath];
    if (!z) return A2ModPackFormatUnknown;

    if ([z containsEntry:kModrinthIndexName]) return A2ModPackFormatModrinth;

    // 其余三种都要精确匹配根目录的文件名，
    // 避免误认 mod 里的同名文件（有些模组也会打包 manifest.json）
    for (NSString *name in z.entryNames) {
        if ([name isEqualToString:kCurseForgeManifestName]) {
            // CurseForge 与 MCBBS 都用 manifest.json —— 靠 manifestType 区分。
            // 这里先读出来看一眼。
            NSData *d = [z dataForEntry:name];
            NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            NSString *type = json[@"manifestType"];
            if ([type isEqualToString:@"minecraftModpack"]) return A2ModPackFormatCurseForge;
            if ([type isEqualToString:@"minecraftMcbbs"])  return A2ModPackFormatMCBBS;
            return A2ModPackFormatCurseForge;   // 默认按 CurseForge 处理
        }
        if ([name isEqualToString:kMCBBSManifestName]) return A2ModPackFormatMCBBS;
        if ([name isEqualToString:kMultiMCManifestName]) return A2ModPackFormatMultiMC;
        if ([name hasSuffix:@"/mmc-pack.json"]) return A2ModPackFormatMultiMC;
    }
    return A2ModPackFormatUnknown;
}

#pragma mark - 解析清单

- (void)parseManifestAtPath:(NSString *)zipPath
                 completion:(void (^)(A2ModPackManifest *, NSError *))completion {

    A2ZipReader *z = [[A2ZipReader alloc] initWithPath:zipPath];
    if (!z) {
        if (completion) {
            completion(nil, [self err:@"无法打开整合包（不是有效的 zip）"]);
        }
        return;
    }

    A2ModPackFormat format = [A2ModPackInstaller detectFormatAtPath:zipPath];

    if (format == A2ModPackFormatModrinth) {
        NSData *d = [z dataForEntry:kModrinthIndexName];
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        A2ModPackManifest *m = [self parseModrinthManifest:json];
        if (completion) completion(m, m ? nil : [self err:@"Modrinth 清单解析失败"]);
        return;
    }

    if (format == A2ModPackFormatCurseForge) {
        NSData *d = [z dataForEntry:kCurseForgeManifestName];
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        A2ModPackManifest *m = [self parseCurseForgeManifest:json];
        if (completion) completion(m, m ? nil : [self err:@"CurseForge 清单解析失败"]);
        return;
    }

    if (format == A2ModPackFormatMCBBS) {
        NSString *entry = [z containsEntry:kMCBBSManifestName]
            ? kMCBBSManifestName : kCurseForgeManifestName;
        NSData *d = [z dataForEntry:entry];
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        A2ModPackManifest *m = [self parseMCBBSManifest:json];
        if (completion) completion(m, m ? nil : [self err:@"MCBBS 清单解析失败"]);
        return;
    }

    if (format == A2ModPackFormatMultiMC) {
        // MultiMC 的清单可能在根目录或实例子目录下
        NSString *entry = nil;
        for (NSString *name in z.entryNames) {
            if ([name isEqualToString:kMultiMCManifestName] ||
                [name hasSuffix:[NSString stringWithFormat:@"/%@", kMultiMCManifestName]]) {
                entry = name;
                break;
            }
        }
        NSData *d = entry ? [z dataForEntry:entry] : nil;
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        A2ModPackManifest *m = [self parseMultiMCManifest:json];
        if (completion) completion(m, m ? nil : [self err:@"MultiMC 清单解析失败"]);
        return;
    }

    if (completion) {
        completion(nil, [self err:@"无法识别的整合包格式（支持 Modrinth / CurseForge / MCBBS / MultiMC）"]);
    }
}

/// Modrinth 的 modrinth.index.json
- (nullable A2ModPackManifest *)parseModrinthManifest:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ModPackManifest *m = [A2ModPackManifest new];
    m.format = A2ModPackFormatModrinth;
    m.name = json[@"name"] ?: @"未命名整合包";
    m.summary = [json[@"summary"] isKindOfClass:NSString.class] ? json[@"summary"] : nil;
    m.overridesDir = @"overrides";

    // 依赖里给游戏版本与加载器
    NSDictionary *deps = json[@"dependencies"];
    if ([deps isKindOfClass:NSDictionary.class]) {
        m.gameVersion = deps[@"minecraft"] ?: @"";
        // 键名形态：fabric-loader / quilt-loader / forge / neoforge
        for (NSString *key in deps) {
            NSString *ident = [self loaderIdentifierFromModrinthKey:key];
            if (ident) {
                m.loaderIdentifier = ident;
                m.loaderVersion = deps[key];
                break;
            }
        }
    }
    if (m.gameVersion.length == 0) return nil;

    // 文件列表
    NSMutableArray<A2ModPackFile *> *files = [NSMutableArray array];
    NSArray *raw = json[@"files"];
    if ([raw isKindOfClass:NSArray.class]) {
        for (NSDictionary *f in raw) {
            if (![f isKindOfClass:NSDictionary.class]) continue;

            // env 为 "unsupported" 的文件是给服务端的，客户端不装
            NSDictionary *env = f[@"env"];
            if ([env isKindOfClass:NSDictionary.class] &&
                [env[@"client"] isEqualToString:@"unsupported"]) {
                continue;
            }

            A2ModPackFile *file = [A2ModPackFile new];
            file.relativePath = f[@"path"] ?: @"";
            file.urls = [f[@"downloads"] isKindOfClass:NSArray.class] ? f[@"downloads"] : @[];
            NSDictionary *hashes = f[@"hashes"];
            if ([hashes isKindOfClass:NSDictionary.class] &&
                [hashes[@"sha1"] isKindOfClass:NSString.class]) {
                file.sha1 = hashes[@"sha1"];
            }
            file.fileSize = [f[@"fileSize"] longLongValue];
            if (file.relativePath.length && file.urls.count) {
                [files addObject:file];
            }
        }
    }
    m.files = files;
    return m;
}

- (nullable NSString *)loaderIdentifierFromModrinthKey:(NSString *)key {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"fabric"]) return @"fabric";
    if ([lower containsString:@"quilt"]) return @"quilt";
    if ([lower containsString:@"neoforge"]) return @"neoforge";
    if ([lower containsString:@"forge"]) return @"forge";
    return nil;
}

/// CurseForge 的 manifest.json
- (nullable A2ModPackManifest *)parseCurseForgeManifest:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ModPackManifest *m = [A2ModPackManifest new];
    m.format = A2ModPackFormatCurseForge;
    m.name = json[@"name"] ?: @"未命名整合包";
    m.overridesDir = [json[@"overrides"] isKindOfClass:NSString.class]
        ? json[@"overrides"] : @"overrides";

    NSDictionary *mc = json[@"minecraft"];
    if (![mc isKindOfClass:NSDictionary.class]) return nil;
    m.gameVersion = mc[@"version"] ?: @"";
    if (m.gameVersion.length == 0) return nil;

    // 加载器：modLoaders 里 primary=true 的那个
    NSArray *loaders = mc[@"modLoaders"];
    if ([loaders isKindOfClass:NSArray.class]) {
        for (NSDictionary *l in loaders) {
            if (![l isKindOfClass:NSDictionary.class]) continue;
            if (![l[@"primary"] boolValue]) continue;
            NSString *ident = l[@"id"];   // 形如 "fabric-0.15.0"
            if (![ident isKindOfClass:NSString.class]) continue;

            NSArray<NSString *> *parts = [ident componentsSeparatedByString:@"-"];
            if (parts.count >= 2) {
                m.loaderIdentifier = parts[0];
                // 版本号可能含连字符（如 forge-47.2.0-1.20.1）
                m.loaderVersion = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
                                   componentsJoinedByString:@"-"];
            }
            break;
        }
    }

    // 文件列表：只给 projectID/fileID，要后续用 API 换地址
    NSMutableArray<A2ModPackFile *> *files = [NSMutableArray array];
    NSArray *raw = json[@"files"];
    if ([raw isKindOfClass:NSArray.class]) {
        for (NSDictionary *f in raw) {
            if (![f isKindOfClass:NSDictionary.class]) continue;
            A2ModPackFile *file = [A2ModPackFile new];
            file.curseForgeProjectID = [f[@"projectID"] integerValue];
            file.curseForgeFileID = [f[@"fileID"] integerValue];
            // 清单里通常带 fileName 作为提示
            if ([f[@"fileName"] isKindOfClass:NSString.class]) {
                file.relativePath = f[@"fileName"];
            }
            if (file.curseForgeProjectID > 0) {
                [files addObject:file];
            }
        }
    }
    m.files = files;
    return m;
}

#pragma mark - 安装

- (void)installPackAtPath:(NSString *)zipPath
              versionName:(NSString *)versionName
                 gameHome:(NSString *)gameHome
                 progress:(void (^)(double, NSString *))progress
               completion:(void (^)(BOOL, NSError *))completion {

    _cancelled = NO;

    self.zipPath = zipPath;
    self.versionName = versionName;
    self.gameHome = gameHome;
    self.progressBlock = progress;
    self.completionBlock = completion;

    [self report:0 message:@"正在读取整合包…"];

    __weak typeof(self) weakSelf = self;
    [self parseManifestAtPath:zipPath completion:^(A2ModPackManifest *manifest, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self->_cancelled) { [self finishCancelled]; return; }
        if (!manifest) { [self failWithError:error]; return; }
        self.manifest = manifest;

        [A2Logger info:@"A2ModPackInstaller"
               message:[NSString stringWithFormat:@"整合包「%@」：MC %@，%@ %@，%lu 个文件",
                        manifest.name, manifest.gameVersion,
                        manifest.loaderIdentifier ?: @"原版",
                        manifest.loaderVersion ?: @"",
                        (unsigned long)manifest.files.count]];

        [self ensureBaseVersion];
    }];
}

/// 确保游戏本体与加载器就绪。
/// 整合包不包含游戏本体，只声明依赖 —— 缺的话要先装。
- (void)ensureBaseVersion {
    if (_cancelled) { [self finishCancelled]; return; }

    A2ModPackManifest *m = self.manifest;

    // 找本地是否有符合的版本（同游戏版本 + 同加载器）
    A2Version *found = [self findMatchingVersion];
    if (found) {
        [A2Logger info:@"A2ModPackInstaller"
               message:[NSString stringWithFormat:@"复用已有版本 %@", found.name]];
        self.versionName = found.name;
        [self report:0.4 message:@"已找到匹配的游戏版本"];
        [self installFiles];
        return;
    }

    // 没有就装。先原版，再加载器 —— 与 A2GameInstaller 的流程串起来。
    [self report:0.05 message:[NSString stringWithFormat:@"正在安装游戏本体 %@…", m.gameVersion]];

    A2InstallRequest *req = [A2InstallRequest new];
    req.mcVersion = m.gameVersion;
    req.gameHome = self.gameHome;

    // 加载器信息填进去，安装器会在最后一步自动装
    if (m.loaderIdentifier.length) {
        for (NSNumber *n in [A2ModLoaderAPI allLoaderTypes]) {
            A2ModLoaderType t = (A2ModLoaderType)n.integerValue;
            if ([[A2ModLoaderAPI identifierForType:t] isEqualToString:m.loaderIdentifier]) {
                req.loaderType = n;
                req.loaderVersion = m.loaderVersion;
                break;
            }
        }
    }
    req.versionName = m.loaderIdentifier.length
        ? [NSString stringWithFormat:@"%@-%@", m.gameVersion, m.loaderIdentifier]
        : m.gameVersion;

    __weak typeof(self) weakSelf = self;
    A2GameInstaller *installer = [[A2GameInstaller alloc] init];
    [installer install:req
        progress:^(A2InstallStage stage, double progress, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 本体安装占总进度的 0~50%
        [self report:progress * 0.5 message:message];
    }
        completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!success) { [self failWithError:error]; return; }
        self.versionName = req.versionName;
        [self installFiles];
    }];
}

/// 找本地符合整合包要求的版本
- (nullable A2Version *)findMatchingVersion {
    A2ModPackManifest *m = self.manifest;
    for (A2Version *v in A2VersionManager.shared.versions) {
        if (![v.name hasPrefix:m.gameVersion]) continue;
        // 加载器也要对上（原版整合包则不要求）
        if (m.loaderIdentifier.length) {
            NSString *ident = [A2ModLoaderAPI identifierForType:A2ModLoaderTypeUnknown];
            (void)ident;
            NSString *loaderInfo = v.loaderInfo.lowercaseString;
            if (![loaderInfo containsString:m.loaderIdentifier.lowercaseString]) continue;
        }
        return v;
    }
    return nil;
}

/// 下载所有文件
- (void)installFiles {
    A2ModPackManifest *m = self.manifest;
    if (m.files.count == 0) {
        [self extractOverrides];
        return;
    }

    NSString *gameDir = [self gameDirectoryForCurrentVersion];

    [self report:0.5 message:[NSString stringWithFormat:@"正在下载 %lu 个文件…",
                              (unsigned long)m.files.count]];

    __block NSUInteger index = 0;
    __block NSUInteger failed = 0;
    NSUInteger total = m.files.count;

    __weak typeof(self) weakSelf = self;
    __block void (^next)(void) = nil;

    next = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (index >= total) {
            [self report:0.9 message:[NSString stringWithFormat:@"文件下载完成（%lu 个失败）",
                                      (unsigned long)failed]];
            [self extractOverrides];
            next = nil;
            return;
        }

        A2ModPackFile *file = m.files[index];
        NSString *dest = [self destinationPathForFile:file gameDir:gameDir];

        // 已存在则跳过（整合包重复安装时不重下）
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) {
            index++;
            [self reportProgressForIndex:index total:total];
            if (next) next();
            return;
        }

        // CurseForge 的文件没有直链，要先查 API 换地址
        if (file.urls.count == 0 && file.curseForgeProjectID > 0) {
            [self resolveCurseForgeFile:file completion:^(NSArray<NSString *> *urls, NSString *relPath) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;

                if (urls.count == 0) {
                    failed++;
                    index++;
                    [self reportProgressForIndex:index total:total];
                    if (next) next();
                    return;
                }
                file.urls = urls;
                if (relPath.length) file.relativePath = relPath;
                [self downloadFile:file to:[self destinationPathForFile:file gameDir:gameDir]
                        completion:^(BOOL ok) {
                    if (!ok) failed++;
                    index++;
                    [self reportProgressForIndex:index total:total];
                    if (next) next();
                }];
            }];
            return;
        }

        [self downloadFile:file to:dest completion:^(BOOL ok) {
            if (!ok) failed++;
            index++;
            [self reportProgressForIndex:index total:total];
            if (next) next();
        }];
    };

    next();
}

- (void)reportProgressForIndex:(NSUInteger)index total:(NSUInteger)total {
    double p = 0.5 + 0.4 * ((double)index / (double)MAX(1, total));
    [self report:p message:[NSString stringWithFormat:@"正在下载 (%lu/%lu)",
                            (unsigned long)index, (unsigned long)total]];
}

/// 文件在游戏目录里的目标路径
- (NSString *)destinationPathForFile:(A2ModPackFile *)file gameDir:(NSString *)gameDir {
    NSString *rel = file.relativePath ?: @"";
    // CurseForge 只给文件名，按 mods 放置（绝大多数整合包文件都是模组）
    if (![rel containsString:@"/"]) {
        rel = [@"mods" stringByAppendingPathComponent:rel];
    }
    return [gameDir stringByAppendingPathComponent:rel];
}

/// CurseForge 的 projectID/fileID → 下载地址
- (void)resolveCurseForgeFile:(A2ModPackFile *)file
                   completion:(void (^)(NSArray<NSString *> *, NSString *))completion {

    [[A2CurseForgeAPI shared] fileWithProjectID:file.curseForgeProjectID
                                         fileID:file.curseForgeFileID
                                     completion:^(A2CFFile *cf, NSError *error) {
        if (error || !cf) {
            [A2Logger warning:@"A2ModPackInstaller"
                   message:[NSString stringWithFormat:@"无法解析 CurseForge 文件 %ld/%ld：%@",
                            (long)file.curseForgeProjectID, (long)file.curseForgeFileID,
                            error.localizedDescription ?: @"未找到"]];
            completion(@[], @"");
            return;
        }
        // downloadUrl 为 nil 表示作者禁止第三方分发，只能标记失败
        NSArray *urls = cf.downloadURL.length ? @[cf.downloadURL] : @[];
        completion(urls, cf.fileName ?: @"");
    }];
}

- (void)downloadFile:(A2ModPackFile *)file
                  to:(NSString *)dest
          completion:(void (^)(BOOL))completion {

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *u in file.urls) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [urls addObject:url];
    }
    if (urls.count == 0) {
        completion(NO);
        return;
    }

    A2DownloadRequest *req = [A2DownloadRequest new];
    req.candidateURLs = urls;
    req.destinationPath = dest;
    req.expectedSize = file.fileSize;
    req.expectedSHA1 = file.sha1;
    req.allowZipFallbackCheck = YES;

    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil speed:nil
        completion:^(BOOL success, NSError *error) {
        if (!success) {
            [A2Logger warning:@"A2ModPackInstaller"
                   message:[NSString stringWithFormat:@"下载失败 %@：%@",
                            file.relativePath, error.localizedDescription ?: @""]];
        }
        completion(success);
    }];
}

/// 当前版本实际使用的游戏目录。
///
/// 隔离档位从版本管理器取 —— 整合包安装是在「已存在的版本」上叠加内容，
/// 那个版本的档位已经确定，不该由安装器自己造一个默认值。
- (NSString *)gameDirectoryForCurrentVersion {
    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];
    A2IsolationMode mode = A2IsolationModeFull;

    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:self.versionName]) {
            mode = [v effectiveIsolationMode];
            break;
        }
    }
    return [path gameDirectoryForVersion:self.versionName mode:mode];
}

#pragma mark - overrides

/// 解压 overrides 目录里的文件（原样覆盖，不走下载）
- (void)extractOverrides {
    A2ModPackManifest *m = self.manifest;
    NSString *overrides = m.overridesDir ?: @"overrides";

    [self report:0.92 message:@"正在解压整合包覆盖文件…"];

    NSString *gameDir = [self gameDirectoryForCurrentVersion];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:self.zipPath];
        NSUInteger extracted = 0;

        if (zip) {
            NSString *prefix = [overrides stringByAppendingString:@"/"];
            for (NSString *entry in zip.entryNames) {
                if (![entry hasPrefix:prefix]) continue;

                NSString *rel = [entry substringFromIndex:prefix.length];
                if (rel.length == 0) continue;

                NSString *dest = [gameDir stringByAppendingPathComponent:rel];
                if ([zip extractEntry:entry toPath:dest]) extracted++;
            }
        }

        [A2Logger info:@"A2ModPackInstaller"
               message:[NSString stringWithFormat:@"覆盖文件解压完成（%lu 个）",
                        (unsigned long)extracted]];

        A2Main(^{
            [self finish];
        });
    });
}

#pragma mark - 收尾

- (void)finish {
    [self report:1.0 message:@"整合包安装完成"];

    // 让版本列表刷新
    [A2VersionManager.shared reload];

    A2Main(^{
        if (self.completionBlock) self.completionBlock(YES, nil);
    });
}

#pragma mark - 工具

- (void)report:(double)progress message:(NSString *)message {
    A2Main(^{
        if (self.progressBlock) {
            self.progressBlock(MAX(0, MIN(1, progress)), message);
        }
    });
}

/// 用户取消 —— 不走 fail 路径，错误信息不同
- (void)finishCancelled {
    [A2Logger info:@"A2ModPackInstaller" message:@"安装已取消"];
    A2Main(^{
        if (self.completionBlock) {
            NSError *e = [NSError errorWithDomain:@"A2ModPackInstaller" code:99
                                         userInfo:@{NSLocalizedDescriptionKey: @"已取消"}];
            self.completionBlock(NO, e);
        }
    });
}

- (void)failWithError:(NSError *)error {
    [A2Logger error:@"A2ModPackInstaller" message:error.localizedDescription ?: @"安装失败"];
    A2Main(^{
        if (self.completionBlock) self.completionBlock(NO, error);
    });
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2ModPackInstaller" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"整合包错误"}];
}

#pragma mark - MCBBS 格式

/// MCBBS（中文社区格式）
///
/// 结构（对照 ZL2 的 MCBBSManifest）：
///   {
///     "manifestType": "minecraftMcbbs",
///     "name": "...", "version": "...", "author": "...",
///     "description": "...", "url": "...",
///     "forceUpdate": bool,
///     "origins": [{ "type": "game"|"forge"|"fabric"|"optifine", "version": "..." }],
///     "addons": [{ "type": "mod"|"resourcepack"|"shader", "url": "...", "name": "..." }],
///     "libraries": [...]
///   }
///
/// origins 声明游戏本体与加载器；addons 是要装的内容文件。
- (nullable A2ModPackManifest *)parseMCBBSManifest:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ModPackManifest *m = [A2ModPackManifest new];
    m.format = A2ModPackFormatMCBBS;
    m.name = json[@"name"] ?: @"未命名整合包";
    m.summary = [json[@"description"] isKindOfClass:NSString.class] ? json[@"description"] : nil;
    m.overridesDir = @"overrides";

    // origins：从中解析游戏版本与加载器
    NSArray *origins = json[@"origins"];
    if ([origins isKindOfClass:NSArray.class]) {
        for (NSDictionary *o in origins) {
            if (![o isKindOfClass:NSDictionary.class]) continue;
            NSString *type = o[@"type"];
            NSString *version = o[@"version"];
            if (![version isKindOfClass:NSString.class]) continue;

            if ([type isEqualToString:@"game"]) {
                m.gameVersion = version;
            } else if ([type isEqualToString:@"forge"]) {
                m.loaderIdentifier = @"forge";
                m.loaderVersion = version;
            } else if ([type isEqualToString:@"neoforge"]) {
                m.loaderIdentifier = @"neoforge";
                m.loaderVersion = version;
            } else if ([type isEqualToString:@"fabric"]) {
                m.loaderIdentifier = @"fabric";
                m.loaderVersion = version;
            } else if ([type isEqualToString:@"quilt"]) {
                m.loaderIdentifier = @"quilt";
                m.loaderVersion = version;
            } else if ([type isEqualToString:@"optifine"]) {
                // OptiFine 不覆盖已有的加载器选择（它可以与 Forge 共存）
                if (!m.loaderIdentifier) m.loaderIdentifier = @"optifine";
            }
        }
    }
    if (m.gameVersion.length == 0) return nil;

    // addons：要下载的内容文件
    NSMutableArray<A2ModPackFile *> *files = [NSMutableArray array];
    NSArray *addons = json[@"addons"];
    if ([addons isKindOfClass:NSArray.class]) {
        for (NSDictionary *a in addons) {
            if (![a isKindOfClass:NSDictionary.class]) continue;

            NSString *url = a[@"url"];
            NSString *name = a[@"name"];
            if (![url isKindOfClass:NSString.class] || url.length == 0) continue;

            A2ModPackFile *file = [A2ModPackFile new];
            file.urls = @[url];

            // 按 type 决定落在哪个目录
            NSString *type = a[@"type"];
            NSString *subdir = @"mods";
            if ([type isEqualToString:@"resourcepack"]) subdir = @"resourcepacks";
            else if ([type isEqualToString:@"shader"]) subdir = @"shaderpacks";
            else if ([type isEqualToString:@"save"]) subdir = @"saves";

            NSString *fileName = [name isKindOfClass:NSString.class] && name.length
                ? name
                : [url lastPathComponent];
            file.relativePath = [subdir stringByAppendingPathComponent:fileName];

            [files addObject:file];
        }
    }
    m.files = files;
    return m;
}

#pragma mark - MultiMC 格式

/// MultiMC / Prism Launcher / ATLauncher 系
///
/// 结构（对照 ZL2 的 MultiMCManifest）：
///   { "formatVersion": 1, "components": [
///       { "uid": "net.minecraft", "version": "1.20.1", "important": true },
///       { "uid": "net.fabricmc.fabric-loader", "version": "0.15.0", "important": true },
///       { "uid": "org.lwjgl3", "version": "3.3.3", ... }
///   ]}
///
/// 靠 uid 反推游戏版本与加载器。
- (nullable A2ModPackManifest *)parseMultiMCManifest:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    A2ModPackManifest *m = [A2ModPackManifest new];
    m.format = A2ModPackFormatMultiMC;
    m.name = @"导入的 MultiMC 整合包";
    m.overridesDir = @".minecraft";   // MultiMC 用 .minecraft 目录存实例内容

    NSArray *components = json[@"components"];
    if (![components isKindOfClass:NSArray.class]) return nil;

    for (NSDictionary *c in components) {
        if (![c isKindOfClass:NSDictionary.class]) continue;
        NSString *uid = c[@"uid"];
        NSString *version = c[@"version"];
        if (![uid isKindOfClass:NSString.class] || ![version isKindOfClass:NSString.class]) {
            continue;
        }

        NSString *lower = uid.lowercaseString;

        if ([lower isEqualToString:@"net.minecraft"]) {
            m.gameVersion = version;
        } else if ([lower containsString:@"fabric-loader"]) {
            m.loaderIdentifier = @"fabric";
            m.loaderVersion = version;
        } else if ([lower containsString:@"quilt-loader"]) {
            m.loaderIdentifier = @"quilt";
            m.loaderVersion = version;
        } else if ([lower containsString:@"forge"]) {
            // 注意顺序：neoforge 也要先判
            if ([lower containsString:@"neoforge"]) {
                m.loaderIdentifier = @"neoforge";
            } else {
                m.loaderIdentifier = @"forge";
            }
            m.loaderVersion = version;
        } else if ([lower containsString:@"optifine"]) {
            if (!m.loaderIdentifier) m.loaderIdentifier = @"optifine";
            m.loaderVersion = version;
        }
    }

    if (m.gameVersion.length == 0) return nil;

    // MultiMC 的清单只声明组件，实际 mod 在 .minecraft 目录里，
    // 靠 overrides 解压。所以 files 为空。
    m.files = @[];
    return m;
}

@end

//
//  A2IntegrityChecker.m
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
//  A2IntegrityChecker.m
//  Air2
//
//  实现说明（对照 ZL2 的位置都标了）：
//    · ZL2 game/download/game/GameInstaller.kt  createGameInstalledTask / mergeGameJson
//    · ZL2 game/version/download/BaseMinecraftDownloader.kt
//          loadLibraryDownloads / loadAssetsDownload（决定了「查哪些文件」）
//    · ZL2 game/version/download/MinecraftDownloader.kt  VERIFY_AND_REPAIR
//
//  与 ZL2 的**行为差异**（都是因为平台或架构不同，不是漏做）：
//    1. ZL2 把加载器 json 与父 json 合并成一份再校验；
//       Air2 每次启动现算合并结果（A2VersionMetadata），盘上不存在合并产物，
//       所以这里现场解析 inheritsFrom 链，按「子覆盖父」去重后校验。
//    2. ZL2 的 scheduleDownload 是「计划下载」，校验与下载在同一批任务里跑；
//       Air2 把校验与下载拆成两个类（Checker / Repairer），
//       因为启动前的快速校验不该把网络栈拖进来。
//    3. iOS 不需要 natives / org.lwjgl 的 jar（A2VersionMetadata 打 skip），
//       这里同步跳过 —— 否则会出现「永远修不完的假缺失」。
//

#import "A2IntegrityChecker.h"
#import "A2Logger.h"
#import "A2VersionIsolation.h"
#import <CommonCrypto/CommonDigest.h>

#pragma mark - 分类名

NSString *A2IntegritySectionKey(A2IntegritySection section) {
    switch (section) {
        case A2IntegritySectionVersionJSON:  return @"versionJSON";
        case A2IntegritySectionClientJar:    return @"clientJar";
        case A2IntegritySectionLibraries:    return @"libraries";
        case A2IntegritySectionAssetIndex:   return @"assetIndex";
        case A2IntegritySectionAssetObjects: return @"assetObjects";
    }
    return @"unknown";
}

NSString *A2IntegritySectionDisplayName(A2IntegritySection section) {
    switch (section) {
        case A2IntegritySectionVersionJSON:  return @"版本信息";
        case A2IntegritySectionClientJar:    return @"客户端";
        case A2IntegritySectionLibraries:    return @"依赖库";
        case A2IntegritySectionAssetIndex:   return @"资源索引";
        case A2IntegritySectionAssetObjects: return @"资源";
    }
    return @"未知";
}

#pragma mark - 问题 / 报告

@implementation A2IntegrityIssue

- (instancetype)init {
    self = [super init];
    if (self) {
        _path = @"";
        _kind = @"";
        _reason = @"";
        _downloadURLs = @[];
        _actualSize = -1;
    }
    return self;
}

- (BOOL)needsRemovalBeforeRepair {
    return self.reasonKind == A2IntegrityReasonSizeMismatch ||
           self.reasonKind == A2IntegrityReasonSHA1Mismatch;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"[%@] %@ — %@", self.kind, self.path, self.reason];
}

@end

@implementation A2IntegrityReport

- (instancetype)init {
    self = [super init];
    if (self) {
        _issues = @[];
        _versionChain = @[];
    }
    return self;
}

- (BOOL)clean {
    return self.issues.count == 0;
}

- (NSInteger)missingCount {
    NSInteger n = 0;
    for (A2IntegrityIssue *issue in self.issues) {
        if (issue.reasonKind == A2IntegrityReasonMissing ||
            issue.reasonKind == A2IntegrityReasonParentMissing) {
            n++;
        }
    }
    return n;
}

- (NSInteger)corruptedCount {
    NSInteger n = 0;
    for (A2IntegrityIssue *issue in self.issues) {
        if (issue.reasonKind == A2IntegrityReasonSizeMismatch ||
            issue.reasonKind == A2IntegrityReasonSHA1Mismatch) {
            n++;
        }
    }
    return n;
}

- (NSInteger)unrepairableCount {
    NSInteger n = 0;
    for (A2IntegrityIssue *issue in self.issues) {
        if (issue.downloadURLs.count == 0) n++;
    }
    return n;
}

- (NSDictionary<NSString *, NSNumber *> *)issueCountsBySection {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (A2IntegrityIssue *issue in self.issues) {
        NSString *key = A2IntegritySectionKey(issue.section);
        counts[key] = @([counts[key] integerValue] + 1);
    }
    return counts;
}

- (NSString *)summaryText {
    if (self.issues.count == 0) {
        return [NSString stringWithFormat:@"%@ 完整（%ld 项，耗时 %.1fs）",
                self.versionChain.firstObject ?: @"版本",
                (long)self.totalFiles, self.elapsed];
    }
    NSMutableString *text = [NSMutableString stringWithFormat:
                             @"%@：%ld/%ld 正常，%ld 个问题（缺失 %ld，损坏 %ld）",
                             self.versionChain.firstObject ?: @"版本",
                             (long)self.okFiles, (long)self.totalFiles,
                             (long)self.issues.count,
                             (long)self.missingCount, (long)self.corruptedCount];
    if (self.chainBroken) [text appendString:@"，继承链已断"];
    if (self.unrepairableCount > 0) {
        [text appendFormat:@"，其中 %ld 项需重装", (long)self.unrepairableCount];
    }
    return text;
}

@end

#pragma mark - 内部：待检查项

@interface A2IntegrityItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSString *sha1;
@property (nonatomic, assign) long long size;
@property (nonatomic, assign) A2IntegritySection section;
@property (nonatomic, copy, nullable) NSString *versionID;
@property (nonatomic, copy) NSArray<NSString *> *urls;
@end

@implementation A2IntegrityItem
- (instancetype)init {
    self = [super init];
    if (self) {
        _path = @"";
        _urls = @[];
        _size = 0;
    }
    return self;
}
@end

#pragma mark - 内部工具

/// JSON null 与缺键等价处理
static BOOL A2HasValue(id value) {
    return value != nil && ![value isKindOfClass:NSNull.class];
}

/// 安全取数字 —— JSON 里的 null 会解析成 NSNull，
/// 直接 [NSNull longLongValue] 是 unrecognized selector，会崩。
static long long A2LongLongValue(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value longLongValue] : 0;
}

/// 安全取布尔
static BOOL A2BoolValue(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : NO;
}

/// 规则判定 —— 与 A2GameInstaller.m 的 isLibraryAllowed: 保持同一套语义。
///
/// 为什么必须一致：校验口径和启动口径不一致时，会出现
/// 「校验说缺了 3 个库，装完还是缺」这种死循环。
static BOOL A2LibraryRulesAllowOnIOS(NSDictionary *lib) {
    NSArray *rules = lib[@"rules"];
    if (![rules isKindOfClass:NSArray.class] || rules.count == 0) return YES;

    // 默认不允许，遇到匹配的 allow 才通过
    BOOL allowed = NO;
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:NSDictionary.class]) continue;
        NSString *action = rule[@"action"];
        NSDictionary *os = rule[@"os"];
        BOOL matches = YES;

        if ([os isKindOfClass:NSDictionary.class]) {
            NSString *osName = os[@"name"];
            // iOS 上按 macOS 处理（原生库大多通用），部分库有 ios 专属条目
            if ([osName isEqualToString:@"windows"] ||
                [osName isEqualToString:@"linux"]) {
                matches = NO;
            } else if ([osName isEqualToString:@"osx"] ||
                       [osName isEqualToString:@"macos"] ||
                       [osName isEqualToString:@"ios"]) {
                matches = YES;
            } else {
                matches = NO;
            }
        }

        if (matches) allowed = [action isEqualToString:@"allow"];
    }
    return allowed;
}

/// 该库条目在本机是否「应当存在」。
///
/// 跳过的三类必须与 A2VersionMetadata.m tweakVersionJson 的 skip 判定一致：
///   1. natives          → iOS 无本地库加载需求
///   2. downloads.classifiers → 仅 natives 分发包
///   3. org.lwjgl*       → 由启动器自带 dylib 提供
static BOOL A2LibraryArtifactWanted(NSDictionary *lib) {
    if (![lib isKindOfClass:NSDictionary.class]) return NO;

    if (A2HasValue(lib[@"natives"])) return NO;

    id downloadsObj = lib[@"downloads"];
    NSDictionary *downloads = [downloadsObj isKindOfClass:NSDictionary.class] ? downloadsObj : nil;

    if (A2HasValue(downloads[@"classifiers"])) return NO;

    id name = lib[@"name"];
    if ([name isKindOfClass:NSString.class] && [name hasPrefix:@"org.lwjgl"]) return NO;

    if (!A2LibraryRulesAllowOnIOS(lib)) return NO;

    return YES;
}

/// 从库条目取 artifact（没有 artifact 时返回 nil）
static NSDictionary *A2LibraryArtifact(NSDictionary *lib) {
    id downloadsObj = lib[@"downloads"];
    if (![downloadsObj isKindOfClass:NSDictionary.class]) return nil;
    id artifact = downloadsObj[@"artifact"];
    return [artifact isKindOfClass:NSDictionary.class] ? artifact : nil;
}

/// 依赖库的下载地址。
///
/// 对照 ZL2 BaseMinecraftDownloader.loadLibraryDownloads：
///   artifact.url 优先；缺失时用 lib.url（maven 根）拼出路径；
///   再没有就退回 Mojang 官方库根。
/// Forge 常把 url 写成空串，所以判空而不是判 nil。
static NSString *A2LibraryArtifactURL(NSDictionary *lib, NSDictionary *artifact, NSString *relPath) {
    id url = artifact[@"url"];
    if ([url isKindOfClass:NSString.class] && [url length] > 0) return url;

    id base = lib[@"url"];
    NSString *baseStr = nil;
    if ([base isKindOfClass:NSString.class] && [base length] > 0) {
        baseStr = base;
    } else if ([base isKindOfClass:NSArray.class] && [base count] > 0) {
        id first = [base firstObject];
        if ([first isKindOfClass:NSString.class] && [first length] > 0) baseStr = first;
    }
    if (!baseStr.length) baseStr = @"https://libraries.minecraft.net";
    return [NSString stringWithFormat:@"%@/%@", baseStr, relPath];
}

/// 沿 inheritsFrom 载入各层 json。
///
/// @param chainOut 出参：版本 id 链（自身 → 根）
/// @param brokenOut 出参：链是否断开
/// @param brokenPathOut 出参：断开处的 json 路径
/// @param brokenReasonOut 出参：断开原因（Missing / ParentMissing / Unreadable）
/// @return 各层 @{@"folder": 目录名, @"json": 解析结果}，自身在前
static NSArray<NSDictionary *> *A2LoadVersionLevels(NSString *versionName,
                                                    A2GamePath *path,
                                                    NSMutableArray<NSString *> *chainOut,
                                                    BOOL *brokenOut,
                                                    NSString * _Nullable *brokenPathOut,
                                                    A2IntegrityReason *brokenReasonOut) {
    NSMutableArray<NSDictionary *> *levels = [NSMutableArray array];

    BOOL broken = NO;
    NSString *brokenPath = nil;
    A2IntegrityReason brokenReason = A2IntegrityReasonMissing;

    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSString *current = versionName;
    NSInteger depth = 0;
    BOOL ranOutOfDepth = NO;

    while (current.length > 0) {
        // 环引用保护：正常版本链最多两三层，16 足够；超出说明 json 被改坏了
        if (depth >= 16) { ranOutOfDepth = YES; break; }

        if ([visited containsObject:current]) {
            // 自引用 / 环
            broken = YES;
            brokenReason = A2IntegrityReasonUnreadable;
            brokenPath = [path versionJSONPath:current];
            break;
        }
        [visited addObject:current];

        NSString *jsonPath = [path versionJSONPath:current];
        NSData *data = [NSData dataWithContentsOfFile:jsonPath];
        if (!data) {
            broken = YES;
            // 第一层就缺 = 本版本没装好；往上缺 = 父版本没了
            brokenReason = (depth == 0) ? A2IntegrityReasonMissing
                                        : A2IntegrityReasonParentMissing;
            brokenPath = jsonPath;
            break;
        }

        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) {
            broken = YES;
            brokenReason = A2IntegrityReasonUnreadable;
            brokenPath = jsonPath;
            break;
        }

        [levels addObject:@{ @"folder": current, @"json": obj }];
        [chainOut addObject:current];

        id parent = obj[@"inheritsFrom"];
        current = ([parent isKindOfClass:NSString.class] && [parent length] > 0)
                    ? (NSString *)parent : nil;
        depth++;
    }

    if (ranOutOfDepth) {
        broken = YES;
        brokenReason = A2IntegrityReasonUnreadable;
        brokenPath = [path versionJSONPath:current ?: versionName];
    }

    if (brokenOut) *brokenOut = broken;
    if (brokenPathOut) *brokenPathOut = brokenPath;
    if (brokenReasonOut) *brokenReasonOut = brokenReason;

    return levels;
}

static A2IntegrityIssue *A2MakeIssue(A2IntegrityItem *item,
                                     A2IntegrityReason reason,
                                     long long actualSize,
                                     NSString *reasonText) {
    A2IntegrityIssue *issue = [A2IntegrityIssue new];
    issue.path = item.path;
    issue.section = item.section;
    issue.kind = A2IntegritySectionDisplayName(item.section);
    issue.reason = reasonText ?: @"";
    issue.reasonKind = reason;
    issue.expectedSHA1 = item.sha1;
    issue.expectedSize = item.size;
    issue.actualSize = actualSize;
    issue.downloadURLs = item.urls ?: @[];
    issue.versionID = item.versionID;
    return issue;
}

#pragma mark - A2IntegrityChecker

@implementation A2IntegrityChecker

#pragma mark SHA1

+ (NSString *)sha1OfFile:(NSString *)path {
    if (path.length == 0) return nil;

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    // 分块读 —— 客户端 jar 有几十 MB，一次读进内存会爆
    const size_t chunk = 256 * 1024;
    BOOL readFailed = NO;
    @try {
        while (YES) {
            @autoreleasepool {
                NSData *d = [fh readDataOfLength:chunk];
                if (d.length == 0) break;
                CC_SHA1_Update(&ctx, d.bytes, (CC_LONG)d.length);
            }
        }
    } @catch (NSException *e) {
        readFailed = YES;
    }
    [fh closeFile];
    if (readFailed) return nil;

    unsigned char digest[20];
    CC_SHA1_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < 20; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark 继承链

+ (NSArray<NSString *> *)resolvedVersionChainFor:(NSString *)versionName
                                        gameHome:(NSString *)gameHome
                                          broken:(BOOL * _Nullable)broken {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    if (versionName.length == 0 || gameHome.length == 0) {
        if (broken) *broken = YES;
        return chain;
    }
    A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];
    BOOL chainBroken = NO;
    (void)A2LoadVersionLevels(versionName, path, chain, &chainBroken, NULL, NULL);
    if (broken) *broken = chainBroken;
    return chain;
}

#pragma mark 检查入口

- (void)checkVersion:(NSString *)versionName
            gameHome:(NSString *)gameHome
                mode:(A2IntegrityCheckMode)mode
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(A2IntegrityReport *))completion {
    [self verifyVersion:versionName
               gameHome:gameHome
                   mode:mode
                  scope:A2IntegrityScopeAll
               progress:progress
             completion:completion];
}

- (void)verifyVersion:(NSString *)versionName
             gameHome:(NSString *)gameHome
                 mode:(A2IntegrityCheckMode)mode
                scope:(A2IntegrityScope)scope
             progress:(void (^)(double, NSString *))progress
           completion:(void (^)(A2IntegrityReport *))completion {

    // 参数错误也走 completion，调用方不用写两套分支。
    // ⚠️ 必须带一条 issue：报告为空时 clean 会返回 YES，
    // 调用方会误判「文件完整」然后照常启动。
    if (versionName.length == 0 || gameHome.length == 0) {
        A2IntegrityReport *report = [A2IntegrityReport new];
        report.versionChain = versionName.length ? @[versionName] : @[];
        report.chainBroken = YES;
        report.totalFiles = 1;
        report.okFiles = 0;

        A2IntegrityIssue *issue = [A2IntegrityIssue new];
        issue.path = @"";
        issue.section = A2IntegritySectionVersionJSON;
        issue.kind = A2IntegritySectionDisplayName(A2IntegritySectionVersionJSON);
        issue.reasonKind = A2IntegrityReasonMissing;
        issue.reason = @"参数不完整（缺少版本名或游戏根目录）";
        issue.downloadURLs = @[];
        report.issues = @[issue];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
        }
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDate *start = [NSDate date];
        A2GamePath *path = [A2GamePath pathWithGameHome:gameHome];

        NSMutableArray<A2IntegrityIssue *> *issues = [NSMutableArray array];
        NSInteger total = 0;
        NSInteger ok = 0;

        // ---- 1. 版本 json 继承链 ----
        NSMutableArray<NSString *> *chain = [NSMutableArray array];
        BOOL broken = NO;
        NSString *brokenPath = nil;
        A2IntegrityReason brokenReason = A2IntegrityReasonMissing;

        NSArray<NSDictionary *> *levels =
            A2LoadVersionLevels(versionName, path, chain, &broken, &brokenPath, &brokenReason);

        // 每层 json 算一项（存在性就是它的全部校验项：版本 json 不自带 sha1）
        total += (NSInteger)levels.count;
        ok += (NSInteger)levels.count;

        if (broken) {
            total += 1;

            A2IntegrityIssue *issue = [A2IntegrityIssue new];
            issue.path = brokenPath ?: @"";
            issue.section = A2IntegritySectionVersionJSON;
            issue.kind = A2IntegritySectionDisplayName(A2IntegritySectionVersionJSON);
            issue.reasonKind = brokenReason;
            issue.downloadURLs = @[];   // 版本 json 无地址，只能重装
            issue.expectedSize = 0;

            NSString *childName = levels.count
                ? [levels.lastObject[@"folder"] description] : nil;
            if (brokenReason == A2IntegrityReasonParentMissing) {
                issue.reason = childName.length
                    ? [NSString stringWithFormat:@"缺失（%@ 依赖它）", childName]
                    : @"缺失（父版本）";
            } else if (brokenReason == A2IntegrityReasonUnreadable) {
                issue.reason = @"无法解析（JSON 损坏或继承成环）";
            } else {
                issue.reason = @"缺失";
            }
            [issues addObject:issue];
        }

        // ---- 2. 收集待检查项 ----
        NSMutableArray<A2IntegrityItem *> *items = [NSMutableArray array];
        NSString *libRoot = [path librariesHome];

        // 只有链读通了才有意义往下查文件
        if (!broken || levels.count > 0) {

            // 2.1 客户端 jar —— 逐层查：加载器版可能没有自己的 client 声明
            if (scope & A2IntegrityScopeClientJar) {
                for (NSDictionary *level in levels) {
                    NSString *folder = level[@"folder"];
                    NSDictionary *json = level[@"json"];

                    id downloadsObj = json[@"downloads"];
                    if (![downloadsObj isKindOfClass:NSDictionary.class]) continue;
                    id clientObj = ((NSDictionary *)downloadsObj)[@"client"];
                    if (![clientObj isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *client = clientObj;

                    A2IntegrityItem *item = [A2IntegrityItem new];
                    item.path = [path versionJarPath:folder];
                    item.section = A2IntegritySectionClientJar;
                    item.versionID = folder;

                    id sha1 = client[@"sha1"];
                    if ([sha1 isKindOfClass:NSString.class] && [sha1 length] > 0) {
                        item.sha1 = sha1;
                    }
                    item.size = A2LongLongValue(client[@"size"]);

                    id url = client[@"url"];
                    item.urls = ([url isKindOfClass:NSString.class] && [url length] > 0)
                                ? @[url] : @[];

                    [items addObject:item];
                }
            }

            // 2.2 依赖库 —— 子层先入，同名 artifact.path 子层优先（覆盖父层声明）
            if (scope & A2IntegrityScopeLibraries) {
                NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

                for (NSDictionary *level in levels) {
                    NSString *folder = level[@"folder"];
                    NSDictionary *json = level[@"json"];
                    id libsObj = json[@"libraries"];
                    if (![libsObj isKindOfClass:NSArray.class]) continue;

                    for (id libObj in (NSArray *)libsObj) {
                        if (![libObj isKindOfClass:NSDictionary.class]) continue;
                        NSDictionary *lib = libObj;
                        if (!A2LibraryArtifactWanted(lib)) continue;

                        NSDictionary *artifact = A2LibraryArtifact(lib);
                        if (!artifact) continue;

                        id relObj = artifact[@"path"];
                        if (![relObj isKindOfClass:NSString.class]) continue;
                        NSString *rel = relObj;
                        if (rel.length == 0) continue;

                        if ([seenPaths containsObject:rel]) continue;
                        [seenPaths addObject:rel];

                        A2IntegrityItem *item = [A2IntegrityItem new];
                        item.path = [libRoot stringByAppendingPathComponent:rel];
                        item.section = A2IntegritySectionLibraries;
                        item.versionID = folder;

                        id sha1 = artifact[@"sha1"];
                        if ([sha1 isKindOfClass:NSString.class] && [sha1 length] > 0) {
                            item.sha1 = sha1;
                        }
                        item.size = A2LongLongValue(artifact[@"size"]);

                        NSString *url = A2LibraryArtifactURL(lib, artifact, rel);
                        item.urls = url.length ? @[url] : @[];

                        [items addObject:item];
                    }
                }
            }

            // 2.3 资源索引 + 资源对象 —— 取链上第一份声明了 assetIndex 的层
            if (scope & (A2IntegrityScopeAssetIndex | A2IntegrityScopeAssetObjects)) {
                NSDictionary *assetIndex = nil;
                NSString *assetOwnerID = nil;

                for (NSDictionary *level in levels) {
                    NSDictionary *json = level[@"json"];
                    id ai = json[@"assetIndex"];
                    if ([ai isKindOfClass:NSDictionary.class]) {
                        assetIndex = ai;
                        assetOwnerID = level[@"folder"];
                        break;
                    }
                }

                if (assetIndex) {
                    NSString *indexID = nil;
                    id aiID = assetIndex[@"id"];
                    if ([aiID isKindOfClass:NSString.class] && [aiID length] > 0) {
                        indexID = aiID;
                    } else {
                        // 老版本用顶层 assets 字段（如 "legacy" / "pre-1.6"）
                        NSDictionary *ownerJSON = nil;
                        for (NSDictionary *level in levels) {
                            if ([level[@"folder"] isEqual:assetOwnerID]) {
                                ownerJSON = level[@"json"];
                                break;
                            }
                        }
                        id assetsID = ownerJSON[@"assets"];
                        indexID = ([assetsID isKindOfClass:NSString.class] && [assetsID length])
                                    ? assetsID : @"legacy";
                    }

                    NSString *indexPath = [[path assetsIndexesHome]
                                           stringByAppendingPathComponent:
                                           [indexID stringByAppendingPathExtension:@"json"]];

                    if (scope & A2IntegrityScopeAssetIndex) {
                        A2IntegrityItem *item = [A2IntegrityItem new];
                        item.path = indexPath;
                        item.section = A2IntegritySectionAssetIndex;
                        item.versionID = assetOwnerID;

                        id sha1 = assetIndex[@"sha1"];
                        if ([sha1 isKindOfClass:NSString.class] && [sha1 length] > 0) {
                            item.sha1 = sha1;
                        }
                        item.size = A2LongLongValue(assetIndex[@"size"]);

                        id url = assetIndex[@"url"];
                        item.urls = ([url isKindOfClass:NSString.class] && [url length] > 0)
                                    ? @[url] : @[];

                        [items addObject:item];
                    }

                    // 资源对象：从索引里取 objects。索引缺失/损坏时不展开
                    // —— 展开的前提是索引可读；索引本身的问题已经报过了。
                    if (scope & A2IntegrityScopeAssetObjects) {
                        NSData *indexData = [NSData dataWithContentsOfFile:indexPath];
                        NSDictionary *indexJSON = indexData
                            ? [NSJSONSerialization JSONObjectWithData:indexData
                                                             options:0 error:nil]
                            : nil;
                        if ([indexJSON isKindOfClass:NSDictionary.class]) {
                            NSDictionary *objects = indexJSON[@"objects"];
                            if ([objects isKindOfClass:NSDictionary.class]) {
                                NSString *objectsRoot = [path assetsObjectsHome];
                                NSString *assetsRoot = [path assetsHome];

                                // 虚拟资源（1.6 之前）：按原路径铺开，不是 hash 布局
                                BOOL isVirtual = A2BoolValue(indexJSON[@"virtual"]) ||
                                                 A2BoolValue(indexJSON[@"map_to_resources"]);

                                for (NSString *key in objects) {
                                    NSDictionary *obj = objects[key];
                                    if (![obj isKindOfClass:NSDictionary.class]) continue;

                                    NSString *hash = obj[@"hash"];
                                    if (![hash isKindOfClass:NSString.class] ||
                                        hash.length < 2) continue;

                                    A2IntegrityItem *item = [A2IntegrityItem new];
                                    item.section = A2IntegritySectionAssetObjects;
                                    item.versionID = assetOwnerID;

                                    if (isVirtual) {
                                        // 1.6 之前的资源按原路径铺开：
                                        //   map_to_resources → <gameHome>/resources/<key>
                                        //   virtual          → <assets>/<key>
                                        // 对照 ZL2 loadAssetsDownload 的 targetFile 分支
                                        BOOL toResources = A2BoolValue(indexJSON[@"map_to_resources"]);
                                        NSString *dir = toResources
                                            ? [path.gameHome stringByAppendingPathComponent:@"resources"]
                                            : assetsRoot;
                                        item.path = [dir stringByAppendingPathComponent:key];
                                    } else {
                                        NSString *sub = [hash substringToIndex:2];
                                        item.path = [[objectsRoot stringByAppendingPathComponent:sub]
                                                     stringByAppendingPathComponent:hash];
                                    }

                                    // 资源对象的 hash 字段本身就是它的 SHA1
                                    item.sha1 = hash;
                                    item.size = A2LongLongValue(obj[@"size"]);
                                    item.urls = @[[NSString stringWithFormat:
                                                   @"https://resources.download.minecraft.net/%@/%@",
                                                   [hash substringToIndex:2], hash]];

                                    [items addObject:item];
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- 3. 逐个检查 ----
        NSFileManager *fm = NSFileManager.defaultManager;
        NSInteger itemCount = (NSInteger)items.count;
        // 进度回调节流：几千个资源文件逐个回调会把主队列灌满
        NSInteger step = MAX(1, itemCount / 200);

        for (NSInteger i = 0; i < itemCount; i++) {
            A2IntegrityItem *item = items[(NSUInteger)i];

            if (progress && (i % step == 0 || i == itemCount - 1)) {
                double p = (double)i / (double)MAX(1, itemCount);
                NSString *name = item.path.lastPathComponent ?: @"";
                dispatch_async(dispatch_get_main_queue(), ^{
                    progress(p, name);
                });
            }

            NSDictionary *attrs = [fm attributesOfItemAtPath:item.path error:nil];
            if (!attrs) {
                total += 1;
                [issues addObject:A2MakeIssue(item, A2IntegrityReasonMissing, -1, @"缺失")];
                continue;
            }

            long long actualSize = [attrs[NSFileSize] longLongValue];

            // 快速档：只比大小。size 未声明（0）时跳过 —— 拿 0 当期望值会全判错
            if (item.size > 0 && actualSize != item.size) {
                total += 1;
                NSString *text = [NSString stringWithFormat:@"大小不符（%lld ≠ %lld）",
                                  actualSize, item.size];
                [issues addObject:A2MakeIssue(item, A2IntegrityReasonSizeMismatch,
                                              actualSize, text)];
                continue;
            }

            // 完整档：算 SHA1。没有 sha1 声明的项（极少数老版本）只能放过
            if (mode == A2IntegrityCheckModeFull && item.sha1.length == 40) {
                NSString *actual = [A2IntegrityChecker sha1OfFile:item.path];
                if (!actual ||
                    [actual caseInsensitiveCompare:item.sha1] != NSOrderedSame) {
                    total += 1;
                    [issues addObject:A2MakeIssue(item, A2IntegrityReasonSHA1Mismatch,
                                                  actualSize, @"SHA1 不符（内容损坏）")];
                    continue;
                }
            }

            total += 1;
            ok += 1;
        }

        // ---- 4. 汇总 ----
        A2IntegrityReport *report = [A2IntegrityReport new];
        report.totalFiles = total;
        report.okFiles = ok;
        report.issues = issues;
        report.versionChain = chain;
        report.chainBroken = broken;
        report.elapsed = [[NSDate date] timeIntervalSinceDate:start];

        [A2Logger info:@"IntegrityChecker"
               message:[NSString stringWithFormat:@"%@（%@档）：%@",
                        versionName,
                        mode == A2IntegrityCheckModeFull ? @"完整" : @"快速",
                        [report summaryText]]];

        if (progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(1.0, @"");
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(report);
        });
    });
}

#pragma mark 旧接口：只删损坏文件

- (NSInteger)repairReport:(A2IntegrityReport *)report {
    NSInteger removed = 0;
    NSFileManager *fm = NSFileManager.defaultManager;

    for (A2IntegrityIssue *issue in report.issues) {
        // 只删「大小不符 / SHA1 不符」。
        // 「缺失」不需要删 —— 本来就没有；
        // 「父版本缺失 / json 坏了」删了只会让状态更糟，交给重装。
        if (!issue.needsRemovalBeforeRepair) continue;
        if ([fm removeItemAtPath:issue.path error:nil]) removed++;
    }

    [A2Logger info:@"IntegrityChecker"
           message:[NSString stringWithFormat:
                    @"修复（仅删除）：删除 %ld 个损坏文件，等待重新下载",
                    (long)removed]];
    return removed;
}

@end

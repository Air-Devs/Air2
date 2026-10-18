#import "ModUpdateService.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "CurseForgeMurmurHash.h"

#pragma mark - ModUpdateResult 实现

@implementation ModUpdateResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _candidateVersions = @[];
        _allVersions = @[];
        _projectType = @"mod";
    }
    return self;
}

/// 是否有可用更新：候选版本列表非空即视为有更新
- (BOOL)hasUpdate {
    return self.candidateVersions.count > 0;
}

@end

#pragma mark - ModUpdateService 实现

@interface ModUpdateService ()
/// 并发反查使用的串行队列（仅用于隔离双源任务派发）
@property (nonatomic, strong) dispatch_queue_t lookupQueue;
@end

@implementation ModUpdateService

+ (instancetype)sharedService {
    static ModUpdateService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 使用全局并发队列派发反查任务，这里仅作为标识保留
        _lookupQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    }
    return self;
}

#pragma mark - 单个 Mod 更新检查（双源抢答）

- (void)checkUpdateForMod:(ModItem *)mod
              gameVersion:(NSString *)gameVersion
                   loader:(nullable NSString *)loader
              projectType:(NSString *)projectType
               completion:(void (^)(ModUpdateResult *_Nullable result))completion {
    // 参数校验：必须有本地文件路径
    if (!mod || mod.filePath.length == 0) {
        [self callCompletionOnMain:nil completion:completion];
        return;
    }

    // 共享状态：用于双源抢答的同步控制
    NSObject *lock = [[NSObject alloc] init];
    __block BOOL resolved = NO;            // 是否已经决定（命中或两个源都失败）
    __block BOOL modrinthDone = NO;        // Modrinth 反查是否完成
    __block BOOL curseforgeDone = NO;      // CurseForge 反查是否完成
    __block NSMutableDictionary *winnerResult = nil;  // 命中源返回的项目字典
    __block NSNumber *winnerSource = nil;              // 命中源（1=Modrinth, 2=CurseForge）

    // 抢答核心逻辑：任一源返回非空即采用，若先返回者为空则等待另一源
    void (^tryResolve)(NSMutableDictionary *_Nullable, NSNumber *) = ^(NSMutableDictionary *_Nullable result, NSNumber *source) {
        @synchronized(lock) {
            // 已决定则直接丢弃后到的结果（软取消）
            if (resolved) return;

            if (result && result.count > 0) {
                // 命中：采用该源结果
                resolved = YES;
                winnerResult = result;
                winnerSource = source;
            } else {
                // 当前源未命中，检查是否两个源都已完成
                if (modrinthDone && curseforgeDone) {
                    // 两个源都未命中，整体失败
                    resolved = YES;
                }
            }
        }

        // 在锁外判断是否需要继续推进（避免持锁回调）
        BOOL shouldFetch = NO;
        BOOL shouldFail = NO;
        @synchronized(lock) {
            if (winnerResult && [winnerSource isEqual:source]) {
                shouldFetch = YES;
                // 取一次后清空，避免重复触发
                winnerSource = nil;
            } else if (resolved && !winnerResult) {
                shouldFail = YES;
            }
        }

        if (shouldFetch) {
            // 命中后拉取该项目全部版本列表
            [self fetchVersionsAndBuildResultWithProjectDict:result
                                                       source:source
                                                          mod:mod
                                                  gameVersion:gameVersion
                                                       loader:loader
                                                  projectType:projectType
                                                   completion:completion];
        } else if (shouldFail) {
            // 两个源都未命中，主线程回调 nil
            [self callCompletionOnMain:nil completion:completion];
        }
    };

    // Modrinth 反查：使用 mod.fileSHA1（同步方法，放到后台队列执行）
    dispatch_async(self.lookupQueue, ^{
        @autoreleasepool {
            NSMutableDictionary *r = nil;
            // Modrinth 必须依赖 fileSHA1
            if (mod.fileSHA1.length > 0) {
                @try {
                    r = [[ModrinthAPI sharedInstance] projectForFileHash:mod.fileSHA1 projectType:projectType];
                } @catch (NSException *exception) {
                    r = nil;
                }
            }
            @synchronized(lock) {
                modrinthDone = YES;
            }
            tryResolve(r, @(1));
        }
    });

    // CurseForge 反查：先用文件路径本地计算 MurmurHash2 指纹，再传指纹数字反查（同步方法）
    // 修复：原实现直接把 mod.filePath 字符串传给 projectForFileHash，内部
    // [murmurHash longLongValue] 对非数字的路径恒为 0，指纹永不命中
    dispatch_async(self.lookupQueue, ^{
        @autoreleasepool {
            NSMutableDictionary *r = nil;
            if (mod.filePath.length > 0) {
                @try {
                    uint32_t fingerprint = [CurseForgeMurmurHash fingerprintForFileAtPath:mod.filePath];
                    if (fingerprint != 0) {
                        r = [[CurseForgeAPI sharedInstance] projectForFileHash:@(fingerprint) projectType:projectType];
                    }
                } @catch (NSException *exception) {
                    r = nil;
                }
            }
            @synchronized(lock) {
                curseforgeDone = YES;
            }
            tryResolve(r, @(2));
        }
    });
}

#pragma mark - 拉取版本列表并构建结果

- (void)fetchVersionsAndBuildResultWithProjectDict:(NSMutableDictionary *)projectDict
                                            source:(NSNumber *)source
                                               mod:(ModItem *)mod
                                       gameVersion:(NSString *)gameVersion
                                            loader:(nullable NSString *)loader
                                       projectType:(NSString *)projectType
                                        completion:(void (^)(ModUpdateResult *_Nullable))completion {
    // 从反查返回的字典中提取项目 ID
    NSString *projectID = [self extractProjectIDFromDict:projectDict source:source];
    if (projectID.length == 0) {
        [self callCompletionOnMain:nil completion:completion];
        return;
    }

    // 选择对应源的 API 实例拉取版本列表
    id api = ([source intValue] == 1) ? [ModrinthAPI sharedInstance] : [CurseForgeAPI sharedInstance];
    if (![api respondsToSelector:@selector(getVersionsForModWithID:completion:)]) {
        [self callCompletionOnMain:nil completion:completion];
        return;
    }

    [api getVersionsForModWithID:projectID completion:^(NSArray<ModVersion *> *_Nullable versions, NSError *_Nullable error) {
        // 注意：现有 API 实现在主线程回调此 block
        if (error || !versions || versions.count == 0) {
            [self callCompletionOnMain:nil completion:completion];
            return;
        }

        ModUpdateResult *result = [self buildResultWithMod:mod
                                                 projectID:projectID
                                                 apiSource:source
                                               projectType:projectType
                                                  versions:versions
                                              gameVersion:gameVersion
                                                   loader:loader
                                              projectDict:projectDict];
        [self callCompletionOnMain:result completion:completion];
    }];
}

#pragma mark - 版本筛选与结果构建

- (ModUpdateResult *)buildResultWithMod:(ModItem *)mod
                              projectID:(NSString *)projectID
                              apiSource:(NSNumber *)apiSource
                            projectType:(NSString *)projectType
                               versions:(NSArray<ModVersion *> *)versions
                           gameVersion:(NSString *)gameVersion
                                loader:(nullable NSString *)loader
                           projectDict:(NSDictionary *)projectDict {
    // 1. 识别当前版本（反查命中的版本）
    ModVersion *currentVersion = [self findCurrentVersionIn:versions
                                                        mod:mod
                                              projectDict:projectDict
                                                   apiSource:apiSource];

    // 2. 全部版本按 datePublished 降序排序（最新在前）
    NSArray<ModVersion *> *sortedAll = [versions sortedArrayUsingComparator:^NSComparisonResult(ModVersion *_Nonnull v1, ModVersion *_Nonnull v2) {
        NSDate *d1 = [self parseISO8601:v1.datePublished];
        NSDate *d2 = [self parseISO8601:v2.datePublished];
        if (!d1 && !d2) return NSOrderedSame;
        if (!d1) return NSOrderedAscending;
        if (!d2) return NSOrderedDescending;
        return [d2 compare:d1]; // 降序
    }];

    // 3. 计算当前版本的发布日期（用于严格大于比较）
    NSDate *currentDate = [self parseISO8601:currentVersion.datePublished];
    if (!currentDate && currentVersion.datePublished.length > 0) {
        currentDate = [self parseISO8601:currentVersion.datePublished];
    }

    // 4. 确定加载器过滤策略（智能回退）
    NSArray<NSString *> *effectiveLoaders = [self effectiveLoadersForMod:mod inputLoader:loader];

    // 5. 筛选更新候选：datePublished 严格大于当前版本 + 游戏版本过滤 + 加载器过滤
    NSMutableArray<ModVersion *> *candidates = [NSMutableArray array];
    for (ModVersion *v in sortedAll) {
        // 5.1 必须能解析出发布日期
        NSDate *vDate = [self parseISO8601:v.datePublished];
        if (!vDate) continue;

        // 5.2 必须严格大于当前版本日期（当前版本日期未知时跳过该过滤）
        if (currentDate && [vDate compare:currentDate] != NSOrderedDescending) {
            continue;
        }

        // 5.3 游戏版本过滤（传入 gameVersion 时必须包含）
        if (gameVersion.length > 0 && ![v.gameVersions containsObject:gameVersion]) {
            continue;
        }

        // 5.4 加载器过滤（智能回退策略，effectiveLoaders 为空时不过滤）
        if (effectiveLoaders.count > 0) {
            BOOL loaderMatch = NO;
            for (NSString *l in effectiveLoaders) {
                if ([v.loaders containsObject:l]) {
                    loaderMatch = YES;
                    break;
                }
            }
            if (!loaderMatch) continue;
        }

        [candidates addObject:v];
    }

    // 6. 构建结果对象
    ModUpdateResult *result = [[ModUpdateResult alloc] init];
    result.localFilePath = mod.filePath;
    result.currentVersion = currentVersion;
    result.candidateVersions = [candidates copy]; // 已是降序
    result.allVersions = sortedAll;
    result.projectID = projectID;
    result.apiSource = apiSource;
    result.projectType = projectType;
    return result;
}

#pragma mark - 当前版本识别

/// 在全部版本列表中识别当前版本（反查命中的版本）
/// 优先级：fileId（CurseForge） > fileSHA1（Modrinth primaryFile） > versionNumber > 最新版本兜底
- (ModVersion *)findCurrentVersionIn:(NSArray<ModVersion *> *)versions
                                 mod:(ModItem *)mod
                        projectDict:(NSDictionary *)projectDict
                            apiSource:(NSNumber *)apiSource {
    if (versions.count == 0) return nil;

    // 策略 1：CurseForge 用 fileId 匹配（反查返回字典里有 fileId）
    if ([apiSource intValue] == 2) {
        NSString *curFileId = [projectDict[@"fileId"] isKindOfClass:[NSString class]] ? projectDict[@"fileId"] : nil;
        if (curFileId.length > 0) {
            for (ModVersion *v in versions) {
                if ([v.fileId isEqualToString:curFileId]) {
                    return v;
                }
            }
        }
    }

    // 策略 2：Modrinth 用 fileSHA1 匹配 primaryFile 的 hashes.sha1
    if (mod.fileSHA1.length > 0) {
        for (ModVersion *v in versions) {
            NSDictionary *primaryFile = v.primaryFile;
            if (![primaryFile isKindOfClass:[NSDictionary class]]) continue;
            // Modrinth 格式：hashes[@"sha1"]
            id hashesVal = primaryFile[@"hashes"];
            if ([hashesVal isKindOfClass:[NSDictionary class]]) {
                NSString *sha1 = [hashesVal[@"sha1"] isKindOfClass:[NSString class]] ? hashesVal[@"sha1"] : nil;
                if (sha1 && [sha1 isEqualToString:mod.fileSHA1]) {
                    return v;
                }
            }
            // 兜底：URL 中包含 sha1（Modrinth 文件 URL 通常以 sha1 为文件名）
            NSString *url = [primaryFile[@"url"] isKindOfClass:[NSString class]] ? primaryFile[@"url"] : nil;
            if (url && [url containsString:mod.fileSHA1]) {
                return v;
            }
        }
    }

    // 策略 3：用版本号匹配（mod.version 与 versionNumber 比较）
    if (mod.version.length > 0) {
        for (ModVersion *v in versions) {
            if ([v.versionNumber isEqualToString:mod.version]) {
                return v;
            }
        }
    }

    // 策略 4：CurseForge 用 fileId 与 ModVersion.fileId 匹配（mod 无 fileId 字段，跳过）

    // 策略 5：兜底，只有一个版本时直接返回
    if (versions.count == 1) {
        return versions.firstObject;
    }

    // 策略 6：兜底，返回降序排序后的第一个（最新版本）
    NSArray<ModVersion *> *sorted = [versions sortedArrayUsingComparator:^NSComparisonResult(ModVersion *_Nonnull v1, ModVersion *_Nonnull v2) {
        NSDate *d1 = [self parseISO8601:v1.datePublished];
        NSDate *d2 = [self parseISO8601:v2.datePublished];
        if (!d1 && !d2) return NSOrderedSame;
        if (!d1) return NSOrderedAscending;
        if (!d2) return NSOrderedDescending;
        return [d2 compare:d1];
    }];
    return sorted.firstObject;
}

#pragma mark - 加载器智能回退

/// 计算用于版本过滤的加载器集合
/// 策略：
///   - 若 mod 声明的加载器（isFabric/isForge/isNeoForge）包含传入的 loader，用传入的 loader 过滤
///   - 若不一致（信雅互联等场景），沿用文件自身声明的加载器集合过滤
///   - 若 mod 未声明加载器且 loader 为 nil，返回空数组（不过滤）
- (NSArray<NSString *> *)effectiveLoadersForMod:(ModItem *)mod inputLoader:(nullable NSString *)loader {
    // 收集 mod 声明的加载器
    NSMutableArray<NSString *> *declared = [NSMutableArray array];
    if (mod.isFabric) [declared addObject:@"fabric"];
    if (mod.isForge) [declared addObject:@"forge"];
    if (mod.isNeoForge) [declared addObject:@"neoforge"];

    // 检查传入的 loader 是否与 mod 声明一致
    if (loader.length > 0) {
        NSString *lowerLoader = [loader lowercaseString];
        for (NSString *l in declared) {
            if ([l isEqualToString:lowerLoader]) {
                // 一致：用传入的 loader 过滤
                return @[lowerLoader];
            }
        }
        // 不一致：若 mod 完全未声明加载器，则信任传入的 loader
        if (declared.count == 0) {
            return @[lowerLoader];
        }
        // 否则落入回退分支（沿用 mod 声明的加载器集合）
    }

    // 不一致或 loader 为空：沿用文件自身声明的加载器集合
    if (declared.count > 0) {
        return [declared copy];
    }

    // 都没有：返回空数组，表示不进行加载器过滤
    return @[];
}

#pragma mark - 工具方法

/// 从反查返回的项目字典中提取项目 ID
- (nullable NSString *)extractProjectIDFromDict:(NSDictionary *)dict source:(NSNumber *)source {
    if (!dict || dict.count == 0) return nil;

    if ([source intValue] == 1) {
        // Modrinth：projectForFileHash 返回的字典中 id 字段即为 project_id
        id v = dict[@"id"];
        if ([v isKindOfClass:[NSString class]]) return v;
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
        // 兜底尝试 project_id 键
        id pid = dict[@"project_id"];
        if ([pid isKindOfClass:[NSString class]]) return pid;
        if ([pid isKindOfClass:[NSNumber class]]) return [pid stringValue];
        return nil;
    } else {
        // CurseForge：projectForFileHash 返回的字典中 id 字段为 modId
        id v = dict[@"id"];
        if ([v isKindOfClass:[NSString class]]) return v;
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
        // 兜底尝试 modId 键
        id mid = dict[@"modId"];
        if ([mid isKindOfClass:[NSString class]]) return mid;
        if ([mid isKindOfClass:[NSNumber class]]) return [mid stringValue];
        return nil;
    }
}

/// 解析 ISO8601 日期字符串为 NSDate（兼容带毫秒和不带毫秒两种格式）
- (nullable NSDate *)parseISO8601:(NSString *)dateString {
    if (![dateString isKindOfClass:[NSString class]] || dateString.length == 0) return nil;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    // 先尝试带毫秒的格式（CurseForge fileDate 常见格式）
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:dateString];
    if (!date) {
        // 降级尝试不带毫秒的格式
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [formatter dateFromString:dateString];
    }
    return date;
}

/// 在主线程回调 completion
- (void)callCompletionOnMain:(ModUpdateResult *_Nullable)result
                  completion:(void (^)(ModUpdateResult *_Nullable))completion {
    if (!completion) return;
    if ([NSThread isMainThread]) {
        completion(result);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    }
}

#pragma mark - 批量检查更新（并发限流 3）

- (void)checkUpdatesForMods:(NSArray<ModItem *> *)mods
               gameVersion:(NSString *)gameVersion
                    loader:(nullable NSString *)loader
               projectType:(NSString *)projectType
                  progress:(void (^)(NSInteger completed, NSInteger total))progress
                completion:(void (^)(NSArray<ModUpdateResult *> *results))completion {
    NSInteger total = mods.count;

    // 空数组直接回调
    if (total == 0) {
        [self callProgressOnMain:0 total:0 progress:progress];
        [self callBatchCompletionOnMain:@[] completion:completion];
        return;
    }

    // 并发限流信号量（最多 3 个并发）
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(3);
    dispatch_queue_t workQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    // 收集结果用的同步锁
    NSObject *lock = [[NSObject alloc] init];
    __block NSMutableArray<ModUpdateResult *> *results = [NSMutableArray array];
    __block NSInteger completed = 0;

    for (ModItem *mod in mods) {
        dispatch_async(workQueue, ^{
            // 等待信号量（限流）
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

            // 调用单个 Mod 的更新检查
            [self checkUpdateForMod:mod
                        gameVersion:gameVersion
                             loader:loader
                        projectType:projectType
                         completion:^(ModUpdateResult *_Nullable result) {
                // 此回调在主线程
                @synchronized(lock) {
                    if (result && [result hasUpdate]) {
                        [results addObject:result];
                    }
                    completed++;
                    NSInteger c = completed;
                    NSArray<ModUpdateResult *> *snapshot = [results copy];

                    // 进度回调
                    [self callProgressOnMain:c total:total progress:progress];

                    // 全部完成时回调最终结果
                    if (c >= total) {
                        [self callBatchCompletionOnMain:snapshot completion:completion];
                    }
                }
                // 释放信号量，允许下一个任务进入
                dispatch_semaphore_signal(semaphore);
            }];
        });
    }
}

/// 在主线程回调进度
- (void)callProgressOnMain:(NSInteger)completed
                     total:(NSInteger)total
                  progress:(void (^)(NSInteger completed, NSInteger total))progress {
    if (!progress) return;
    if ([NSThread isMainThread]) {
        progress(completed, total);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(completed, total);
        });
    }
}

/// 在主线程回调批量完成
- (void)callBatchCompletionOnMain:(NSArray<ModUpdateResult *> *)results
                       completion:(void (^)(NSArray<ModUpdateResult *> *results))completion {
    if (!completion) return;
    if ([NSThread isMainThread]) {
        completion(results);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results);
        });
    }
}

@end

//
//  A2GamePathManager.m
//  Air2
//

#import "A2GamePathManager.h"
#import "A2Logger.h"

NSNotificationName const A2GamePathsDidChangeNotification = @"A2GamePathsDidChangeNotification";

static NSString *const kPathsKey = @"A2GamePaths";
static NSString *const kCurrentKey = @"A2GamePathCurrent";

@implementation A2GamePathItem
@end

@interface A2GamePathManager ()
@property (nonatomic, strong) NSMutableArray<A2GamePathItem *> *paths;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *bookmarks;
@property (nonatomic, copy) NSString *currentIdentifier;
@end

@implementation A2GamePathManager

+ (instancetype)shared {
    static A2GamePathManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2GamePathManager alloc] init];
    });
    return shared;
}

+ (NSString *)defaultIdentifier {
    return @"default";
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _bookmarks = [NSMutableDictionary dictionary];
    [self load];
    return self;
}

#pragma mark - 持久化

- (NSString *)defaultGameHomePath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"minecraft"];
}

- (void)load {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    // 默认目录永远存在 —— 用户删不掉，也不能丢
    A2GamePathItem *def = [A2GamePathItem new];
    def.identifier = [A2GamePathManager defaultIdentifier];
    def.name = @"默认目录";
    def.path = [self defaultGameHomePath];
    def.isDefault = YES;

    NSMutableArray<A2GamePathItem *> *list = [NSMutableArray arrayWithObject:def];

    // 读用户添加的目录
    NSArray *saved = [d arrayForKey:kPathsKey];
    if ([saved isKindOfClass:NSArray.class]) {
        for (NSDictionary *dict in saved) {
            if (![dict isKindOfClass:NSDictionary.class]) continue;
            A2GamePathItem *item = [A2GamePathItem new];
            item.identifier = dict[@"id"] ?: [[NSUUID UUID] UUIDString];
            item.name = dict[@"name"] ?: @"未命名";
            item.path = dict[@"path"] ?: @"";
            item.isDefault = NO;
            if (item.path.length == 0) continue;
            [list addObject:item];
        }
    }

    // 读书签（外部目录需要安全书签才能访问）
    NSDictionary *bm = [d dictionaryForKey:@"A2GamePathBookmarks"];
    if ([bm isKindOfClass:NSDictionary.class]) {
        for (NSString *key in bm) {
            if ([bm[key] isKindOfClass:NSData.class]) {
                self.bookmarks[key] = bm[key];
            }
        }
    }

    self.paths = list;

    NSString *savedCurrent = [d stringForKey:kCurrentKey];
    if (savedCurrent.length && [self itemWithIdentifier:savedCurrent]) {
        self.currentIdentifier = savedCurrent;
    } else {
        self.currentIdentifier = [A2GamePathManager defaultIdentifier];
    }

    [self ensureDefaultDirectoryExists];
}

- (void)save {
    NSMutableArray *arr = [NSMutableArray array];
    for (A2GamePathItem *item in self.paths) {
        if (item.isDefault) continue;   // 默认目录不存，启动时重建
        [arr addObject:@{ @"id": item.identifier,
                          @"name": item.name,
                          @"path": item.path }];
    }

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:arr forKey:kPathsKey];
    [d setObject:self.currentIdentifier forKey:kCurrentKey];
    [d setObject:self.bookmarks forKey:@"A2GamePathBookmarks"];

    [NSNotificationCenter.defaultCenter postNotificationName:A2GamePathsDidChangeNotification
                                                      object:nil];
}

- (void)ensureDefaultDirectoryExists {
    NSString *path = [self defaultGameHomePath];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [NSFileManager.defaultManager createDirectoryAtPath:path
                                withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *versions = [path stringByAppendingPathComponent:@"versions"];
    if (![NSFileManager.defaultManager fileExistsAtPath:versions]) {
        [NSFileManager.defaultManager createDirectoryAtPath:versions
                                withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

#pragma mark - 查询

- (NSArray<A2GamePathItem *> *)allPaths {
    return [self.paths copy];
}

- (A2GamePathItem *)itemWithIdentifier:(NSString *)identifier {
    for (A2GamePathItem *item in self.paths) {
        if ([item.identifier isEqualToString:identifier]) return item;
    }
    return nil;
}

- (A2GamePathItem *)currentPath {
    A2GamePathItem *item = [self itemWithIdentifier:self.currentIdentifier];
    return item ?: self.paths.firstObject;
}

- (NSString *)currentGameHome {
    return self.currentPath.path;
}

#pragma mark - 操作

- (BOOL)selectPathWithIdentifier:(NSString *)identifier error:(NSError **)error {
    A2GamePathItem *item = [self itemWithIdentifier:identifier];
    if (!item) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2GamePathManager" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"目录不存在"}];
        }
        return NO;
    }

    // 外部目录要通过安全书签恢复访问权限
    if (!item.isDefault) {
        NSData *bm = self.bookmarks[item.identifier];
        if (bm) {
            BOOL ok = NO;
            NSError *bmErr = nil;
            // 同理：NSURLBookmarkResolutionWithoutUI 也是 macOS 专属，
            // iOS 上传 0 即可。
            NSURL *url = [NSURL URLByResolvingBookmarkData:bm
                                                   options:0
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&ok
                                                     error:&bmErr];
            if (url) {
                [url startAccessingSecurityScopedResource];
            } else {
                [A2Logger warning:@"A2GamePathManager"
                          message:[NSString stringWithFormat:@"书签解析失败：%@",
                                   bmErr.localizedDescription ?: @""]];
            }
        }
    }

    self.currentIdentifier = identifier;
    [self save];

    [A2Logger info:@"A2GamePathManager"
           message:[NSString stringWithFormat:@"切换到游戏目录：%@ (%@)", item.name, item.path]];
    return YES;
}

- (BOOL)addPathFromURL:(NSURL *)url name:(NSString *)name error:(NSError **)error {
    if (!url.isFileURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2GamePathManager" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"不是本地目录"}];
        }
        return NO;
    }

    // 去重：同一路径不重复添加
    NSString *path = url.path;
    for (A2GamePathItem *item in self.paths) {
        if ([item.path isEqualToString:path]) {
            if (error) {
                *error = [NSError errorWithDomain:@"A2GamePathManager" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"该目录已在列表中"}];
            }
            return NO;
        }
    }

    // 持久化安全书签 —— 否则重启后没有权限访问外部目录。
    //
    // ⚠️ 不要用 NSURLBookmarkCreationWithSecurityScope：
    //    这个选项是 macOS 专属的，iOS 上会报
    //    "'NSURLBookmarkCreationWithSecurityScope' is unavailable"。
    //    iOS 的沙盒机制下，书签本身就是安全作用域的，
    //    直接传 0（无额外选项）即可。
    NSError *bmErr = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&bmErr];

    if (!bookmark) {
        [A2Logger warning:@"A2GamePathManager"
                  message:[NSString stringWithFormat:@"书签创建失败（重启后可能需要重新授权）：%@",
                           bmErr.localizedDescription ?: @""]];
    }

    A2GamePathItem *item = [A2GamePathItem new];
    item.identifier = [[NSUUID UUID] UUIDString];
    item.name = name.length ? name : url.lastPathComponent;
    item.path = path;
    item.isDefault = NO;

    [self.paths addObject:item];
    if (bookmark) self.bookmarks[item.identifier] = bookmark;

    [self save];
    return YES;
}

- (BOOL)removePathWithIdentifier:(NSString *)identifier error:(NSError **)error {
    A2GamePathItem *item = [self itemWithIdentifier:identifier];
    if (!item) return NO;

    if (item.isDefault) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2GamePathManager" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"默认目录不能删除"}];
        }
        return NO;
    }

    [self.paths removeObject:item];
    [self.bookmarks removeObjectForKey:identifier];

    // 删掉的正好是当前目录 → 退回默认
    if ([self.currentIdentifier isEqualToString:identifier]) {
        self.currentIdentifier = [A2GamePathManager defaultIdentifier];
    }

    [self save];
    return YES;
}

- (BOOL)renamePathWithIdentifier:(NSString *)identifier
                              to:(NSString *)newName
                            error:(NSError **)error {
    A2GamePathItem *item = [self itemWithIdentifier:identifier];
    if (!item || newName.length == 0) return NO;

    item.name = newName;
    [self save];
    return YES;
}

- (BOOL)looksLikeGameDirectory:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return NO;

    // 有 versions 目录或 minecraft 特征文件就认为是游戏目录
    if ([fm fileExistsAtPath:[path stringByAppendingPathComponent:@"versions"]]) return YES;
    if ([fm fileExistsAtPath:[path stringByAppendingPathComponent:@"options.txt"]]) return YES;
    return NO;
}

@end

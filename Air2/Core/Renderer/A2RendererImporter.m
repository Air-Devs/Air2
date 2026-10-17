//
//  A2RendererImporter.m
//  Air2
//

#import "A2RendererImporter.h"
#import "A2ZipReader.h"
#import "A2Logger.h"

NSNotificationName const A2RendererPluginsDidChangeNotification = @"A2RendererPluginsDidChangeNotification";

static void A2Main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

@implementation A2RendererImportResult
@end

@interface A2RendererImporter ()
@property (nonatomic, strong) NSMutableArray<A2RendererPlugin *> *plugins;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation A2RendererImporter

+ (instancetype)shared {
    static A2RendererImporter *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2RendererImporter alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _plugins = [NSMutableArray array];
    _lock = [[NSLock alloc] init];
    return self;
}

/// 插件正式目录。
///
/// 放在 Documents 而不是 Library/Caches —— 用户导入的插件不该被系统清理。
/// （Caches 随时可能被清空，渲染器是用户主动装的，删了会很困惑）
- (NSString *)pluginsDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Air2/Renderers"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - 读取已安装

- (NSArray<A2RendererPlugin *> *)installedPlugins {
    [_lock lock];
    NSArray *copy = [self.plugins sortedArrayUsingComparator:^NSComparisonResult(
        A2RendererPlugin *a, A2RendererPlugin *b) {
        return [a.displayName compare:b.displayName];
    }];
    [_lock unlock];
    return copy;
}

- (void)reloadAll {
    NSString *dir = self.pluginsDirectory;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
                                    contentsOfDirectoryAtPath:dir error:nil];

    NSMutableArray<A2RendererPlugin *> *found = [NSMutableArray array];

    for (NSString *name in entries) {
        NSString *sub = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:sub isDirectory:&isDir];
        if (!isDir) continue;

        NSString *manifestPath = [sub stringByAppendingPathComponent:@"manifest.json"];
        NSData *data = [NSData dataWithContentsOfFile:manifestPath];
        if (!data) continue;

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        A2RendererPlugin *plugin = [A2RendererPlugin pluginWithManifest:json installPath:sub];
        if (!plugin) {
            [A2Logger warning:@"A2RendererImporter"
                      message:[NSString stringWithFormat:@"manifest 解析失败: %@", manifestPath]];
            continue;
        }

        [plugin validate];
        [found addObject:plugin];
    }

    [_lock lock];
    self.plugins = found;
    [_lock unlock];

    [A2Logger info:@"A2RendererImporter"
           message:[NSString stringWithFormat:@"扫描到 %lu 个导入渲染器", (unsigned long)found.count]];

    [NSNotificationCenter.defaultCenter postNotificationName:A2RendererPluginsDidChangeNotification
                                                      object:nil];
}

#pragma mark - 导入

- (void)importPluginAtPath:(NSString *)zipPath
                  progress:(void (^)(double, NSString *))progress
                completion:(void (^)(A2RendererImportResult *))completion {

    A2Main(^{
        if (progress) progress(0.05, @"正在读取插件包…");
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        A2RendererImportResult *result = [A2RendererImportResult new];

        // ---- 1. 解压到临时目录 ----
        NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"renderer_import_%u",
                              arc4random_uniform(1000000)]];
        [NSFileManager.defaultManager createDirectoryAtPath:tempDir
                                withIntermediateDirectories:YES attributes:nil error:nil];

        NSError *unzipError = nil;
        if (![self unzip:zipPath to:tempDir error:&unzipError]) {
            result.errorMessage = unzipError.localizedDescription ?: @"解压失败";
            [self cleanup:tempDir];
            [self finish:result progress:progress completion:completion];
            return;
        }

        A2Main(^{ if (progress) progress(0.3, @"正在校验插件…"); });

        // ---- 2. 找 manifest ----
        // 允许 zip 里套一层目录（用户打包时常这么干）
        NSString *manifestPath = [tempDir stringByAppendingPathComponent:@"manifest.json"];
        NSString *packageRoot = tempDir;

        if (![NSFileManager.defaultManager fileExistsAtPath:manifestPath]) {
            NSArray<NSString *> *entries = [NSFileManager.defaultManager
                                            contentsOfDirectoryAtPath:tempDir error:nil];
            for (NSString *name in entries) {
                NSString *sub = [tempDir stringByAppendingPathComponent:name];
                BOOL isDir = NO;
                [NSFileManager.defaultManager fileExistsAtPath:sub isDirectory:&isDir];
                if (!isDir) continue;

                NSString *m = [sub stringByAppendingPathComponent:@"manifest.json"];
                if ([NSFileManager.defaultManager fileExistsAtPath:m]) {
                    manifestPath = m;
                    packageRoot = sub;
                    break;
                }
            }
        }

        if (![NSFileManager.defaultManager fileExistsAtPath:manifestPath]) {
            result.errorMessage = @"插件包里没有 manifest.json";
            [self cleanup:tempDir];
            [self finish:result progress:progress completion:completion];
            return;
        }

        // ---- 3. 解析 manifest ----
        NSData *data = [NSData dataWithContentsOfFile:manifestPath];
        NSDictionary *json = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        A2RendererPlugin *plugin = [A2RendererPlugin pluginWithManifest:json installPath:packageRoot];

        if (!plugin) {
            result.errorMessage = @"manifest.json 格式不正确（缺 rendererId 或 rendererGLPath）";
            [self cleanup:tempDir];
            [self finish:result progress:progress completion:completion];
            return;
        }

        A2Main(^{ if (progress) progress(0.5, @"正在安装…"); });

        // ---- 4. 移到正式目录 ----
        NSString *destDir = [self.pluginsDirectory
                             stringByAppendingPathComponent:plugin.rendererID];
        BOOL existed = [NSFileManager.defaultManager fileExistsAtPath:destDir];

        NSFileManager *fm = NSFileManager.defaultManager;
        if (existed) {
            // 覆盖安装：先删旧的
            [fm removeItemAtPath:destDir error:nil];
        }

        NSError *moveError = nil;
        // 用 copy 而不是 move —— 临时目录与 Documents 可能不在同一卷
        BOOL moved = [fm copyItemAtPath:packageRoot toPath:destDir error:&moveError];

        [self cleanup:tempDir];

        if (!moved) {
            result.errorMessage = moveError.localizedDescription ?: @"安装到插件目录失败";
            [self finish:result progress:progress completion:completion];
            return;
        }

        // 重建插件对象（installPath 变成正式目录）
        plugin = [A2RendererPlugin pluginWithManifest:json installPath:destDir];
        [plugin validate];

        A2Main(^{ if (progress) progress(0.9, @"正在注册…"); });

        // ---- 5. 注册 ----
        [_lock lock];
        NSMutableArray *list = [self.plugins mutableCopy] ?: [NSMutableArray array];
        for (NSUInteger i = 0; i < list.count; i++) {
            A2RendererPlugin *p = list[i];
            if ([p.rendererID isEqualToString:plugin.rendererID]) {
                [list removeObjectAtIndex:i];
                break;
            }
        }
        [list addObject:plugin];
        self.plugins = list;
        [_lock unlock];

        [A2Logger info:@"A2RendererImporter"
               message:[NSString stringWithFormat:@"插件「%@」导入成功，状态=%ld",
                        plugin.displayName, (long)plugin.availability]];

        result.success = YES;
        result.plugin = plugin;
        result.replacedExisting = existed;

        [self finish:result progress:progress completion:completion];
    });
}

- (void)finish:(A2RendererImportResult *)result
      progress:(void (^)(double, NSString *))progress
    completion:(void (^)(A2RendererImportResult *))completion {
    A2Main(^{
        if (progress) {
            progress(1.0, result.success ? @"导入完成" : (result.errorMessage ?: @"导入失败"));
        }
        if (result.success) {
            [NSNotificationCenter.defaultCenter postNotificationName:A2RendererPluginsDidChangeNotification
                                                              object:nil];
        }
        if (completion) completion(result);
    });
}

- (void)cleanup:(NSString *)dir {
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

#pragma mark - 解压

/// 用 A2ZipReader 解压全部条目。
///
/// 为什么要自己解压而不是用系统 API：
/// iOS 没有公开的 zip 解压 API。A2ZipReader 是为读 installer jar 写的，
/// 这里复用 —— 它支持 stored 与 deflate，覆盖插件包的实际情况。
- (BOOL)unzip:(NSString *)zipPath to:(NSString *)destDir error:(NSError **)error {
    A2ZipReader *zip = [[A2ZipReader alloc] initWithPath:zipPath];
    if (!zip) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RendererImporter" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"不是有效的 zip 文件"}];
        }
        return NO;
    }

    NSUInteger extracted = 0;
    for (NSString *entry in zip.entryNames) {
        // 防目录穿越：拒绝包含 .. 的路径
        if ([entry containsString:@".."]) {
            [A2Logger warning:@"A2RendererImporter"
                      message:[NSString stringWithFormat:@"跳过可疑路径: %@", entry]];
            continue;
        }

        NSString *dest = [destDir stringByAppendingPathComponent:entry];
        if ([zip extractEntry:entry toPath:dest]) extracted++;
    }

    if (extracted == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2RendererImporter" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"包内没有可解压的文件"}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - 卸载

- (BOOL)removePlugin:(A2RendererPlugin *)plugin error:(NSError **)error {
    if (!plugin) return NO;

    NSString *dir = [self.pluginsDirectory stringByAppendingPathComponent:plugin.rendererID];
    NSError *rmError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:dir error:&rmError]) {
        if (error) *error = rmError;
        return NO;
    }

    [_lock lock];
    NSMutableArray *list = [self.plugins mutableCopy];
    for (NSUInteger i = 0; i < list.count; i++) {
        if ([list[i] isEqual:plugin]) { [list removeObjectAtIndex:i]; break; }
    }
    self.plugins = list;
    [_lock unlock];

    [NSNotificationCenter.defaultCenter postNotificationName:A2RendererPluginsDidChangeNotification
                                                      object:nil];
    return YES;
}

@end

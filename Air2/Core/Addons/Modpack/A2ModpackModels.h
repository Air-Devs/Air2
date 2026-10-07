//
//  A2ModpackModels.h
//  Air2
//
//  整合包的统一数据模型。
//
//  四种来源格式字段各异，但「装成本地版本」要做的事是同一件：
//  知道目标 MC 版本、加载器，知道要下载哪些文件、往哪个目录落，
//  知道哪些目录要整块铺进游戏目录。各解析器把自己的清单读成这里
//  的两类对象，安装器只面对统一模型，不必了解来源差异。
//

#import <Foundation/Foundation.h>
#import "A2ModpackFormat.h"
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 待下载文件

/// 整合包里需要下载的一个文件。
@interface A2ModpackFile : NSObject

/// 相对游戏目录的目标路径，如 mods/xxx.jar。
/// CurseForge 清单只给 projectID/fileID，路径要等 API 查完项目分类
/// 才能确定，此时这里是空串，由安装器补齐。
@property (nonatomic, copy) NSString *relativePath;

/// 候选下载地址，按优先级。CurseForge 惰性补齐前是空数组。
@property (nonatomic, copy) NSArray<NSString *> *downloadURLs;

/// 期望 SHA1，小写十六进制；无则 nil
@property (nonatomic, copy, nullable) NSString *sha1;

/// 期望大小，单位字节；0 表示未知
@property (nonatomic, assign) long long size;

/// 需要经 CurseForge API 查下载地址与目标目录
@property (nonatomic, assign) BOOL requiresCurseForgeLookup;
@property (nonatomic, assign) long long curseForgeProjectID;
@property (nonatomic, assign) long long curseForgeFileID;

@end

#pragma mark - 整合包元数据

/// 与来源格式无关的整合包描述。
@interface A2ModpackInfo : NSObject

@property (nonatomic, assign) A2ModpackFormat format;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *summary;

/// 推荐内存，单位 MB；0 表示清单未声明
@property (nonatomic, assign) NSInteger recommendedRAM;

/// 目标 MC 版本
@property (nonatomic, copy, nullable) NSString *gameVersion;

/// 加载器类型，对应 A2ModLoaderType；nil 表示原版
@property (nonatomic, strong, nullable) NSNumber *loaderType;

/// 加载器版本，nil 表示交给安装器选最新稳定版
@property (nonatomic, copy, nullable) NSString *loaderVersion;

/// 需要逐个下载的文件
@property (nonatomic, copy) NSArray<A2ModpackFile *> *files;

/// 需要整目录铺进游戏目录的 overrides 目录，相对解压后的根目录；
/// 按数组顺序处理，靠后的会覆盖靠前的同名文件。
@property (nonatomic, copy) NSArray<NSString *> *overrideDirectories;

@end

#pragma mark - 解析辅助

/// 读取 JSON 文件并解析成对象；文件不存在或内容非法时返回 nil。
static inline id _Nullable A2ModpackReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

/// 只接受字符串，其它类型一律当不存在，避免把数字或字典当成字符串用。
static inline NSString * _Nullable A2ModpackString(id _Nullable value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

/// zip 内路径统一用正斜杠，个别清单会写反斜杠。
static inline NSString *A2ModpackNormalizedPath(NSString *path) {
    return [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

/// 从候选目录名里挑出真正存在的那些，用于确定 overrides 目录。
static inline NSArray<NSString *> *A2ModpackExistingDirectories(NSString *root,
                                                                NSArray<NSString *> *candidates) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in candidates) {
        BOOL isDir = NO;
        NSString *path = [root stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) [out addObject:name];
    }
    return out;
}

/// 把各家格式里的加载器标识统一映射到 A2ModLoaderType。
/// 无法识别、或本来就是原版时返回 nil。
///
/// 三家写法都不同：Modrinth 用 forge / fabric-loader，
/// CurseForge 用 forge-47.2.0，MultiMC 用 net.minecraftforge。
/// 统一收在这里，避免每个解析器各写一份容易漏判的 switch。
static inline NSNumber * _Nullable A2ModpackLoaderTypeForIdentifier(NSString * _Nullable identifier) {
    if (identifier.length == 0) return nil;
    NSString *s = identifier.lowercaseString;
    // NeoForge 的名字里含 forge，必须先判，否则会被 Forge 抢走
    if ([s containsString:@"neoforge"]) return @(A2ModLoaderTypeNeoForge);
    if ([s containsString:@"legacyfabric"] || [s containsString:@"legacy-fabric"]) {
        return @(A2ModLoaderTypeLegacyFabric);
    }
    if ([s containsString:@"optifine"]) return @(A2ModLoaderTypeOptiFine);
    if ([s containsString:@"quilt"]) return @(A2ModLoaderTypeQuilt);
    if ([s containsString:@"fabric"]) return @(A2ModLoaderTypeFabric);
    if ([s containsString:@"forge"]) return @(A2ModLoaderTypeForge);
    return nil;
}

/// CurseForge 的 modLoaders 标识形如 forge-47.2.0、neoforge-21.1.72，
/// 版本号从第一个数字字符开始 —— 比按短横线切更稳，
/// 因为 legacy-fabric-0.15 这种前缀本身就含短横线。
static inline NSString * _Nullable A2ModpackVersionFromCurseForgeLoaderID(NSString * _Nullable identifier) {
    if (identifier.length == 0) return nil;
    for (NSUInteger i = 0; i < identifier.length; i++) {
        unichar c = [identifier characterAtIndex:i];
        if (c >= '0' && c <= '9') return [identifier substringFromIndex:i];
    }
    return nil;
}

NS_ASSUME_NONNULL_END

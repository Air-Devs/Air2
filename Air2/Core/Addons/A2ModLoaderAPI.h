//
//  A2ModLoaderAPI.h
//  Air2
//
//  模组加载器的版本查询与安装。
//
//  支持的加载器（对应 ZL2 的 addons/modloader 四类）：
//    FabricLike   Fabric / Quilt / LegacyFabric
//    ForgeLike    Forge / NeoForge
//    OptiFine     （需从官方页面解析）
//
//  数据源：
//    Fabric 系  https://meta.fabricmc.net/v2
//              https://bmclapi2.bangbang93.com/fabric-meta/v2（国内镜像）
//    Forge      https://maven.minecraftforge.net
//    NeoForge   https://maven.neoforged.net
//
//  国内镜像只在国内网络时优先，海外网络用官方源更快。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ModLoaderType) {
    A2ModLoaderTypeFabric = 0,
    A2ModLoaderTypeQuilt,
    A2ModLoaderTypeLegacyFabric,
    A2ModLoaderTypeForge,
    A2ModLoaderTypeNeoForge,
    A2ModLoaderTypeOptiFine,
};

/// 一个加载器版本
@interface A2ModLoaderVersion : NSObject
/// 加载器版本号（如 0.16.10）
@property (nonatomic, copy) NSString *version;
/// 是否为稳定版
@property (nonatomic, assign) BOOL stable;
/// 对应的加载器类型
@property (nonatomic, assign) A2ModLoaderType type;
/// 展示名（含类型前缀）
@property (nonatomic, copy, readonly) NSString *displayName;
+ (instancetype)version:(NSString *)v stable:(BOOL)stable type:(A2ModLoaderType)type;
@end

@interface A2ModLoaderAPI : NSObject

+ (instancetype)shared;

/// 查询指定加载器在某 MC 版本下的可用版本。
///
/// 会先检查该 MC 版本是否被这个加载器支持（不支持直接回调空数组）。
/// 国内网络会自动优先使用镜像源。
- (void)versionsForLoader:(A2ModLoaderType)type
              mcVersion:(NSString *)mcVersion
             completion:(void (^)(NSArray<A2ModLoaderVersion *> * _Nullable versions,
                                  NSError * _Nullable error))completion;

/// 加载器的显示名
+ (NSString *)displayNameForType:(A2ModLoaderType)type;
/// 加载器的标识（用于版本命名，如 fabric）
+ (NSString *)identifierForType:(A2ModLoaderType)type;
/// 全部支持的加载器
+ (NSArray<NSNumber *> *)allLoaderTypes;

@end

NS_ASSUME_NONNULL_END

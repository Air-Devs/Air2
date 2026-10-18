#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

/// 根据 loader 类型构造 installer.jar 下载 URL（Forge/NeoForge）
/// 提取自 ModpackImportService，供 ModrinthAPI/CurseForgeAPI 整合包安装复用
+ (nullable NSString *)installerURLForLoader:(NSString *)loader
                               loaderVersion:(NSString *)loaderVersion
                            minecraftVersion:(NSString *)minecraftVersion;

/// 根据 MC 版本推断所需 Java 主版本号
+ (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion;

/// 写入显式失败的占位 version JSON（mainClass 指向不存在的类，启动时显式报错）
/// 避免 Forge/NeoForge 直装失败后误装作 vanilla MC 让用户以为 mods 生效
+ (void)writePlaceholderVersionJSONForVersionId:(NSString *)versionId
                               minecraftVersion:(NSString *)minecraftVersion
                                         loader:(NSString *)loader
                                 loaderVersion:(NSString *)loaderVersion
                                          error:(NSError *)error;

@end

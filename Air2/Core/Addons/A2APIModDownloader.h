//
//  A2APIModDownloader.h
//  Air2
//
//  前置模组的下载（Fabric API / Quilt API / Legacy Fabric API）。
//
//  为什么单独做：
//    这些「API 模组」不在加载器的 meta 服务里 —— 它们是
//    Modrinth / CurseForge 上的普通模组，只是几乎所有模组都依赖。
//    ZL2 在加载器安装界面把它们单列出来，我们保持同样设计。
//
//  下载这些模组要：
//    1. 按 slug 查项目（fabric-api / quilted-fabric-api / legacy-fabric-api）
//    2. 按游戏版本 + 加载器筛出对应版本
//    3. 下载 jar 到版本的 mods 目录
//
//  ⚠️ 与普通 mod 下载的区别：这些要装进【版本的 mods 目录】，
//     而不是下载目录 —— 它们是让游戏能跑起来的前置，不是用户内容。
//

#import <Foundation/Foundation.h>
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2APIModDownloader : NSObject

+ (instancetype)shared;

/// 该 API 模组在 Modrinth 上的项目 slug。
/// 返回 nil 表示我们不知道它对应哪个项目。
+ (nullable NSString *)modrinthSlugForAPIType:(A2ModLoaderType)apiType;

/// 该 API 模组需要的加载器标识（用于筛版本）
+ (nullable NSString *)loaderIdentifierForAPIType:(A2ModLoaderType)apiType;

/// 查版本列表（供 UI 展示或自动选最新）
- (void)versionsForAPIType:(A2ModLoaderType)apiType
                mcVersion:(NSString *)mcVersion
               completion:(void (^)(NSArray<A2ModLoaderVersion *> * _Nullable versions,
                                    NSError * _Nullable error))completion;

/// 下载并安装到指定版本的 mods 目录。
///
/// @param apiType 前置模组类型
/// @param mcVersion 游戏版本
/// @param versionName 目标版本名（决定 mods 目录位置）
/// @param gameHome 游戏根目录
/// @param preferredVersion 指定版本号，nil 表示自动选最新
- (void)installAPIType:(A2ModLoaderType)apiType
             mcVersion:(NSString *)mcVersion
           versionName:(NSString *)versionName
              gameHome:(NSString *)gameHome
      preferredVersion:(nullable NSString *)preferredVersion
              progress:(void (^)(double progress, NSString *message))progress
            completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

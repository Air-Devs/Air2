//
//  A2ModLoaderSelection.h
//  Air2
//
//  加载器选择的互斥与配对规则 —— 对照 ZL2 的 DownloadGameModLoaderLists.kt。
//
//  这是加载器安装界面的核心逻辑，规则如下：
//
//  **主加载器之间互斥**
//    Forge 与 Fabric 不能同时选 —— 它们都要接管启动流程。
//
//  **API 模组依附于主加载器**
//    FabricAPI 必须配 Fabric，配 Forge 就互斥。
//    QuiltAPI → Quilt，LegacyFabricAPI → LegacyFabric。
//    选主加载器时不会自动带 API，但取消主加载器时会连带取消 API。
//
//  **OptiFine 与 Forge 是特例**
//    这两者可以共存（OptiFine 作为 Forge 的模组），
//    但要按版本成对校验 —— OptiFine 对 Forge 版本有最低要求。
//

#import <Foundation/Foundation.h>
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

/// 当前的选择状态
@interface A2ModLoaderSelection : NSObject

/// 各类型的已选版本。键是 @(A2ModLoaderType)，值是版本号字符串。
/// 不支持某类型则可直接不设。
@property (nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, NSString *> *versions;

/// 选定某类型的版本。会自动清除与之互斥的其它选择。
/// @param version 传 nil 表示取消选择
- (void)selectType:(A2ModLoaderType)type version:(nullable NSString *)version;

/// 当前已选的主加载器（可能为 nil）
@property (nonatomic, readonly, nullable) NSNumber *selectedLoaderType;
/// 当前已选的 API 模组（可能为 nil）
@property (nonatomic, readonly, nullable) NSNumber *selectedAPIType;

/// 该类型当前是否可选（与已选的不冲突）
- (BOOL)canSelectType:(A2ModLoaderType)type;

/// 该类型是否与当前选择冲突（用于 UI 置灰）
- (BOOL)isConflictingType:(A2ModLoaderType)type;

/// 某个 API 模组对应的主加载器
+ (nullable NSNumber *)primaryLoaderForAPI:(A2ModLoaderType)apiType;

/// 某个主加载器对应的 API 模组（没有则返回 nil）
+ (nullable NSNumber *)apiForPrimaryLoader:(A2ModLoaderType)loaderType;

/// 全部可选的主加载器
+ (NSArray<NSNumber *> *)allPrimaryLoaders;
/// 全部可选的 API 模组
+ (NSArray<NSNumber *> *)allAPIMods;

@end

NS_ASSUME_NONNULL_END

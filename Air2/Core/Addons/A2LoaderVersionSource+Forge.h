//
//  A2LoaderVersionSource+Forge.h
//  Air2
//
//  Forge / NeoForge 版本列表获取（实现见 A2LoaderVersionSource+Forge.m）。
//  单独建这个分类头，是为了让 A2LoaderVersionSource.m 能看见这两个方法
//  —— 它们的实现在分类里，此前没有任何头文件声明，导致主 .m 调用时报
//  “no visible @interface … declares the selector”。
//

#import "A2LoaderVersionSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2LoaderVersionSource (Forge)

/// 拉取指定 MC 版本的 Forge 版本列表（内部会走 BMCLAPI / 官网 HTML 两条路）
- (void)fetchForgeVersionsForMC:(NSString *)mcVersion
                     completion:(void (^)(NSArray<A2ModLoaderVersion *> *_Nullable versions,
                                          NSError *_Nullable error))completion;

/// 拉取指定 MC 版本的 NeoForge 版本列表
- (void)fetchNeoForgeVersionsForMC:(NSString *)mcVersion
                        completion:(void (^)(NSArray<A2ModLoaderVersion *> *_Nullable versions,
                                             NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

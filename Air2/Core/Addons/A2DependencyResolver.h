//
//  A2DependencyResolver.h
//  Air2
//
//  模组前置（依赖）自动解析。
//
//  为什么需要：玩家点「安装」一个模组时，很多模组必须配前置（Fabric API / Architectury …），
//  缺前置进游戏就崩或功能缺失。上游 herbrine8403 的
//  `feat(download): 模组依赖（前置）自动解析与安装` 就是做这件事，本文件按同样思路自研。
//
//  数据来源：Modrinth 的 version.dependencies
//    [{ "project_id": "...", "dependency_type": "required" | "optional" | "embedded" | "incompatible" }]
//  只把 required 当作"必须自动装"，其余仅报告。
//
//  调用点（后续接线）：下载/安装流程在真正下载主模组之前调用
//    +resolveForProjectID:gameVersion:loader:completion:
//  拿到前置清单 → 弹确认 → 先装前置 → 再装主模组。
//

#import <Foundation/Foundation.h>
#import "A2ModrinthAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DependencyResolver : NSObject

/// 解析某 Modrinth 工程的必需前置。
/// @param projectID   工程 id（不是 slug）
/// @param gameVersion 例如 "1.21.1"（为空则取该工程最新版本）
/// @param loader      例如 "fabric"（为空则不限）
/// @param completion  主线程回调：required 为必需前置工程（已含标题/图标），error 仅在完全失败时非空
+ (void)resolveForProjectID:(NSString *)projectID
                gameVersion:(nullable NSString *)gameVersion
                     loader:(nullable NSString *)loader
                 completion:(void (^)(NSArray<A2ModrinthProject *> * _Nullable required,
                                      NSArray<NSString *> * _Nullable optionalTitles,
                                      NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

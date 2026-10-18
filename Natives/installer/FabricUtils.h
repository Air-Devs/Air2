#import <Foundation/Foundation.h>

@interface FabricUtils : NSObject

/// 官方端点表（Fabric / Quilt 的 meta 与 profile json 模板）
+ (NSDictionary *)endpoints;

/// 按当前镜像策略返回 Fabric/Quilt meta 端点的候选 URL 数组
/// （endpoint 取值 game / loader；候选顺序由 download.modLoaderSource 策略决定，
///   Fabric meta → BMCLAPI /fabric-meta，Quilt meta → BMCLAPI /quilt-meta）
+ (NSArray<NSURL *> *)candidateURLsForVendor:(NSString *)vendor endpoint:(NSString *)endpoint;

/// 按当前镜像策略返回 profile json 端点格式化后的候选 URL 数组
/// （Fabric/Quilt loader 的 version JSON 下载地址，maven 体系 → BMCLAPI /maven）
+ (NSArray<NSURL *> *)candidateURLsForVendor:(NSString *)vendor
                             minecraftVersion:(NSString *)minecraftVersion
                               loaderVersion:(NSString *)loaderVersion;

@end

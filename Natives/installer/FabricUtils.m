#import "FabricUtils.h"
#import "PLMirrorCenter.h"

@implementation FabricUtils

+ (NSDictionary *)endpoints {
    return @{
        @"Fabric": @{
            @"game": @"https://meta.fabricmc.net/v2/versions/game",
            @"loader": @"https://meta.fabricmc.net/v2/versions/loader",
            @"icon": @"https://avatars.githubusercontent.com/u/21025855?s=64",
            @"json": @"https://meta.fabricmc.net/v2/versions/loader/%@/%@/profile/json"
        },
        @"Quilt": @{
            @"game": @"https://meta.quiltmc.org/v3/versions/game",
            @"loader": @"https://meta.quiltmc.org/v3/versions/loader",
            @"icon": @"https://raw.githubusercontent.com/QuiltMC/art/master/brand/64png/quilt_logo_transparent.png",
            @"json": @"https://meta.quiltmc.org/v3/versions/loader/%@/%@/profile/json"
        }
    };
}

/// 统一经 PLMirrorCenter（ModLoader 类型）生成候选：
/// 候选顺序由 download.modLoaderSource 策略（official_first / mirror_first）决定，
/// Fabric meta → BMCLAPI /fabric-meta，Quilt meta → BMCLAPI /quilt-meta，
/// 调用方按顺序尝试，失败即换下一候选。
+ (NSArray<NSURL *> *)candidateURLsForVendor:(NSString *)vendor endpoint:(NSString *)endpoint {
    NSString *template = self.endpoints[vendor][endpoint];
    if (![template isKindOfClass:[NSString class]]) return @[];
    return [PLMirrorCenter candidateURLsForOriginalURL:[NSURL URLWithString:template]
                                          resourceType:PLMirrorResourceTypeModLoader];
}

/// profile json 端点格式化（游戏版本 + 加载器版本）后再生成候选，
/// maven 体系 URL → BMCLAPI /maven 映射
+ (NSArray<NSURL *> *)candidateURLsForVendor:(NSString *)vendor
                             minecraftVersion:(NSString *)minecraftVersion
                               loaderVersion:(NSString *)loaderVersion {
    NSString *template = self.endpoints[vendor][@"json"];
    if (![template isKindOfClass:[NSString class]]) return @[];
    NSURL *official = [NSURL URLWithString:[NSString stringWithFormat:template, minecraftVersion, loaderVersion]];
    return [PLMirrorCenter candidateURLsForOriginalURL:official
                                          resourceType:PLMirrorResourceTypeModLoader];
}

@end

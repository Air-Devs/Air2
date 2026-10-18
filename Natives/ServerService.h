//
//  ServerService.h
//  Amethyst
//
//  服务器项目服务层，参照 ModService/ShaderService 的模式：
//  - 封装 Modrinth 和 CurseForge 双源切换
//  - 搜索/详情/加入服务器/下载服务端整合包
//

#import <Foundation/Foundation.h>
#import "ServerItem.h"

NS_ASSUME_NONNULL_BEGIN

/// 服务器搜索来源（与 PLPreferences.currentDownloadSourceForType:@"server" 对应）
typedef NS_ENUM(NSInteger, ServerDownloadAPI) {
    ServerDownloadAPIModrinth = 1,
    ServerDownloadAPICurseForge = 2,
};

typedef void(^ServerListHandler)(NSArray<ServerItem *> *servers, NSError * _Nullable error);
typedef void(^ServerDetailHandler)(ServerItem * _Nullable server, NSError * _Nullable error);
typedef void(^ServerDownloadHandler)(NSError * _Nullable error);
typedef void(^ServerProgressHandler)(NSProgress *progress);

@interface ServerService : NSObject

+ (instancetype)sharedService;

/// 根据当前偏好返回对应的 API（Modrinth 或 CurseForge）
+ (ServerDownloadAPI)currentAPI;

/// 搜索服务器项目（按当前偏好源）
/// @param api 指定使用的 API（Modrinth/CurseForge）
/// @param filters 搜索过滤条件（query/limit/offset/mcVersion/loader 等）
- (void)searchServersWithAPI:(ServerDownloadAPI)api
                     filters:(NSDictionary *)filters
                  completion:(ServerListHandler)completion;

/// 获取服务器详情（补充服务器地址、关联整合包等信息）
/// @param api 与搜索时使用的 API 一致
- (void)getServerDetailsWithAPI:(ServerDownloadAPI)api
                       serverID:(NSString *)serverID
                      completion:(ServerDetailHandler)completion;

/// 加入服务器：将服务器地址保存到当前 profile 配置（写入 serverIp 字段）
/// @param address 服务器地址（IP:端口 或 域名:端口）
/// @param profileName 目标 profile 名，nil 表示当前 profile
- (BOOL)joinServer:(NSString *)address
        forProfile:(nullable NSString *)profileName
             error:(NSError **)error;

/// 下载服务端整合包到指定 profile 目录
/// @param serverItem 已填充 serverPackDownloadURL/serverPackFileName 的服务器项目
/// @param profileName 目标 profile 名
/// @param progress 下载进度回调（主线程）
/// @param completion 下载完成回调（主线程）
- (void)downloadServerPack:(ServerItem *)serverItem
                 toProfile:(NSString *)profileName
                  progress:(nullable ServerProgressHandler)progress
                completion:(ServerDownloadHandler)completion;

/// 图标缓存路径（与 ModService 一致的策略）
- (NSString *)iconCachePathForURL:(NSString *)urlString;

@end

NS_ASSUME_NONNULL_END

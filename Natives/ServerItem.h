//
//  ServerItem.h
//  Amethyst
//
//  服务器项目数据模型，参照 ModItem 的设计：
//  既可以承载 Modrinth Server Projects（project_type=server），
//  也可以承载 CurseForge modpack 的 server pack 信息。
//  当 Modrinth Server Projects API 不可用时，回退使用 modpack 搜索结果。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 服务器项目来源 API
typedef NS_ENUM(NSInteger, ServerAPISource) {
    ServerAPISourceModrinth = 1, // Modrinth（project_type=server 或 modpack）
    ServerAPISourceCurseForge = 2, // CurseForge（modpack 的 server pack）
};

@interface ServerItem : NSObject

/// 服务器项目 ID（Modrinth project_id 或 CurseForge project id 字符串）
@property (nonatomic, copy, nullable) NSString *serverID;
/// 显示名称
@property (nonatomic, copy, nullable) NSString *title;
/// 简介/描述
@property (nonatomic, copy, nullable) NSString *serverDescription;
/// 图标 URL
@property (nonatomic, copy, nullable) NSString *iconURL;
/// 图标（缓存后的 UIImage）
@property (nonatomic, strong, nullable) UIImage *icon;
/// 下载数
@property (nonatomic, strong, nullable) NSNumber *downloads;
/// 关注/点赞数
@property (nonatomic, strong, nullable) NSNumber *likes;
/// 最后更新时间
@property (nonatomic, copy, nullable) NSString *lastUpdated;
/// 项目类型（"server" 或 "modpack"）
@property (nonatomic, copy, nullable) NSString *projectType;
/// 来源 API
@property (nonatomic, assign) ServerAPISource apiSource;
/// 作者
@property (nonatomic, copy, nullable) NSString *author;
/// 分类标签
@property (nonatomic, strong, nullable) NSArray<NSString *> *categories;

/// 服务器地址（IP/域名:端口），从项目详情或描述中解析得到，可能为空
@property (nonatomic, copy, nullable) NSString *serverAddress;
/// 关联的整合包 ID（若该服务器关联了 modpack，则记录其 project ID）
@property (nonatomic, copy, nullable) NSString *associatedModpackID;
/// 关联整合包的来源 API（与 associatedModpackID 配套，1=Modrinth, 2=CurseForge）
@property (nonatomic, assign) ServerAPISource associatedModpackSource;

/// 详情页所需：服务器关联整合包的下载 URL（如果有可直接下载的服务端整合包文件）
@property (nonatomic, copy, nullable) NSString *serverPackDownloadURL;
/// 详情页所需：服务端整合包文件名
@property (nonatomic, copy, nullable) NSString *serverPackFileName;
/// 详情页所需：服务端整合包文件大小（字节）
@property (nonatomic, strong, nullable) NSNumber *serverPackFileSize;

/// 项目主页 URL
@property (nonatomic, copy, nullable) NSString *homepage;

/// 通过 API 返回的字典构造（统一适配 Modrinth 与 CurseForge 字段）
- (instancetype)initWithSearchData:(NSDictionary *)data;

/// 通过详情 API 返回的字典补充字段（地址、关联整合包等）
- (void)applyDetailData:(NSDictionary *)data;

/// 格式化的下载数（如 1.2k）
- (NSString *)formattedDownloads;

/// 格式化的点赞数
- (NSString *)formattedLikes;

@end

NS_ASSUME_NONNULL_END

//
//  A2ContentSource.h
//  Air2
//
//  资源源的统一抽象 —— 抹平 Modrinth 与 CurseForge 的差异。
//
//  为什么需要这层：
//    两家的数据模型不同（字段名、分类体系、分页方式、能否下载的判断），
//    如果让 UI 层分别处理，每个页面都要写两套逻辑。
//    这里统一成 A2ContentItem，UI 只面对一种数据结构。
//
//  差异对照：
//    | 项        | Modrinth        | CurseForge           |
//    | 项目 ID   | 字符串 slug     | 数字 projectID        |
//    | 分类      | facets 字符串   | classId 数字          |
//    | 分页      | offset/limit    | index/pageSize        |
//    | 下载限制  | 无              | allowModDistribution  |
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ContentPlatform) {
    A2ContentPlatformModrinth = 0,
    A2ContentPlatformCurseForge,
};

/// 统一的资源条目
@interface A2ContentItem : NSObject
@property (nonatomic, assign) A2ContentPlatform platform;
/// 平台内的项目标识（Modrinth 是字符串 ID，CurseForge 是数字 ID 的字符串形式）
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloadCount;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, copy) NSArray<NSString *> *categories;
/// 是否允许第三方下载。CurseForge 上部分作者禁止。
@property (nonatomic, assign) BOOL downloadable;
@end

/// 统一的文件版本
@interface A2ContentVersion : NSObject
@property (nonatomic, copy) NSString *versionID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
@property (nonatomic, copy) NSArray<NSString *> *loaders;
/// 下载地址。为 nil 表示该平台不允许第三方下载。
@property (nonatomic, copy, nullable) NSString *downloadURL;
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, assign) long long fileSize;
@end

/// 统一的资源源
@interface A2ContentSource : NSObject

+ (instancetype)sourceForPlatform:(A2ContentPlatform)platform;

@property (nonatomic, assign, readonly) A2ContentPlatform platform;
/// 该源是否可用（CurseForge 需要 API Key）
@property (nonatomic, assign, readonly, getter=isAvailable) BOOL available;
/// 不可用时的原因
@property (nonatomic, copy, nullable, readonly) NSString *unavailableReason;

/// 搜索
- (void)searchWithQuery:(nullable NSString *)query
               category:(NSInteger)categoryIndex   // 统一用索引，各自映射
            gameVersion:(nullable NSString *)gameVersion
                 loader:(nullable NSString *)loader
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2ContentItem *> * _Nullable items,
                                  NSError * _Nullable error))completion;

/// 取项目的版本列表
- (void)versionsForProject:(NSString *)projectID
               gameVersion:(nullable NSString *)gameVersion
                    loader:(nullable NSString *)loader
                completion:(void (^)(NSArray<A2ContentVersion *> * _Nullable versions,
                                     NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

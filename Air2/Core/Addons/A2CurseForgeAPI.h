//
//  A2CurseForgeAPI.h
//  Air2
//
//  CurseForge 官方 API 客户端。
//
//  与 Modrinth 不同，CurseForge 要求应用方自备 API Key，
//  每个请求都要带 x-api-key 头。Air2 暂无设置模块，Key 先用
//  NSUserDefaults 的 A2CurseForgeAPIKey 承载，等设置模块就位再迁走。
//
//  端点前缀：https://api.curseforge.com/v1
//    GET  /mods/search            搜项目，classId 4471 即整合包
//    GET  /mods/{id}/files        列某项目的文件
//    GET  /mods/{id}/files/{fid}  单个文件详情
//    POST /mods/files             批量文件详情
//    POST /mods                   批量项目详情
//
//  整合包清单只给 projectID + fileID，直链、文件名、sha1 与
//  落盘目录都得回来查这里，所以安装器会走批量接口。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CurseForge 错误域
FOUNDATION_EXPORT NSString *const A2CurseForgeErrorDomain;

typedef NS_ENUM(NSInteger, A2CurseForgeErrorCode) {
    A2CurseForgeErrorMissingAPIKey = 1,   ///< 未配置 API Key
    A2CurseForgeErrorHTTPFailure = 2,     ///< 连接失败或 HTTP 非 2xx
    A2CurseForgeErrorInvalidResponse = 3, ///< 返回数据格式异常
};

static inline NSError *A2CurseForgeMakeError(A2CurseForgeErrorCode code, NSString *message) {
    return [NSError errorWithDomain:A2CurseForgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - 项目

/// 搜索结果里的一个 CurseForge 项目
@interface A2CurseForgeProject : NSObject
@property (nonatomic, assign) long long projectID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *slug;
@property (nonatomic, copy) NSString *projectDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloads;
@property (nonatomic, copy) NSArray<NSString *> *authors;
/// 分类 ID，整合包项目固定为 4471
@property (nonatomic, assign) NSInteger classID;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

#pragma mark - 文件

/// 一个 CurseForge 文件
@interface A2CurseForgeFile : NSObject
@property (nonatomic, assign) long long fileID;
/// 所属项目 ID
@property (nonatomic, assign) long long projectID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *fileName;
/// 直链；未许可第三方下载时按 CDN 规律回退生成
@property (nonatomic, copy, nullable) NSString *downloadURL;
/// SHA1，小写十六进制；清单/接口未提供则 nil
@property (nonatomic, copy, nullable) NSString *sha1;
@property (nonatomic, assign) long long fileLength;
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
/// 所属项目的分类 ID，决定落盘目录；未查到时为 0
@property (nonatomic, assign) NSInteger classID;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

#pragma mark - API

@interface A2CurseForgeAPI : NSObject

+ (instancetype)shared;

#pragma mark API Key

/// 是否已配置 API Key
+ (BOOL)hasAPIKey;
/// 当前 API Key，未配置时返回 nil
+ (nullable NSString *)apiKey;
/// 写入 API Key；传 nil 清除
+ (void)setAPIKey:(nullable NSString *)apiKey;

#pragma mark 查询

/// 搜索整合包
- (void)searchModpacksWithQuery:(nullable NSString *)query
                    gameVersion:(nullable NSString *)gameVersion
                         offset:(NSInteger)offset
                          limit:(NSInteger)limit
                     completion:(void (^)(NSArray<A2CurseForgeProject *> * _Nullable projects,
                                          NSError * _Nullable error))completion;

/// 列出某整合包项目的文件
- (void)filesForProject:(long long)projectID
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2CurseForgeFile *> * _Nullable files,
                                  NSError * _Nullable error))completion;

/// 单个文件详情，附带所属项目的分类 ID。
- (void)versionDetailForProject:(long long)projectID
                         fileID:(long long)fileID
                     completion:(void (^)(A2CurseForgeFile * _Nullable file,
                                          NSError * _Nullable error))completion;

/// 批量取文件详情，供整合包安装时补齐直链与 sha1。
- (void)fileDetailsForFileIDs:(NSArray<NSNumber *> *)fileIDs
                   completion:(void (^)(NSArray<A2CurseForgeFile *> * _Nullable files,
                                        NSError * _Nullable error))completion;

/// 批量取项目分类 ID，键为项目 ID 的 NSNumber，值为分类 ID 的 NSNumber。
- (void)classIDsForProjectIDs:(NSArray<NSNumber *> *)projectIDs
                   completion:(void (^)(NSDictionary<NSNumber *, NSNumber *> * _Nullable classIDs,
                                        NSError * _Nullable error))completion;

#pragma mark 分类映射

/// 项目分类 → 游戏目录下的落盘子目录。
+ (NSString *)directoryForClassID:(NSInteger)classID;

@end

NS_ASSUME_NONNULL_END

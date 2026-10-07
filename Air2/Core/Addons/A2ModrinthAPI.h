//
//  A2ModrinthAPI.h
//  Air2
//
//  Modrinth API 客户端。
//
//  公开 API，无需 Key：https://api.modrinth.com/v2
//  需要对所有请求设置 User-Agent（Modrinth 的要求，
//  不设会被限流或拒绝）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 项目类型
typedef NS_ENUM(NSInteger, A2ModrinthProjectType) {
    A2ModrinthProjectTypeMod = 0,
    A2ModrinthProjectTypeModpack,
    A2ModrinthProjectTypeResourcePack,
    A2ModrinthProjectTypeShader,
    A2ModrinthProjectTypeDatapack,
};

/// 搜索结果里的一个项目
@interface A2ModrinthProject : NSObject
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *slug;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *projectDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloads;
@property (nonatomic, assign) long long followers;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *author;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

/// 项目的某个版本
@interface A2ModrinthVersion : NSObject
@property (nonatomic, copy) NSString *versionID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *versionNumber;
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
@property (nonatomic, copy) NSArray<NSString *> *loaders;
@property (nonatomic, assign) NSInteger downloads;
@property (nonatomic, copy, nullable) NSString *datePublished;
@property (nonatomic, copy, nullable) NSString *changelog;
/// 主文件的下载地址
@property (nonatomic, copy, nullable) NSString *downloadURL;
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, assign) long long fileSize;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface A2ModrinthAPI : NSObject

+ (instancetype)shared;

/// 搜索项目
- (void)searchWithQuery:(nullable NSString *)query
                   type:(A2ModrinthProjectType)type
            gameVersion:(nullable NSString *)gameVersion
                 loader:(nullable NSString *)loader
                 offset:(NSInteger)offset
                  limit:(NSInteger)limit
             completion:(void (^)(NSArray<A2ModrinthProject *> * _Nullable results,
                                  NSError * _Nullable error))completion;

/// 取项目的所有版本
- (void)versionsForProject:(NSString *)projectID
              gameVersion:(nullable NSString *)gameVersion
                   loader:(nullable NSString *)loader
               completion:(void (^)(NSArray<A2ModrinthVersion *> * _Nullable versions,
                                    NSError * _Nullable error))completion;

/// 取项目详情
- (void)projectWithID:(NSString *)projectID
           completion:(void (^)(A2ModrinthProject * _Nullable project,
                                NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

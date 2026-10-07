//
//  A2CurseForgeAPI.h
//  Air2
//
//  CurseForge API 客户端。
//
//  与 Modrinth 的差异：
//    · 需要 API Key（在 console.curseforge.com 申请）
//    · 请求要带两个头：x-api-key 和 Authorization: Bearer
//    · Minecraft 的 gameId 固定为 432
//    · 部分作者禁止第三方分发，能否下载要看项目的 allowModDistribution
//
//  Key 不硬编码在源码里 —— 从 Keychain / 设置读取。
//  硬编码会进 git 历史，且无法吊销。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CurseForge 的资源分类（classId）
typedef NS_ENUM(NSInteger, A2CFClassID) {
    A2CFClassIDMod = 6,
    A2CFClassIDModpack = 4471,
    A2CFClassIDResourcePack = 12,
    A2CFClassIDShader = 6552,
    A2CFClassIDWorld = 17,
    A2CFClassIDDataPack = 6945,
};

/// Minecraft 在 CurseForge 的固定 ID
extern const NSInteger A2CFMinecraftGameID;

#pragma mark - 模型

/// 搜索结果里的一个项目
@interface A2CFProject : NSObject
@property (nonatomic, assign) NSInteger projectID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) long long downloadCount;
@property (nonatomic, assign) NSInteger classID;
@property (nonatomic, copy, nullable) NSString *slug;
@property (nonatomic, copy, nullable) NSString *authorName;
/// 作者是否允许第三方分发（false 表示只能去官网下）
@property (nonatomic, assign) BOOL allowDistribution;
+ (nullable instancetype)fromJSON:(NSDictionary *)json;
@end

/// 项目的某个文件
@interface A2CFFile : NSObject
@property (nonatomic, assign) NSInteger fileID;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *displayName;
/// 下载地址。为 nil 表示作者禁止第三方分发。
@property (nonatomic, copy, nullable) NSString *downloadURL;
@property (nonatomic, assign) long long fileLength;
/// 支持的 MC 版本（如 1.21.5）
@property (nonatomic, copy) NSArray<NSString *> *gameVersions;
+ (nullable instancetype)fromJSON:(NSDictionary *)json;
@end

#pragma mark - 客户端

@interface A2CurseForgeAPI : NSObject

+ (instancetype)shared;

/// API Key。不设置则所有请求都会失败。
/// 存 Keychain 而不是 UserDefaults —— 它是凭据。
@property (nonatomic, copy, nullable) NSString *apiKey;
+ (BOOL)hasAPIKey;
+ (void)setAPIKey:(nullable NSString *)key;

/// 测试 Key 是否有效
- (void)validateKeyWithCompletion:(void (^)(BOOL valid, NSError * _Nullable error))completion;

/// 搜索项目
- (void)searchClassID:(A2CFClassID)classID
                query:(nullable NSString *)query
          gameVersion:(nullable NSString *)gameVersion
            sortField:(nullable NSString *)sortField
               offset:(NSInteger)offset
                limit:(NSInteger)limit
           completion:(void (^)(NSArray<A2CFProject *> * _Nullable results,
                                NSError * _Nullable error))completion;

/// 按文件的 murmur2 哈希反查版本。
/// CurseForge 用 MurmurHash2 而不是 SHA1 —— 这是它自己的指纹体系。
- (void)versionByMurmurHash:(NSString *)sha1
                       size:(long long)size
                 completion:(void (^)(A2CFFile * _Nullable file,
                                      NSError * _Nullable error))completion;

/// 取项目的文件列表
- (void)filesForProject:(NSInteger)projectID
            gameVersion:(nullable NSString *)gameVersion
             completion:(void (^)(NSArray<A2CFFile *> * _Nullable files,
                                  NSError * _Nullable error))completion;

/// 取项目详情
- (void)projectWithID:(NSInteger)projectID
           completion:(void (^)(A2CFProject * _Nullable project,
                                NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

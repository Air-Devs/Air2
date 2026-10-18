//
//  ShaderVersion.h
//  Amethyst
//
//  Shader version model for shader downloads
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ShaderVersion : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *versionNumber;
@property (nonatomic, copy, readonly) NSString *datePublished; // ISO 8601 string
@property (nonatomic, copy, readonly) NSArray<NSString *> *gameVersions;
@property (nonatomic, copy, readonly) NSArray<NSString *> *loaders;
@property (nonatomic, copy, readonly, nullable) NSDictionary *primaryFile; // The first file in the files array
// 发布类型（Modrinth: release/beta/alpha；CurseForge: 1=release/2=beta/3=alpha）
@property (nonatomic, copy, readonly) NSString *versionType;

// 资源来源 API（1=Modrinth, 2=CurseForge）
@property (nonatomic, assign) NSInteger apiSource;
// 文件大小（字节）
@property (nonatomic, strong, nullable) NSNumber *fileSize;
// CurseForge file ID
@property (nonatomic, copy, nullable) NSString *fileId;
// CurseForge project ID
@property (nonatomic, copy, nullable) NSString *projectId;

- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;

@end

NS_ASSUME_NONNULL_END

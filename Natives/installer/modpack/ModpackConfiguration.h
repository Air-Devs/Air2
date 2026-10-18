//
//  ModpackConfiguration.h
//  Amethyst
//
//  Created by iFlow on 2024/11/29.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModpackFileInformation : NSObject
@property (nonatomic, strong) NSString *path;
@property (nonatomic, strong) NSString *fileHash;
@property (nonatomic, strong) NSString *downloadURL;
@property (nonatomic, assign) NSUInteger fileSize;

- (instancetype)initWithPath:(NSString *)path fileHash:(NSString *)fileHash downloadURL:(NSString *)downloadURL fileSize:(NSUInteger)fileSize;
- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (BOOL)validate;
@end

@interface ModpackConfiguration : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *version;
@property (nonatomic, strong) NSString *gameVersion;
@property (nonatomic, strong, nullable) NSString *author;
@property (nonatomic, strong, nullable) NSString *packDescription;
@property (nonatomic, strong) NSArray<ModpackFileInformation *> *files;
@property (nonatomic, strong) NSDictionary *dependencies;

- (instancetype)initWithName:(NSString *)name version:(NSString *)version gameVersion:(NSString *)gameVersion;
- (void)saveToFile:(NSString *)filePath error:(NSError **)error;
- (nullable instancetype)initWithContentsOfFile:(NSString *)filePath error:(NSError **)error;
- (BOOL)validate;
@end

NS_ASSUME_NONNULL_END
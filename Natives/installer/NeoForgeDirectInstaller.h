//
//  NeoForgeDirectInstaller.h
//  Amethyst
//
//  Direct NeoForge installer, independent from Forge direct installer.
//

#import <Foundation/Foundation.h>

extern NSString *const NeoForgeDirectInstallerErrorDomain;

typedef NS_ENUM(NSInteger, NeoForgeDirectInstallerErrorCode) {
    NeoForgeDirectInstallerErrorInvalidArchive   = 1,
    NeoForgeDirectInstallerErrorMissingProfile   = 2,
    NeoForgeDirectInstallerErrorInvalidProfile   = 3,
    NeoForgeDirectInstallerErrorExtractionFailed = 4,
    NeoForgeDirectInstallerErrorWriteFailed      = 5,
    NeoForgeDirectInstallerErrorException        = 6
};

@interface NeoForgeDirectInstaller : NSObject

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                               error:(NSError **)error;

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error;

// 整合包导入专用：支持自定义 gameDir
+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                       customGameDir:(nullable NSString *)customGameDir
                 skipRegisterVersion:(BOOL)skipRegisterVersion
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error;

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath;

@end

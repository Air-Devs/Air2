#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NeoForgeVersionFetcher : NSObject

+ (void)fetchVersionsForGameVersion:(NSString *)gameVersion
                         completion:(void (^)(NSArray *versions, NSError * _Nullable error))completion;

+ (NSString *)installerURLForVersion:(NSString *)version;

@end

NS_ASSUME_NONNULL_END

//
//  A2CurseForgePackParser.h
//  Air2
//
//  CurseForge 整合包解析：读 manifest.json。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ModpackInfo;

@interface A2CurseForgePackParser : NSObject

+ (nullable A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

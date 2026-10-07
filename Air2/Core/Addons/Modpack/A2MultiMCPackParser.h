//
//  A2MultiMCPackParser.h
//  Air2
//
//  MultiMC 整合包解析：读 mmc-pack.json。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ModpackInfo;

@interface A2MultiMCPackParser : NSObject

+ (nullable A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

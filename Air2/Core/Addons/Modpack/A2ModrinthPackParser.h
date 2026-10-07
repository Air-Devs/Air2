//
//  A2ModrinthPackParser.h
//  Air2
//
//  Modrinth 整合包解析：读 modrinth.index.json。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ModpackInfo;

@interface A2ModrinthPackParser : NSObject

+ (nullable A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

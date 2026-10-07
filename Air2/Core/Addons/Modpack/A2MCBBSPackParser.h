//
//  A2MCBBSPackParser.h
//  Air2
//
//  MCBBS 整合包解析：读 mcbbs.packmeta，旧包退回 manifest.json。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ModpackInfo;

@interface A2MCBBSPackParser : NSObject

+ (nullable A2ModpackInfo *)parseAtRoot:(NSString *)root error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

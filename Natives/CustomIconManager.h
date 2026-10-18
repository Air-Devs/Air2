#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface CustomIconManager : NSObject

+ (instancetype)sharedManager;
- (void)saveCustomIcon:(UIImage *)image withCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)setCustomIconWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (BOOL)hasCustomIcon;
- (void)removeCustomIcon;

@end
#import <UIKit/UIKit.h>

@class HomeTileConfig;

@interface HomeCustomizeViewController : UIViewController

@property (nonatomic, copy) NSArray<HomeTileConfig *> *tileConfigs;
@property (nonatomic, copy) void (^onConfigsChanged)(NSArray<HomeTileConfig *> *newConfigs);

@end

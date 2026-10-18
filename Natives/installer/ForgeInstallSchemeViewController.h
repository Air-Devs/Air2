#import <UIKit/UIKit.h>

@class ForgeInstallSchemeViewController;

@protocol ForgeInstallSchemeViewControllerDelegate <NSObject>
- (void)schemeViewController:(ForgeInstallSchemeViewController *)controller didSelectScheme:(NSInteger)scheme;
@end

@interface ForgeInstallSchemeViewController : UIViewController

@property (nonatomic, weak) id<ForgeInstallSchemeViewControllerDelegate> delegate;

@end

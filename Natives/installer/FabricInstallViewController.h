#import <UIKit/UIKit.h>
#import "PLPrefTableViewController.h"

@interface FabricInstallViewController : PLPrefTableViewController

@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, assign) BOOL shouldInstallAPI;
@property (nonatomic, copy) void (^completionHandler)(BOOL success, NSString *profileName, NSError *error);

@end

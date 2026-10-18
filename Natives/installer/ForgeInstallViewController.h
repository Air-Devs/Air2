#import <UIKit/UIKit.h>
#import "installer/ForgeInstallSchemeViewController.h"

extern NSString * const ForgeInstallerFlowErrorDomain;
typedef NS_ENUM(NSInteger, ForgeInstallerFlowErrorCode) {
    ForgeInstallerFlowErrorCodeCancelled = 1,
    ForgeInstallerFlowErrorCodeFailedToOpenInstaller = 2,
};

@interface ForgeInstallViewController : UITableViewController <ForgeInstallSchemeViewControllerDelegate>

@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, assign) BOOL isNeoForge;
@property (nonatomic, assign) NSInteger selectedScheme;
@property (nonatomic, copy) void (^completionHandler)(BOOL success, NSString *profileName, id resultOrError);
// 预设版本：由 LoaderSelectionViewController 选中后传入，避免用户在 ForgeInstallVC 里重复选版本
// 非空时 viewDidLoad 跳过 metadata 拉取，直接进入方案选择
@property (nonatomic, copy) NSString *presetVersionString;

@end

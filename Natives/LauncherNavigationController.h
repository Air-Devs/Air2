#import <UIKit/UIKit.h>

NSMutableArray<NSDictionary *> *localVersionList, *remoteVersionList;

@interface LauncherNavigationController : UINavigationController

@property(nonatomic) UIButton* buttonInstall;

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter;

- (void)fetchLocalVersionList;
- (void)fetchRemoteVersionListForce:(BOOL)force;
- (void)reloadProfileList;
- (void)setInteractionEnabled:(BOOL)enable forDownloading:(BOOL)downloading;

@end

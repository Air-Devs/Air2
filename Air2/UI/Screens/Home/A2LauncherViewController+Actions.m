//
//  A2LauncherViewController+Actions.m
//  Air2
//
//  主界面的动作与导航。独立成文件是因为入口会持续增加。
//

#import "A2LauncherViewController_Internal.h"
#import "A2NavigationController.h"
#import "A2Toast.h"
#import "A2Metrics.h"

#import "A2AccountViewController.h"
#import "A2SettingsViewController.h"
#import "A2VersionListViewController.h"
#import "A2DownloadViewController.h"

@implementation A2LauncherViewController (Actions)


- (void)launchGame {
    _launchButton.loading = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.launchButton.loading = NO;
        [A2Toast show:@"启动流程尚未接入" inView:self.view];
    });
}

- (void)pushScreen:(UIViewController *)vc style:(A2TransitionStyle)style {
    if ([self.navigationController isKindOfClass:A2NavigationController.class]) {
        [(A2NavigationController *)self.navigationController pushViewController:vc transition:style animated:YES];
    } else {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    }
}

- (void)openAccount {
    [self pushScreen:[[A2AccountViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openSettings {
    [self pushScreen:[[A2SettingsViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openVersions {
    [self pushScreen:[[A2VersionListViewController alloc] init] style:A2TransitionStyleScaleFade];
}

- (void)openDownload {
    [self pushScreen:[[A2DownloadViewController alloc] init] style:A2TransitionStyleSheet];
}

- (void)openMultiplayer { [A2Toast show:@"联机功能尚未接入" inView:self.view]; }
- (void)openFiles       { [A2Toast show:@"文件管理尚未接入" inView:self.view]; }
- (void)openVersionSettings { [A2Toast show:@"版本设置" inView:self.view]; }

@end

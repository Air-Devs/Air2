#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "LauncherPreferences.h"

// SurfaceViewController
extern dispatch_group_t fatalExitGroup;

@interface AppDelegate ()
@property (nonatomic, copy) void (^backgroundURLSessionCompletionHandler)(void);
@end

@implementation AppDelegate

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // ★ [I18N-ORDER] 全 App 最早入口:在任何 UI 构建之前解析并缓存"生效语言"（幂等）。
    AmeLauncherPrimeLanguage();
    // 一次性迁移旧版全局下载源偏好到分类镜像策略键（幂等，早于任何 UI 读取偏好）
    migrateDownloadSourcePreferences();
    // Called when a new scene session is being created.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
}

- (void)applicationWillTerminate:(UIApplication *)application {
    if (fatalExitGroup != nil) {
        dispatch_group_leave(fatalExitGroup);
        fatalExitGroup = nil;
    }
}

#pragma mark - Background URL Session

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    if (![identifier isEqualToString:kMinecraftResourceDownloadBackgroundSessionIdentifier]) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }

    self.backgroundURLSessionCompletionHandler = completionHandler;

    AFURLSessionManager *manager = [MinecraftResourceDownloadTask sharedBackgroundSessionManager];
    __weak typeof(self) weakSelf = self;
    [manager setDidFinishEventsForBackgroundURLSessionBlock:^(NSURLSession *session) {
        if (weakSelf.backgroundURLSessionCompletionHandler) {
            weakSelf.backgroundURLSessionCompletionHandler();
            weakSelf.backgroundURLSessionCompletionHandler = nil;
        }
    }];
}

#pragma mark - Orientation Support

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    // ★ [GAME-LANDSCAPE] 启动中/游戏中本层也收窄为仅横屏（与根 VC 层取交集 ⇒ 双保险；
    //   未锁时返回值与改动前逐字一致）。
    if (AmeGameLandscapeLockActive()) return UIInterfaceOrientationMaskLandscape;
    // Force landscape only
    return UIInterfaceOrientationMaskAllButUpsideDown;   // ★ [PORTRAIT] 窗口层放开(游戏页单独锁横屏)
}

@end

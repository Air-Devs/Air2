//
//  A2AppDelegate.m
//  Air2
//

#import "A2AppDelegate.h"
#import "A2SceneDelegate.h"

@implementation A2AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    // 主题在窗口建立前就要就位，避免首帧闪一下默认配色
    [A2ThemeManager.shared applyAppearanceToWindow:nil];
    return YES;
}

#pragma mark - Scene 生命周期

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                                                 sessionRole:connectingSceneSession.role];
    config.delegateClass = [A2SceneDelegate class];
    return config;
}

@end

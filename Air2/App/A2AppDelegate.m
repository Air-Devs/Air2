//
//  A2AppDelegate.m
//  Air2
//

#import "A2AppDelegate.h"
#import "A2SceneDelegate.h"
#import "A2ThemeManager.h"

@implementation A2AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    // 主题要在窗口建立前就位，避免首帧闪一下默认配色
    [A2ThemeManager.shared applyAppearanceToWindow:nil];
    return YES;
}

#pragma mark - 方向锁定

/// 全应用锁定横屏。
///
/// 理由：Minecraft Java 版是横屏游戏。启动器如果支持竖屏，
/// 从启动器切到游戏时需要旋转一次；从游戏返回时又要转回来。
/// 这两次旋转都会产生黑屏和内容重排，体验是断裂的。
/// 锁横屏后整个使用流程方向恒定，也没有旋转带来的布局抖动。
- (UIInterfaceOrientationMask)application:(UIApplication *)application
  supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - Scene 生命周期

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config =
        [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                      sessionRole:connectingSceneSession.role];
    config.delegateClass = [A2SceneDelegate class];
    return config;
}

@end

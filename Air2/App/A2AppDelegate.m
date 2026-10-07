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
    // 提前实例化主题管理器。它第一次访问会读 UserDefaults 与沙盒里的
    // 背景图，放在启动早期做，避免首次渲染时在布局过程中触发磁盘 IO。
    (void)A2ThemeManager.shared;
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

/// 返回 Scene 配置。
///
/// 用代码显式指定代理类，不依赖 Info.plist 的 UIApplicationSceneManifest
/// 清单 —— 清单方式在字段不全时会静默失败（没有窗口 / 白屏 / 闪退），
/// 原因极难定位。代码方式配置是明确的。
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

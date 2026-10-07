//
//  A2SceneDelegate.m
//  Air2
//

#import "A2SceneDelegate.h"
#import "A2RootViewController.h"

@implementation A2SceneDelegate

- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;

    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = [[A2RootViewController alloc] init];
    [A2ThemeManager.shared applyAppearanceToWindow:self.window];
    [self.window makeKeyAndVisible];
}

/// 主题变更时同步窗口外观
- (void)sceneDidBecomeActive:(UIScene *)scene {
    [A2ThemeManager.shared applyAppearanceToWindow:self.window];
}

@end

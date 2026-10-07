//
//  A2SceneDelegate.m
//  Air2
//

#import "A2SceneDelegate.h"
#import "A2RootViewController.h"
#import "A2ThemeManager.h"

@implementation A2SceneDelegate

- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {

    // scene 必须是 UIWindowScene 才能建窗口。
    // 如果不是（理论上不会发生），记录下来而不是静默返回 ——
    // 静默返回的表现是「启动了什么都没有」，极难排查。
    if (![scene isKindOfClass:UIWindowScene.class]) {
        NSLog(@"[Air2] 意外的 scene 类型: %@", NSStringFromClass(scene.class));
        return;
    }

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

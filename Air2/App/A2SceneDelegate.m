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

    // 关键顺序：外观必须在 rootViewController 之前设置。
    //
    // 原因：给 window.rootViewController 赋值会立即触发它的 viewDidLoad，
    // 里面所有取色逻辑都会按「当时的 trait」执行。如果此时还没设
    // overrideUserInterfaceStyle，取到的就是系统外观（可能与应用内
    // 选择相反），而且事后改样式不会让已取色的视图自动重算 ——
    // 表现为「iPad 系统亮色 + 应用选了暗色 → 界面按亮色渲染」。
    [A2ThemeManager.shared applyAppearanceToWindow:self.window];

    self.window.rootViewController = [[A2RootViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 窗口上屏后再刷一次，兜底覆盖 viewDidLoad 阶段可能取错的颜色
    [A2ThemeManager.shared notifyThemeChanged];
}

/// 主题变更时同步窗口外观
- (void)sceneDidBecomeActive:(UIScene *)scene {
    [A2ThemeManager.shared applyAppearanceToWindow:self.window];
}

@end

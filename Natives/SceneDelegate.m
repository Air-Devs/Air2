#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "LauncherRootViewController.h"
#import "LauncherCardLayoutViewController.h"
#import "AmeRootTabController.h"   // ★ [ROOTTAB] 根标签栏控制器
#import "LauncherLanguageViewController.h"   // ★ [I18N] 语言切换广播/语言选单
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "UpdateChecker.h"
// ★ [MP-RESTORE] Terracotta 联机恢复
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "VersionIsolationWizardViewController.h"   // ★ [VI-POLISH] 版本隔离首启向导（只写设置）

extern UIWindow *mainWindow;

@interface SceneDelegate ()
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // ★ [I18N-ORDER] 装根 UI 之前再兜一次:确保"生效语言"已解析(幂等;AppDelegate 已提前调过)。
    AmeLauncherPrimeLanguage();
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    
    // 初始方向：让系统按 AppDelegate/各根 VC 的 mask 重新评估。
    // ★ [API-GUARD] requestGeometryUpdateWithPreferences:（iOS 16+ 实例方法）与
    //   UIWindowSceneGeometryPreferencesIOS（iOS 16+ 类）都不能直接调：
    //   老系统（iOS 14/15）直接调 ⇒ unrecognized selector 闪退。
    //   守门组合：@available 版本判定 + respondsToSelector: 实例方法探测 + NSClassFromString 运行期类查找。
    //   老系统回退：attemptRotationToDeviceOrientation（iOS 5–16 官方"重评估方向"手段）。
    if (@available(iOS 16.0, *)) {
        if ([windowScene respondsToSelector:@selector(requestGeometryUpdateWithPreferences:errorHandler:)]) {
            Class prefsCls = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");   // ★ 运行期类查找
            if (prefsCls != Nil) {
                UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[prefsCls alloc] init];
                geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskAllButUpsideDown;   // ★ [PORTRAIT]
                [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError *error) {
                    NSLog(@"[SceneDelegate] Failed to update geometry: %@", error);
                }];
            } else {
                NSLog(@"★ [GAME-LANDSCAPE] legacy path: UIWindowSceneGeometryPreferencesIOS 缺失 ⇒ 跳过初始 geometry 请求");
            }
        } else {
            NSLog(@"★ [GAME-LANDSCAPE] legacy path: 场景不支持 requestGeometryUpdateWithPreferences: ⇒ 跳过初始 geometry 请求");
        }
    } else if ([UIViewController respondsToSelector:NSSelectorFromString(@"attemptRotationToDeviceOrientation")]) {
        [UIViewController attemptRotationToDeviceOrientation];
        NSLog(@"★ [GAME-LANDSCAPE] legacy path: iOS<16 ⇒ 初始方向走 attemptRotationToDeviceOrientation");
    }
    
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式。
    // 之前硬编码深灰（0.08）在浅色模式下导致"中间一片黑"。
    // systemBackgroundColor 在浅色模式为白、深色模式为黑，自动适配。
    // BackgroundManager.applyBackgroundToWindow 会根据用户是否设置自定义壁纸覆盖此颜色。
    if (@available(iOS 13.0, *)) {
        self.window.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.window.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    }
    mainWindow = self.window;

    // ★ [I18N] 根 UI 由统一入口安装（语言切换时会整体重建，见 handleLauncherLanguageChanged:）。
    // 之前这里内联按布局创建主页容器；抽成方法后，重建走同一逻辑，避免两处漂移。
    [self ameInstallLauncherRootUIWithSettingsLanguagePage:NO];

    // 外观模式（浅色/深色/跟随系统）：读 general.ui_theme 偏好。
    //   light  -> UIUserInterfaceStyleLight
    //   dark   -> UIUserInterfaceStyleDark（默认，保持与原行为一致）
    //   auto   -> UIUserInterfaceStyleUnspecified（跟随系统）
    // iOS 13+ 支持 overrideUserInterfaceStyle。仅设置 window 级别，不触碰账号/偏好。
    if (@available(iOS 13.0, *)) {
        NSString *theme = getPrefObject(@"general.ui_theme");
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }

    [self.window makeKeyAndVisible];

    // 立即应用背景（移除原来的 0.1s 延迟）：
    // 延迟会在启动时露出窗口底色形成"黑条"或"黑闪"。BackgroundManager 在其 init
    // 中已 loadSavedBackground/loadUISettings，单例首次访问即完成初始化，无需延迟。
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    [self showTranslationNoticeIfNeeded];

    // 启动时自动检查启动器更新（参照 ZL2 LauncherUpgradeViewModel.checkOnAppStart）。
    // 仅当确实存在新版本时才弹窗；请求失败、已是最新、处于限频窗口内一律静默。
    // 延后一拍执行，等 rootViewController 完成首轮布局后再 present。
    dispatch_async(dispatch_get_main_queue(), ^{
        [UpdateChecker performStartupCheckFromPresenter:self.window.rootViewController];
    });

    // ★ [VI-FLOW] B：版本隔离向导 —— 每次进启动器都会再弹，直到用户主动选「以后不再提示」
    //   （哨兵 internal.version_isolation_wizard_off 只在用户点该按钮时写；弹出时【不】写哨兵）。
    //   延后一拍 + 可跳过 ⇒ 绝不阻碍启动；用户随时可从实例设置页的「版本隔离向导」入口重新打开。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self amePresentVersionIsolationWizardIfNeeded];
    });

    // ★ [MP-RESTORE] 联机恢复 —— lazy init：启动路径上**不**创建 TerracottaManager /
    //   不触发 terracotta_ios_start / 不起 ZeroTier 节点（避免把当年"启动崩溃"风险带回）。
    //   TerracottaManager 是 dispatch_once 单例，首次进入联机页 [shared] 时才 init；
    //   这里只探测 libterracotta 是否已链接，供日志诊断。
    if ([TerracottaBridge isAvailable]) {
        NSLog(@"[SceneDelegate] libterracotta linked, multiplayer available (lazy init)");
    } else {
        NSLog(@"[SceneDelegate] libterracotta not linked, multiplayer disabled");
    }

    // 监听主题切换通知（设置页"外观模式"切换时实时应用，无需重启）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyUITheme:)
                                                 name:@"UIThemeChanged"
                                               object:nil];

    // ★ [I18N] 语言切换：重建整棵启动器 UI，让所有页面重跑 localize（真正即时生效）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLauncherLanguageChanged:)
                                                 name:AmeLauncherLanguageChangedNotification
                                               object:nil];
}

#pragma mark - ★ [I18N] 启动器根 UI 安装 / 语言切换重建

// ★ [UI-LAYOUT] 布局按设备自动判定（用户切换入口已移除；旧 general.ui_layout=card 已由
//   PLPreferences 在启动最早期【主动迁移】为 vs，见 [UI-LAYOUT-MIGRATE]）：
//   iPhone ⇒ 标准（LauncherRootViewController）；iPad ⇒ 卡片（LauncherCardLayoutViewController）。
//
//   为什么不再读 general.ui_layout：该键曾是设置页「UI 布局」的取值（vs/card）。用户可把
//   iPhone 也设成 card ⇒ iPhone 跑 iPad 的卡片布局 ⇒ 主页错乱（群主报的那个 bug）。旧值
//   即使仍留在 plist 里也不再影响根 VC 选择 ⇒ 存量 iPhone 不会卡在错乱态。
//
//   设备判定必须用【物理机型】(UIDevice.model)，不能用 idiom / traitCollection：
//   UIKit+hook.m 的 init_hookUIKitConstructor 会把 UIDevice/Screen 的 active idiom 强制
//   改写成 Pad 或 Phone（见 debug.debug_ipad_ui），那时 realUIIdiom、trait.userInterfaceIdiom
//   都不可靠。LauncherRootViewController / LauncherCardLayoutViewController 内部也各自用
//   同一套 UIDevice.model 判定（LauncherRootIsPhysicalPhone / LauncherCardLayoutIsPhysicalPhone），
//   口径一致。
// 按设备创建主页容器（willConnect 与语言切换重建共用同一逻辑）。
// ★ [UI-LAYOUT-MIGRATE] 布局统一走 ameResolveUILayout()（唯一解析函数，见 LauncherPreferences.m）。
//   它只按物理机型判定，不读遗留的 general.ui_layout —— 该键的 card 值已在启动最早期
//   被 PLPreferences 迁移（iPhone 上写回 vs），故无论库里存过什么，iPhone 一律标准布局。
- (UIViewController *)ameMakeLauncherHomeViewController {
    NSString *layout = ameResolveUILayout();
    BOOL isPad = [layout isEqualToString:@"card"];
    // ★ [UI-LAYOUT] 内部回退开关（不暴露给设置 UI，便于以后回退/装机对照）：
    //   仅 iPad 生效，值 "vs" ⇒ 临时强制标准布局；iPhone 端一律标准 ⇒ 无论配什么都不会
    //   再出现 card-on-iPhone 错乱。默认空串 = 按设备自动。
    NSString *force = getPrefObject(@"debug.debug_ui_layout_force");
    if (isPad && [force isEqualToString:@"vs"]) {
        NSLog(@"[UI-LAYOUT] iPad debug.debug_ui_layout_force=vs ⇒ standard(Root)");
        return [[LauncherRootViewController alloc] init];
    }
    if (isPad) {
        NSLog(@"[UI-LAYOUT] device=iPad ⇒ card layout (auto)");
        return [[LauncherCardLayoutViewController alloc] init];
    }
    NSLog(@"[UI-LAYOUT] device=iPhone ⇒ standard layout (auto); legacy general.ui_layout migrated -> vs");
    return [[LauncherRootViewController alloc] init];
}

// 安装 / 重建启动器根 UI。pushLanguagePage=YES 时（语言切换后）自动回到「设置 > 语言」
// 页面，并在新语言下给出确认提示。
// ★ 为什么整体重建：全启动器 2093 处 localize() 文案，大量在 viewDidLoad / cellForRow
//   里取好；只 reloadData 无法刷新 viewDidLoad 的静态文案。换成全新实例即可让它们
//   重新取词 —— 等价于"重启一次界面"，但不动进程、不动运行中的游戏
//   （SurfaceViewController 不在这棵树里，且切语言只可能发生在启动器设置页）。
- (void)ameInstallLauncherRootUIWithSettingsLanguagePage:(BOOL)pushLanguagePage {
    UIViewController *home = [self ameMakeLauncherHomeViewController];
    AmeRootTabController *tabs = [AmeRootTabController tabControllerWithHomeViewController:home];
    self.window.rootViewController = tabs;
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    if (!pushLanguagePage) return;

    const NSUInteger settingsIndex = 4;   // 与 AmeRootTabController 的标签顺序保持一致
    if (settingsIndex >= tabs.viewControllers.count) return;
    tabs.selectedIndex = settingsIndex;
    UIViewController *settingsVC = tabs.viewControllers[settingsIndex];
    if (![settingsVC isKindOfClass:[UINavigationController class]]) return;
    UINavigationController *nav = (UINavigationController *)settingsVC;

    LauncherLanguageViewController *lang = [[LauncherLanguageViewController alloc] init];
    [nav pushViewController:lang animated:NO];

    // 语言已切换的确认提示（用新语言显示），明确告诉用户"已经真的换了"。
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"preference.lang.switched.title", @"语言已切换")
                             message:localize(@"preference.lang.switched.message",
                                 @"界面已按所选语言重新加载。")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [lang presentViewController:alert animated:YES completion:nil];
    });
}

- (void)handleLauncherLanguageChanged:(NSNotification *)notification {
    // ★ [I18N] 重建根 UI ⇒ 底栏 / 主页 / 卡片 / 胶囊 / 设置页等全部重新取词。
    [self ameInstallLauncherRootUIWithSettingsLanguagePage:YES];
}

- (void)showTranslationNoticeIfNeeded {
    // 仅当系统语言为英文时提示：部分内容为机翻，可能不够准确，欢迎提交翻译 PR。
    // 用户选择"不再提醒"后通过偏好持久化，下次不再弹出。
    // ★ [I18N] 用"实际生效语言"判断（与界面渲染同一事实源），不再直接读 preferredLanguages。
    if (![AmeLauncherEffectiveLanguageCode() hasPrefix:@"en"]) {
        return;
    }
    if (getPrefBool(@"general.translation_notice_dismissed")) {
        return;
    }

    UIViewController *presenter = self.window.rootViewController;
    if (presenter == nil) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_2000", nil)
                                                                   message:localize(@"i18n_str_2001", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *gotItAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2002", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil];
    [alert addAction:gotItAction];

    UIAlertAction *dontAskAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2003", nil)
                                                            style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction *action) {
        setPrefBool(@"general.translation_notice_dismissed", YES);
    }];
    [alert addAction:dontAskAction];

    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - ★ [VI-FLOW] B. 版本隔离向导（每次进启动器再弹，直到用户选「以后不再提示」）

// ★ [VI-FLOW]（用户修正 1 + 补充）：需求是「弹到用户主动说『以后都不弹』为止」，因此：
//   ① 入口只【读】哨兵（ameVIWizardShouldPresent）：未落 ⇒ YES（该弹，本次进入都会出现）；
//      已落 ⇒ NO（用户已选「以后不再提示」）。
//   ② 弹出【不写】哨兵 —— 哨兵只由向导页里的「以后不再提示」按钮写（写点唯一）。
//      ⇒ 用户「跳过」/ 本次关闭 ≠ 以后不弹，下次进启动器仍会再出现。
//   ③ 手动重开：实例设置页「版本隔离向导」入口直接走 amePresentVersionIsolationWizard，
//      不经过本哨兵 ⇒ 哨兵落了也能随时再看。
// 可跳过：向导页自带「跳过」按钮，什么都不写。
// 不阻碍启动：以下在 dispatch_async(主队列) 里跑，启动路径不等它。
// 呈现兜底：若已有模态（更新提示 / 翻译提示）就挂到最顶层模态上，避免 present 失败。
- (void)amePresentVersionIsolationWizardIfNeeded {
    if (!ameVIWizardShouldPresent()) return;   // ★ [VI-FLOW] 用户已选「以后不再提示」⇒ 不自动弹
    [self amePresentVersionIsolationWizard];
}

// 实际弹出向导（自动入口与手动入口共用；本身不读/写哨兵）。
- (void)amePresentVersionIsolationWizard {
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) {
        NSLog(@"★ [VI-FLOW] 向导：无可用 presenter，本次跳过");
        return;
    }

    VersionIsolationWizardViewController *vc = [[VersionIsolationWizardViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
    NSLog(@"★ [VI-FLOW] 向导已弹出（只写设置、不搬文件；可跳过；可选「以后不再提示」）");
}

- (void)applyUITheme:(NSNotification *)notification {
    // 实时切换外观模式。仅修改 window.overrideUserInterfaceStyle，
    // 不触碰 PLPreferences 重置逻辑、不读写账号数据，确保切换主题不会导致账号退出。
    NSString *theme = notification.object ?: getPrefObject(@"general.ui_theme");
    if (@available(iOS 13.0, *)) {
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIThemeChanged" object:nil];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
}

- (void)sceneWillResignActive:(UIScene *)scene {
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    CallbackBridge_pauseGameIfNeed();
}

#pragma mark - Orientation Support (iOS 16+)

// ★ [API-GUARD] 审计结论（存疑/死代码，但【不会崩】）：
//   UIKit 并未声明 `scene:supportedInterfaceOrientationsForWindowScene:` 这个 selector
//   （iPhoneOS26.2 SDK 全量检索无此符号，UIWindowSceneDelegate 协议里也没有）⇒ 系统不会调用本方法。
//   真正的窗口层方向约束来自 AppDelegate 的
//   `application:supportedInterfaceOrientationsForWindow:` + 各根 VC 的 supportedInterfaceOrientations。
//   这里保留实现只为"万一某版本系统按未文档化协议调用时兜底"；因为只是被【定义】而从不被系统调用，
//   所以它本身不会产生 unrecognized selector。若后续要真正控制窗口场景方向，请用 iOS16+
//   requestGeometryUpdateWithPreferences:（已按 [API-GUARD] 做存在性守门）+ 根 VC mask。
- (UIInterfaceOrientationMask)scene:(UIScene *)scene supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene API_AVAILABLE(ios(16.0)) {
    // ★ [GAME-LANDSCAPE] 启动中/游戏中收窄为仅横屏（与根 VC 层一致；未锁时与改动前逐字一致）
    if (AmeGameLandscapeLockActive()) return UIInterfaceOrientationMaskLandscape;
    return UIInterfaceOrientationMaskAllButUpsideDown;   // ★ [PORTRAIT] 窗口层放开
}

@end

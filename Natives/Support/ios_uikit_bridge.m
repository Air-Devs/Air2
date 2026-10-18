#import "authenticator/BaseAuthenticator.h"
#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherSplitViewController.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"

#include <objc/runtime.h>
#include "ios_uikit_bridge.h"
#include "utils.h"

// ===== ★ [GAME-LANDSCAPE] 游戏方向锁（幂等、成对）=====
// 为什么放在这里：本文件已经拥有「启动器根 ⇄ 游戏曲面根」的唯一互换点
//   (UIKit_launchMinecraftSurfaceVC / UIKit_returnToSplitView)，方向锁与根互换同源最不容易漂移。
//
// 语义：
//   Enter ⇒ gAmeGameLandscapeLocked = YES；各根 VC 的 supportedInterfaceOrientations 收窄为
//           【仅横屏】(见 LauncherRootViewController / LauncherCardLayoutViewController /
//           AmeRootTabController / SurfaceViewController)，并主动 requestGeometryUpdate 转到横屏；
//   Exit  ⇒ 置回 NO；各 VC 回落到它们原本的 mask（竖屏 + 横屏，与改动前逐字一致），并主动转回。
// 幂等：重复 Enter / 重复 Exit 都安全（多处启动入口各调一次，不必判断是否已锁）。
// 线程：状态只在主线程读写（Enter/Exit 归一化到主队列；supportedInterfaceOrientations 由系统在主线程调用）。
static BOOL gAmeGameLandscapeLocked = NO;

BOOL AmeGameLandscapeLockActive(void) {
    return gAmeGameLandscapeLocked;
}

/// 找到承载「启动器/游戏」的那个前台 UIWindowScene。
/// 多窗口（iPad 分屏 / 多场景）下只作用于活跃场景，别的窗口不受影响。
static UIWindowScene *AmeGameLandscapeActiveWindowScene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    return (UIWindowScene *)UIWindow.mainWindow.windowScene;   // 兜底
}

/// 让某个 VC 重新评估它的 supportedInterfaceOrientations（改了 mask 后的标准配套动作）。
/// ★ [API-GUARD] setNeedsUpdateOfSupportedInterfaceOrientations 是 iOS 16+ 才有的【实例方法】；
///   老系统（iOS 14/15）上直接发消息 ⇒ unrecognized selector ⇒ NSInvalidArgumentException 闪退。
///   这里双重守门：@available 版本判定 + respondsToSelector: 运行期确认方法真的存在；
///   任一条不满足就什么都不做（绝不做"编译期符号 + 无存在性判定"的直接调用）。
static void AmeGameLandscapeNeedsOrientationUpdate(UIViewController *vc) {
    if (vc == nil) return;
    SEL sel = @selector(setNeedsUpdateOfSupportedInterfaceOrientations);
    if (@available(iOS 16.0, *)) {
        if ([vc respondsToSelector:sel]) {
            [vc setNeedsUpdateOfSupportedInterfaceOrientations];
        }
    }
    (void)sel;
}

/// 主动把窗口场景转成 mask 允许的方向，并让系统重新查询各窗口根 VC 的 supportedInterfaceOrientations。
/// iOS 16+ 走官方 API（可强转到非设备物理方向）；iOS 15 及以下只能让系统重新评估
/// （VC mask 已收窄，设备若已是横屏则立即归位；旧系统上限见报告「未做/存疑」）。
///
/// ★ [API-GUARD] 本函数【只】调用满足下列之一的符号，老系统下不可能抛 unrecognized selector：
///   · @available(iOS 16.0, *) 包住版本判定；
///   · 实例方法先 respondsToSelector: 探测（requestGeometryUpdateWithPreferences: /
///     setNeedsUpdateOfSupportedInterfaceOrientations）；
///   · 类/类型走 NSClassFromString 运行期查找（UIWindowSceneGeometryPreferencesIOS）；
///   · 老系统分支只用 iOS 2–7 就存在的老 API（attemptRotationToDeviceOrientation /
///     setNeedsStatusBarAppearanceUpdate）。
static void AmeGameLandscapeApplyMask(UIInterfaceOrientationMask mask) {
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = AmeGameLandscapeActiveWindowScene();
        if (!scene) {
            NSLog(@"★ [GAME-LANDSCAPE] no foreground windowScene available, skip rotate (mask=%lu)", (unsigned long)mask);
        } else if ([scene respondsToSelector:@selector(requestGeometryUpdateWithPreferences:errorHandler:)]) {
            // ★ 类走运行期查找（不用编译期类符号）：老/裁剪系统拿不到 ⇒ 跳过，绝不发未定义消息。
            Class prefsCls = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");
            if (prefsCls != Nil) {
                UIWindowSceneGeometryPreferencesIOS *prefs = [[prefsCls alloc] init];
                prefs.interfaceOrientations = mask;
                [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                    // 失败不致命：各根 VC 的 mask 已同步收窄/放开，下一次系统评估会自行归位。
                    NSLog(@"★ [GAME-LANDSCAPE] geometry request (mask=%lu) error: %@", (unsigned long)mask, error);
                }];
            } else {
                NSLog(@"★ [GAME-LANDSCAPE] legacy path: UIWindowSceneGeometryPreferencesIOS 缺失 ⇒ 跳过强转(mask=%lu)", (unsigned long)mask);
            }
        } else {
            NSLog(@"★ [GAME-LANDSCAPE] legacy path: 场景不支持 requestGeometryUpdateWithPreferences: ⇒ 仅靠 mask 收窄 + 重评估(mask=%lu)", (unsigned long)mask);
        }
        // 通知 UIKit 重新查询各窗口根 VC 链的 supportedInterfaceOrientations（改了 mask 的标准配套动作）。
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                AmeGameLandscapeNeedsOrientationUpdate(w.rootViewController);
                AmeGameLandscapeNeedsOrientationUpdate(w.rootViewController.presentedViewController);
            }
        }
    } else {
        // ===== ★ [GAME-LANDSCAPE] 老系统回退：iOS <16 没有官方强转 API =====
        // ① attemptRotationToDeviceOrientation：iOS 5–16 官方"让系统按当前 mask 重新评估方向"的手段；
        //    各根 VC / AppDelegate 的 mask 已同步收窄为仅横屏 ⇒ 重评估即把界面转成横屏。
        if ([UIViewController respondsToSelector:NSSelectorFromString(@"attemptRotationToDeviceOrientation")]) {
            [UIViewController attemptRotationToDeviceOrientation];
        }
        // ② 再补一轮根 VC 刷新（setNeedsStatusBarAppearanceUpdate 是 iOS 7 老 API，恒可用）：
        //    触发方向/状态栏布局重算；不引入任何新符号 ⇒ 不可能崩。
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                UIViewController *rootVC = w.rootViewController;
                if (rootVC == nil) continue;
                [rootVC setNeedsStatusBarAppearanceUpdate];
                AmeGameLandscapeNeedsOrientationUpdate(rootVC.presentedViewController);
            }
        }
        NSLog(@"★ [GAME-LANDSCAPE] legacy path: iOS<16 ⇒ attemptRotationToDeviceOrientation(mask=%lu)", (unsigned long)mask);
    }
}

void AmeGameLandscapeLockEnter(void) {
    void (^apply)(void) = ^{
        BOOL was = gAmeGameLandscapeLocked;
        gAmeGameLandscapeLocked = YES;                    // 先落状态再发请求：mask 查询与请求同拍生效
        AmeGameLandscapeApplyMask(UIInterfaceOrientationMaskLandscape);
        NSLog(@"★ [GAME-LANDSCAPE] ENTER (wasLocked=%d) ⇒ 支持方向=仅横屏(已请求转到横屏)", was);
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void AmeGameLandscapeLockExit(void) {
    void (^apply)(void) = ^{
        BOOL was = gAmeGameLandscapeLocked;
        gAmeGameLandscapeLocked = NO;
        AmeGameLandscapeApplyMask(UIInterfaceOrientationMaskAllButUpsideDown);   // 与 SceneDelegate 初始放开值逐字一致
        NSLog(@"★ [GAME-LANDSCAPE] EXIT (wasLocked=%d) ⇒ 恢复启动器方向(竖屏+横屏)", was);
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

// ★ [GAME-LANDSCAPE] showDialog 用的 level-1000 独立窗口宿主 VC：
//   游戏中/启动中时同样只允许横屏，避免这个独立窗口把窗口场景方向重新放开
//   （窗口场景方向取各窗口根 VC 的交集；这里显式收窄 = 给交集再加一道保险）。
@interface AmeGameLandscapeAlertHostViewController : UIViewController
@end
@implementation AmeGameLandscapeAlertHostViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (AmeGameLandscapeLockActive()) return UIInterfaceOrientationMaskLandscape;
    return [super supportedInterfaceOrientations];
}
@end
// ===== ★ [GAME-LANDSCAPE] 游戏方向锁结束 =====

void internal_showDialog(NSString* title, NSString* message) {
    NSLog(@"[UI] Dialog shown: %@: %@", title, message);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    //text.dataDetectorTypes = UIDataDetectorTypeLink;
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];

    UIWindow *alertWindow = [[UIWindow alloc] initWithWindowScene:UIWindow.mainWindow.windowScene];
    alertWindow.frame = UIScreen.mainScreen.bounds;
    // ★ [GAME-LANDSCAPE] 用会跟着游戏方向锁收窄的宿主 VC（游戏中弹窗也保持横屏）
    alertWindow.rootViewController = [AmeGameLandscapeAlertHostViewController new];
    alertWindow.windowLevel = 1000;
    [alertWindow makeKeyAndVisible];
    objc_setAssociatedObject(alert, @selector(alertWindow), alertWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

void showDialog(NSString* title, NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        internal_showDialog(title, message);
    });
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_showError(JNIEnv* env, jclass clazz, jstring title, jstring message, jboolean exitIfOk) {
    const char *title_c = (*env)->GetStringUTFChars(env, title, 0);
    const char *message_c = (*env)->GetStringUTFChars(env, message, 0);
    NSString *title_o = @(title_c);
    NSString *message_o = @(message_c);
    (*env)->ReleaseStringUTFChars(env, title, title_c);
    (*env)->ReleaseStringUTFChars(env, message, message_c);

    if (SurfaceViewController.isRunning) {
        NSLog(@"%@\n%@", title_o, message_o);
        [PLLogOutputView handleExitCode:1];
        return;
    }

dispatch_async(dispatch_get_main_queue(), ^{

    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:title_o message:message_o
        preferredStyle:UIAlertControllerStyleAlert];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentLeft;

    NSMutableAttributedString *atrStr = [[NSMutableAttributedString alloc] initWithString:message_o attributes:@{NSParagraphStyleAttributeName:style,NSFontAttributeName:[UIFont systemFontOfSize:13.0]}];

    [alert setValue:atrStr forKey:@"attributedMessage"];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
            if (exitIfOk == JNI_TRUE) {
                exit(-1);
            }
        }];
    [alert addAction:okAction];
    
    UIAlertAction* copyAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
            UIPasteboard.generalPasteboard.string = message_o;
            if (exitIfOk == JNI_TRUE) {
                exit(-1);
            }
        }];
    [alert addAction:copyAction];
    
    [currentVC() presentViewController:alert animated:YES completion:nil];
});
}

jstring UIKit_accessClipboard(JNIEnv* env, jint action, jbyteArray copySrc) {
    if (action == CLIPBOARD_PASTE) {
        // paste request
        if (UIPasteboard.generalPasteboard.hasStrings) {
            return (*env)->NewStringUTF(env, [UIPasteboard.generalPasteboard.string UTF8String]);
        } else {
            return (*env)->NewStringUTF(env, "");
        }
    } else if (action == CLIPBOARD_COPY) {
        // copy request
        const char* copySrcC = (*env)->GetByteArrayElements(env, copySrc, 0);
        if (copySrcC) {
            UIPasteboard.generalPasteboard.string = @(copySrcC);
            (*env)->ReleaseByteArrayElements(env, copySrc, copySrcC, 0);
        }
        return NULL;
    } else {
        // unknown request
        NSLog(@"Warning: unknown clipboard action: %x", action);
        return NULL;
    }
}

void UIKit_launchMinecraftSurfaceVC(UIWindow* window, NSDictionary* metadata) {
    // Leave this pref, might be useful later for launching with Quick Actions/Shortcuts/URL Scheme
    //setPreference(@"internal_launch_on_boot", getPreference(@"restart_before_launch"));
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    // selected_account 存储 accountId（唯一标识），确保重启后能按 accountId 恢复登录状态
    setPrefObject(@"internal.selected_account", currentAuth.authData[@"accountId"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        tmpRootVC = window.rootViewController;
        [UIView animateWithDuration:0.2 animations:^{
            window.alpha = 0;
        } completion:^(BOOL b){
            [window resignKeyWindow];
            window.alpha = 1;
            window.rootViewController = [[SurfaceViewController alloc] initWithMetadata:metadata];
            [window makeKeyAndVisible];
            // ★ [GAME-LANDSCAPE] 游戏曲面已接管根 ⇒ 再确认一次锁（幂等）：与 returnToSplitView 的 Exit 成对。
            AmeGameLandscapeLockEnter();
        }];
    });
}

void UIKit_returnToSplitView() {
    // Researching memory-safe ways to return from SurfaceViewController to the split view
    // so that the app doesn't close when quitting the game (similar behaviour to Android)
    dispatch_async(dispatch_get_main_queue(), ^{
        // ★ [GAME-LANDSCAPE] 回启动器 ⇒ 恢复启动器原方向（幂等；与各启动入口的 Enter 成对）。
        //   为什么先调一次：本函数是「游戏曲面 → 启动器」的唯一收口（JavaLauncher 的 5 处
        //   退出/崩溃/存档关闭路径全部经此）；先把状态落成"未锁"，后续换上的启动器根才被允许竖屏。
        //   注意此刻根还是 SurfaceViewController（它恒 landscape-only）⇒ 这一拍的 geometry 请求会被
        //   系统拒绝并只打一行日志，属于预期；真正的"转回"由下面换根后的第二次 Exit 完成。
        AmeGameLandscapeLockExit();
        UIWindow *window = UIWindow.mainWindow;

        // Return from JavaGUIViewController
        if ([window.rootViewController isKindOfClass:LauncherSplitViewController.class]) {
            [currentVC() dismissViewControllerAnimated:YES completion:nil];
            // ★ [GAME-LANDSCAPE] 这条路径不换根 ⇒ 这里补一次（幂等）确保解锁 + 主动转回。
            AmeGameLandscapeLockExit();
            return;
        }

        // Return from SurfaceViewController
        [UIView animateWithDuration:0.2 animations:^{
            window.alpha = 0;
        } completion:^(BOOL b){
            [window resignKeyWindow];
            window.alpha = 1;
            if (tmpRootVC) {
                window.rootViewController = tmpRootVC;
                tmpRootVC = nil;
            } else {
                window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
            }
            [window makeKeyAndVisible];
            // ★ [GAME-LANDSCAPE] 根已换回启动器 ⇒ 这一刻再调一次 Exit（幂等）：
            //   此刻根 VC 已允许竖屏，geometry 请求才真正生效 ⇒ 设备竖持就立刻转回竖屏。
            AmeGameLandscapeLockExit();
        }];
    });
}

void launchInitialViewController(UIWindow *window) {
    window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
#if 0
    if (getPrefBool(@"internal.internal_launch_on_boot")) {
        window.rootViewController = [[SurfaceViewController alloc] init];
    } else {
        window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    }
#endif
}

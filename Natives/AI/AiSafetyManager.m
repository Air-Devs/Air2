//
//  AiSafetyManager.m
//  Amethyst
//
//  约定：
//  - 传统中括号语法 + Objective-C ARC。
//  - UI 一律主线程 dispatch_async(dispatch_get_main_queue(), ...)。
//  - 若无法获得可 present 的 VC，默认按「不允许」处理（安全优先）。
//

#import "AiSafetyManager.h"
#import <UIKit/UIKit.h>

// 说明：AiSafetyMode 在 AiSettings.h 与 AiTool.h 中均有定义（契约约定两处一致），
// 为免同一编译单元重复 typedef，此处不 import AiSettings.h，
// 而是直接读取其底层 NSUserDefaults 键（ai.safety_mode），结果与 AiSettings.safetyMode 完全一致。
static NSString * const kAiSafetyModeKey = @"ai.safety_mode";

@implementation AiSafetyManager

+ (instancetype)sharedManager {
    static AiSafetyManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiSafetyManager alloc] init];
    });
    return instance;
}

- (AiSafetyMode)currentMode {
    // 与 AiSettings.safetyMode 同一存储、同一夹取逻辑
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kAiSafetyModeKey];
    return (value < AiSafetyModeSafe || value > AiSafetyModeYOLO) ? AiSafetyModeSafe : (AiSafetyMode)value;
}

#pragma mark - 权限确认判定

- (BOOL)needsUserConfirmationForPermission:(AiToolPermission)permission {
    switch (permission) {
        case AiToolPermissionReadOnly:
            return NO; // 只读，始终放行
        case AiToolPermissionDangerousWrite:
            return YES; // 危险写入，所有模式都要求确认
        case AiToolPermissionControlledWrite:
        case AiToolPermissionExternalNetwork: {
            // 仅 YOLO（完全）模式免确认
            return [self currentMode] == AiSafetyModeYOLO ? NO : YES;
        }
    }
    return YES; // 未知权限保守处理
}

#pragma mark - 视图控制器定位

/// 获取当前可用来 present 的最顶层视图控制器（处理已 presenting 的场景）
- (UIViewController * _Nullable)topmostPresentableViewController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }

    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

#pragma mark - 确认框

- (void)requestConfirmationWithTitle:(NSString *)title
                             message:(NSString *)message
                          completion:(void (^)(BOOL approved))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presentingVC = [self topmostPresentableViewController];
        if (!presentingVC) {
            // 拿不到可 present 的 VC：安全优先，默认不允许
            if (completion) completion(NO);
            return;
        }

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title ?: @"AI 操作确认"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];

        // 「允许」（危险操作显示为「仍要执行」），点击 → 批准
        NSString *actionTitle = (self.currentMode == AiSafetyModeSafe) ? @"仍要执行" : @"允许";
        UIAlertAction *allowAction = [UIAlertAction actionWithTitle:actionTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action) {
            if (completion) completion(YES);
        }];
        [alert addAction:allowAction];

        // 「取消」→ 不批准
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:^(UIAlertAction *action) {
            if (completion) completion(NO);
        }];
        [alert addAction:cancelAction];

        [presentingVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - 安全模式提示

- (void)showSafetyModeChangedHint {
    dispatch_async(dispatch_get_main_queue(), ^{
        AiSafetyMode mode = [self currentMode];
        NSString *title = @"安全模式已更改";
        NSString *message = [[self class] safetyModeChineseName:mode];
        UIViewController *presentingVC = [self topmostPresentableViewController];
        if (!presentingVC) {
            NSLog(@"[AiSafetyManager] 无法展示安全模式提示（无可用 VC）");
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                        message:message
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presentingVC presentViewController:alert animated:YES completion:nil];
    });
}

- (NSString *)permissionChineseName:(AiToolPermission)permission {
    switch (permission) {
        case AiToolPermissionReadOnly:          return @"只读操作";
        case AiToolPermissionControlledWrite:   return @"受控写入";
        case AiToolPermissionDangerousWrite:    return @"危险写入";
        case AiToolPermissionExternalNetwork:   return @"网络访问";
    }
    return @"未知操作";
}

+ (NSString *)safetyModeChineseName:(AiSafetyMode)mode {
    switch (mode) {
        case AiSafetyModeSafe:
            return @"安全（Safe）\n\n仅允许执行只读操作，会修改或删除文件等操作将被拒绝。\n适合日常使用，最大限度地保护你的数据。";
        case AiSafetyModeAsk:
            return @"询问（Ask）\n\n写操作与网络请求在执行前会弹出确认框，由你逐个决定是否放行。\n兼顾安全与便利的推荐模式。";
        case AiSafetyModeYOLO:
            return @"完全（YOLO）\n\n写操作与网络请求不再询问，直接执行。\n适合完全信任 AI 的场景，谨慎使用！";
    }
    return @"未知模式";
}

@end
//
//  A2PairingNotifier.m
//  Air2 —— [PAIRWIRE-NOTIFY] 实现（见头文件说明）
//

#import "A2PairingNotifier.h"
#import "A2Log.h"     // [A2Log criterion:]：判据行的统一出口（控制台 + 会话日志文件）

#import <UserNotifications/UserNotifications.h>

static NSString *const kA2PairingNotificationCodeID = @"a2.pairing.code";
static NSString *const kA2PairingNotificationDoneID = @"a2.pairing.done";

static void A2PairingEnsureAuthorization(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
        [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                        completionHandler:^(BOOL granted, NSError *error) {
            if (!granted) {
                NSLog(@"[A2JIT] 通知权限未授予 ⇒ 配对码不会出现在通知里（不影响配对本身）%@",
                      error.localizedDescription ?: @"");
            }
        }];
    });
}

static void A2PairingPost(NSString *identifier, NSString *title, NSString *body) {
    A2PairingEnsureAuthorization();
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:identifier
                                                                     content:content
                                                                     trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:req
                                                         withCompletionHandler:^(NSError *error) {
        if (error != nil) {
            NSLog(@"[A2JIT] 本地通知发送失败: %@", error.localizedDescription ?: @"");
        }
    }];
}

void A2PairingNotifyPostCode(NSString *code, NSString *hostName) {
    if (code.length != 6) {
        return;   // 只发真的 6 位码，不做半截提示
    }
    NSString *name = hostName.length > 0 ? hostName : @"Air2";
    A2PairingPost(kA2PairingNotificationCodeID,
                  [NSString stringWithFormat:@"与 %@ 配对", name],
                  [NSString stringWithFormat:
                   @"在 设置 › 通用 › VPN 与设备管理（或 隐私与安全性 › 开发者模式）里点「与 %@ 配对」，输入：%@",
                   name, code]);
    [A2Log criterion:@"%@", A2PairingNotifierCriterionLine(@"code")];
}

void A2PairingNotifyPostDone(BOOL success, NSString *_Nullable detail) {
    if (success) {
        A2PairingPost(kA2PairingNotificationDoneID, @"配对完成",
                      @"回到 Air2 即可使用（配对文件已落到 App 容器）。");
        [A2Log criterion:@"%@", A2PairingNotifierCriterionLine(@"done")];
        return;
    }
    A2PairingPost(kA2PairingNotificationDoneID, @"配对失败",
                  detail.length > 0 ? detail : @"回到 Air2 看具体原因。");
    [A2Log criterion:@"%@", A2PairingNotifierCriterionLine(@"failed")];
}

NSString *A2PairingNotifierCriterionLine(NSString *kind) {
    return [NSString stringWithFormat:@"[A2-PAIRPIN] notify=%@", kind ?: @"unknown"];
}

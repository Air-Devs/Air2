//
//  A2PairingNotifier.h
//  Air2 —— [PAIRWIRE-NOTIFY] 把配对码/配对结果发成本地通知
//
//  为什么要它：设备发起配对时，用户必须【离开本 App】去「设置 › 通用 › VPN 与设备管理」
//  （或 隐私与安全性 › 开发者模式）里输那 6 位码；一旦切走，本 App 可能被挂起、界面看不见了。
//  把码同时发一条本地通知，用户在下拉通知里就能看到码（StikPair 用的是同一招）。
//
//  ★调用点★：Air2/UI/Screens/Settings/A2JITSettings.m
//    · 生成/显示 6 位码之后 ⇒ A2PairingNotifyPostCode
//    · 配对收尾（成功/失败）之后 ⇒ A2PairingNotifyPostDone
//
//  首次调用会异步请求通知权限；用户拒了不影响配对本身（只是看不到通知）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把「正在显示的 6 位码」发一条本地通知（同一个 id ⇒ 重复调用只更新，不刷屏）。
void A2PairingNotifyPostCode(NSString *code, NSString *hostName);

/// 配对收尾提醒：成功 ⇒ 提示回 App 导出配对文件；失败 ⇒ 带上失败类名。
void A2PairingNotifyPostDone(BOOL success, NSString *_Nullable detail);

/// 判据行（可 grep）：[A2-PAIRPIN] notify=code|done|failed-auth
NSString *A2PairingNotifierCriterionLine(NSString *kind);

NS_ASSUME_NONNULL_END

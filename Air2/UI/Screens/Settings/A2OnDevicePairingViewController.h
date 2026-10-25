//
//  A2OnDevicePairingViewController.h
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  UI —— [A2-PAIR-ONDEVICE] 「设备内配对」页：在本机发起配对、把 6 位码显示给用户，
//  用户去「设置 › 隐私与安全性 › 开发者模式 › 与 <名字> 配对」输码。
//
//  ★本页面只读状态机★：码与状态全部来自 Player 的 A2JITPairingCodeSession
//    （它自己负责生成码、持久化、打 `[A2-PAIRPIN]` 判据行）；本页不生成码、不改语义。
//  ★不谎报★：配对链路是否真跑起来，取决于后面有没有人起 mDNS 广告 + responder
//    （见 A2JITPairingCodeSession.h:20-28 的「唯一改点」）。本页把这一点写在界面上，
//    不让用户以为「点了就一定能连上设备」。
//

#import "A2BaseViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2OnDevicePairingViewController : A2BaseViewController
@end

NS_ASSUME_NONNULL_END

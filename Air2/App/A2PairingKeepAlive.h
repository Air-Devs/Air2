//
//  A2PairingKeepAlive.h
//  Air2 —— [PAIRWIRE-KEEPALIVE] 配对期间保活（用户必须离开 App 去系统设置输码）
//
//  为什么需要：“设备发起配对”要求用户切到「设置 › 通用 › VPN 与设备管理」里输 6 位码；
//  一旦切走，App 会被系统挂起 —— 挂起后 listener 等不到连入，配对就废了。
//  两条保活手段（照公开实现 StikPair 的【做法】，非代码）：
//    ① 后台继续任务：BGContinuedProcessingTaskRequest（iOS 26+；Info.plist 需登记 identifier）
//    ② 静音音频循环：AVAudioSession(.playback) + AVAudioEngine 循环播一段静音缓冲
//       —— Air2 的 Info.plist 已声明 UIBackgroundModes = audio，游戏本身也要用它
//
//  ★调用点★：
//    · A2AppDelegate.m -application:didFinishLaunching… ⇒ A2PairingKeepAliveRegisterBGTask()
//      （BGTaskScheduler 必须在启动早期注册 handler，之后不能再注册）
//    · A2JITSettings.m 的「开始配对」 ⇒ A2PairingKeepAliveStart(subtitle)
//    · 同一处收尾（成功/失败/取消） ⇒ A2PairingKeepAliveStop()
//    · ★等 JIT（开着启动不进游戏的那个「正在等待 JIT」窗口）★：A2AppDelegate.m 里挂在
//      A2JITEnabler 的两条广播上（Natives 不认识本件，只发广播，避免下层依赖上层）：
//        A2JITEnablerWaitingDidBeginNotification ⇒ A2PairingKeepAliveStart(@"正在等待 JIT…")
//        A2JITEnablerWaitingDidEndNotification   ⇒ A2PairingKeepAliveStop()
//      （拿到 JIT / 超时 / 用户取消 四个出口都走 DidEnd ⇒ 保活不会漏关）
//
//  判据行（默认可见、可 grep）：[A2-PAIRPIN] keepalive=audio-on|audio-off bg=submitted|unavailable|skipped
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动早期调用一次（AppDelegate）。幂等；重复调用只注册一次。
void A2PairingKeepAliveRegisterBGTask(void);

/// 配对开始时调用：起静音音频 + 提交后台继续任务。
/// @param subtitle 后台任务里显示的文字（例如「等待设备连入…」）
void A2PairingKeepAliveStart(NSString *subtitle);

/// 配对收尾时调用：停音频 + 结束后台任务。幂等。
void A2PairingKeepAliveStop(void);

/// 当前是否处于保活中（UI 可用来显示状态）。
BOOL A2PairingKeepAliveIsActive(void);

/// 判据行
NSString *A2PairingKeepAliveCriterionLine(void);

NS_ASSUME_NONNULL_END

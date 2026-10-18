//
//  A2LaunchOverlay.m
//  Air2
//
//  ★启动遮罩★ 冷启动/进世界时盖在启动器之上，显示当前阶段与进度，
//  避免「点了启动什么都不发生」的空白期。
//
//  设计约束（与项目规范一致）：
//   · 纯 ObjC + UIKit（Air2 不做 Swift / 不做液态玻璃）
//   · 不使用 UIVisualEffectView（不做玻璃），深色实底 + MD3 圆角卡片
//   · 唯一数据源 = Natives 层已有的阶段播报（a2_progress_enter/fail），
//     本层不自己猜进度：native 播到哪，遮罩就显示到哪。
//
//  调用点：
//    [A2LaunchOverlay show];   // A2LaunchSession 进入后台启动链之前
//    [A2LaunchOverlay hide];   // 启动失败(finish) 或阶段8(完成) 时
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// native → UI 的阶段播报通知（由 Natives/Support/a2_log.m 发出）。
/// userInfo: stage(NSNumber) / name(NSString) / failed(NSNumber)
FOUNDATION_EXPORT NSNotificationName const A2LaunchStageNotification;

@interface A2LaunchOverlay : NSObject

/// 显示遮罩（幂等）。必须主线程。
+ (void)show;

/// 立即移除（幂等）。
+ (void)hide;

/// 当前是否在显示（诊断用）。
+ (BOOL)isVisible;

@end

NS_ASSUME_NONNULL_END

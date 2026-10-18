#import <UIKit/UIKit.h>

// FCL 风格重构：PLCrashView 现为 UIViewController 子类（不再是 UIView）。
// 类名保留为 PLCrashView 以保持向后兼容（PLLogOutputView 的调用点不变）。
// 内部采用左右分栏布局（左日志 + 右按钮）+ Auto Layout + UIStackView，
// 参照 FCL 的崩溃界面设计。
//   1. OOM 卡片高度被 layoutSubviews 硬编码 140 覆盖
//   2. 窄屏左右分栏挤压（iPhone 上右栏过窄）
//   3. layoutSubviews 反复重算导致按钮错位
@interface PLCrashView : UIViewController

/// 显示崩溃界面并处理退出代码
/// @param exitCode 游戏退出代码
/// @param customTitle 自定义错误标题（可选）
/// @param customReason 自定义错误原因（可选）
+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason;

/// 显示崩溃界面（仅退出代码）
/// @param exitCode 游戏退出代码
+ (void)showWithExitCode:(int)exitCode;

/// 隐藏崩溃界面并返回启动器
- (void)dismissAndReturnToLauncher;

/// 重启启动器（类方法，可从其他 VC 安全调用）
/// 会清理当前崩溃界面并重启应用进程
+ (void)restartLauncher;

/// 隐藏崩溃界面并返回启动器（类方法，可从其他 VC 安全调用）
+ (void)dismissAndReturnToLauncher;

@end

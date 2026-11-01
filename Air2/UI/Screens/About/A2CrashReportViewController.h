//
//  A2CrashReportViewController.h
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  崩溃页。两种进入方式（同一个类，不另造一套视觉）：
//    · 上次启动异常结束时展示（带「导出日志」）
//        调用方：A2AppDelegate didFinishLaunchingWithOptions: / A2CrashGuard 的「非主线程信号崩」轮询
//    · ★游戏异常退出遮罩★（JVM 已经跑起来之后主类 main 以非 0 返回）
//        调用方：A2AppDelegate 的 A2GameExitedNotification 观察者
//        内容：标题「游戏崩溃了」+ 退出码 + 崩溃报告路径 + 可滚动报告 + 两个按钮
//              「重启启动器」「返回启动器」（交互照老 Air 的 PLCrashView：不闪退、给可读的一页）。
//
//  ★为什么复用本类而不新建★：它已经是「整页崩溃报告（可滚动 + 导出日志）」的唯一实现；
//  游戏崩溃遮罩需要的正文/滚动/返回启动器与它完全一致，只多一行退出码与一个重启按钮。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CrashReportViewController : UIViewController

/// 上次启动异常结束（既有路径，行为不变）。
/// @param report  崩溃摘要文本（调用方负责读取/裁剪）
/// @param logPath 要导出的日志文件路径（可为空 ⇒ 回退到 A2Log.previousLogPath）
- (instancetype)initWithReport:(nullable NSString *)report
                       logPath:(nullable NSString *)logPath;

/// ★游戏崩溃遮罩★（只在「VM 已建好 + 主类 main 已派发」之后异常退出时使用）。
/// @param exitCode   主类 main 的返回码（非 0 才会走到这里；-7 = main 抛了未捕获异常）
/// @param reportPath 最新的崩溃报告文件（实例目录 crash-reports/ 下；可空 ⇒ 正文用会话日志）
/// @param report     可滚动正文（调用方负责读取/裁剪；可空）
- (instancetype)initWithGameExitCode:(NSInteger)exitCode
                          reportPath:(nullable NSString *)reportPath
                              report:(nullable NSString *)report;

@end

NS_ASSUME_NONNULL_END

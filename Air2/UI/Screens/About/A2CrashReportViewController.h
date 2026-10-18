//
//  A2CrashReportViewController.h
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  崩溃页（上次启动异常结束时展示；带「导出日志」）。
//  调用方：A2AppDelegate didFinishLaunchingWithOptions:。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CrashReportViewController : UIViewController

/// @param report  崩溃摘要文本（调用方负责读取/裁剪）
/// @param logPath 要导出的日志文件路径（可为空 ⇒ 回退到 A2Log.previousLogPath）
- (instancetype)initWithReport:(nullable NSString *)report
                       logPath:(nullable NSString *)logPath;

@end

NS_ASSUME_NONNULL_END

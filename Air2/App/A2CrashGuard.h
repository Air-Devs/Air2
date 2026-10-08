//
//  A2CrashGuard.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//  崩溃兜底 —— 把异常信息落盘，便于在没有 Xcode 的情况下定位问题。
//
//  为什么需要：这个环境里没有调试器，用户拿到的是直接闪退。
//  装上前先注册异常处理器，崩溃时把原因写到 Documents/air2_crash.log，
//  用户可以通过「文件」App 取出来，或者下次启动时自动显示。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CrashGuard : NSObject

/// 注册异常与信号处理器。应在 main() 最早期调用。
+ (void)install;

/// 读取上一次崩溃日志，没有则返回 nil
+ (nullable NSString *)lastCrashLog;

/// 清除崩溃日志
+ (void)clearCrashLog;

/// 崩溃日志文件路径
+ (NSString *)crashLogPath;

@end

NS_ASSUME_NONNULL_END

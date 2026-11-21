//
//  A2Log.h
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
//  统一日志。与 Minecraft 无关，故放在 Utils（叶子层，不反向依赖业务层）。
//
//  落盘策略：
//    · 每次启动做一次轮转：
//        删除 lastlog.old.txt → 把 lastlog.txt 改名为 lastlog.old.txt
//        → 新建空的 lastlog.txt。
//    · 两个文件都在 Documents 下，Info.plist 已开文件共享，
//      「文件」App 里可以直接打开、导出。lastlog.txt 是本次会话，
//      lastlog.old.txt 是上一次会话 —— 崩溃后要看的就是它。
//    · 只保留两代：更早的会在下次轮转时被覆盖，避免日志无限增长。
//    · 崩溃兜底（A2CrashGuard）也写进同一份日志，不再另开文件。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 当前日志文件的 C 路径。startSession 之前为空串，之后在进程生命周期内始终有效。
///
/// 只给崩溃信号处理器用：信号上下文里不能安全地发 ObjC 消息，
/// 所以这里单独暴露一个纯 C 访问器。业务代码请用 +currentLogPath。
const char *a2_log_current_path(void);

@interface A2Log : NSObject

/// 轮转日志并写会话头。应在 main() 早期调用，且早于任何业务日志。
+ (void)startSession;

/// 写一条日志，自动带时间戳。线程安全。
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// 本次会话的日志路径（Documents/lastlog.txt）。
+ (NSString *)currentLogPath;

/// 上一次会话的日志路径（Documents/lastlog.old.txt）。
+ (NSString *)previousLogPath;

@end

NS_ASSUME_NONNULL_END

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
//  两份落盘文件（都在 Documents 下，Info.plist 已开文件共享，「文件」App 可见）：
//    · lastlog.txt        —— ★会话日志★：本进程经 +log: / +criterion: 写下的逐行日志，
//                            也是「运行日志」页（A2LogViewController）读的那一份。
//    · latestlog.txt      —— ★控制台归档★：stderr 的去处（+archiveStderr 接上），
//                            native 层的 NSLog / a2_log_* 与控制台输出都在这里。
//    · 两者的上代分别留档为 lastlog.old.txt / latestlog.old.txt（崩溃后要看的是它们）。
//
//  落盘策略：
//    · 每次启动做一次轮转：
//        删除 lastlog.old.txt → 把 lastlog.txt 改名为 lastlog.old.txt
//        → 新建空的 lastlog.txt。
//    · 只保留两代：更早的会在下次轮转时被覆盖，避免日志无限增长。
//    · 控制台归档另有运行中的大小上限（见 +archiveStderr），超了就原地轮转。
//    · 崩溃兜底（A2CrashGuard）也写进同一份会话日志，不再另开文件。
//
//  ★判据行统一出口★（[A2-PAIRPIN] / [RXPC] / [FRAME] / [MEM] 这类「一行一个结论」的行）：
//    · Air2 侧（App/UI/Player/Bridge）：`+criterion:` —— 同时送控制台与会话日志；
//    · native 侧（Natives/**）      ：`a2_log_criterion`（Natives/Support/a2_log.h）；
//    · 两侧共用同一个落盘函数 `a2_log_session_sink`（本文件的纯 C 导出），
//      由 main() 这一处装配点把 native 侧接过来（Natives 不认识 A2Log，故用注入）。
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

#pragma mark - 判据行统一出口

/// ★判据行统一出口（Air2 侧）★：一条判据行同时送
///   ① 控制台 —— stderr（Xcode / Console.app 可见；+archiveStderr 之后也落 latestlog.txt）
///   ② 会话日志文件 —— Documents/lastlog.txt（「运行日志」页读的那一份）
///
/// native 侧的同类出口是 `a2_log_criterion`（Natives/Support/a2_log.h）；
/// 两侧共用同一个落盘函数 `a2_log_session_sink` ⇒ ★落点只有一处，不各写各的★。
///
/// 调用点（本包内的判据行都在这里，新增判据行照此写）：
///   [A2-PAIRPIN]：A2PairingKeepAlive / A2PairingNotifier / A2JITSettings /
///                 A2JITPairingCodeSession / A2JITAutoPairingEngineBridge
///   [MEM]       ：A2LaunchRunner（probe）/ A2LaunchSession（ceiling → -Xmx）
+ (void)criterion:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

#pragma mark - 控制台归档

/// 把 stderr 接进 Documents/latestlog.txt（★main() 最早期调一次★，幂等）。
/// · 启动时轮转一次：latestlog.txt → latestlog.old.txt（只留两代）。
/// · 运行中超过上限即★原地轮转★（先抄一份到 .old，再把归档截断续写）⇒ 不会无限涨。
/// · 用 dup2 直接接文件（⚠️不经管道）；无缓冲、逐行 flush。
///   ⇒ 崩溃那一刻已经写出的 stderr 内容都在文件里，不会像管道那样丢一截。
/// 副作用：接上后，native 层（NSLog / a2_log_* / printf）的每一行都会出现在该文件里。
+ (void)archiveStderr;

/// 控制台归档路径（Documents/latestlog.txt）。
+ (NSString *)consoleLogPath;

#pragma mark - 导出

/// 把 ①会话日志 ②控制台归档 折成一个 UTF-8 文本写到 destination（供「运行日志」页分享）。
/// 两个文件都读不到时失败（error 说明原因）；只有一个文件时照样成功。
+ (BOOL)exportCombinedLogToPath:(NSString *)destination error:(NSError **)error;

/// native 侧判据行的落点：把一条判据行写进会话日志文件（Documents/lastlog.txt）。
/// 签名与 native 的 `a2_log_set_sink` 一致；由 main() 注入（见本文件头部说明）。
/// 纯 C 导出（不走 ObjC 消息），供 native 与 C 侧调用。
void a2_log_session_sink(const char *utf8Line);

@end

NS_ASSUME_NONNULL_END

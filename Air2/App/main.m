//
//  main.m
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
//  应用入口。
//
//  语言策略：本项目主用 Objective-C，Swift 仅保留为极少量衔接点。
//  入口保持 ObjC，是为了让启动路径上不引入 Swift 运行时初始化开销
//  （iOS 上 Swift runtime 首次加载约几十毫秒，对启动器来说没必要付这个成本）。
//

#import <UIKit/UIKit.h>
#import "A2AppDelegate.h"
#import "A2CrashGuard.h"
#import "A2Log.h"
// Natives/Support：native 层判据行的统一出口（a2_log_criterion / a2_log_set_sink）。
// ★App → Natives 是允许方向★（见 docs/ARCHITECTURE.md 顶层表：`Air2/` 允许依赖 `Natives`）。
// 装配点放在这里，是因为只有 main() 同时看得到两侧：Natives 侧不认识 A2Log（它只依赖 Libraries），
// 所以「判据行落进会话日志文件」这件事必须由这里把 A2Log 的落点注进去。
#import "a2_log.h"

int main(int argc, char *argv[]) {
    NSString *delegateName = NSStringFromClass([A2AppDelegate class]);
    @autoreleasepool {
        // 崩溃兜底要在最早时机注册 —— 之后任何一行代码崩溃都能留下线索。
        // 这个环境没有调试器，日志是唯一的定位手段。
        [A2CrashGuard install];

        // ★控制台归档★：把 stderr 接进 Documents/latestlog.txt（启动时轮转、运行中超上限就地轮转）。
        // 接上之后，native 层（NSLog / a2_log_* / printf）与控制台的每一行都落文件，
        // 不再只存在于 Xcode / Console.app。放在 startSession 之前 —— 越早接上漏得越少。
        // ★顺序★：先 startSession（轮转 lastlog.txt 并打开句柄），再把 stderr dup2 到
        //   同一个文件 —— 反过来会把 stderr 接到刚被改名成 .old 的那份上。
        [A2Log startSession];

        // 再轮转日志（上一次会话留档为 lastlog.old.txt）。
        // 必须早于任何业务日志，否则上一轮的日志会被本轮内容污染。
        [A2Log archiveStderr];   // stderr → 同一个 lastlog.txt（单文件模式）

        // ★接线★：native 侧的判据行（[RXPC]/[FRAME]/native 的 [A2-PAIRPIN]）
        // 经 a2_log_criterion → a2_log_session_sink 落进会话日志文件 lastlog.txt，
        // 与 Air2 侧的 [A2Log criterion:] 同一个落点 ⇒ 「运行日志」页一处看全。
        a2_log_set_sink(a2_log_session_sink);

        [A2Log log:@"main: 进入 UIApplicationMain"];
    // ★构建戳★：日志第一屏就能看到装的是哪一次构建（打包时 CFBundleVersion = 提交短 sha）
    {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        [A2Log log:@"[A2-BUILD] Air2 %@ (%@)",
                     info[@"CFBundleShortVersionString"] ?: @"?",
                     info[@"CFBundleVersion"] ?: @"?"];
        [A2Log log:@"[A2-BUILD] 日志文件：%@ | 控制台归档：%@",
                     [A2Log currentLogPath], [A2Log consoleLogPath]];
    }

        return UIApplicationMain(argc, argv, nil, delegateName);
    }
}

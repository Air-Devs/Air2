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

int main(int argc, char *argv[]) {
    NSString *delegateName = NSStringFromClass([A2AppDelegate class]);
    @autoreleasepool {
        // 崩溃兜底要在最早时机注册 —— 之后任何一行代码崩溃都能留下线索。
        // 这个环境没有调试器，日志是唯一的定位手段。
        [A2CrashGuard install];

        // 再轮转日志（上一次会话留档为 lastlog.old.txt）。
        // 必须早于任何业务日志，否则上一轮的日志会被本轮内容污染。
        [A2Log startSession];
        [A2Log log:@"main: 进入 UIApplicationMain"];

        return UIApplicationMain(argc, argv, nil, delegateName);
    }
}

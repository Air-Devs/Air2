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
#import "A2Logger.h"
#import "utils.h"
#import "JavaLauncher.h"

//  ★ main 必须对 dlsym 可见 ★
//
//  JavaLauncher.m 取到 JLI_Launch 后直接调用它，而 macOS/iOS 版 libjli 在
//  JLI_Launch 内部要靠 dlsym(RTLD_DEFAULT, "main") 反查"宿主可执行文件是谁"。
//
//  Clang 默认给 main 打上隐藏可见性（不进动态导出表），于是 libjli 报：
//      Error: could not find executable dlsym(RTLD_DEFAULT, main): symbol not found
//      error locating main entrypoint
//  JVM 还没起来就退出。
//
//  两条一起才有效（缺任一条都实测失败）：
//    1. 这里显式 visibility("default")：把 main 变成可导出的外部符号；
//    2. scripts/main_exports.txt + EXPORTED_SYMBOLS_FILE：ld 只把白名单里的
//       _main 放进导出表 —— 而不用 -Wl,-export_dynamic，后者会把全部全局符号
//       （含 glslang 运行期符号）一起变成启动期强引用，导致 dyld 直接闪退。
#if defined(__GNUC__) || defined(__clang__)
__attribute__((visibility("default"), used))
#endif
int main(int argc, char *argv[]) {
    //  ★ 游戏进程分支：与上游 Amethyst 完全同构 ★
    //
    //  libjli 拿到 main 后会【再调用一次 main】来跑 Java 主类（这是它的入口约定）。
    //  此时本进程已经有一个跑着的 UIApplication；若继续往下走到
    //  UIApplicationMain 就会：
    //      *** Assertion failure in UIApplicationInstantiateSingleton()
    //      *** 'There can only be one UIApplication instance.'
    //  直接崩溃。上机日志已实锤。
    //
    //  上游 herbrine8403/Amethyst-iOS-MyRemastered 的 Natives/main.m 正是在
    //  函数最开头做这个判断并直接 return，游戏进程根本不碰 UIApplicationMain。
    //  这里照搬同一语义（引用 JavaLauncher.h 的 extern pJLI_Launch）。
    if (pJLI_Launch != NULL) {
        return pJLI_Launch(argc, (const char **)argv,
                           0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                           0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                           "1.8.0-internal",
                           "1.8",
                           "java", "openjdk",
                           JNI_FALSE,
                           JNI_TRUE, JNI_FALSE, JNI_TRUE);
    }

    NSString *delegateName = NSStringFromClass([A2AppDelegate class]);
    @autoreleasepool {
        // 崩溃兜底要在最早时机注册 —— 之后任何一行代码崩溃都能留下线索。
        // 这个环境没有调试器，日志是唯一的定位手段。
        [A2CrashGuard install];

        // 再轮转日志（上一次会话留档为 lastlog.old.txt）。
        // 必须早于任何业务日志，否则上一轮的日志会被本轮内容污染。
        [A2Log startSession];
        [A2Log log:@"main: 进入 UIApplicationMain"];

        // ★ 分级日志 + 进程级 stdio 接管，都要在 UIApplicationMain 之前 ★
        //
        // 顺序说明：
        //   1. [A2Logger shared] 触发 -initialize（建 docs/logs/log_*.log）。
        //   2. captureStandardIO 把 fd 1/2 指到同一个文件。
        //
        // 之后 JVM 和 Minecraft 的 stdout/stderr（含 HotSpot 的致命错误、hs_err、
        // egl_bridge/gl_bridge 的 fprintf）全部落进这一份文件，不再只有系统日志。
        // 这是「启动黑屏但日志里什么都没有」的直接修复：以前游戏进程的输出
        // 根本没接到任何磁盘文件上。
        // ★ POJAV_HOME / POJAV_GAME_DIR ★
        //
        // 必须在任何 getenv("POJAV_HOME") 之前跑。函数原先只有声明没有定义，
        // 于是这整条路径全是 (null)：JVM 的 -Duser.home、MobileGlues 的
        // MG_DIR_PATH、native-crash.log、CWD 对齐、latestlog 全部失效。
        init_setupMultiDir();

        [A2Logger shared];
        [A2Logger.shared captureStandardIO];
        [A2Logger info:@"Boot" message:@"main: stdio 已接管，进入 UIApplicationMain"];

        return UIApplicationMain(argc, argv, nil, delegateName);
    }
}

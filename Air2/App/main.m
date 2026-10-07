//
//  main.m
//  Air2
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

int main(int argc, char *argv[]) {
    NSString *delegateName = NSStringFromClass([A2AppDelegate class]);
    @autoreleasepool {
        // 崩溃兜底要在最早时机注册 —— 之后任何一行代码崩溃都能留下线索。
        // 这个环境没有调试器，日志是唯一的定位手段。
        [A2CrashGuard install];
        return UIApplicationMain(argc, argv, nil, delegateName);
    }
}

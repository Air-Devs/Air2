#ifndef A2_MOD_COMPATIBILITY_H
#define A2_MOD_COMPATIBILITY_H

#import <Foundation/Foundation.h>

// 移植自 weecritikal/Flux-Launcher-iOS 的 ModCompatibility。
//
// 目的：有些 mod 在 iOS 上根本不可能工作，而且会把游戏一起带崩（例：Controllable
// 加载桌面版 SDL2，链接 Apple ForceFeedback 框架，iOS 没有）。还有些 mod 两两互斥
// （两个渲染器同时改写同一套绘制代码 ⇒ 进世界就 SIGSEGV，看起来像驱动故障）。
//
// 做法：启动前扫 mods 目录，把命中的 jar 移到 `.a2_unsupported/` 下（不删除），
// 并逐条记录原因。用户自己装的文件，永远不销毁。

@interface A2ModCompatibility : NSObject

/// 扫一遍，返回会被剔除的条目（不移动）。元素形如 {name, reason}。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)unsupportedModsInDirectory:(NSString *)directory;

/// 扫一遍并把要剔除的移进 `.a2_unsupported/`，返回实际移动成功的条目。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)setAsideUnsupportedModsInDirectory:(NSString *)directory;

@end

#endif  // A2_MOD_COMPATIBILITY_H

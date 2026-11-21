//
//  A2VersionMetadata.h
//  Air2
//
//  版本元数据（launchTarget）—— pojav 后端的 iOS 适配层。
//
//  ## 这是「pojav 后端适配 Air2」的核心
//
//  Pojav 的 Java 启动器（net.kdt.pojavlaunch.PojavLauncher）需要一份
//  **已经为 iOS 调整过的版本 JSON**，而不是原始文件。Air1 在
//  MinecraftResourceDownloadTask + MinecraftResourceUtils.tweakVersionJson
//  里做这件事，Air2 之前完全没做 —— 直接导致：
//
//    · arguments.jvm_processed 为空 → MC 26.x 需要的 --add-opens /
//      --add-exports 全丢 → 反射访问失败、卡死
//    · JNA 5.17 未降级 → darwin-aarch64 版在 iOS 上 native crash
//    · 官方 natives 库未跳过 → classpath 里混进 Android/Linux 的 .so
//    · client jar 未追加到 libraries → 启动器找不到 MC 本体
//
//  ## 处理清单（逐条对应 Air1 的 tweakVersionJson）
//
//    1. 继承合并        有 inheritsFrom 时把父版本合进来
//    2. library skip    打上 skip 标记（natives / org.lwjgl）
//    3. JNA 降级        5.17 → 5.13.0
//    4. asm-all 降级    → 5.0.4
//    5. client jar      追加到 libraries
//    6. jvm_processed   展开 ${natives_directory} 等占位符
//    7. 参数跳过        -cp / -Djava.library.path / -XstartOnFirstThread
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionMetadata : NSObject

/// 读取并为 iOS 调整版本 JSON。
///
/// 会依次：读 versions/<name>/<name>.json → 若有 inheritsFrom 则合并父版本
/// → tweakVersionJson → 填上 id / javaVersion / gameHome 等启动必需键。
///
/// @param versionName 版本目录名（如 "26.3" 或 "26.3-fabric"）
/// @param gameHome    游戏根目录
/// @return 可直接传给 launchJVM 的字典；失败返回 nil
+ (nullable NSDictionary *)launchTargetForVersion:(NSString *)versionName
                                         gameHome:(NSString *)gameHome;

/// 只做 tweak（用于已解析好的 JSON）
+ (void)tweakVersionJson:(NSMutableDictionary *)json gameHome:(NSString *)gameHome;

@end

NS_ASSUME_NONNULL_END

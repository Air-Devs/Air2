//
//  McLanPortDetector.h
//  Amethyst
//
//  ★ [PORT-AUTO] Minecraft「对局域网开放」端口自动探测器
//
//  背景：MC 的局域网端口是【游戏自己随机开】的（玩家在游戏里点「对局域网开放」时生成），
//  不是启动器选的 —— 所以【绝对不能】自己 bind 一个端口当房主端口（那样和游戏实际端口不一致，
//  房客连不上）。
//
//  探测途径（按可靠性）：
//    1. 解析游戏日志：实例目录 logs/latest.log（MC 日志）与启动器 latestlog.txt（含游戏 stdout）
//       里「对局域网开放」那一行 —— 典型形态：
//         [Render thread/INFO]: Started serving on port 54321
//         [Client thread/INFO]: Local game hosted on port 54321
//       取【最后一次】出现的端口（再开一次局域网会再打一行）。
//    2. 增量轮询：创建房间面板打开期间每 1s 重读一次日志，端口变化时回调。
//    3. 回退：探测不到返回 0 —— 不写死值、不崩溃，用户仍可手填。
//
//  本类只做「读日志 + 定时轮询 + 回调」，不做任何网络绑定。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface McLanPortDetector : NSObject

/// 单例（便捷；需要独立生命周期时也可直接 [[McLanPortDetector alloc] init]）。
+ (instancetype)sharedDetector;

#pragma mark - 路径解析（纯环境变量/沙箱，不读偏好，便于单测）

/// 启动器主目录：POJAV_HOME → Documents。
+ (nullable NSString *)launcherHome;

/// 当前实例根目录：POJAV_GAME_DIR → <POJAV_HOME>/instances/<instanceName|default> → Documents。
/// @param instanceName 当前实例名（调用方从 general.game_directory 读取；nil/空 → "default"）
+ (nullable NSString *)resolveGameDirectoryWithInstanceName:(nullable NSString *)instanceName;

#pragma mark - 解析

/// 解析一段日志文本，返回【最后一次】出现的 MC 局域网端口（1024..65535）；找不到返回 0。
+ (uint16_t)parsePortFromLogText:(nullable NSString *)text;

/// 在给定日志文件路径里找端口：取「有匹配且修改时间最新」的那份（即最近一次开局域网）。
/// 找不到返回 0。所有文件读取都限制在末尾 8MB。
+ (uint16_t)detectPortInLogFiles:(NSArray<NSString *> *)paths;

/// 在实例目录 + 启动器目录下搜集候选日志（logs/latest.log、latestlog.txt、logs/*.log …）并解析。
/// 找不到返回 0。
+ (uint16_t)detectPortInGameDirectory:(nullable NSString *)gameDir
                         launcherHome:(nullable NSString *)home;

#pragma mark - 轮询（创建房间面板打开期间）

/// 开始轮询（1s）：端口变化时在主线程回调（首次探到也会回调）。停旧的再起新的。
/// @param gameDir 实例目录（可 nil）
/// @param home    启动器主目录（可 nil）
/// @param handler 主线程回调（port > 0）
- (void)startPollingGameDirectory:(nullable NSString *)gameDir
                     launcherHome:(nullable NSString *)home
                          handler:(void (^)(uint16_t port))handler;

/// 停止轮询（离开页面 / 会话开始 / 断开时调用）。幂等。
- (void)stopPolling;

/// 当前是否在轮询。
@property (nonatomic, readonly) BOOL polling;

@end

NS_ASSUME_NONNULL_END

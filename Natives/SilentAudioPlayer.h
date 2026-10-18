#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 后台保活音频播放器
///
/// 通过循环播放极低音量的静音 WAV，让 iOS 系统认为 App 正在播放音频，
/// 从而允许 App 在后台长时间运行（用于陶瓦联机期间维持 EasyTier P2P 连接）。
///
/// 使用 AVAudioSession playback 类别，会与其他 App 的音频混合（mixWithOthers），
/// 不影响用户正常听音乐。联机结束时调用 stopKeepingAlive 释放 AudioSession，
/// 让 MC 的 OpenAL 能正常获取音频设备。
///
/// 线程安全：所有方法内部加锁，可从任意线程调用。
@interface SilentAudioPlayer : NSObject

+ (instancetype)shared;

/// 开始后台保活。幂等，重复调用安全。
- (void)startKeepingAlive;

/// 停止后台保活并释放 AudioSession。幂等。
- (void)stopKeepingAlive;

/// 当前是否处于保活状态。
@property(nonatomic, readonly, getter=isKeepingAlive) BOOL keepingAlive;

@end

NS_ASSUME_NONNULL_END

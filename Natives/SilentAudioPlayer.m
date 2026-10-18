#import "SilentAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

/// 后台保活音频播放器实现
///
/// 设计要点（重写版）：
/// 1. 处理 AVAudioSession 中断通知（来电、闹钟等），中断结束后自动恢复播放
/// 2. 处理 AVAudioSession 路由变化（耳机插拔、蓝牙连接），保证播放连续
/// 3. 用 mixWithOthers 选项避免打断用户当前播放的音乐
/// 4. 静音 WAV 在内存中生成，不依赖外部资源文件
/// 5. 单例 + NSLock 保证线程安全
@implementation SilentAudioPlayer {
    AVAudioPlayer *_player;
    BOOL _active;
    NSLock *_lock;
    BOOL _interruptionPaused;  /* 被系统中断后暂停，等待恢复 */
}

#pragma mark - Singleton

+ (instancetype)shared {
    static SilentAudioPlayer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SilentAudioPlayer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _player = [self buildSilentPlayer];
        [self registerNotifications];
    }
    return self;
}

#pragma mark - Public API

- (BOOL)isKeepingAlive {
    [_lock lock];
    BOOL active = _active;
    [_lock unlock];
    return active;
}

- (void)startKeepingAlive {
    [_lock lock];
    if (_active) {
        [_lock unlock];
        return;
    }
    if (_player == nil) {
        NSLog(@"[SilentAudioPlayer] player unavailable, keeping alive skipped");
        [_lock unlock];
        return;
    }

    /* 配置 AudioSession：
     * - playback：允许后台播放
     * - mixWithOthers：与其他 App 音频混合，不打断用户当前音乐
     * - duckOthers：可选，这里不用（duck 会降低其他 App 音量，干扰用户）
     * 用 try/catch 防止 iOS 13 以下设备某些选项不支持 */
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:options
                        error:&error]) {
        NSLog(@"[SilentAudioPlayer] setCategory failed: %@", error);
        /* 降级：不带 options 再试一次（iOS 14 以下某些设备兼容） */
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    }
    if (![session setActive:YES error:&error]) {
        NSLog(@"[SilentAudioPlayer] activate session failed: %@", error);
        /* 即使 activate 失败也尝试 play，有些场景下仍可工作 */
    }

    _player.numberOfLoops = -1;  /* 无限循环 */
    _player.volume = 0.01f;       /* 极低音量（0 会被 iOS 优化掉） */

    if (![_player prepareToPlay]) {
        NSLog(@"[SilentAudioPlayer] prepareToPlay failed");
        [_lock unlock];
        return;
    }
    if (![_player play]) {
        NSLog(@"[SilentAudioPlayer] play failed");
        [_lock unlock];
        return;
    }
    _active = YES;
    _interruptionPaused = NO;
    [_lock unlock];
    NSLog(@"[SilentAudioPlayer] keeping alive started");
}

- (void)stopKeepingAlive {
    [_lock lock];
    if (!_active) {
        [_lock unlock];
        return;
    }
    [_player stop];
    _active = NO;
    _interruptionPaused = NO;
    [_lock unlock];

    /* 释放 AudioSession（在锁外执行，避免阻塞主线程太久）
     * NotifyOthersOnDeactivation 让其他 App（如 MC 自身的 OpenAL）能重新获取音频设备 */
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:NO
                                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                              error:&error]) {
        NSLog(@"[SilentAudioPlayer] deactivate session failed: %@", error);
    }
    NSLog(@"[SilentAudioPlayer] keeping alive stopped");
}

#pragma mark - Silent WAV Generation

/// 生成 200ms 静音 WAV 数据（44100Hz, 16-bit, mono）。
/// 总字节 = 44(WAV头) + 44100*0.2*2 = 44 + 17640 = 17684 字节。
/// 不依赖外部资源文件，避免打包丢失。
- (AVAudioPlayer *)buildSilentPlayer {
    NSUInteger sampleRate = 44100;
    NSUInteger durationMs = 200;
    NSUInteger numSamples = (sampleRate * durationMs) / 1000;  /* 8820 samples */
    NSUInteger dataSize = numSamples * 2;  /* 16-bit = 2 bytes/sample */
    NSUInteger fileSize = 36 + dataSize;   /* RIFF chunk size */

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    /* RIFF header */
    [wav appendBytes:"RIFF" length:4];
    uint32_t riffSize = (uint32_t)fileSize;
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVE" length:4];
    /* fmt chunk */
    [wav appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16;
    [wav appendBytes:&fmtSize length:4];
    uint16_t audioFormat = 1;  /* PCM */
    [wav appendBytes:&audioFormat length:2];
    uint16_t numChannels = 1;
    [wav appendBytes:&numChannels length:2];
    uint32_t sr = (uint32_t)sampleRate;
    [wav appendBytes:&sr length:4];
    uint32_t byteRate = (uint32_t)(sampleRate * 2);
    [wav appendBytes:&byteRate length:4];
    uint16_t blockAlign = 2;
    [wav appendBytes:&blockAlign length:2];
    uint16_t bitsPerSample = 16;
    [wav appendBytes:&bitsPerSample length:2];
    /* data chunk */
    [wav appendBytes:"data" length:4];
    uint32_t dataLen = (uint32_t)dataSize;
    [wav appendBytes:&dataLen length:4];
    /* 静音数据（全零，NSMutableData 已经 zero-fill） */
    [wav increaseLengthBy:dataSize];

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    if (player == nil) {
        NSLog(@"[SilentAudioPlayer] init failed: %@", error);
        return nil;
    }
    return player;
}

#pragma mark - AVAudioSession Notifications

/// 监听音频中断和路由变化通知，确保后台保活在系统事件后仍可恢复。
- (void)registerNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    /* 音频中断（来电、闹钟、Siri 等） */
    [nc addObserver:self
           selector:@selector(handleInterruption:)
               name:AVAudioSessionInterruptionNotification
             object:nil];
    /* 路由变化（耳机插拔、蓝牙连接） */
    [nc addObserver:self
           selector:@selector(handleRouteChange:)
               name:AVAudioSessionRouteChangeNotification
             object:nil];
}

- (void)handleInterruption:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSUInteger type = [info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

    [_lock lock];
    switch (type) {
        case AVAudioSessionInterruptionTypeBegan: {
            /* 系统开始中断（如来电），音频被强制暂停 */
            if (_active) {
                _interruptionPaused = YES;
                NSLog(@"[SilentAudioPlayer] interruption began");
            }
            break;
        }
        case AVAudioSessionInterruptionTypeEnded: {
            /* 中断结束，尝试恢复播放 */
            if (_active && _interruptionPaused) {
                NSUInteger options = [info[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
                NSError *error = nil;
                [[AVAudioSession sharedInstance] setActive:YES error:&error];
                if (error != nil) {
                    NSLog(@"[SilentAudioPlayer] resume activate failed: %@", error);
                }
                if (options & AVAudioSessionInterruptionOptionShouldResume) {
                    [_player prepareToPlay];
                    [_player play];
                    NSLog(@"[SilentAudioPlayer] resumed after interruption");
                } else {
                    NSLog(@"[SilentAudioPlayer] interruption ended but should not resume");
                }
                _interruptionPaused = NO;
            }
            break;
        }
    }
    [_lock unlock];
}

- (void)handleRouteChange:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSUInteger reason = [info[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];

    [_lock lock];
    /* 老设备断开（如拔耳机）时，系统会自动暂停播放；这里在新设备连接后恢复 */
    if (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable
        || reason == AVAudioSessionRouteChangeReasonOverride) {
        if (_active && !_player.playing) {
            [_player prepareToPlay];
            [_player play];
            NSLog(@"[SilentAudioPlayer] resumed after route change (reason=%lu)", (unsigned long)reason);
        }
    }
    [_lock unlock];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

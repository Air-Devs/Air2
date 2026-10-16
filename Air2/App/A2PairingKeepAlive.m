//
//  A2PairingKeepAlive.m
//  Air2 —— [PAIRWIRE-KEEPALIVE] 实现（见头文件说明）
//

#import "A2PairingKeepAlive.h"

#import <AVFAudio/AVFAudio.h>
#import <BackgroundTasks/BackgroundTasks.h>

/// 与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 必须逐字一致。
static NSString *const kA2PairingBGTaskIdentifier = @"dev.airdevs.air2.pairing";

static AVAudioEngine *gEngine = nil;
static AVAudioPlayerNode *gPlayer = nil;

static BOOL gActive = NO;
static BOOL gBGRegistered = NO;
static BOOL gBGSubmitted = NO;
static NSString *gLastBGNote = @"none";   ///< 判据用：submitted / unavailable / failed:<msg> / skipped
static NSString *gSubtitle = @"等待设备连入…";

#pragma mark - 静音音频

static void A2PairingAudioStart(void) {
    if (gEngine != nil) {
        return;
    }
    NSError *err = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // .playback + .mixWithOthers：能后台播放，且不打断用户正在听的东西。
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err != nil) {
        NSLog(@"[A2-PAIRPIN] keepalive 音频类别设置失败: %@", err.localizedDescription ?: @"");
    }
    [session setActive:YES error:&err];

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *player = [[AVAudioPlayerNode alloc] init];
    const AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
    [engine attachNode:player];
    [engine connect:player to:engine.mainMixerNode format:fmt];

    // 1 秒静音缓冲，循环播 —— 只为把 App 顶在后台（不改渲染、不出声）。
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:44100];
    buf.frameLength = 44100;
    [player scheduleBuffer:buf atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];

    if ([engine startAndReturnError:&err]) {
        [player play];
        gEngine = engine;
        gPlayer = player;
        NSLog(@"[A2-PAIRPIN] keepalive 静音音频已启动（后台保活）");
    } else {
        NSLog(@"[A2-PAIRPIN] keepalive 静音音频启动失败: %@", err.localizedDescription ?: @"");
    }
}

static void A2PairingAudioStop(void) {
    if (gPlayer != nil) {
        [gPlayer stop];
        gPlayer = nil;
    }
    if (gEngine != nil) {
        [gEngine stop];
        gEngine = nil;
    }
}

#pragma mark - 后台继续任务

void A2PairingKeepAliveRegisterBGTask(void) {
    if (gBGRegistered) {
        return;
    }
    if (@available(iOS 26.0, *)) {
        [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:kA2PairingBGTaskIdentifier
                                                           usingQueue:dispatch_get_main_queue()
                                                        launchHandler:^(BGTask *task) {
            // 配对本身跑在别的队列上；这里只需要在过期时收尾，避免系统判定任务已死。
            NSLog(@"[A2-PAIRPIN] keepalive 后台任务回调（%@）", task.identifier ?: @"-");
            task.expirationHandler = ^{
                NSLog(@"[A2-PAIRPIN] keepalive 后台任务过期 ⇒ 停止保活（配对可能被挂起）");
                A2PairingKeepAliveStop();
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (A2PairingKeepAliveIsActive()) {
                    A2PairingKeepAliveStop();
                }
            });
        }];
        gBGRegistered = YES;
    } else {
        gLastBGNote = @"unavailable";
        NSLog(@"[A2-PAIRPIN] keepalive 后台继续任务不可用（需要 iOS 26+）⇒ 只剩音频保活");
    }
}

static void A2PairingBGSubmit(void) {
    if (@available(iOS 26.0, *)) {
        BGContinuedProcessingTaskRequest *req =
            [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:kA2PairingBGTaskIdentifier
                                                                   title:@"Air2 配对"
                                                                subtitle:gSubtitle];
        req.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyQueue;
        NSError *err = nil;
        if ([BGTaskScheduler.sharedScheduler submitTaskRequest:req error:&err]) {
            gBGSubmitted = YES;
            gLastBGNote = @"submitted";
        } else {
            gBGSubmitted = NO;
            gLastBGNote = [NSString stringWithFormat:@"failed:%@", err.localizedDescription ?: @"-"];
        }
    } else {
        gLastBGNote = @"unavailable";
    }
}

static void A2PairingBGCancel(void) {
    if (gBGSubmitted) {
        [BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:kA2PairingBGTaskIdentifier];
        gBGSubmitted = NO;
    }
}

#pragma mark - 对外

void A2PairingKeepAliveStart(NSString *subtitle) {
    if (subtitle.length > 0) {
        gSubtitle = subtitle;
    }
    gActive = YES;
    A2PairingAudioStart();
    A2PairingBGSubmit();
    NSLog(@"%@", A2PairingKeepAliveCriterionLine());
}

void A2PairingKeepAliveStop(void) {
    gActive = NO;
    A2PairingAudioStop();
    A2PairingBGCancel();
    NSLog(@"%@", A2PairingKeepAliveCriterionLine());
}

BOOL A2PairingKeepAliveIsActive(void) {
    return gActive;
}

NSString *A2PairingKeepAliveCriterionLine(void) {
    return [NSString stringWithFormat:@"[A2-PAIRPIN] keepalive=%@ bg=%@",
            (gEngine != nil) ? @"audio-on" : @"audio-off", gLastBGNote ?: @"none"];
}

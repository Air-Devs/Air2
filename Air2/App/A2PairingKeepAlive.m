//
//  A2PairingKeepAlive.m
//  Air2 —— [PAIRWIRE-KEEPALIVE] 实现（见头文件说明）
//

#import "A2PairingKeepAlive.h"
#import "A2Log.h"     // [A2Log criterion:]：判据行的统一出口（控制台 + 会话日志文件）

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

// 前向声明：注册函数（下方）的到期回调要用到「取消后台任务」这一支（定义在本文件后段）。
static void A2PairingBGCancel(void);

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
        [A2Log criterion:@"[A2-PAIRPIN] keepalive 音频类别设置失败: %@", err.localizedDescription ?: @""];
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
        [A2Log criterion:@"[A2-PAIRPIN] keepalive 静音音频已启动（后台保活）"];
    } else {
        [A2Log criterion:@"[A2-PAIRPIN] keepalive 静音音频启动失败: %@", err.localizedDescription ?: @""];
    }
}

static void A2PairingAudioStop(void) {
    BOOL hadEngine = (gEngine != nil);
    if (gPlayer != nil) {
        [gPlayer stop];
        gPlayer = nil;
    }
    if (gEngine != nil) {
        [gEngine stop];
        gEngine = nil;
    }
    // ★只回收我们自己起的会话来★：不主动 setActive:NO 会让「保活已经结束」的进程继续占着
    //   音频会话（紧接着的建 VM / 游戏音频会被它影响）；但如果这次没起过引擎，就绝不碰别人的会话。
    if (hadEngine) {
        NSError *err = nil;
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:&err];
        if (err != nil) {
            [A2Log criterion:@"[A2-PAIRPIN] keepalive 音频会话回收失败: %@",
             err.localizedDescription ?: @""];
        }
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
            [A2Log criterion:@"[A2-PAIRPIN] keepalive 后台任务回调（%@）", task.identifier ?: @"-"];
            task.expirationHandler = ^{
                // ★只让后台任务到期，不整体停保活★：静音音频才是主力（配对 / 等 JIT 都靠它扛住挂起）。
                //   这里若调 A2PairingKeepAliveStop()，后台继续任务一到期就把音频也停掉 ⇒ 进程照样被挂起。
                [A2Log criterion:@"[A2-PAIRPIN] keepalive 后台继续任务到期 ⇒ 静音音频继续保活"
                 @"（keepalive=%s）", (gEngine != nil) ? "audio-on" : "audio-off"];
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (A2PairingKeepAliveIsActive()) {
                    // 同上：300s 上限只针对「后台继续任务」，音频保活由调用方 Stop() 收尾。
                    A2PairingBGCancel();
                }
            });
        }];
        gBGRegistered = YES;
    } else {
        gLastBGNote = @"unavailable";
        [A2Log criterion:@"[A2-PAIRPIN] keepalive 后台继续任务不可用（需要 iOS 26+）⇒ 只剩音频保活"];
    }
}

static void A2PairingBGSubmit(void) {
    if (@available(iOS 26.0, *)) {
        BGContinuedProcessingTaskRequest *req =
            [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:kA2PairingBGTaskIdentifier
                                                                   title:@"Air2"
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
    [A2Log criterion:@"%@", A2PairingKeepAliveCriterionLine()];
}

void A2PairingKeepAliveStop(void) {
    gActive = NO;
    A2PairingAudioStop();
    A2PairingBGCancel();
    [A2Log criterion:@"%@", A2PairingKeepAliveCriterionLine()];
}

BOOL A2PairingKeepAliveIsActive(void) {
    return gActive;
}

NSString *A2PairingKeepAliveCriterionLine(void) {
    return [NSString stringWithFormat:@"[A2-PAIRPIN] keepalive=%@ bg=%@",
            (gEngine != nil) ? @"audio-on" : @"audio-off", gLastBGNote ?: @"none"];
}

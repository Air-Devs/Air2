//
//  A2LaunchOverlay.m
//  Air2
//

#import "A2LaunchOverlay.h"
#import "A2PluginBootGuard.h"   // ★插件 P1 第⑤块★ 首帧到达 ⇒ 清 boot marker（接线点 B）
#import "A2Log.h"

NSNotificationName const A2LaunchStageNotification = @"A2LaunchStageNotification";

static UIView *gOverlayView = nil;
static NSTimer *gFirstFrameWatchdog = nil;   // 阶段8之后仍无首帧 ⇒ 兜底提示
static UILabel *gStageLabel = nil;
static UIProgressView *gProgress = nil;

@implementation A2LaunchOverlay

+ (void)show {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self show]; });
        return;
    }
    if (gOverlayView != nil) {
        return;   // 幂等
    }
    UIWindow *win = UIApplication.sharedApplication.keyWindow;
    if (win == nil) {
        // 场景启动早期 keyWindow 可能还没就绪：稍后重试一次，不递归
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self show]; });
        return;
    }

    UIView *cover = [[UIView alloc] initWithFrame:win.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
    cover.tag = 0x4C41554E;   // 'LAUN'：便于排查「遮罩没关掉」

    // 卡片
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [cover addSubview:card];

    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = [UIColor whiteColor];
    [spinner startAnimating];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"正在启动游戏";
    title.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];

    UILabel *stage = [[UILabel alloc] initWithFrame:CGRectZero];
    stage.translatesAutoresizingMaskIntoConstraints = NO;
    stage.text = @"准备中…";
    stage.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    stage.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    stage.numberOfLines = 2;

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.progress = 0.05;
    progress.progressTintColor = [UIColor colorWithRed:0.42 green:0.65 blue:1.0 alpha:1.0];
    progress.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.15];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = @"首次启动较慢，请保持前台";
    hint.font = [UIFont systemFontOfSize:11.0];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];

    for (UIView *v in @[ spinner, title, stage, progress, hint ]) {
        [card addSubview:v];
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300.0],

        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:24.0],
        [spinner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],

        [title.centerYAnchor constraintEqualToAnchor:spinner.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:spinner.trailingAnchor constant:10.0],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],

        [stage.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:18.0],
        [stage.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [stage.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],

        [progress.topAnchor constraintEqualToAnchor:stage.bottomAnchor constant:14.0],
        [progress.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [progress.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],

        [hint.topAnchor constraintEqualToAnchor:progress.bottomAnchor constant:12.0],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0],
    ]];

    [win addSubview:cover];
    gOverlayView = cover;
    gStageLabel = stage;
    gProgress = progress;

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(a2_stageChanged:)
                                              name:A2LaunchStageNotification
                                            object:nil];
    // 首帧通知（native 在 GL 桥帧回调里发）：这才是"游戏真的在画"的时刻
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(a2_gameFirstFrame:)
                                              name:@"A2GameFirstFrame"
                                            object:nil];
}

+ (void)hide {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hide]; });
        return;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self name:A2LaunchStageNotification object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:@"A2GameFirstFrame" object:nil];
    [gFirstFrameWatchdog invalidate];
    gFirstFrameWatchdog = nil;
    if (gOverlayView != nil) {
        [gOverlayView removeFromSuperview];
    }
    gOverlayView = nil;
    gStageLabel = nil;
    gProgress = nil;
}

+ (void)a2_gameFirstFrame:(NSNotification *)note {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self a2_gameFirstFrame:note]; });
        return;
    }
    // ★插件 P1 第⑤块★ 接线点 B：首帧到了 = 这次启动成功跨过了启动链。
    //   放在最前面 —— 后面全是动画与遮罩，任何早退都不该让「启动成功」这件事丢失。
    //   本类是「A2GameFirstFrame」的唯一观察者，因此这里是全进程唯一能收到首帧的 UI 位置。
    //   返回值只在单测里断言；失败最多让下次多记一次失败，不影响画面。
    (void)[A2PluginBootGuard markFirstFrameReached];

    [gFirstFrameWatchdog invalidate];
    gFirstFrameWatchdog = nil;
    [A2Log log:@"[A2-LAUNCH] ✅ 收到首帧通知 ⇒ 撤遮罩"];
    // 稍等一下让第一帧真正上屏，再淡出
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self hide]; });
}

+ (BOOL)isVisible {
    return gOverlayView != nil;
}

/// native 阶段播报 → 文案/进度。进度只做粗粒度映射（阶段 5..8），
/// 真实耗时由日志判据承担，UI 不假装精确。
+ (void)a2_stageChanged:(NSNotification *)note {
    NSNumber *stageNum = note.userInfo[@"stage"];
    NSString *name = note.userInfo[@"name"] ?: @"";
    BOOL failed = [note.userInfo[@"failed"] boolValue];
    NSInteger stage = stageNum.integerValue;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self a2_stageChanged:note]; });
        return;
    }
    if (failed) {
        gStageLabel.text = [NSString stringWithFormat:@"启动失败：%@", name];
        gProgress.progress = 0.0;
        return;
    }
    if (stage >= 8) {
        // ★不再在这里撤★ 阶段8 只代表"VM/主类已派发"，此时画面还是黑的。
        //   真正撤遮罩由 native 的「首帧」通知驱动（A2GameFirstFrame）。
        gStageLabel.text = @"游戏启动中…";
        gProgress.progress = 0.95;
        // ★首帧兜底★ 主类已派发但迟迟没有首帧 ⇒ 不假装成功，把真实状态告诉用户。
        //   ★只提示、不杀进程★：1.17 + MG 首次进世界要编译着色器/建区块，120s 并非异常；
        //   提前退出会毁掉一次本来能干成的启动（也毁掉诊断样本）。
        if (gFirstFrameWatchdog == nil) {
            gFirstFrameWatchdog = [NSTimer scheduledTimerWithTimeInterval:120.0 repeats:NO block:^(NSTimer *tm) {
                if (gOverlayView == nil) return;           // 已经撤了就啥也不做
                gStageLabel.text = @"画面仍未出现（可能在编译着色器/加载资源）";
                gProgress.progress = 0.95;
                [A2Log log:@"[A2-LAUNCH] ★首帧超时（120s，不杀）★ 阶段8已过 120s 仍未收到 A2GameFirstFrame（遮罩保持，进程继续）"];
            }];
        }
        return;
    }
    gStageLabel.text = name;
    if (gProgress != nil && stage > 0) {
        gProgress.progress = MIN(0.95, MAX(0.05, (float)stage / 8.0f));
    }
}

@end

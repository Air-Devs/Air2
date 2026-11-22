//
//  A2BackgroundView.m
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

#import "A2BackgroundView.h"
#import "A2ThemeManager.h"
#import <AVFoundation/AVFoundation.h>

/// KVO 的上下文指针。用独立地址而不是 keyPath 字符串判断来源 ——
/// 同一个 keyPath 可能被别的观察者监听，字符串比较不可靠。
static void *kA2BackgroundVideoKVO = &kA2BackgroundVideoKVO;

@interface A2BackgroundView ()
/// 静态图 / 视频首帧海报
@property (nonatomic, strong) UIImageView *imageView;

/// 三段连续模糊权重（见 applyBackgroundAnimated:）
@property (nonatomic, strong) UIVisualEffectView *blurLight;
@property (nonatomic, strong) UIVisualEffectView *blurMedium;
@property (nonatomic, strong) UIVisualEffectView *blurHeavy;
/// 暗色遮罩
@property (nonatomic, strong) UIView *dimOverlay;
/// 右侧渐隐
@property (nonatomic, strong) CAGradientLayer *fadeLayer;

/// 视频背景（没有视频时为 nil）
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerItem *playerItem;
@property (nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
/// 当前 player 对应的视频路径，用来避免重复重建
@property (nonatomic, copy, nullable) NSString *loadedVideoPath;
/// 已确认解码失败的视频路径：同一个文件不再反复重试，避免重建循环
@property (nonatomic, copy, nullable) NSString *failedVideoPath;

/// App 是否在前台
@property (nonatomic, assign) BOOL appActive;
/// 宿主页面是否希望播放（viewWillAppear / viewWillDisappear 控制）
@property (nonatomic, assign) BOOL playbackWanted;
@end

@implementation A2BackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;
    _fadeRatio = 0.35;
    _appActive = (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground);
    _playbackWanted = YES;

    // 无媒体即纯色（MD3 surface），装饰渐变与光斑已移除：
    // 背景隐身、靠卡片 tonal 层级表达深度。
    self.backgroundColor = UIColor.clearColor;

    // ---- 图片 / 视频海报 ----
    _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds = YES;
    _imageView.alpha = 0;
    [self addSubview:_imageView];

    // ---- 模糊：三层交叉淡入，得到 0~100 连续可感知的强度 ----
    // 系统材质只有几档，单靠 effect 切换会出现「滑了半截没变化」；
    // 叠三层不同粗糙度的材质、按比例分配 alpha，滑杆才跟手。
    _blurLight = [self makeBlurViewWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    _blurMedium = [self makeBlurViewWithStyle:UIBlurEffectStyleSystemThinMaterial];
    _blurHeavy = [self makeBlurViewWithStyle:UIBlurEffectStyleSystemMaterial];

    // ---- 遮罩 ----
    _dimOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    _dimOverlay.userInteractionEnabled = NO;
    [self addSubview:_dimOverlay];

    // ---- 渐隐 ----
    _fadeLayer = [CAGradientLayer layer];
    _fadeLayer.startPoint = CGPointMake(0.0, 0.5);
    _fadeLayer.endPoint = CGPointMake(1.0, 0.5);
    [self.layer addSublayer:_fadeLayer];

    [self applyBackground];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(handleThemeChanged:)
               name:A2ThemeDidChangeNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleBackgroundChanged:)
               name:A2BackgroundDidChangeNotification
             object:nil];
    // 进后台暂停解码，回前台恢复 —— 视频背景不该在后台空耗电量
    [nc addObserver:self
           selector:@selector(handleAppWillResignActive:)
               name:UIApplicationWillResignActiveNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleAppDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleAppDidEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleAppWillEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification
             object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removePlayerItemObservers];
    [_player pause];
    _playerLayer.player = nil;
}

- (UIVisualEffectView *)makeBlurViewWithStyle:(UIBlurEffectStyle)style {
    UIVisualEffectView *v = [[UIVisualEffectView alloc]
                             initWithEffect:[UIBlurEffect effectWithStyle:style]];
    v.userInteractionEnabled = NO;
    v.alpha = 0;
    v.hidden = YES;
    [self addSubview:v];
    return v;
}

#pragma mark - 应用背景

- (void)handleThemeChanged:(NSNotification *)note      { [self applyBackgroundAnimated:YES]; }
- (void)handleBackgroundChanged:(NSNotification *)note {
    // 只有视频来源真的换了才清掉失败记忆；滑杆拖动这类通知不清，
    // 否则一个坏视频会在每次调模糊时反复重建解码器。
    NSString *currentPath = A2ThemeManager.shared.backgroundVideoURL.path;
    if (self.failedVideoPath && ![currentPath isEqualToString:self.failedVideoPath]) {
        self.failedVideoPath = nil;
    }
    [self applyBackgroundAnimated:YES];
}

- (void)applyBackground {
    [self applyBackgroundAnimated:NO];
}

- (void)applyBackgroundAnimated:(BOOL)animated {
    // 通知可能来自后台线程，UI 一律回主线程
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyBackgroundAnimated:animated];
        });
        return;
    }

    A2ThemeManager *tm = A2ThemeManager.shared;
    BOOL dark = tm.isDark;
    UIColor *surface = tm.scheme.cSurface;

    // ---- 媒体来源：图片 or 视频（共用同一份 ThemeManager 状态）----
    NSURL *videoURL = tm.backgroundVideoURL;
    if (videoURL && self.failedVideoPath &&
        [videoURL.path isEqualToString:self.failedVideoPath]) {
        videoURL = nil;      // 这个文件已经确认解不了，别再试
    }
    BOOL hasVideo = (videoURL != nil);
    UIImage *still = hasVideo ? tm.backgroundPosterImage : tm.backgroundImage;
    BOOL hasMedia = hasVideo || (still != nil);

    // 纯色底：没有媒体时就是它；有媒体时垫在下面，切换过程不露黑
    self.backgroundColor = surface;

    if (hasVideo) {
        [self preparePlayerWithURL:videoURL];
    } else {
        [self teardownPlayer];
    }

    self.imageView.image = still;
    // 视频时海报也保留在播放层下面：还没出画 / 解码失败时看到的是海报而不是黑屏
    CGFloat imageAlpha = (still != nil || hasVideo) ? 1.0 : 0.0;

    // ---- 模糊：0~100 映射成三段材质的连续权重 ----
    CGFloat blur = hasMedia ? MAX(0.0, MIN(100.0, (CGFloat)tm.backgroundBlur)) / 100.0 : 0.0;
    CGFloat lightAlpha  = MIN(1.0, blur / 0.40);
    CGFloat mediumAlpha = MIN(1.0, MAX(0.0, (blur - 0.30) / 0.40));
    CGFloat heavyAlpha  = MIN(1.0, MAX(0.0, (blur - 0.60) / 0.40));

    // ---- 暗色遮罩：只在有媒体且确实开了模糊时按比例压暗 ----
    // 清晰模式（blur = 0）不加遮罩，否则用户没开模糊也会被整体压暗 ——
    // 这正是之前「明明调了 0 还是灰蒙蒙」的原因。
    CGFloat overlay = 0.0;
    if (hasMedia && dark) {
        overlay = tm.backgroundDarkOverlay * MIN(1.0, blur / 0.60);
    }

    // 动画开始前先让所有模糊层可见，避免 alpha 从 0 起跳时被 hidden 吃掉
    _blurLight.hidden = NO;
    _blurMedium.hidden = NO;
    _blurHeavy.hidden = NO;

    void (^changes)(void) = ^{
        self.imageView.alpha = imageAlpha;
        self.blurLight.alpha = lightAlpha;
        self.blurMedium.alpha = mediumAlpha;
        self.blurHeavy.alpha = heavyAlpha;
        self.dimOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:overlay];
    };

    if (animated) {
        [UIView animateWithDuration:0.28
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:changes
                         completion:^(BOOL finished) {
            [self updateBlurVisibility];
        }];
    } else {
        changes();
        [self updateBlurVisibility];
    }

    [self updatePlaybackState];
    [self setNeedsLayout];
}

/// alpha 为 0 的模糊层隐藏起来，省掉无意义的离屏合成
- (void)updateBlurVisibility {
    _blurLight.hidden  = (_blurLight.alpha  <= 0.001);
    _blurMedium.hidden = (_blurMedium.alpha <= 0.001);
    _blurHeavy.hidden  = (_blurHeavy.alpha  <= 0.001);
}

#pragma mark - 视频播放

- (void)preparePlayerWithURL:(NSURL *)url {
    if (self.player && [self.loadedVideoPath isEqualToString:url.path]) return;

    [self teardownPlayer];
    self.loadedVideoPath = url.path;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionNew
              context:kA2BackgroundVideoKVO];
    self.playerItem = item;

    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.muted = YES;                                      // 背景视频不出声
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;    // 循环自己接管
    player.automaticallyWaitsToMinimizeStalling = YES;
    self.player = player;

    if (!self.playerLayer) {
        self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        // 层级：海报 < 视频 < 模糊 < 遮罩 < 渐隐
        [self.layer insertSublayer:self.playerLayer above:self.imageView.layer];
    }
    self.playerLayer.player = player;
    self.playerLayer.hidden = YES;      // 解码就绪前先别显示，避免闪黑
    self.playerLayer.frame = self.bounds;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(handleVideoItemDidPlayToEnd:)
               name:AVPlayerItemDidPlayToEndTimeNotification
             object:item];
    [nc addObserver:self
           selector:@selector(handleVideoItemFailed:)
               name:AVPlayerItemFailedToPlayToEndTimeNotification
             object:item];

    [self updatePlaybackState];
}

/// 拆掉当前 player。任何失败路径都走这里，保证 KVO / 通知 / layer 引用全部断开。
- (void)teardownPlayer {
    [self removePlayerItemObservers];
    [self.player pause];
    self.playerLayer.player = nil;
    self.playerLayer.hidden = YES;
    self.playerItem = nil;
    self.player = nil;
    self.loadedVideoPath = nil;
}

- (void)removePlayerItemObservers {
    AVPlayerItem *item = self.playerItem;
    if (!item) return;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [nc removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    // KVO 必须成对移除，否则 item 释放后它仍可能回消息给已销毁的 view
    @try {
        [item removeObserver:self forKeyPath:@"status" context:kA2BackgroundVideoKVO];
    } @catch (NSException *exception) {
        // 没注册成功时移除会抛异常，忽略即可
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != kA2BackgroundVideoKVO) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    // KVO 回调线程不保证是主线程，统一回主线程处理
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handlePlayerItemStatusChange:(AVPlayerItem *)object];
        });
        return;
    }
    [self handlePlayerItemStatusChange:(AVPlayerItem *)object];
}

- (void)handlePlayerItemStatusChange:(AVPlayerItem *)item {
    if (item != self.playerItem) return;   // 旧 item 的迟到回调，忽略

    switch (item.status) {
        case AVPlayerItemStatusReadyToPlay:
            self.playerLayer.hidden = NO;
            [self updatePlaybackState];
            break;
        case AVPlayerItemStatusFailed:
            [self handleVideoFailure:item.error];
            break;
        case AVPlayerItemStatusUnknown:
        default:
            break;
    }
}

- (void)handleVideoItemDidPlayToEnd:(NSNotification *)note {
    if (note.object != self.playerItem) return;
    // 循环播放：回到片头再播
    [self.playerItem seekToTime:kCMTimeZero
              toleranceBefore:kCMTimeZero
                  toleranceAfter:kCMTimeZero];
    [self updatePlaybackState];
}

- (void)handleVideoItemFailed:(NSNotification *)note {
    NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self handleVideoFailure:error];
}

/// 视频解码失败 —— 降级顺序：海报 → 纯色，绝不黑屏。
- (void)handleVideoFailure:(NSError *)error {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleVideoFailure:error];
        });
        return;
    }

    NSURL *url = A2ThemeManager.shared.backgroundVideoURL;
    if (url) self.failedVideoPath = url.path;
    NSLog(@"[Air2] 背景视频无法播放，已回落到静态兜底: %@",
          error.localizedDescription ?: @"unknown");

    [self teardownPlayer];

    UIImage *poster = A2ThemeManager.shared.backgroundPosterImage;
    self.imageView.image = poster;
    self.imageView.alpha = poster ? 1.0 : 0.0;
    // 没有海报时留 self.backgroundColor（主题 surface），不是黑色
}

- (void)updatePlaybackState {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updatePlaybackState]; });
        return;
    }
    BOOL ready = (self.playerItem.status == AVPlayerItemStatusReadyToPlay);
    BOOL shouldPlay = self.playbackWanted
                   && self.appActive
                   && self.window != nil
                   && self.player != nil
                   && ready;

    if (shouldPlay) {
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
            [self.player play];
        }
    } else {
        [self.player pause];
    }
}

- (void)pausePlayback {
    self.playbackWanted = NO;
    [self updatePlaybackState];
}

- (void)resumePlayback {
    self.playbackWanted = YES;
    [self updatePlaybackState];
}

- (void)handleAppWillResignActive:(NSNotification *)note {
    self.appActive = NO;
    [self updatePlaybackState];
}

- (void)handleAppDidBecomeActive:(NSNotification *)note {
    self.appActive = YES;
    [self updatePlaybackState];
}

- (void)handleAppDidEnterBackground:(NSNotification *)note {
    self.appActive = NO;
    [self updatePlaybackState];
}

- (void)handleAppWillEnterForeground:(NSNotification *)note {
    self.appActive = YES;
    [self updatePlaybackState];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updatePlaybackState];
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    // CAGradientLayer / AVPlayerLayer 不参与自动布局，帧变化时要手动同步并关隐式动画
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _imageView.frame = self.bounds;
    _playerLayer.frame = self.bounds;
    _blurLight.frame = self.bounds;
    _blurMedium.frame = self.bounds;
    _blurHeavy.frame = self.bounds;
    _dimOverlay.frame = self.bounds;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    // 右侧渐隐：从透明过渡到当前表面色，让操作栏一侧有稳定的底色
    CGFloat fadeW = w * MAX(0.0, MIN(1.0, _fadeRatio));
    _fadeLayer.frame = CGRectMake(w - fadeW, 0, fadeW, h);
    _fadeLayer.hidden = (fadeW <= 1);

    [CATransaction commit];

    [self updateFadeColors];
}

- (void)updateFadeColors {
    if (_fadeLayer.hidden) return;

    A2ThemeManager *tm = A2ThemeManager.shared;
    UIColor *edge = tm.isDark
        ? [tm.scheme.cSurface colorWithAlphaComponent:0.92]
        : [tm.scheme.cSurface colorWithAlphaComponent:0.88];

    UIColor *clear = [edge colorWithAlphaComponent:0.0];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fadeLayer.colors = @[
        (__bridge id)clear.CGColor,
        (__bridge id)[edge colorWithAlphaComponent:0.45].CGColor,
        (__bridge id)edge.CGColor,
    ];
    _fadeLayer.locations = @[@0.0, @0.6, @1.0];
    [CATransaction commit];
}

@end

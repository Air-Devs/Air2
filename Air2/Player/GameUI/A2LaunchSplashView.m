//
//  A2LaunchSplashView.m
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
//
//  A2LaunchSplashView.m
//  Air2
//

#import "A2LaunchSplashView.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"

@interface A2LaunchSplashView ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign, readwrite) A2LaunchStage stage;
@property (nonatomic, assign, readwrite) double progress;

/// 进度条轨道（圆角底）
@property (nonatomic, strong) UIView *progressTrack;
/// 进度条填充（用宽度约束驱动，避免 frame 动画在旋转时错位）
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, strong) NSLayoutConstraint *progressBarWidth;
/// 百分比文字
@property (nonatomic, strong) UILabel *percentLabel;
@end

@implementation A2LaunchSplashView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _startTime = [NSDate date];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // 模糊背景 —— 游戏画面先出来时做底
    _blurView = [[UIVisualEffectView alloc] initWithEffect:
                 [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_blurView];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.layer.cornerRadius = 18;
    _iconView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView.clipsToBounds = YES;
    [_iconView.widthAnchor constraintEqualToConstant:72].active = YES;
    [_iconView.heightAnchor constraintEqualToConstant:72].active = YES;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;

    _stageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stageLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.text = @"正在准备…";
    _stageLabel.numberOfLines = 2;

    _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _elapsedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _elapsedLabel.textAlignment = NSTextAlignmentCenter;
    _elapsedLabel.text = @"0.0s";

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:
                UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimating];

    _logView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsMake(8, 10, 8, 10);
    _logView.layer.cornerRadius = 12;
    _logView.layer.cornerCurve = kCACornerCurveContinuous;
    _logView.hidden = YES;

    // ---- 进度条 ----
    //
    // 对照 FCL / ZL2 的启动页：一条横向进度条 + 右侧百分比，
    // 覆盖「点启动 → JVM 起来 → MC 加载 → 首帧出现」整段过程。
    // Air2 原来只有转圈 + 阶段文字，用户看不到还要等多久。
    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _progressTrack.layer.cornerRadius = 3;
    _progressTrack.layer.cornerCurve = kCACornerCurveContinuous;
    _progressTrack.clipsToBounds = YES;

    _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    _progressFill.translatesAutoresizingMaskIntoConstraints = NO;
    _progressFill.layer.cornerRadius = 3;
    _progressFill.layer.cornerCurve = kCACornerCurveContinuous;
    [_progressTrack addSubview:_progressFill];

    _progressBarWidth = [_progressFill.widthAnchor constraintEqualToConstant:0];

    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _percentLabel.textAlignment = NSTextAlignmentRight;
    _percentLabel.text = @"0%";
    [_percentLabel setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    [_percentLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *progressRow = [[UIStackView alloc] initWithArrangedSubviews:
                                @[_progressTrack, _percentLabel]];
    progressRow.translatesAutoresizingMaskIntoConstraints = NO;
    progressRow.axis = UILayoutConstraintAxisHorizontal;
    progressRow.alignment = UIStackViewAlignmentCenter;
    progressRow.spacing = A2SpaceS;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_iconView, _titleLabel, _stageLabel, progressRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = A2SpaceM;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_spinner, _elapsedLabel]];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = A2SpaceS;
    statusRow.alignment = UIStackViewAlignmentCenter;

    [self addSubview:stack];
    [self addSubview:statusRow];
    [self addSubview:_logView];

    [NSLayoutConstraint activateConstraints:@[
        [_blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-20],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:40],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-40],

        // 进度条：轨道撑满 stack 宽度，高 6；min 宽 220 让它在窄屏也可读
        [_progressTrack.heightAnchor constraintEqualToConstant:6],
        [_progressTrack.widthAnchor constraintGreaterThanOrEqualToConstant:220],
        [progressRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],

        [_progressFill.topAnchor constraintEqualToAnchor:_progressTrack.topAnchor],
        [_progressFill.bottomAnchor constraintEqualToAnchor:_progressTrack.bottomAnchor],
        [_progressFill.leadingAnchor constraintEqualToAnchor:_progressTrack.leadingAnchor],
        _progressBarWidth,

        [statusRow.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:A2SpaceL],
        [statusRow.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

        [_logView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
        [_logView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
        [_logView.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor
                                              constant:-16],
        [_logView.heightAnchor constraintEqualToConstant:120],
    ]];

    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSTimeInterval dt = [[NSDate date] timeIntervalSinceDate:self.startTime];
        self.elapsedLabel.text = [NSString stringWithFormat:@"%.1fs", dt];
    }];

    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

#pragma mark - 阶段

/// 阶段 -> 进度区间的起点。
///
/// 权重不是平均分的，按真实耗时估算：
///   · 检查/补下载：文件多但大多命中缓存，给 0~28
///   · JVM 启动 + 类加载：MC 首次加载类是大头，30~72
///   · 渲染器初始化：ANGLE/MobileGlues 起来比较慢，72~92
///   · 等窗口 + 首帧：最后一段，92~100
/// 这样进度条不会在「等首帧」那段卡在 50% 不动，也不会前段跑太快后段爬。
+ (double)startProgressForStage:(A2LaunchStage)stage {
    switch (stage) {
        case A2LaunchStagePreparing:      return 0.00;
        case A2LaunchStageRepairing:      return 0.06;
        case A2LaunchStageStartingJVM:    return 0.28;
        case A2LaunchStageLoadingClasses: return 0.42;
        case A2LaunchStageInitializingGL: return 0.72;
        case A2LaunchStageWaitingWindow:  return 0.92;
        case A2LaunchStageFinished:       return 1.00;
        case A2LaunchStageFailed:         return -1;    // 不推进
    }
    return 0;
}

- (void)setStage:(A2LaunchStage)stage message:(NSString *)message {
    _stage = stage;
    NSString *text = message.length ? message : [self defaultTextForStage:stage];

    // 交叉淡入，避免文字硬切
    [UIView transitionWithView:_stageLabel
                      duration:0.22
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self->_stageLabel.text = text;
    } completion:nil];

    double start = [[self class] startProgressForStage:stage];
    if (start >= 0) {
        [self setProgress:start message:nil];
    }

    if (stage == A2LaunchStageFinished) {
        // 首帧已经出来了，把进度条走满再淡出，别停在 99%
        [self setProgress:1.0 message:nil];
    }
}

- (void)setProgress:(double)progress message:(NSString *)message {
    if (!isfinite(progress)) return;
    double clamped = MAX(0.0, MIN(1.0, progress));
    // 只进不退：阶段切换和字节回调可能乱序，回退会让进度条来回抖
    if (clamped <= _progress) {
        if (message.length) [self updateStageText:message];
        return;
    }
    _progress = clamped;
    [self applyProgress:clamped animated:YES];
    if (message.length) [self updateStageText:message];
}

- (void)updateStageText:(NSString *)text {
    if (!text.length) return;
    [UIView transitionWithView:_stageLabel
                      duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self->_stageLabel.text = text;
    } completion:nil];
}

- (void)applyProgress:(double)progress animated:(BOOL)animated {
    if (!_progressTrack || !_progressBarWidth) return;
    [_progressTrack layoutIfNeeded];
    CGFloat total = _progressTrack.bounds.size.width;
    CGFloat w = MAX(0.0, total * progress);

    void (^changes)(void) = ^{
        self->_progressBarWidth.constant = w;
        [self->_progressTrack layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.35
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
    // 百分比文字
    _percentLabel.text = progress >= 1.0
        ? @"100%"
        : [NSString stringWithFormat:@"%d%%", (int)floor(progress * 100)];
}

- (NSString *)defaultTextForStage:(A2LaunchStage)stage {
    switch (stage) {
        case A2LaunchStagePreparing:      return @"正在检查游戏文件…";
        case A2LaunchStageRepairing:      return @"正在补齐缺失文件…";
        case A2LaunchStageStartingJVM:    return @"正在启动 Java 虚拟机…";
        case A2LaunchStageLoadingClasses: return @"正在加载游戏…";
        case A2LaunchStageInitializingGL: return @"正在初始化渲染…";
        case A2LaunchStageWaitingWindow:  return @"正在等待游戏窗口…";
        case A2LaunchStageFinished:       return @"进入游戏";
        case A2LaunchStageFailed:         return @"启动失败";
    }
    return @"";
}

- (void)setVersionName:(NSString *)versionName {
    _versionName = [versionName copy];
    _titleLabel.text = versionName;
}

- (void)setVersionIcon:(UIImage *)versionIcon {
    _versionIcon = versionIcon;
    _iconView.image = versionIcon;
}

- (void)setShowsLog:(BOOL)showsLog {
    _showsLog = showsLog;
    _logView.hidden = !showsLog;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.25 animations:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.logView.alpha = showsLog ? 1 : 0;
    }];
}

- (void)appendLog:(NSString *)line {
    if (!_showsLog || line.length == 0) return;
    NSString *cur = _logView.text ?: @"";
    _logView.text = [cur stringByAppendingFormat:@"%@\n", line];
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

#pragma mark - 失败

- (void)showFailure:(NSString *)message onRetry:(void (^)(void))onRetry onQuit:(void (^)(void))onQuit {
    [self setStage:A2LaunchStageFailed message:@"启动失败"];
    [_spinner stopAnimating];
    [_timer invalidate];

    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    UILabel *msg = [[UILabel alloc] initWithFrame:CGRectZero];
    msg.translatesAutoresizingMaskIntoConstraints = NO;
    msg.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    msg.numberOfLines = 0;
    msg.textAlignment = NSTextAlignmentCenter;
    msg.textColor = t.cOnSurfaceVariant;
    msg.text = message;

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [retry setTitle:@"重新启动" forState:UIControlStateNormal];
    retry.backgroundColor = t.cPrimary;
    [retry setTitleColor:t.cOnPrimary forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    retry.layer.cornerRadius = 22;
    retry.layer.cornerCurve = kCACornerCurveContinuous;
    [retry.heightAnchor constraintEqualToConstant:44].active = YES;
    [retry addAction:[UIAction actionWithHandler:^(UIAction *a) {
        if (onRetry) onRetry();
    }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *quit = [UIButton buttonWithType:UIButtonTypeSystem];
    quit.translatesAutoresizingMaskIntoConstraints = NO;
    [quit setTitle:@"退出" forState:UIControlStateNormal];
    [quit setTitleColor:t.cOnSurfaceVariant forState:UIControlStateNormal];
    [quit.heightAnchor constraintEqualToConstant:44].active = YES;
    [quit addAction:[UIAction actionWithHandler:^(UIAction *a) {
        if (onQuit) onQuit();
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[msg, retry, quit]];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = A2SpaceM;
    [self addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [v.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [v.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.6],
        [v.topAnchor constraintEqualToAnchor:_stageLabel.bottomAnchor constant:A2SpaceXL],
    ]];

    // 失败时把日志显示出来 —— 用户截图就能报问题
    self.showsLog = YES;
}

#pragma mark - 完成

- (void)finishAndDismissWithCompletion:(void (^)(void))completion {
    [self setStage:A2LaunchStageFinished message:@"进入游戏"];
    [_spinner stopAnimating];
    [_timer invalidate];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.45
                          delay:0.15
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(1.04, 1.04);
    }
                     completion:^(BOOL finished) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self removeFromSuperview];
        if (completion) completion();
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.cOnSurface;
    _stageLabel.textColor = t.cOnSurfaceVariant;
    _elapsedLabel.textColor = t.cOnSurfaceVariant;
    _spinner.color = t.cPrimary;
    _logView.backgroundColor = [t.cSurfaceContainer colorWithAlphaComponent:0.7];
    _logView.textColor = t.cOnSurfaceVariant;

    // 进度条配色：轨道用表面容器的低透明版本，填充用主色（和 spinner 一致）
    _progressTrack.backgroundColor = [t.cSurfaceContainer
        colorWithAlphaComponent:0.55];
    _progressFill.backgroundColor = t.cPrimary;
    _percentLabel.textColor = t.cOnSurfaceVariant;
}

@end

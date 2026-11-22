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

@interface A2LaunchTaskItem ()
@property (nonatomic, copy, readwrite) NSString *symbolName;
@property (nonatomic, copy, readwrite) NSString *title;
@end

@implementation A2LaunchTaskItem

+ (instancetype)itemWithSymbol:(NSString *)symbol title:(NSString *)title {
    A2LaunchTaskItem *it = [A2LaunchTaskItem new];
    it->_symbolName = [symbol copy] ?: @"circle";
    it->_title = [title copy] ?: @"";
    it->_state = A2LaunchTaskStatePending;
    return it;
}

@end

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
/// 任务清单数据源
@property (nonatomic, copy, nullable) NSArray<A2LaunchTaskItem *> *tasks;
/// 任务清单容器（纵向 stack）
@property (nonatomic, strong) UIStackView *taskStack;
/// 每一行对应的视图，按索引对齐 tasks
@property (nonatomic, strong) NSMutableArray<UIView *> *taskRows;
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

    // ---- 启动任务清单（对照 ZL2 buildLaunchPhases）----
    _taskStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _taskStack.translatesAutoresizingMaskIntoConstraints = NO;
    _taskStack.axis = UILayoutConstraintAxisVertical;
    _taskStack.alignment = UIStackViewAlignmentLeading;
    _taskStack.spacing = 10;
    _taskStack.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_iconView, _titleLabel, _stageLabel, _taskStack]];
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

// ------------------------------------------------------------------
//  启动任务清单
// ------------------------------------------------------------------

- (void)setTasks:(NSArray<A2LaunchTaskItem *> *)tasks {
    _tasks = [tasks copy];
    _taskRows = [NSMutableArray array];

    // 清空旧行
    for (UIView *v in _taskStack.arrangedSubviews) {
        [_taskStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (tasks.count == 0) {
        _taskStack.hidden = YES;
        [self setNeedsLayout];
        return;
    }

    for (NSUInteger i = 0; i < tasks.count; i++) {
        UIView *row = [self buildRowForTask:tasks[i]];
        [_taskStack addArrangedSubview:row];
        [_taskRows addObject:row];
    }
    _taskStack.hidden = NO;
    [self refreshAllRows];
    [self setNeedsLayout];
}

- (UIView *)buildRowForTask:(A2LaunchTaskItem *)task {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tag = 1001;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    title.text = task.title ?: @"";
    title.tag = 1002;

    UILabel *detail = [UILabel new];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    detail.numberOfLines = 1;
    detail.textColor = [UIColor secondaryLabelColor];
    detail.tag = 1003;

    UIActivityIndicatorView *spin =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    spin.hidesWhenStopped = YES;
    spin.tag = 1004;

    [row addSubview:icon];
    [row addSubview:title];
    [row addSubview:detail];
    [row addSubview:spin];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:22],

        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:18],
        [icon.heightAnchor constraintEqualToConstant:18],

        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [title.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [detail.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:spin.leadingAnchor constant:-6],
        [detail.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [spin.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [spin.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [spin.widthAnchor constraintEqualToConstant:16],
        [spin.heightAnchor constraintEqualToConstant:16],

        [title.trailingAnchor constraintLessThanOrEqualToAnchor:spin.leadingAnchor constant:-6],
    ]];
    return row;
}

- (void)refreshAllRows {
    for (NSUInteger i = 0; i < _tasks.count && i < _taskRows.count; i++) {
        [self renderRow:_taskRows[i] withTask:_tasks[i]];
    }
}

- (void)renderRow:(UIView *)row withTask:(A2LaunchTaskItem *)task {
    UIImageView *icon = (UIImageView *)[row viewWithTag:1001];
    UILabel *title = (UILabel *)[row viewWithTag:1002];
    UILabel *detail = (UILabel *)[row viewWithTag:1003];
    UIActivityIndicatorView *spin = (UIActivityIndicatorView *)[row viewWithTag:1004];

    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    NSString *symbol = task.symbolName;
    UIColor *tint = t.cOnSurfaceVariant;

    switch (task.state) {
        case A2LaunchTaskStatePending:
            tint = [t.cOnSurfaceVariant colorWithAlphaComponent:0.45];
            symbol = @"circle";
            break;
        case A2LaunchTaskStateRunning:
            tint = t.cPrimary;
            symbol = task.symbolName;
            break;
        case A2LaunchTaskStateDone:
            tint = [UIColor systemGreenColor];
            symbol = @"checkmark.circle.fill";
            break;
        case A2LaunchTaskStateFailed:
            tint = [UIColor systemRedColor];
            symbol = @"xmark.circle.fill";
            break;
        case A2LaunchTaskStateSkipped:
            tint = [t.cOnSurfaceVariant colorWithAlphaComponent:0.55];
            symbol = @"minus.circle";
            break;
    }

    icon.image = [UIImage systemImageNamed:symbol
                         withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15
                                                                                         weight:UIImageSymbolWeightMedium]];
    icon.tintColor = tint;
    title.textColor = (task.state == A2LaunchTaskStatePending) ? [t.cOnSurfaceVariant colorWithAlphaComponent:0.6] : t.cOnSurface;

    BOOL running = (task.state == A2LaunchTaskStateRunning);
    if (running) [spin startAnimating]; else [spin stopAnimating];
    spin.color = t.cPrimary;
    icon.hidden = running;      // 进行中用工转圈代替图标

    detail.text = task.detail;
    detail.hidden = (task.detail.length == 0);

    row.alpha = (task.state == A2LaunchTaskStatePending) ? 0.75 : 1.0;
}

- (void)setTaskState:(A2LaunchTaskState)state atIndex:(NSInteger)index detail:(NSString *)detail {
    if (index < 0 || (NSUInteger)index >= _tasks.count) return;
    A2LaunchTaskItem *task = _tasks[index];
    task.state = state;
    if (detail) task.detail = detail;
    if ((NSUInteger)index < _taskRows.count) {
        [UIView transitionWithView:_taskRows[index] duration:0.18
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ [self renderRow:self->_taskRows[index] withTask:task]; }
                        completion:nil];
    }
}

/// 兼容旧调用：把语言级阶段映射到清单里「进行中」的那一项。
- (void)setStage:(A2LaunchStage)stage message:(NSString *)message {
    _stage = stage;
    NSString *text = message.length ? message : [self defaultTextForStage:stage];

    [UIView transitionWithView:_stageLabel
                      duration:0.22
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self->_stageLabel.text = text; }
                    completion:nil];

    // ------------------------------------------------------------------
    //  「启动前检查」与「MC 启动中」是两个不同阶段，不复用同一套 UI
    //
    //  启动前检查（ZL2 buildLaunchPhases）：账号 / 环境 / 完整性 / 准备启动
    //      —— 在启动器进程里跑，用上面的任务清单表达。
    //  MC 启动中（JVM 起来 → 首帧）：JVM 初始化 → 类加载 → 渲染器初始化
    //      → 等窗口 → 首帧
    //      —— 已经在游戏进程里，清单没有意义，改为单行阶段文字 + 转圈。
    //
    //  所以一旦跨进 StartingJVM，就把清单收起来，避免两段混在一起。
    // ------------------------------------------------------------------
    if (stage >= A2LaunchStageStartingJVM && stage != A2LaunchStageFailed) {
        _taskStack.hidden = YES;
    }

    if (stage == A2LaunchStageFailed || stage == A2LaunchStageFinished) {
        for (A2LaunchTaskItem *task in _tasks) {
            if (task.state == A2LaunchTaskStateRunning) {
                task.state = (stage == A2LaunchStageFailed) ? A2LaunchTaskStateFailed : A2LaunchTaskStateDone;
            }
        }
        [self refreshAllRows];
    }
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

    // 任务清单一行的配色由 renderRow:withTask: 逐行处理（状态色），
    // 这里只需要把已有行重刷一遍，保证换主题后颜色跟着变。
    [self refreshAllRows];
}

@end

//
//  A2PluginCriticalConfirmFlow.m
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

#import "A2PluginCriticalConfirmFlow.h"

#import <QuartzCore/QuartzCore.h>

#import "A2BaseViewController.h"
#import "A2Log.h"
#import "A2Metrics.h"
#import "A2PluginManifest.h"
#import "A2PrimaryButton.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"

/// 每一步的倒计时（§3.3：三次都是 5 秒）。
static const NSTimeInterval A2PluginCriticalCountdownSeconds = 5.0;

/// 倒计时按钮的禁用外观。`A2PrimaryButton` 没实现 disabled 的视觉态，
/// 不手动压暗的话按钮看起来可点、点了没反应 —— 那比一直灰着更让人困惑。
static const CGFloat A2PluginCriticalDisabledAlpha = 0.38;

#pragma mark - 单个确认页

/// 三次确认的公共页：大标题 + 若干段正文 + 两个按钮（其中一个受倒计时约束）。
/// 三个步骤只在**文案与按钮语义**上不同，所以是同一个类换配置，
/// 不是三个各写一遍的页面 —— 否则「5 秒 / 后台暂停 / VoiceOver」要改三处。
@interface A2PluginCriticalConfirmPage : A2BaseViewController

/// §3.3 规定的标题（`高危权限：…` / `再确认：…` / `最后确认：…`）。
@property (nonatomic, copy) NSString *headline;

/// 正文段落。每条一个段（空串表示段间留白）。
@property (nonatomic, copy) NSArray<NSString *> *paragraphs;

/// 倒计时提示（如「请阅读以上说明，5 秒后可继续」）。为 nil 表示本页不需要倒计时。
@property (nonatomic, copy, nullable) NSString *promptText;

@property (nonatomic, copy) NSString *primaryTitle;
@property (nonatomic, assign) A2ButtonStyle primaryStyle;
@property (nonatomic, copy) NSString *secondaryTitle;
@property (nonatomic, assign) A2ButtonStyle secondaryStyle;

/// YES = 主按钮（`primaryTitle`）要等倒计时结束才可点；NO = 主按钮立刻可点（第 3 步的「不授权」）。
@property (nonatomic, assign) BOOL gatesPrimaryButton;

@property (nonatomic, copy, nullable) void (^onPrimary)(void);
@property (nonatomic, copy, nullable) void (^onSecondary)(void);

@end

@interface A2PluginCriticalConfirmPage ()
@property (nonatomic, strong) UILabel *headlineLabel;
@property (nonatomic, strong) UIStackView *paragraphStack;
@property (nonatomic, strong) UILabel *countdownLabel;
@property (nonatomic, strong) A2PrimaryButton *primaryButton;
@property (nonatomic, strong) A2PrimaryButton *secondaryButton;

@property (nonatomic, strong, nullable) NSTimer *countdownTimer;
@property (nonatomic, assign) NSTimeInterval remainingSeconds;
@property (nonatomic, assign) BOOL gatedButtonEnabled;
@property (nonatomic, assign) BOOL countdownSuspended;

/// 上一次 tick 的单调时钟读数（`CACurrentMediaTime`）。
@property (nonatomic, assign) CFTimeInterval lastTickTime;

@end

@implementation A2PluginCriticalConfirmPage

- (void)viewDidLoad {
    [super viewDidLoad];

    // §3.3：三次提示框都是独立的全屏页，不允许用小号 ActionSheet 代替。
    // 这里没有顶栏 —— 顶栏的返回箭头会让「取消」变成「返回」，文案就兜不住了。
    self.hidesTopBar = YES;

    _headlineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headlineLabel.numberOfLines = 0;
    _headlineLabel.font = [A2Typography titleLarge];
    _headlineLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    _headlineLabel.text = self.headline;
    [self.contentStack addArrangedSubview:_headlineLabel];

    _paragraphStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _paragraphStack.axis = UILayoutConstraintAxisVertical;
    _paragraphStack.spacing = A2SpaceM;
    for (NSString *paragraph in self.paragraphs) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 0;
        label.font = [A2Typography body];
        label.text = paragraph;
        // 正文必须能被 VoiceOver 逐段读到（§3.3 辅助功能那一行）
        label.isAccessibilityElement = paragraph.length > 0;
        label.accessibilityLabel = paragraph;
        [_paragraphStack addArrangedSubview:label];
    }
    [self.contentStack addArrangedSubview:_paragraphStack];

    _countdownLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countdownLabel.numberOfLines = 0;
    _countdownLabel.font = [A2Typography caption];
    _countdownLabel.textAlignment = NSTextAlignmentCenter;
    _countdownLabel.hidden = (self.promptText.length == 0);
    _countdownLabel.text = self.promptText;
    [self.contentStack addArrangedSubview:_countdownLabel];

    _primaryButton = [[A2PrimaryButton alloc] initWithTitle:self.primaryTitle
                                                     style:self.primaryStyle];
    _primaryButton.minHeight = A2ButtonHeight;
    _primaryButton.accessibilityLabel = self.primaryTitle;
    [_primaryButton addTarget:self
                       action:@selector(handlePrimary)
             forControlEvents:UIControlEventTouchUpInside];
    [self.contentStack addArrangedSubview:_primaryButton];

    _secondaryButton = [[A2PrimaryButton alloc] initWithTitle:self.secondaryTitle
                                                       style:self.secondaryStyle];
    _secondaryButton.minHeight = A2ButtonHeight;
    _secondaryButton.accessibilityLabel = self.secondaryTitle;
    [_secondaryButton addTarget:self
                         action:@selector(handleSecondary)
               forControlEvents:UIControlEventTouchUpInside];
    [self.contentStack addArrangedSubview:_secondaryButton];

    // 倒计时状态先落到按钮上，再等 viewDidAppear 才真正开始计时。
    // 顺序反过来的话，页面还没显示就已经扣掉几百毫秒。
    if (self.promptText.length > 0) {
        [self setGatedButtonEnabled:NO];
        _countdownLabel.text = [self countdownTextWithRemaining:A2PluginCriticalCountdownSeconds];
    }

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleWillResignActive:)
                                              name:UIApplicationWillResignActiveNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleDidBecomeActive:)
                                              name:UIApplicationDidBecomeActiveNotification
                                            object:nil];

    [self applyTheme];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_countdownTimer invalidate];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startCountdownIfNeeded];

    // 进入页面就把焦点交给标题，VoiceOver 会从「高危权限：…」开始读，
    // 而不是从屏幕左上角第一个可点元素开始。
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.headlineLabel);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopCountdownTimer];
}

#pragma mark 外观

- (void)applyTheme {
    [super applyTheme];
    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    self.headlineLabel.textColor = scheme.cOnSurface;
    for (UILabel *label in self.paragraphStack.arrangedSubviews) {
        if ([label isKindOfClass:UILabel.class]) label.textColor = scheme.cOnSurfaceVariant;
    }
    self.countdownLabel.textColor = scheme.cOnSurfaceVariant;
}

#pragma mark 按钮

/// 受倒计时约束的那个按钮：主按钮受约束时是它，否则是次按钮（第 3 步的「授权」是次按钮）。
- (nullable A2PrimaryButton *)gatedButton {
    if (self.promptText.length == 0) return nil;
    return self.gatesPrimaryButton ? self.primaryButton : self.secondaryButton;
}

- (void)setGatedButtonEnabled:(BOOL)enabled {
    _gatedButtonEnabled = enabled;
    A2PrimaryButton *button = [self gatedButton];
    if (!button) return;
    button.enabled = enabled;
    button.alpha = enabled ? 1.0 : A2PluginCriticalDisabledAlpha;
    button.accessibilityHint = enabled ? nil : @"倒计时结束后才能点击";
}

- (void)handlePrimary {
    // 双保险：按钮 enabled == NO 时 UIControl 不会发 touchUpInside，
    // 但外部（辅助功能 / 测试）直接调用这个方法时必须自己拦住。
    A2PrimaryButton *gated = [self gatedButton];
    if (gated == self.primaryButton && !self.gatedButtonEnabled) return;
    if (self.onPrimary) self.onPrimary();
}

- (void)handleSecondary {
    A2PrimaryButton *gated = [self gatedButton];
    if (gated == self.secondaryButton && !self.gatedButtonEnabled) return;
    if (self.onSecondary) self.onSecondary();
}

#pragma mark 倒计时

- (NSString *)countdownTextWithRemaining:(NSTimeInterval)remaining {
    NSInteger seconds = (NSInteger)ceil(remaining);
    if (seconds < 0) seconds = 0;
    return [NSString stringWithFormat:@"%@（%ld）", (self.promptText ?: @""), (long)seconds];
}

- (void)startCountdownIfNeeded {
    if (self.promptText.length == 0) return;
    if (self.gatedButtonEnabled) return;
    self.remainingSeconds = A2PluginCriticalCountdownSeconds;
    [self setGatedButtonEnabled:NO];
    [self updateCountdownLabel];
    [self scheduleCountdownTimer];
}

- (void)scheduleCountdownTimer {
    [self stopCountdownTimer];
    // 单调时钟：改系统时间不会让 5 秒变成 5 毫秒（§3.3 计时源那一行）。
    self.lastTickTime = CACurrentMediaTime();
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1
                                             target:self
                                           selector:@selector(handleCountdownTick:)
                                           userInfo:nil
                                            repeats:YES];
    self.countdownTimer = timer;
    // CommonModes：滚动正文（或分屏拖动）时计时继续走，旋转也不重置。
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)stopCountdownTimer {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
}

- (void)handleCountdownTick:(NSTimer *)timer {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval delta = now - self.lastTickTime;
    self.lastTickTime = now;
    if (delta < 0) delta = 0;   // 单调时钟不该出现，出现也只当作 0
    self.remainingSeconds = MAX(0.0, self.remainingSeconds - delta);
    [self updateCountdownLabel];
    if (self.remainingSeconds <= 0.0) [self finishCountdown];
}

- (void)updateCountdownLabel {
    if (self.promptText.length == 0) return;
    if (self.gatedButtonEnabled) {
        self.countdownLabel.text = @"现在可以继续";
        return;
    }
    self.countdownLabel.text = [self countdownTextWithRemaining:self.remainingSeconds];
}

- (void)finishCountdown {
    [self stopCountdownTimer];
    self.remainingSeconds = 0;
    [self setGatedButtonEnabled:YES];
    [self updateCountdownLabel];
    // 读屏用户看不到按钮「变亮」，必须主动说出来。
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                    @"倒计时结束，现在可以继续");
}

- (void)handleWillResignActive:(NSNotification *)notification {
    if (!self.countdownTimer) return;
    // 进后台就停表。不清零 remaining 也不补算 —— 回前台时整体重置（见下）。
    [self stopCountdownTimer];
    self.countdownSuspended = YES;
}

- (void)handleDidBecomeActive:(NSNotification *)notification {
    if (!self.countdownSuspended) return;
    self.countdownSuspended = NO;
    if (self.gatedButtonEnabled) return;
    // §3.3：回前台重新计满 5 秒 —— 不允许「后台等 5 秒再回来点」。
    self.remainingSeconds = A2PluginCriticalCountdownSeconds;
    [self setGatedButtonEnabled:NO];
    [self updateCountdownLabel];
    [self scheduleCountdownTimer];
}

@end

#pragma mark - 流程

/// 三步的编号。用枚举而不是 int，是因为第 3 步的按钮语义与 1/2 完全不同 ——
/// 任何 `step == 3` 的特判都必须在编译期看得见。
typedef NS_ENUM(NSInteger, A2PluginCriticalConfirmStep) {
    A2PluginCriticalConfirmStepCapability = 1,
    A2PluginCriticalConfirmStepHarm = 2,
    A2PluginCriticalConfirmStepFinal = 3,
};

@interface A2PluginCriticalConfirmFlow ()
@property (nonatomic, strong) A2PluginManifest *manifest;
@property (nonatomic, strong) A2PluginPermissionStore *store;
@property (nonatomic, copy, nullable) NSString *packageHash;

@property (nonatomic, strong, nullable) A2PluginPermissionInfo *info;
@property (nonatomic, weak, nullable) UIViewController *presenter;
@property (nonatomic, copy, nullable) A2PluginCriticalConfirmResult completion;
@property (nonatomic, assign) A2PluginCriticalConfirmStep step;
@property (nonatomic, assign) BOOL didFinish;
@end

@implementation A2PluginCriticalConfirmFlow

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：没有 manifest / store 的流程是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithManifest:(A2PluginManifest *)manifest
                           store:(A2PluginPermissionStore *)store
                     packageHash:(nullable NSString *)packageHash {
    self = [super init];
    if (self) {
        _manifest = manifest;
        _store = store;
        _packageHash = [packageHash copy];
    }
    return self;
}

#pragma mark 日志

- (void)logLine:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [@"[A2-PLUGIN-PERM] " stringByAppendingString:message ?: @""];
    [A2Log log:@"%@", line];
}

#pragma mark 入口

- (void)runForPermission:(NSString *)permissionId
                    from:(UIViewController *)presenter
              completion:(nullable A2PluginCriticalConfirmResult)completion {
    self.completion = completion;
    self.didFinish = NO;

    A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
    if (!info) {
        NSError *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorUnknownPermission,
                                                     @"权限目录里没有「%@」", permissionId ?: @"(空)");
        [self finishWithGranted:NO error:error];
        return;
    }
    if (info.risk != A2PluginRiskCritical) {
        // 低/中权限不需要三次确认：调用方传错时立刻失败，不要静默变成一次点击授予。
        NSError *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorInvalidManifest,
                                                     @"「%@」不是高危权限，不需要三次确认", permissionId);
        [self finishWithGranted:NO error:error];
        return;
    }

    self.info = info;
    self.presenter = presenter;
    [self presentStep:A2PluginCriticalConfirmStepCapability];
}

#pragma mark 步骤推进

- (void)presentStep:(A2PluginCriticalConfirmStep)step {
    UIViewController *presenter = self.presenter;
    if (!presenter) {
        [self finishWithGranted:NO error:nil];
        return;
    }
    self.step = step;

    A2PluginCriticalConfirmPage *page = [self pageForStep:step];
    page.modalPresentationStyle = UIModalPresentationFullScreen;
    page.modalTransitionStyle = UIModalTransitionStyleCoverVertical;

    __weak typeof(self) weakSelf = self;
    page.onSecondary = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self handleSecondaryAction];
    };
    page.onPrimary = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self handlePrimaryAction];
    };

    [self logLine:@"confirm-step plugin=%@ perm=%@ step=%ld",
           self.manifest.pluginId, self.info.permissionId, (long)step];
    [presenter presentViewController:page animated:YES completion:nil];
}

- (void)handlePrimaryAction {
    if (self.step == A2PluginCriticalConfirmStepFinal) {
        // 第 3 步的主按钮是「不授权」
        [self cancelCurrentStep];
        return;
    }
    [self advanceToNextStep];
}

- (void)handleSecondaryAction {
    if (self.step == A2PluginCriticalConfirmStepFinal) {
        // 第 3 步的次按钮是「我已知晓，授权」—— 只有走到这里才写 registry
        [self grantCurrentPermission];
        return;
    }
    [self cancelCurrentStep];
}

- (void)advanceToNextStep {
    A2PluginCriticalConfirmStep next = self.step == A2PluginCriticalConfirmStepCapability
        ? A2PluginCriticalConfirmStepHarm
        : A2PluginCriticalConfirmStepFinal;
    [self dismissCurrentPageThen:^{
        [self presentStep:next];
    }];
}

- (void)cancelCurrentStep {
    [self logLine:@"confirm-cancelled plugin=%@ perm=%@ step=%ld",
           self.manifest.pluginId, self.info.permissionId, (long)self.step];
    [self dismissCurrentPageThen:^{
        [self finishWithGranted:NO error:nil];
    }];
}

- (void)grantCurrentPermission {
    NSError *error = nil;
    BOOL granted = [self.store grantCriticalPermission:self.info.permissionId
                                             forPlugin:self.manifest
                                                 error:&error];
    [self logLine:@"confirm-granted=%@ plugin=%@ perm=%@ error=%@",
           granted ? @"1" : @"0", self.manifest.pluginId, self.info.permissionId,
           error.localizedDescription ?: @"-"];
    [self dismissCurrentPageThen:^{
        [self finishWithGranted:granted error:error];
    }];
}

- (void)dismissCurrentPageThen:(void (^)(void))continuation {
    UIViewController *presenter = self.presenter;
    if (!presenter) {
        if (continuation) continuation();
        return;
    }
    [presenter dismissViewControllerAnimated:YES completion:^{
        if (continuation) continuation();
    }];
}

- (void)finishWithGranted:(BOOL)granted error:(NSError *)error {
    if (self.didFinish) return;
    self.didFinish = YES;
    self.presenter = nil;
    A2PluginCriticalConfirmResult completion = self.completion;
    self.completion = nil;
    if (completion) completion(granted, error);
}

#pragma mark 文案

- (NSString *)hashPrefix {
    if (!self.packageHash.length) return @"（未提供）";
    NSString *value = [self.packageHash hasPrefix:@"sha256:"]
        ? [self.packageHash substringFromIndex:7] : self.packageHash;
    if (value.length <= 8) return value;
    return [value substringToIndex:8];
}

- (NSString *)stageTextForInfo:(A2PluginPermissionInfo *)info {
    // 风险级文案只从 `A2PluginRiskDisplayName` 来：确认页和授权页必须用同一个词
    // （「高危」），两处各写一遍迟早一处写成「高」一处写成「高危」。
    return [NSString stringWithFormat:@"风险级：%@ · 生效阶段：%@ 起可用",
            A2PluginRiskDisplayName(info.risk),
            A2PluginMilestoneName(info.milestone)];
}

- (NSArray<NSString *> *)alreadyGrantedCriticalConsequences {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (NSString *permissionId in self.manifest.permissions) {
        A2PluginPermissionInfo *other = A2PluginPermissionInfoForId(permissionId);
        if (other.risk != A2PluginRiskCritical) continue;
        if ([other.permissionId isEqualToString:self.info.permissionId]) continue;
        if (![self.store isGranted:permissionId forPlugin:self.manifest.pluginId]) continue;
        [items addObject:[NSString stringWithFormat:@"· %@ —— %@", other.shortName,
                          other.consequence]];
    }
    return items;
}

- (A2PluginCriticalConfirmPage *)pageForStep:(A2PluginCriticalConfirmStep)step {
    A2PluginPermissionInfo *info = self.info;
    A2PluginCriticalConfirmPage *page = [[A2PluginCriticalConfirmPage alloc] init];
    page.promptText = @"请阅读以上说明，5 秒后可继续";
    page.primaryStyle = A2ButtonStylePrimary;
    page.secondaryStyle = A2ButtonStyleSecondary;

    if (step == A2PluginCriticalConfirmStepCapability) {
        // ---- 第 1 次：这个权限能做什么 ----
        NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
        [paragraphs addObject:info.consequence];
        [paragraphs addObject:info.definition];
        [paragraphs addObject:@"允许的具体操作："];
        for (NSString *operation in info.allowedOperations) {
            [paragraphs addObject:[@"· " stringByAppendingString:operation]];
        }
        [paragraphs addObject:@"这个权限不能做什么："];
        [paragraphs addObject:info.boundary];
        [paragraphs addObject:[self stageTextForInfo:info]];

        page.headline = [NSString stringWithFormat:@"高危权限：%@", info.shortName];
        page.paragraphs = paragraphs;
        page.primaryTitle = @"继续";
        page.secondaryTitle = @"取消";
        page.gatesPrimaryButton = YES;
        return page;
    }

    if (step == A2PluginCriticalConfirmStepHarm) {
        // ---- 第 2 次：允许之后可能造成的危害 ----
        NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
        [paragraphs addObject:[NSString stringWithFormat:@"授予「%@」之后，可能发生：",
                               info.shortName]];
        for (NSString *scenario in info.harmScenarios) {
            [paragraphs addObject:[@"· " stringByAppendingString:scenario]];
        }
        [paragraphs addObject:@"如果你不确定这个插件为什么需要它，请取消。"];

        page.headline = [NSString stringWithFormat:@"再确认：%@可能造成什么", info.shortName];
        page.paragraphs = paragraphs;
        page.primaryTitle = @"继续";
        page.secondaryTitle = @"取消";
        page.gatesPrimaryButton = YES;
        return page;
    }

    // ---- 第 3 次：最终确认 ----
    NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
    [paragraphs addObject:[NSString stringWithFormat:@"权限：%@", info.permissionId]];
    [paragraphs addObject:[NSString stringWithFormat:@"插件：%@（%@）",
                           self.manifest.name, self.manifest.pluginId]];
    [paragraphs addObject:[NSString stringWithFormat:@"包哈希：%@…", [self hashPrefix]]];

    NSArray<NSString *> *others = [self alreadyGrantedCriticalConsequences];
    if (others.count) {
        [paragraphs addObject:@"本次已经授权的其它高危权限："];
        [paragraphs addObjectsFromArray:others];
    } else {
        [paragraphs addObject:@"本次还没有授权其它高危权限。"];
    }

    [paragraphs addObject:@"授权后，插件可以在你不知情的情况下执行上述操作。"];
    [paragraphs addObject:@"这项授权绑定的是「权限」本身：插件更新内容但权限不变时，"
                          "不会再问你；一旦新增或变更高危权限、或跨大版本升级，会重新向你确认。"];

    page.headline = [NSString stringWithFormat:@"最后确认：授予 %@？", info.shortName];
    page.paragraphs = paragraphs;
    // 第 3 次的主按钮是「不授权」（默认高亮），「授权」是次要按钮且受倒计时约束。
    page.primaryTitle = @"不授权";
    page.secondaryTitle = @"我已知晓，授权";
    page.promptText = @"请阅读以上说明，5 秒后可授权";
    page.gatesPrimaryButton = NO;
    return page;
}

@end

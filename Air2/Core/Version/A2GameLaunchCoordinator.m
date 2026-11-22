//
//  A2GameLaunchCoordinator.m
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
//  启动编排器的实现。结构说明见头文件。
//
//  ## 线程模型（为什么可以阻塞执行队列）
//
//    A2TaskFlowExecutor 在私有串行队列上调用 -[A2Task runWithContext:]。
//    账号续期 / 完整性校验 / 批量下载都是异步回调，所以任务体用信号量
//    等待回调，而不是把异步链拆成多个任务 —— 任务体阻塞的是执行队列，
//    不是主线程。所有 completion 都回到主线程，主线程始终可响应 UI。
//
//    取消通过轮询 context.isCancelled（100ms 一次）实现；对 A2IntegrityRepairer
//    与 A2GameInstaller 会额外调用它们的 cancel，让批量下载尽快停下。
//
//  ## 失败分类（对照 ZL2 GameLaunchFlow.kt 第 68~79、144~155 行）
//
//    账号 401/403 → ReloginRequired（引导重新登录）
//    账号其它    → CheckFailed（可重试）
//    文件问题    → FileIntegrity（带文件/地址；能补则补，不能补就提示重装）
//    渲染器      → RendererUnsupported（引导切换渲染器）
//    JRE         → NoJRE（引导检查 Java 运行时）
//
//  每条失败都由 A2LaunchDiagnostics 组装，字段固定，UI 不用再猜。
//

#import "A2GameLaunchCoordinator.h"

#import "A2TaskFlowExecutor.h"
#import "A2TaskFlowSnapshot.h"
#import "A2TaskPhase.h"
#import "A2Task.h"
#import "A2TaskContext.h"

#import "A2LaunchPrecheck.h"

#import "A2IntegrityChecker.h"
#import "A2IntegrityRepairer.h"
#import "A2GameInstaller.h"
#import "A2DownloadEngine.h"
#import "A2MirrorResolver.h"
#import "A2JREManager.h"
#import "A2AccountManager.h"
#import "A2Logger.h"

NSNotificationName const A2LaunchProgressDidChangeNotification = @"A2LaunchProgressDidChangeNotification";

/// 任务清单固定 6 项。与 A2LaunchStepTitle / A2LaunchKindForStep 一一对应。
static const NSInteger kA2LaunchStepCount = 6;

/// 各步骤的等待上限。超时按「可重试」失败处理，避免 UI 永远卡住。
static const NSTimeInterval kA2AccountTimeout = 60.0;
static const NSTimeInterval kA2IntegrityCheckTimeout = 30.0 * 60.0;
static const NSTimeInterval kA2IntegrityRepairTimeout = 45.0 * 60.0;
static const NSTimeInterval kA2LoggingConfigTimeout = 120.0;
static const NSTimeInterval kA2ReinstallTimeout = 30.0 * 60.0;

static NSString *A2LaunchStepTitle(NSInteger index) {
    switch (index) {
        case 0: return @"校验账号";
        case 1: return @"扫描模组";
        case 2: return @"检查渲染器";
        case 3: return @"解析版本清单";
        case 4: return @"校验并修复文件";
        case 5: return @"启动游戏";
        default: return @"启动检查";
    }
}

/// 粗分类映射：UI 仍按旧的 A2LaunchTask 决定小卡片标题/阶段文案。
static A2LaunchTask A2LaunchKindForStep(NSInteger index) {
    switch (index) {
        case 0: return A2LaunchTaskCheckAccount;
        case 1:
        case 2:
        case 3: return A2LaunchTaskScanMods;
        case 4: return A2LaunchTaskVerifyFiles;
        default: return A2LaunchTaskStartGame;
    }
}

/// 任务正常返回但语义上是「跳过」：UI 的清单要显示灰色，不是绿色完成。
static BOOL A2LaunchDetailIsSkip(NSString *detail) {
    if (![detail isKindOfClass:NSString.class] || detail.length == 0) return NO;
    return [detail containsString:@"已跳过"] ||
           [detail containsString:@"无需校验"] ||
           [detail containsString:@"未选择账号"];
}

#pragma mark - 任务清单项

@interface A2LaunchStep ()
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, assign, readwrite) A2LaunchStepState state;
@property (nonatomic, copy, readwrite, nullable) NSString *detail;
@property (nonatomic, strong, readwrite, nullable) NSError *error;
@property (nonatomic, assign, readwrite, getter=isRetryable) BOOL retryable;
@end

@implementation A2LaunchStep
@end

@implementation A2LaunchProgress

- (instancetype)init {
    self = [super init];
    if (self) {
        _stepIndex = -1;
        _stepCount = 0;
        _stepState = A2LaunchStepStatePending;
        _title = @"";
        _message = @"";
    }
    return self;
}

@end

#pragma mark - 协调器

@interface A2GameLaunchCoordinator () {
    NSLock *_lock;
    NSArray<A2LaunchStep *> *_stepsSnapshot;
    NSError *_pendingError;
}

@property (nonatomic, assign, readwrite, getter=isLaunching) BOOL launching;
@property (nonatomic, assign, readwrite) A2LaunchTask currentTask;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL skipAccountRefresh;
@property (nonatomic, assign) BOOL skipIntegrityCheck;

@property (nonatomic, strong, nullable) A2Version *version;
@property (nonatomic, copy, nullable) NSString *gameHome;
@property (nonatomic, strong, nullable) A2LaunchEnvReport *env;
@property (nonatomic, strong, nullable) A2TaskFlowExecutor *executor;
@property (nonatomic, copy, nullable) NSArray<A2Task *> *tasks;
@property (nonatomic, copy, nullable) void (^finalCompletion)(BOOL, NSError *);
@property (nonatomic, strong, nullable) A2IntegrityRepairer *activeRepairer;
@property (nonatomic, strong, nullable) A2GameInstaller *activeInstaller;
/// 最近一次失败的完整诊断（含 file/url/retryable）。
/// 自定义 getter/setter 加锁，因为任务线程写、主线程读。
@property (nonatomic, strong, nullable) NSError *pendingError;

@end

@implementation A2GameLaunchCoordinator

+ (instancetype)shared {
    static A2GameLaunchCoordinator *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2GameLaunchCoordinator alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _stepsSnapshot = @[];
        _currentTask = A2LaunchTaskCheckAccount;
    }
    return self;
}

#pragma mark - 观察

- (NSArray<A2LaunchStep *> *)steps {
    [_lock lock];
    NSArray<A2LaunchStep *> *snapshot = _stepsSnapshot;
    [_lock unlock];
    return snapshot;
}

- (NSError *)lastError {
    [_lock lock];
    NSError *error = _pendingError;
    [_lock unlock];
    return error;
}

- (void)setPendingError:(NSError *)error {
    [_lock lock];
    _pendingError = error;
    [_lock unlock];
}

- (NSError *)pendingError {
    [_lock lock];
    NSError *error = _pendingError;
    [_lock unlock];
    return error;
}

/// 由任务对象生成一份不可变清单。每次状态变化都重建，读取方不需要加锁
/// 也不需要担心对象在别的线程被改。
- (NSArray<A2LaunchStep *> *)buildStepsFromTasks:(NSArray<A2Task *> *)tasks {
    NSMutableArray<A2LaunchStep *> *steps = [NSMutableArray arrayWithCapacity:tasks.count];
    NSError *failure = self.pendingError;

    for (NSInteger i = 0; i < (NSInteger)tasks.count; i++) {
        A2Task *task = tasks[(NSUInteger)i];
        A2LaunchStep *step = [A2LaunchStep new];
        step.title = task.title.length ? task.title : A2LaunchStepTitle(i);
        step.detail = task.detail;

        switch (task.stage) {
            case A2TaskStagePending:
                step.state = A2LaunchStepStatePending;
                break;
            case A2TaskStageRunning:
                step.state = A2LaunchStepStateRunning;
                break;
            case A2TaskStageSuccess:
                step.state = A2LaunchDetailIsSkip(task.detail)
                             ? A2LaunchStepStateSkipped
                             : A2LaunchStepStateDone;
                break;
            case A2TaskStageFailed:
                step.state = A2LaunchStepStateFailed;
                step.error = failure;
                step.retryable = A2LaunchErrorIsRetryable(failure);
                break;
            case A2TaskStageCancelled:
                step.state = A2LaunchStepStateSkipped;
                break;
        }
        [steps addObject:step];
    }
    return steps;
}

- (NSArray<A2LaunchStep *> *)publishStepsFromTasks:(NSArray<A2Task *> *)tasks {
    NSArray<A2LaunchStep *> *steps = tasks.count ? [self buildStepsFromTasks:tasks] : @[];
    [_lock lock];
    _stepsSnapshot = steps;
    [_lock unlock];
    return steps;
}

#pragma mark - 启动入口

- (void)launchVersion:(NSString *)versionName
   skipAccountRefresh:(BOOL)skipAccountRefresh
  skipIntegrityCheck:(BOOL)skipIntegrityCheck
           completion:(void (^)(BOOL, NSError *))completion {

    if (self.launching) {
        if (completion) {
            completion(NO, A2LaunchDiagnose(A2LaunchErrorKindUnknown,
                                            @"启动检查",
                                            @"已有启动流程在进行。",
                                            nil, nil, NO));
        }
        return;
    }

    A2Version *version = nil;
    for (A2Version *candidate in A2VersionManager.shared.versions) {
        if ([candidate.name isEqualToString:versionName]) { version = candidate; break; }
    }
    if (!version) {
        if (completion) {
            completion(NO, A2LaunchDiagnose(A2LaunchErrorKindUnknown,
                                            @"启动检查",
                                            [NSString stringWithFormat:@"找不到版本「%@」。", versionName ?: @""],
                                            nil, nil, NO));
        }
        return;
    }

    self.launching = YES;
    self.cancelled = NO;
    self.skipAccountRefresh = skipAccountRefresh;
    self.skipIntegrityCheck = skipIntegrityCheck;
    self.version = version;
    self.gameHome = version.gameHome;
    self.env = [A2LaunchEnvReport new];
    self.finalCompletion = completion;
    [self setPendingError:nil];

    NSArray<A2Task *> *tasks = [self buildTasks];
    self.tasks = tasks;
    [self publishStepsFromTasks:tasks];

    A2TaskPhase *phase = [A2TaskPhase phaseWithTitle:@"启动检查"];
    for (A2Task *task in tasks) {
        [phase addTask:task];
    }

    A2TaskFlowExecutor *executor = [A2TaskFlowExecutor new];
    self.executor = executor;

    __weak typeof(self) weakSelf = self;
    executor.changeHandler = ^(A2TaskFlowSnapshot *snapshot) {
        [weakSelf handleFlowChange:snapshot];
    };

    [executor addPhase:phase];

    BOOL started = [executor startWithCompletion:^(A2TaskFlowResult result, NSError *error) {
        [weakSelf handleFlowCompletion:result error:error];
    }];

    if (!started) {
        [self finishBeforeStartWithError:A2LaunchDiagnose(A2LaunchErrorKindUnknown,
                                                          @"启动检查",
                                                          @"任务流未能启动（可能已在运行）。",
                                                          nil, nil, NO)];
        return;
    }

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:
                    @"启动检查开始：%@（跳过账号=%d，跳过校验=%d）",
                    version.name, skipAccountRefresh, skipIntegrityCheck]];
}

- (NSArray<A2Task *> *)buildTasks {
    NSMutableArray<A2Task *> *tasks = [NSMutableArray arrayWithCapacity:kA2LaunchStepCount];

    for (NSInteger i = 0; i < kA2LaunchStepCount; i++) {
        A2Task *task = [A2Task taskWithTitle:A2LaunchStepTitle(i)];
        __weak typeof(self) weakSelf = self;
        task.action = ^(A2Task *currentTask, A2TaskContext *context) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                currentTask.stage = A2TaskStageFailed;
                currentTask.detail = @"启动协调器已释放";
                return;
            }
            [self runStep:i task:currentTask context:context];
        };
        [tasks addObject:task];
    }
    return tasks;
}

#pragma mark - 任务体

- (void)runStep:(NSInteger)index task:(A2Task *)task context:(A2TaskContext *)context {
    if (context.isCancelled) {
        task.stage = A2TaskStageCancelled;
        return;
    }

    switch (index) {
        case 0: [self stepCheckAccount:task context:context]; break;
        case 1: [self stepScanMods:task context:context]; break;
        case 2: [self stepCheckRenderer:task context:context]; break;
        case 3: [self stepParseManifest:task context:context]; break;
        case 4: [self stepVerifyAndRepair:task context:context]; break;
        case 5: [self stepStartGame:task context:context]; break;
        default: break;
    }
}

- (void)failTask:(A2Task *)task error:(NSError *)error {
    NSString *reason = error.userInfo[A2LaunchErrorReasonKey];
    task.stage = A2TaskStageFailed;
    task.detail = reason.length ? reason : error.localizedDescription;
    [self setPendingError:error];

    [A2Logger error:@"Launch"
            message:[NSString stringWithFormat:@"%@：%@",
                     error.userInfo[A2LaunchErrorStepKey] ?: task.title,
                     reason ?: @"未知原因"]];
}

/// 等待异步回调，同时保持取消响应。
/// @return YES = 已等到；NO = 被取消或超时（调用方再用 context.isCancelled 区分）
- (BOOL)waitForSemaphore:(dispatch_semaphore_t)sem
                 context:(A2TaskContext *)context
                 timeout:(NSTimeInterval)timeout {
    NSDate *start = [NSDate date];

    while (YES) {
        if (context.isCancelled) return NO;

        dispatch_time_t slice = dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)(0.1 * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(sem, slice) == 0) return YES;

        if (timeout > 0 && [[NSDate date] timeIntervalSinceDate:start] >= timeout) {
            return NO;
        }
    }
}

#pragma mark 1. 账号

/// 对照 ZL2 GameLaunchFlow.kt 第 187~209 行：
///   有网 && !skipAccountRefresh && AccountsManager.isLaunchCheckNeeded(account)
/// ZL2 还会在无网时把非本地账号当离线账号启动；Air2 没有
/// offlineAccountLogin 这个开关，所以无网时只按账号续期失败如实报错。
- (void)stepCheckAccount:(A2Task *)task context:(A2TaskContext *)context {
    if (self.skipAccountRefresh) {
        [context updateProgress:1.0 detail:@"已跳过账号校验（用户选择）"];
        return;
    }

    A2Account *account = A2AccountManager.shared.currentAccount;
    if (!account) {
        // 旧协调器允许无账号直接启动（JVM 侧用默认玩家名），保持兼容。
        [context updateProgress:1.0 detail:@"未选择账号，按离线模式继续"];
        return;
    }
    if (account.type == A2AccountTypeOffline) {
        [context updateProgress:1.0 detail:@"离线账号，无需校验"];
        return;
    }

    [context updateProgress:0.2
                     detail:[NSString stringWithFormat:@"正在校验 %@…", account.username ?: @""]];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *refreshError = nil;

    [A2AccountManager.shared refreshCurrentAccountIfNeeded:^(BOOL success, NSError *error) {
        ok = success;
        refreshError = error;
        dispatch_semaphore_signal(sem);
    }];

    if (![self waitForSemaphore:sem context:context timeout:kA2AccountTimeout]) {
        if (context.isCancelled) {
            task.stage = A2TaskStageCancelled;
            return;
        }
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindCheckFailed,
                                        @"校验账号",
                                        @"账号校验收不到服务器响应（超时 60 秒）。检查网络后重试。",
                                        nil, nil, YES)];
        return;
    }

    if (!ok) {
        BOOL relogin = (refreshError.code == 401 || refreshError.code == 403);
        NSString *reason = relogin
            ? @"登录凭据已失效，请重新登录该账号。"
            : [NSString stringWithFormat:@"账号校验失败：%@",
               refreshError.localizedDescription ?: @"网络或认证服务器异常"];

        [self failTask:task
                 error:A2LaunchDiagnose(relogin ? A2LaunchErrorKindReloginRequired
                                                : A2LaunchErrorKindCheckFailed,
                                        @"校验账号",
                                        reason,
                                        nil, nil,
                                        relogin ? NO : YES)];
        return;
    }

    [context updateProgress:1.0 detail:@"账号有效"];
}

#pragma mark 2. 扫描模组

- (void)stepScanMods:(A2Task *)task context:(A2TaskContext *)context {
    [A2LaunchPrecheck scanModsForVersion:self.version report:self.env];

    NSString *detail = [NSString stringWithFormat:@"发现 %ld 个模组",
                        (long)self.env.modCount];
    if (self.env.modNames.count > 0) {
        // 只把前几个名字带给日志，任务 detail 保持一行。
        [A2Logger info:@"Launch"
               message:[NSString stringWithFormat:@"模组：%@",
                        [self.env.modNames componentsJoinedByString:@", "]]];
    }
    [context updateProgress:1.0 detail:detail];
}

#pragma mark 3. 检查渲染器

- (void)stepCheckRenderer:(A2Task *)task context:(A2TaskContext *)context {
    // 这一步在「解析版本清单」之前跑，所以不能等 env.mcVersion ——
    // 用版本管理器已经解析好的身份（对照 ZL2 checkRendererSupport：
    // version.getVersionInfo()?.minecraftVersion ?: version.getVersionName()）。
    NSString *mcVersion = self.version.versionInfo.minecraftVersion ?: self.version.name;
    self.env.mcVersion = mcVersion;

    NSError *error = nil;
    BOOL ok = [A2LaunchPrecheck checkRendererForMCVersion:mcVersion
                                                   report:self.env
                                                    error:&error];
    if (!ok) {
        [self failTask:task error:error ?: A2LaunchDiagnose(A2LaunchErrorKindRendererUnsupported,
                                                            @"检查渲染器",
                                                            @"渲染器检查失败",
                                                            nil, nil, NO)];
        return;
    }

    [context updateProgress:1.0
                     detail:[NSString stringWithFormat:@"%@ 可用",
                             self.env.rendererName ?: @"渲染器"]];
}

#pragma mark 4. 解析版本清单

- (void)stepParseManifest:(A2Task *)task context:(A2TaskContext *)context {
    NSError *error = nil;
    NSDictionary *manifest = [A2LaunchPrecheck parseManifestForVersion:self.version
                                                                report:self.env
                                                                 error:&error];
    if (!manifest) {
        [self failTask:task error:error ?: A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                                            @"解析版本清单",
                                                            @"版本清单解析失败",
                                                            nil, nil, NO)];
        return;
    }

    [context updateProgress:1.0
                     detail:[NSString stringWithFormat:@"Minecraft %@，继承链就绪",
                             self.env.mcVersion ?: @"?"]];
}

#pragma mark 5. 校验并修复

- (void)stepVerifyAndRepair:(A2Task *)task context:(A2TaskContext *)context {
    if (self.skipIntegrityCheck) {
        [context updateProgress:1.0 detail:@"已跳过文件校验（用户设置）"];
        return;
    }

    NSString *versionName = self.version.name;
    NSString *gameHome = self.gameHome;
    A2IntegrityCheckMode mode = A2IntegrityCheckModeQuick;
    A2IntegrityScope scope = A2IntegrityScopeAll;

    [context updateProgress:0.02 detail:@"正在校验游戏文件…"];

    // ---- 先校验 ----
    dispatch_semaphore_t checkSem = dispatch_semaphore_create(0);
    __block A2IntegrityReport *report = nil;

    [[A2IntegrityChecker new] verifyVersion:versionName
                                  gameHome:gameHome
                                      mode:mode
                                     scope:scope
                                  progress:^(double progress, NSString *currentFile) {
        double fraction = 0.03 + MAX(0.0, MIN(1.0, progress)) * 0.22;
        NSString *detail = currentFile.length
            ? [NSString stringWithFormat:@"检查 %@", currentFile]
            : @"正在校验游戏文件…";
        [context updateProgress:fraction detail:detail];
    }
                                completion:^(A2IntegrityReport *result) {
        report = result;
        dispatch_semaphore_signal(checkSem);
    }];

    if (![self waitForSemaphore:checkSem context:context timeout:kA2IntegrityCheckTimeout]) {
        if (context.isCancelled) {
            task.stage = A2TaskStageCancelled;
            return;
        }
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        @"文件校验超时（30 分钟）。可能是资源文件太多或存储读取异常。",
                                        nil, nil, YES)];
        return;
    }

    if (!report) {
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        @"校验器没有返回报告。",
                                        nil, nil, YES)];
        return;
    }

    if (report.clean && !report.chainBroken) {
        [A2Logger info:@"Launch" message:[NSString stringWithFormat:@"文件完整：%@",
                                          [report summaryText]]];
        [context updateProgress:0.92 detail:@"文件完整"];
        [self ensureLoggingConfigWithContext:context task:task];
        return;
    }

    [context updateProgress:0.25
                     detail:[NSString stringWithFormat:@"发现 %ld 个问题，准备修复…",
                             (long)report.issues.count]];

    // ---- 逐项修复（只补缺失/损坏，不重建版本） ----
    dispatch_semaphore_t repairSem = dispatch_semaphore_create(0);
    __block A2IntegrityRepairResult *repairResult = nil;

    A2IntegrityRepairer *repairer = [A2IntegrityRepairer new];
    self.activeRepairer = repairer;

    [repairer repairReport:report
                  gameHome:gameHome
                verifyMode:mode
                     scope:scope
                  progress:^(A2IntegrityRepairPhase phase, double fraction, NSString *message) {
        double start = (phase == A2IntegrityRepairPhaseVerify) ? 0.88 : 0.25;
        double span = (phase == A2IntegrityRepairPhaseVerify) ? 0.10 : 0.63;
        [context updateProgress:start + MAX(0.0, MIN(1.0, fraction)) * span
                         detail:message.length ? message : @"正在修复文件…"];
    }
                completion:^(A2IntegrityRepairResult *result) {
        repairResult = result;
        dispatch_semaphore_signal(repairSem);
    }];

    if (![self waitForSemaphore:repairSem context:context timeout:kA2IntegrityRepairTimeout]) {
        if (context.isCancelled) {
            [repairer cancel];
            task.stage = A2TaskStageCancelled;
            self.activeRepairer = nil;
            return;
        }
        [repairer cancel];
        self.activeRepairer = nil;
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        @"文件修复超时（45 分钟）。检查网络后重试，或重新安装该版本。",
                                        nil, nil, YES)];
        return;
    }

    self.activeRepairer = nil;

    if (context.isCancelled) {
        task.stage = A2TaskStageCancelled;
        return;
    }

    // ---- 分类失败 ----
    if (repairResult.failuresByPath.count > 0) {
        NSString *firstPath = repairResult.failuresByPath.allKeys.firstObject;
        NSError *fileError = repairResult.failuresByPath[firstPath];
        NSDictionary *info = fileError.userInfo ?: @{};
        NSString *url = info[@"url"];
        if (![url isKindOfClass:NSString.class]) {
            url = [self downloadURLForPath:firstPath inReport:report];
        }

        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        [NSString stringWithFormat:
                                         @"补下载失败（%@）。可重试；若多次失败请换镜像或检查网络。",
                                         fileError.localizedDescription ?: @"未知原因"],
                                        firstPath, url, YES)];
        return;
    }

    if (!repairResult.clean) {
        A2IntegrityIssue *issue = repairResult.unrepairableIssues.firstObject
                                ?: repairResult.remainingIssues.firstObject;

        // 版本 JSON（尤其是父版本）坏了可以重装原版基底补回来；
        // 加载器自己的 json 坏了重装原版救不回来，直接如实报。
        NSError *override = nil;
        BOOL reinstalled = [self attemptBaseReinstallForIssue:issue
                                                      context:context
                                              failureOverride:&override];
        if (context.isCancelled) {
            task.stage = A2TaskStageCancelled;
            return;
        }

        if (reinstalled) {
            [context updateProgress:0.95 detail:@"已重装原版基底并复检通过"];
        } else if (override) {
            [self failTask:task error:override];
            return;
        } else if (issue) {
            [self failTask:task error:[self diagnoseIssue:issue step:@"校验并修复文件"]];
            return;
        } else {
            [self failTask:task
                     error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                            @"校验并修复文件",
                                            @"修复后仍有问题，但修复器没有给出具体项。",
                                            nil, nil, NO)];
            return;
        }
    }

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"文件修复完成：%@",
                    [repairResult summaryText]]];
    [context updateProgress:0.95 detail:@"游戏文件已修复"];
    [self ensureLoggingConfigWithContext:context task:task];
}

/// 从原报告里找某个路径对应的下载地址 —— 失败透传只给了 path，
/// 诊断里要带上 URL 才能判断是镜像问题还是源站问题。
- (NSString *)downloadURLForPath:(NSString *)path inReport:(A2IntegrityReport *)report {
    if (!path.length || !report) return nil;
    for (A2IntegrityIssue *issue in report.issues) {
        if ([issue.path isEqualToString:path]) {
            return issue.downloadURLs.firstObject;
        }
    }
    return nil;
}

- (NSError *)diagnoseIssue:(A2IntegrityIssue *)issue step:(NSString *)step {
    if (!issue) {
        return A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity, step,
                                @"文件不完整，但修复器没有返回具体原因。",
                                nil, nil, NO);
    }

    NSMutableString *reason = [NSMutableString string];
    switch (issue.reasonKind) {
        case A2IntegrityReasonMissing:
            [reason appendString:@"文件缺失"];
            break;
        case A2IntegrityReasonSizeMismatch:
            [reason appendFormat:@"大小不符（期望 %lld，实际 %lld）",
             issue.expectedSize, issue.actualSize];
            break;
        case A2IntegrityReasonSHA1Mismatch:
            [reason appendFormat:@"内容损坏（SHA1 不符，期望 %@）",
             issue.expectedSHA1.length ? issue.expectedSHA1 : @"未知"];
            break;
        case A2IntegrityReasonParentMissing:
            [reason appendString:@"父版本 JSON 缺失（继承链断开）"];
            break;
        case A2IntegrityReasonUnreadable:
            [reason appendString:@"无法解析（JSON 损坏或继承成环）"];
            break;
    }
    if (issue.versionID.length) {
        [reason appendFormat:@"，归属版本 %@", issue.versionID];
    }
    [reason appendString:@"。"];

    BOOL repairable = issue.downloadURLs.count > 0 &&
                      (issue.reasonKind == A2IntegrityReasonMissing ||
                       issue.reasonKind == A2IntegrityReasonSizeMismatch ||
                       issue.reasonKind == A2IntegrityReasonSHA1Mismatch);

    if (!repairable) {
        [reason appendString:@"没有可用的下载地址，需要重新安装/修改该版本。"];
    } else {
        [reason appendString:@"可重试。"];
    }

    return A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                            step,
                            reason,
                            issue.path,
                            issue.downloadURLs.firstObject,
                            repairable);
}

/// 版本 JSON 坏了时的兜底：重装原版基底（只动 versions/<mcVersion>/ 的
/// json/jar，不碰加载器版目录）。复用 A2GameInstaller 的下载与校验逻辑。
- (BOOL)attemptBaseReinstallForIssue:(A2IntegrityIssue *)issue
                             context:(A2TaskContext *)context
                     failureOverride:(NSError **)failureOverride {
    if (!issue || issue.section != A2IntegritySectionVersionJSON) return NO;

    NSString *mcVersion = self.env.mcVersion;
    if (mcVersion.length == 0) return NO;

    A2GamePath *path = [A2GamePath pathWithGameHome:self.gameHome];
    NSString *baseJSON = [path versionJSONPath:mcVersion];

    // 只有「原版基底的 json」能靠重装原版修复。
    // 加载器版自己的 json 缺失/损坏，重装原版没有用 —— 那需要重装加载器。
    // 纯原版版本（name == mcVersion）的 json 坏了，同样走重装。
    if (![issue.path isEqualToString:baseJSON]) {
        return NO;
    }

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"版本 JSON 损坏（%@），尝试重装原版基底 %@",
                    issue.path, mcVersion]];

    [context updateProgress:0.55 detail:@"正在重装原版基底…"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *installError = nil;

    A2InstallRequest *request = [A2InstallRequest new];
    request.mcVersion = mcVersion;
    request.versionName = mcVersion;
    request.loaderType = nil;
    request.loaderVersion = nil;
    request.gameHome = self.gameHome;

    A2GameInstaller *installer = [A2GameInstaller new];
    self.activeInstaller = installer;

    [installer install:request
             progress:^(A2InstallStage stage, double progress, NSString *message) {
        [context updateProgress:0.55 + MAX(0.0, MIN(1.0, progress)) * 0.25
                         detail:message.length ? message : @"正在重装原版基底…"];
    }
           completion:^(BOOL success, NSError *error) {
        ok = success;
        installError = error;
        dispatch_semaphore_signal(sem);
    }];

    if (![self waitForSemaphore:sem context:context timeout:kA2ReinstallTimeout]) {
        [installer cancel];
        self.activeInstaller = nil;
        if (context.isCancelled) return NO;
        if (failureOverride) {
            *failureOverride = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                                @"校验并修复文件",
                                                @"重装原版基底超时（30 分钟）。",
                                                baseJSON, nil, YES);
        }
        return NO;
    }

    self.activeInstaller = nil;

    if (!ok) {
        if (failureOverride) {
            *failureOverride = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                                @"校验并修复文件",
                                                [NSString stringWithFormat:@"重装原版基底失败：%@",
                                                 installError.localizedDescription ?: @"未知原因"],
                                                baseJSON, nil, YES);
        }
        return NO;
    }

    // 重装后按同一口径复检，避免「装完但还缺库」被当成成功。
    dispatch_semaphore_t verifySem = dispatch_semaphore_create(0);
    __block A2IntegrityReport *postReport = nil;

    [[A2IntegrityChecker new] verifyVersion:self.version.name
                                  gameHome:self.gameHome
                                      mode:A2IntegrityCheckModeQuick
                                     scope:A2IntegrityScopeAll
                                  progress:nil
                                completion:^(A2IntegrityReport *result) {
        postReport = result;
        dispatch_semaphore_signal(verifySem);
    }];

    if (![self waitForSemaphore:verifySem context:context timeout:kA2IntegrityCheckTimeout]) {
        if (context.isCancelled) return NO;
        if (failureOverride) {
            *failureOverride = A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                                @"校验并修复文件",
                                                @"重装后复检超时。",
                                                baseJSON, nil, YES);
        }
        return NO;
    }

    if (postReport.clean && !postReport.chainBroken) {
        [A2Logger info:@"Launch" message:@"重装原版基底后复检通过"];
        return YES;
    }

    if (failureOverride) {
        A2IntegrityIssue *remaining = postReport.issues.firstObject;
        *failureOverride = remaining
            ? [self diagnoseIssue:remaining step:@"校验并修复文件"]
            : A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                               @"校验并修复文件",
                               @"重装原版基底后复检仍不通过。",
                               baseJSON, nil, NO);
    }
    return NO;
}

#pragma mark 5.1 日志配置补齐

/// 版本 json 声明了 logging.client.file 时，把它补到 {assets}/log_configs/。
/// ZL2 的对应函数是注释掉的（BaseMinecraftDownloader.kt 第 189~199 行），
/// 这里按 Vanilla 启动器的路径约定补齐；文件很小，失败也只影响日志格式。
- (void)ensureLoggingConfigWithContext:(A2TaskContext *)context task:(A2Task *)task {
    A2LaunchEnvReport *env = self.env;
    if (env.loggingConfigURL.length == 0 || env.loggingConfigID.length == 0) {
        [context updateProgress:1.0 detail:@"文件完整"];
        return;
    }

    NSString *dest = [env loggingConfigPathForGameHome:self.gameHome];
    if (dest.length == 0) {
        [context updateProgress:1.0 detail:@"文件完整"];
        return;
    }

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:dest error:nil];
    if (attrs) {
        long long actual = [attrs[NSFileSize] longLongValue];
        if (env.loggingConfigSize <= 0 || actual == env.loggingConfigSize) {
            [context updateProgress:1.0 detail:@"文件完整（含日志配置）"];
            return;
        }
    }

    [context updateProgress:0.96 detail:@"正在补下载日志配置…"];

    NSArray<NSString *> *candidates = [[A2MirrorResolver shared]
                                       candidateURLsForURL:env.loggingConfigURL];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *string in (candidates.count ? candidates : @[env.loggingConfigURL])) {
        NSURL *url = [NSURL URLWithString:string];
        if (url) [urls addObject:url];
    }
    if (urls.count == 0) {
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        @"日志配置的下载地址无效。",
                                        dest, env.loggingConfigURL, NO)];
        return;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *downloadError = nil;

    A2DownloadRequest *request = [A2DownloadRequest new];
    request.candidateURLs = urls;
    request.destinationPath = dest;
    request.expectedSHA1 = env.loggingConfigSHA1;
    request.expectedSize = env.loggingConfigSize;
    // 日志配置不是 zip/jar，EOCD 兜底没有意义。
    request.allowZipFallbackCheck = NO;

    __block int64_t received = 0;
    [[A2DownloadEngine sharedClient] startRequest:request
        progress:^(int64_t delta, int64_t total) {
            received += delta;
            if (received < 0) received = 0;
            if (total > 0) {
                double ratio = MIN(1.0, (double)received / (double)total);
                [context updateProgress:0.96 + 0.04 * ratio
                                 detail:@"正在补下载日志配置…"];
            }
        }
        speed:nil
        completion:^(BOOL success, NSError *error) {
            ok = success;
            downloadError = error;
            dispatch_semaphore_signal(sem);
        }];

    if (![self waitForSemaphore:sem context:context timeout:kA2LoggingConfigTimeout]) {
        if (context.isCancelled) {
            task.stage = A2TaskStageCancelled;
            return;
        }
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        @"日志配置下载超时（120 秒）。",
                                        dest, env.loggingConfigURL, YES)];
        return;
    }

    if (!ok) {
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindFileIntegrity,
                                        @"校验并修复文件",
                                        [NSString stringWithFormat:@"日志配置下载失败：%@",
                                         downloadError.localizedDescription ?: @"未知原因"],
                                        dest, env.loggingConfigURL, YES)];
        return;
    }

    [context updateProgress:1.0 detail:@"文件完整（含日志配置）"];
}

#pragma mark 6. 启动

- (void)stepStartGame:(A2Task *)task context:(A2TaskContext *)context {
    NSString *mcVersion = self.env.mcVersion ?: self.version.name;
    A2JRE *jre = [A2JREManager.shared jreForVersionName:self.version.name
                                              mcVersion:mcVersion];

    if (!jre || !jre.valid) {
        NSInteger required = [A2JREManager.shared requiredJavaVersionForMC:mcVersion];
        [self failTask:task
                 error:A2LaunchDiagnose(A2LaunchErrorKindNoJRE,
                                        @"启动游戏",
                                        [NSString stringWithFormat:
                                         @"没有可用的 Java 运行时（%@ 需要 Java %ld）。"
                                         @"请到「设置 → Java 运行时」检查/重新导入。",
                                         mcVersion, (long)required],
                                        nil, nil, NO)];
        return;
    }

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"选用 Java 运行时 %@（%@）",
                    jre.displayName, jre.path]];

    // 真正的 JVM 启动由 UI 层（SurfaceViewController）执行 —— Core 不依赖 UI。
    [context updateProgress:1.0 detail:@"准备就绪，正在拉起 JVM…"];
}

#pragma mark - 任务流回调

- (void)handleFlowChange:(A2TaskFlowSnapshot *)snapshot {
    NSArray<A2Task *> *tasks = self.tasks;
    if (!snapshot || tasks.count == 0) return;

    NSInteger runningIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)tasks.count; i++) {
        if (tasks[(NSUInteger)i].stage == A2TaskStageRunning) {
            runningIndex = i;
            break;
        }
    }

    // 收尾快照里已经没有 Running 任务了；失败时把「出错的那一项」当作
    // 当前步骤展示，UI 才能看到红行和失败原因，而不是停在「准备中…」。
    NSInteger displayIndex = runningIndex;
    if (displayIndex < 0) {
        for (NSInteger i = 0; i < (NSInteger)tasks.count; i++) {
            if (tasks[(NSUInteger)i].stage == A2TaskStageFailed) {
                displayIndex = i;
                break;
            }
        }
    }

    A2LaunchTask kind = displayIndex >= 0
        ? A2LaunchKindForStep(displayIndex)
        : (snapshot.state == A2TaskFlowStateSucceeded ? A2LaunchTaskStartGame : self.currentTask);
    if (displayIndex >= 0) {
        self.currentTask = kind;
    }

    A2Task *currentTask = displayIndex >= 0 ? tasks[(NSUInteger)displayIndex] : nil;

    A2LaunchProgress *progress = [A2LaunchProgress new];
    progress.task = kind;
    progress.stepIndex = displayIndex;
    progress.stepCount = (NSInteger)tasks.count;
    progress.fraction = snapshot.totalProgress;
    progress.taskFraction = currentTask ? currentTask.progress
                                       : (snapshot.state == A2TaskFlowStateSucceeded ? 1.0 : 0.0);
    progress.title = displayIndex >= 0 ? A2LaunchStepTitle(displayIndex) : @"启动检查";
    progress.message = currentTask.detail.length
        ? currentTask.detail
        : (displayIndex >= 0 ? @"进行中…" : @"准备中…");
    progress.stepState = currentTask
        ? [self stateForTask:currentTask]
        : (snapshot.state == A2TaskFlowStateSucceeded ? A2LaunchStepStateDone
                                                      : A2LaunchStepStatePending);
    progress.failureReason = (currentTask.stage == A2TaskStageFailed)
        ? currentTask.detail : nil;
    progress.retryable = A2LaunchErrorIsRetryable(self.pendingError);

    NSArray<A2LaunchStep *> *steps = [self publishStepsFromTasks:tasks];

    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:A2LaunchProgressDidChangeNotification
                          object:nil
                        userInfo:@{@"progress": progress, @"steps": steps}];
    };
    if ([NSThread isMainThread]) {
        post();
    } else {
        dispatch_async(dispatch_get_main_queue(), post);
    }
}

- (A2LaunchStepState)stateForTask:(A2Task *)task {
    switch (task.stage) {
        case A2TaskStagePending: return A2LaunchStepStatePending;
        case A2TaskStageRunning: return A2LaunchStepStateRunning;
        case A2TaskStageSuccess: return A2LaunchStepStateDone;
        case A2TaskStageFailed: return A2LaunchStepStateFailed;
        case A2TaskStageCancelled: return A2LaunchStepStateSkipped;
    }
    return A2LaunchStepStatePending;
}

- (void)handleFlowCompletion:(A2TaskFlowResult)result error:(NSError *)error {
    self.launching = NO;
    self.executor.changeHandler = nil;

    NSArray<A2Task *> *tasks = self.tasks;
    [self publishStepsFromTasks:tasks];

    BOOL wasCancelled = self.cancelled;
    void (^completion)(BOOL, NSError *) = self.finalCompletion;
    self.finalCompletion = nil;

    NSError *finalError = nil;
    if (result == A2TaskFlowResultFailed) {
        finalError = self.pendingError ?: error;
        if (!finalError) {
            finalError = A2LaunchDiagnose(A2LaunchErrorKindUnknown,
                                          @"启动检查",
                                          @"任务流失败，但没有收到具体原因。",
                                          nil, nil, NO);
        }
    }

    BOOL success = (result == A2TaskFlowResultSucceeded);

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"启动检查结束：%@%@",
                    success ? @"成功" : (wasCancelled ? @"已取消" : @"失败"),
                    finalError ? [NSString stringWithFormat:@"（%@）",
                                  finalError.localizedDescription] : @""]];

    // 先清掉流程对象，再回调 —— 调用方可能在回调里直接「重试」。
    [self cleanupFlow];

    if (wasCancelled) {
        // 与旧行为一致：用户主动取消不弹失败框，也不执行成功回调。
        return;
    }
    if (completion) {
        completion(success, success ? nil : finalError);
    }
}

- (void)finishBeforeStartWithError:(NSError *)error {
    self.launching = NO;
    [self setPendingError:error];

    NSArray<A2Task *> *tasks = self.tasks;
    if (tasks.count > 0) {
        A2Task *first = tasks.firstObject;
        first.stage = A2TaskStageFailed;
        first.detail = error.userInfo[A2LaunchErrorReasonKey] ?: error.localizedDescription;
    }
    [self publishStepsFromTasks:tasks];

    void (^completion)(BOOL, NSError *) = self.finalCompletion;
    self.finalCompletion = nil;
    [self cleanupFlow];
    if (completion) completion(NO, error);
}

- (void)cleanupFlow {
    self.executor = nil;
    self.tasks = nil;
    self.activeRepairer = nil;
    self.activeInstaller = nil;
    self.env = nil;
    self.gameHome = nil;
}

#pragma mark - 取消

- (void)cancel {
    if (!self.launching) return;

    self.cancelled = YES;
    [A2Logger info:@"Launch" message:@"收到取消请求"];

    [self.executor cancel];
    [self.activeRepairer cancel];
    [self.activeInstaller cancel];

    // 与旧行为一致：取消后不再回调调用方。正在等待的任务最多 100ms 后
    // 发现 context.isCancelled 并返回，执行器随后以 Cancelled 收尾。
    self.finalCompletion = nil;
}

@end

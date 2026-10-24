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
//
//  A2GameLaunchCoordinator.m
//  Air2
//

#import "A2GameLaunchCoordinator.h"
#import "A2GameInstaller.h"
#import "A2IntegrityChecker.h"
#import "A2JREManager.h"
#import "A2ResolutionManager.h"
#import "A2AccountManager.h"
#import "A2Logger.h"

NSNotificationName const A2LaunchProgressDidChangeNotification = @"A2LaunchProgressDidChangeNotification";

#pragma mark - 进度

@implementation A2LaunchProgress
@end

#pragma mark - 错误

static NSError *A2LaunchError(A2LaunchErrorKind kind, NSString *msg) {
    return [NSError errorWithDomain:@"A2LaunchCoordinator" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"启动失败",
                                      @"kind": @(kind)}];
}

#pragma mark - 协调器

@interface A2GameLaunchCoordinator ()
@property (nonatomic, assign, readwrite, getter=isLaunching) BOOL launching;
@property (nonatomic, assign, readwrite) A2LaunchTask currentTask;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong, nullable) A2Version *version;
@property (nonatomic, copy, nullable) void (^finalCompletion)(BOOL, NSError *);
/// 必须强引用 —— 安装器是异步的，局部变量会在 install: 返回后
/// 被 ARC 立即释放，下载还没跑完对象就没了。
@property (nonatomic, strong, nullable) A2GameInstaller *activeInstaller;
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

#pragma mark - 进度上报

/// 四个 Task 的权重（对照 ZL2 的观感）
///   账号 0.05 / 模组 0.05 / 校验 0.85 / 启动 0.05
static double A2TaskStartFraction(A2LaunchTask task) {
    switch (task) {
        case A2LaunchTaskCheckAccount: return 0.0;
        case A2LaunchTaskScanMods:     return 0.05;
        case A2LaunchTaskVerifyFiles:  return 0.10;
        case A2LaunchTaskStartGame:    return 0.95;
    }
    return 0;
}

static double A2TaskWeight(A2LaunchTask task) {
    switch (task) {
        case A2LaunchTaskCheckAccount: return 0.05;
        case A2LaunchTaskScanMods:     return 0.05;
        case A2LaunchTaskVerifyFiles:  return 0.85;
        case A2LaunchTaskStartGame:    return 0.05;
    }
    return 0.1;
}

- (NSString *)titleForTask:(A2LaunchTask)task {
    switch (task) {
        case A2LaunchTaskCheckAccount: return @"校验账号";
        case A2LaunchTaskScanMods:     return @"扫描模组";
        case A2LaunchTaskVerifyFiles:  return @"校验游戏文件";
        case A2LaunchTaskStartGame:    return @"启动游戏";
    }
    return @"";
}

- (void)reportTask:(A2LaunchTask)task
           fraction:(double)fraction
            message:(NSString *)message {

    self.currentTask = task;

    A2LaunchProgress *p = [A2LaunchProgress new];
    p.task = task;
    p.taskFraction = MAX(0, MIN(1, fraction));
    p.fraction = A2TaskStartFraction(task) + A2TaskWeight(task) * p.taskFraction;
    p.title = [self titleForTask:task];
    p.message = message ?: @"";

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"[%@] %.0f%% %@",
                    p.title, p.taskFraction * 100, p.message]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:A2LaunchProgressDidChangeNotification
                                                          object:nil
                                                        userInfo:@{@"progress": p}];
    });
}

#pragma mark - 主流程

- (void)launchVersion:(NSString *)versionName
   skipAccountRefresh:(BOOL)skipAccountRefresh
  skipIntegrityCheck:(BOOL)skipIntegrityCheck
           completion:(void (^)(BOOL, NSError *))completion {

    if (self.launching) {
        if (completion) completion(NO, A2LaunchError(A2LaunchErrorKindUnknown, @"已有启动流程在进行"));
        return;
    }

    A2Version *v = nil;
    for (A2Version *x in A2VersionManager.shared.versions) {
        if ([x.name isEqualToString:versionName]) { v = x; break; }
    }
    if (!v) {
        if (completion) completion(NO, A2LaunchError(A2LaunchErrorKindUnknown,
                                                     @"找不到该版本"));
        return;
    }

    self.launching = YES;
    self.cancelled = NO;
    self.version = v;
    self.finalCompletion = completion;

    // ---- Task 1：账号校验 ----
    [self runTaskCheckAccount:skipAccountRefresh then:^{
        // ---- Task 2：扫描模组 ----
        [self runTaskScanMods:^{
            // ---- Task 3：完整性校验 ----
            [self runTaskVerifyFiles:skipIntegrityCheck then:^{
                // ---- Task 4：启动 ----
                [self runTaskStartGame];
            }];
        }];
    }];
}

#pragma mark - Task 1：账号校验

/// 对照 ZL2 的 Task 1：
///   条件：有网 && !skip && 需要校验
///   微软账号：临近过期先刷新，否则 validate → 失败再 refresh
///   外置账号：validateOrRefresh → 失败则 passwordLogin
///
/// 我们的 A2AccountManager 提供了 refreshCurrentAccountIfNeeded:，
/// 它内部就是这个「需要才刷新」的语义（离线账号直接返回成功）。
/// 失败分类保留：401/403 = 凭据被拒（要重新登录），其余 = 网络问题（可重试）。
- (void)runTaskCheckAccount:(BOOL)skip then:(void (^)(void))then {

    A2Account *account = A2AccountManager.shared.currentAccount;

    if (skip || !account) {
        [self reportTask:A2LaunchTaskCheckAccount fraction:1 message:@"跳过账号校验"];
        then();
        return;
    }

    // 离线账号没有远端凭据，不需要校验
    if (account.type == A2AccountTypeOffline) {
        [self reportTask:A2LaunchTaskCheckAccount fraction:1 message:@"离线账号"];
        then();
        return;
    }

    [self reportTask:A2LaunchTaskCheckAccount fraction:0.2
             message:[NSString stringWithFormat:@"正在校验 %@", account.username ?: @""]];

    [A2AccountManager.shared refreshCurrentAccountIfNeeded:^(BOOL success, NSError *error) {
        if (self.cancelled) return;

        if (!success) {
            BOOL relogin = (error.code == 401 || error.code == 403);
            A2LaunchErrorKind kind = relogin ? A2LaunchErrorKindReloginRequired
                                             : A2LaunchErrorKindCheckFailed;
            [self failWith:A2LaunchError(kind, relogin
                ? @"登录凭据已失效，请重新登录"
                : [NSString stringWithFormat:@"账号校验失败：%@",
                   error.localizedDescription ?: @""])];
            return;
        }

        [self reportTask:A2LaunchTaskCheckAccount fraction:1 message:@"账号有效"];
        then();
    }];
}

#pragma mark - Task 2：扫描模组

/// 对照 ZL2 的 checkMods：
///   · 读 mods 目录
///   · lwjgl3ify 需要补丁 → 打补丁 → **重新检索依赖并下载**
///
/// 我们目前还没有 lwjgl3ify 补丁逻辑，但把结构留好 ——
/// 补丁一旦引入，这里的「重下依赖」不能漏。
- (void)runTaskScanMods:(void (^)(void))then {

    [self reportTask:A2LaunchTaskScanMods fraction:0 message:@"正在扫描模组…"];

    A2GamePath *path = [A2GamePath pathWithGameHome:A2VersionManager.shared.gameHome];
    NSString *modsDir = [[path gameDirectoryForVersion:self.version.name
                                                 mode:[self.version effectiveIsolationMode]]
                         stringByAppendingPathComponent:@"mods"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *files = [NSFileManager.defaultManager
                                      contentsOfDirectoryAtPath:modsDir error:nil];
        NSUInteger count = 0;
        for (NSString *f in files) {
            if ([f hasSuffix:@".jar"] || [f hasSuffix:@".disabled"]) count++;
        }

        // TODO(lwjgl3ify)：如果检测到需要打补丁的模组，
        // 在这里改 manifest 并触发依赖重检 —— 参照 ZL2 的
        // patchLwjgl3ifyIfNeeded + GameLibDownloader.schedule/download

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelled) return;
            [self reportTask:A2LaunchTaskScanMods fraction:1
                     message:[NSString stringWithFormat:@"发现 %lu 个模组", (unsigned long)count]];
            then();
        });
    });
}

#pragma mark - Task 3：完整性校验

/// 对照 ZL2 的 MinecraftDownloader(mode = VERIFY_AND_REPAIR)：
///   只读【本地已存在的】版本 json → 按 sha1/size 校验 → 缺的补下、错的删除重下
- (void)runTaskVerifyFiles:(BOOL)skip then:(void (^)(void))then {

    if (skip) {
        [self reportTask:A2LaunchTaskVerifyFiles fraction:1 message:@"跳过文件校验"];
        [self prepareJRE:then];
        return;
    }

    [self reportTask:A2LaunchTaskVerifyFiles fraction:0 message:@"正在校验游戏文件…"];

    NSString *gameHome = A2VersionManager.shared.gameHome;
    NSString *versionName = self.version.name;

    [[A2IntegrityChecker new] checkVersion:versionName
                                  gameHome:gameHome
                                      mode:A2IntegrityCheckModeQuick
                                  progress:^(double p, NSString *file) {
        // 校验只占这段时间的前 30%
        [self reportTask:A2LaunchTaskVerifyFiles fraction:p * 0.3
                 message:[NSString stringWithFormat:@"检查 %@", file]];
    }
                                completion:^(A2IntegrityReport *report) {
        if (self.cancelled) return;

        if (report.clean) {
            [self reportTask:A2LaunchTaskVerifyFiles fraction:0.3 message:@"文件完整"];
            [self prepareJRE:then];
            return;
        }

        // 有损坏/缺失 → 删损坏的，再补下载（剩余 70% 进度）
        [[A2IntegrityChecker new] repairReport:report];

        A2InstallRequest *req = [A2InstallRequest new];
        req.mcVersion = self.version.versionInfo.minecraftVersion ?: versionName;
        req.versionName = versionName;
        req.gameHome = gameHome;

        // ⚠️ 必须用属性持有：install: 是异步的，
        // 用局部变量的话方法一返回 ARC 就释放它，
        // 下载会在中途静默死掉（表现为「3 秒就报安装完成」）。
        self.activeInstaller = [[A2GameInstaller alloc] init];
        [self.activeInstaller install:req
            progress:^(A2InstallStage stage, double progress, NSString *message) {
            [self reportTask:A2LaunchTaskVerifyFiles
                    fraction:0.3 + progress * 0.7
                     message:message];
        }
            completion:^(BOOL success, NSError *error) {
            self.activeInstaller = nil;   // 完成后再释放
            if (self.cancelled) return;
            if (!success) {
                [self failWith:A2LaunchError(A2LaunchErrorKindFileIntegrity,
                    [NSString stringWithFormat:@"文件补齐失败：%@",
                     error.localizedDescription ?: @""])];
                return;
            }
            [self prepareJRE:then];
        }];
    }];
}

#pragma mark - JRE 准备（不属于 ZL2 的四个 Task，是我们特有的）

/// ZL2 的 JRE 在 APK 里按版本打包好，运行时直接选；
/// 我们打包了 4 个，需要按 MC 版本挑 —— 所以插一步。
- (void)prepareJRE:(void (^)(void))then {
    NSString *mc = self.version.versionInfo.minecraftVersion ?: self.version.name;
    A2JRE *jre = [A2JREManager.shared jreForVersionName:self.version.name mcVersion:mc];

    if (!jre || !jre.valid) {
        [self failWith:A2LaunchError(A2LaunchErrorKindNoJRE,
            [NSString stringWithFormat:@"没有可用的 Java 运行时（%@ 需要 Java %ld）。"
             @"请到 设置 → 渲染 → Java 运行时 检查",
             mc, (long)[A2JREManager.shared requiredJavaVersionForMC:mc]])];
        return;
    }

    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"选用 %@（%@）", jre.displayName, jre.path]];
    then();
}

#pragma mark - Task 4：启动

- (void)runTaskStartGame {
    [self reportTask:A2LaunchTaskStartGame fraction:0.5 message:@"正在拉起游戏…"];

    // 分辨率在 JVM 启动前应用 —— surface 创建时就能拿到对的尺寸
    CGSize rs = A2ResolutionManager.shared.renderSize;
    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"渲染分辨率 %.0fx%.0f", rs.width, rs.height]];

    // JVM 启动需要 SurfaceViewController（UI 层）——
    // Core 不依赖 UI，所以这里只把「已就绪」交给上层。
    [self reportTask:A2LaunchTaskStartGame fraction:1 message:@"准备就绪"];

    self.launching = NO;
    if (self.finalCompletion) {
        void (^cb)(BOOL, NSError *) = self.finalCompletion;
        self.finalCompletion = nil;
        cb(YES, nil);
    }
}

#pragma mark - 失败 / 取消

- (void)failWith:(NSError *)error {
    self.launching = NO;
    [self reportTask:self.currentTask fraction:0
             message:error.localizedDescription ?: @"启动失败"];

    if (self.finalCompletion) {
        void (^cb)(BOOL, NSError *) = self.finalCompletion;
        self.finalCompletion = nil;
        cb(NO, error);
    }
}

- (void)cancel {
    self.cancelled = YES;
    self.launching = NO;
    self.finalCompletion = nil;
    [A2Logger info:@"Launch" message:@"启动已取消"];
}

@end

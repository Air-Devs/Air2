//
//  A2GameLaunchCoordinator.m
//  Air2
//

#import "A2GameLaunchCoordinator.h"
#import "A2GameInstaller.h"
#import "A2JREManager.h"
#import "A2ResolutionManager.h"
#import "A2Logger.h"

NSNotificationName const A2LaunchProgressDidChangeNotification = @"A2LaunchProgressDidChangeNotification";

@implementation A2LaunchProgress
@end

@interface A2GameLaunchCoordinator ()
@property (nonatomic, assign, readwrite) A2LaunchPhase phase;
@property (nonatomic, assign, readwrite, getter=isLaunching) BOOL launching;
@property (nonatomic, assign) BOOL cancelled;
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

#pragma mark - 进度

- (void)report:(A2LaunchPhase)phase fraction:(double)fraction message:(NSString *)message {
    self.phase = phase;

    A2LaunchProgress *p = [A2LaunchProgress new];
    p.phase = phase;
    p.fraction = MAX(0, MIN(1, fraction));
    p.message = message ?: @"";

    [A2Logger info:@"Launch" message:[NSString stringWithFormat:@"[%ld] %.0f%% %@",
                                     (long)phase, p.fraction * 100, p.message]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:A2LaunchProgressDidChangeNotification
                                                          object:nil
                                                        userInfo:@{@"progress": p}];
    });
}

#pragma mark - 主流程

- (void)launchVersion:(NSString *)versionName
            skipCheck:(BOOL)skipCheck
           completion:(void (^)(BOOL, NSError *))completion {

    if (self.launching) {
        if (completion) {
            completion(NO, [self err:@"已有启动流程在进行中"]);
        }
        return;
    }

    self.launching = YES;
    self.cancelled = NO;

    A2Version *target = nil;
    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:versionName]) { target = v; break; }
    }

    if (!target) {
        self.launching = NO;
        if (completion) completion(NO, [self err:
            [NSString stringWithFormat:@"找不到版本「%@」", versionName]]);
        return;
    }

    NSString *gameHome = A2VersionManager.shared.gameHome;

    // ---- 阶段 1：完整性检查 ----
    void (^afterCheck)(void) = ^{
        [self prepareJREForVersion:target completion:completion];
    };

    if (skipCheck) {
        [self report:A2LaunchPhaseChecking fraction:1.0 message:@"跳过完整性检查"];
        afterCheck();
        return;
    }

    [self report:A2LaunchPhaseChecking fraction:0 message:@"正在检查游戏文件…"];

    [[A2IntegrityChecker new] checkVersion:versionName
                                  gameHome:gameHome
                                      mode:A2IntegrityCheckModeQuick
                                  progress:^(double progress, NSString *file) {
        [self report:A2LaunchPhaseChecking fraction:progress
             message:[NSString stringWithFormat:@"检查 %@", file]];
    }
                                completion:^(A2IntegrityReport *report) {
        if (self.cancelled) { self.launching = NO; return; }

        [A2Logger info:@"Launch"
               message:[NSString stringWithFormat:@"完整性检查：%ld/%ld 正常，%lu 个问题",
                        (long)report.okFiles, (long)report.totalFiles,
                        (unsigned long)report.issues.count]];

        if (report.clean) {
            [self report:A2LaunchPhaseChecking fraction:1 message:@"文件完整"];
            afterCheck();
            return;
        }

        // 有缺失/损坏 → 进入补全阶段
        [self repairAndContinue:report version:target completion:completion];
    }];
}

/// 补下载：先删掉损坏的，再走安装器的「只下缺的」逻辑。
- (void)repairAndContinue:(A2IntegrityReport *)report
                  version:(A2Version *)version
               completion:(void (^)(BOOL, NSError *))completion {

    [self report:A2LaunchPhaseRepairing fraction:0
         message:[NSString stringWithFormat:@"发现 %lu 个文件需要修复",
                  (unsigned long)report.issues.count]];

    // 删除损坏文件（大小不符 / SHA1 不符）。缺失的不用管。
    NSInteger removed = [[A2IntegrityChecker new] repairReport:report];
    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"删除 %ld 个损坏文件，开始补下载", (long)removed]];

    // 用安装器补齐。安装器的下载逻辑已经带 SHA1 校验，
    // 会对「已存在且正确」的文件直接跳过，所以这里不会重复下载。
    A2InstallRequest *req = [A2InstallRequest new];
    req.mcVersion = version.mcVersion ?: version.name;
    req.versionName = version.name;
    req.gameHome = A2VersionManager.shared.gameHome;

    A2GameInstaller *installer = [[A2GameInstaller alloc] init];
    [installer install:req
        progress:^(A2InstallStage stage, double progress, NSString *message) {
        // 补齐阶段的进度映射到 0.3~1.0（前三成留给检查）
        [self report:A2LaunchPhaseRepairing
            fraction:0.3 + progress * 0.7
             message:message];
    }
        completion:^(BOOL success, NSError *error) {
        if (self.cancelled) { self.launching = NO; return; }

        if (!success) {
            self.launching = NO;
            [self report:A2LaunchPhaseFailed fraction:0
                 message:[NSString stringWithFormat:@"补齐失败：%@",
                          error.localizedDescription ?: @""]];
            if (completion) completion(NO, error);
            return;
        }

        [self report:A2LaunchPhaseRepairing fraction:1 message:@"文件已补齐"];
        [self prepareJREForVersion:version completion:completion];
    }];
}

#pragma mark - 阶段 2：JRE

- (void)prepareJREForVersion:(A2Version *)version
                  completion:(void (^)(BOOL, NSError *))completion {

    [self report:A2LaunchPhasePreparingJRE fraction:0 message:@"正在准备 Java 运行时…"];

    NSString *mcVersion = version.mcVersion ?: version.name;
    A2JRE *jre = [A2JREManager.shared jreForVersionName:version.name mcVersion:mcVersion];

    if (!jre) {
        self.launching = NO;
        NSError *e = [self err:@"没有可用的 Java 运行时。请到 设置 → 渲染 → Java 运行时 检查"];
        [self report:A2LaunchPhaseFailed fraction:0 message:e.localizedDescription];
        if (completion) completion(NO, e);
        return;
    }

    if (!jre.valid) {
        self.launching = NO;
        NSError *e = [self err:[NSString stringWithFormat:@"%@ 不可用：%@",
                                jre.displayName, jre.invalidReason ?: @""]];
        [self report:A2LaunchPhaseFailed fraction:0 message:e.localizedDescription];
        if (completion) completion(NO, e);
        return;
    }

    [self report:A2LaunchPhasePreparingJRE fraction:1
         message:[NSString stringWithFormat:@"使用 %@", jre.displayName]];

    [self startGameForVersion:version jre:jre completion:completion];
}

#pragma mark - 阶段 3：拉起 JVM

- (void)startGameForVersion:(A2Version *)version
                        jre:(A2JRE *)jre
                 completion:(void (^)(BOOL, NSError *))completion {

    [self report:A2LaunchPhaseStarting fraction:0 message:@"正在启动游戏…"];

    // 应用分辨率（在 JVM 启动前设置好，surface 创建时就能用对尺寸）
    CGSize renderSize = A2ResolutionManager.shared.renderSize;
    [A2Logger info:@"Launch"
           message:[NSString stringWithFormat:@"渲染分辨率 %.0fx%.0f，JRE %@",
                    renderSize.width, renderSize.height, jre.displayName]];

    // ⚠️ JVM 启动需要 SurfaceViewController（它负责 surface 与 JVM 生命周期），
    // 那是 UI 层的类。Core 层不依赖 UI，所以这里只做「准备」，
    // 实际启动由 UI 层订阅本协调器的结果后自己调。
    //
    // 这样分层不破，并且 UI 层拿到的是一份「已校验、已补齐、
    // JRE 已选好」的干净状态 —— 它不需要重复做任何检查。
    self.launching = NO;
    [self report:A2LaunchPhaseSuccess fraction:1
         message:[NSString stringWithFormat:@"已准备就绪（%@）", jre.displayName]];

    if (completion) completion(YES, nil);
}

#pragma mark - 取消

- (void)cancel {
    self.cancelled = YES;
    self.launching = NO;
    self.phase = A2LaunchPhaseIdle;
    [self report:A2LaunchPhaseIdle fraction:0 message:@"已取消"];
}

#pragma mark - 工具

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2LaunchCoordinator" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"启动失败"}];
}

@end

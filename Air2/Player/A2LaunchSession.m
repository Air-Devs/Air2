//
//  A2LaunchSession.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  编排实现。★所有取值都在本层解析完，交给 Natives 的只有「已解析参数」★。
//

#import "A2LaunchSession.h"
#import "A2LaunchPlan.h"
#import "A2LaunchRunner.h"
#import "A2LaunchChain.h"            // ①→②→③ 的顺序与状态（★单一真相源★）
#import "A2LaunchFailure.h"          // 失败分类 / 判据行 / 用户文案（Player 纯逻辑）
#import "A2JITEnvironmentProbe.h"    // ② 真调判据（Bridge → Natives/A2JITEnvironment）
#import "A2JITScriptDelivery.h"      // ① 下发脚本（Bridge → Natives 的下发原语）
#import "A2LaunchContract.h"
#import "A2VersionManager.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2Settings.h"
#import "A2Log.h"

// ② 有界探测预算（本函数在后台队列跑；对齐 A2JITEnvironment 的建议量级）。
static const NSTimeInterval A2LaunchJITVerifyBudget = 3.0;

@interface A2LaunchSessionResult ()

@property (nonatomic, assign, readwrite) BOOL started;
@property (nonatomic, assign, readwrite) NSInteger returnCode;
@property (nonatomic, copy, readwrite) NSString *message;

@end

@implementation A2LaunchSessionResult

+ (instancetype)resultWithStarted:(BOOL)started
                       returnCode:(NSInteger)returnCode
                          message:(NSString *)message {
    A2LaunchSessionResult *r = [[A2LaunchSessionResult alloc] init];
    r.started = started;
    r.returnCode = returnCode;
    r.message = message ?: @"";
    return r;
}

@end

// 包内首个 name 以 prefix 开头的子目录（用于 libs/lwjgl-<ver>、java_runtimes/<ver> 的版本无关解析）。
static NSString *A2LaunchFirstSubdirectory(NSString *parent, NSString *prefix) {
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:parent error:nil];
    NSArray<NSString *> *sorted = [entries sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sorted) {
        if ([name hasPrefix:prefix]) {
            BOOL isDir = NO;
            NSString *full = [parent stringByAppendingPathComponent:name];
            if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && isDir) {
                return full;
            }
        }
    }
    return nil;
}

@implementation A2LaunchSession

+ (BOOL)runtimeChainEnabled {
    return [A2LaunchRunner runtimeChainEnabled];
}

+ (void)startCurrentVersionWithCompletion:(void (^)(A2LaunchSessionResult *))completion {
    if (completion == nil) return;
    void (^finish)(BOOL, NSInteger, NSString *) = ^(BOOL started, NSInteger rc, NSString *message) {
        A2LaunchSessionResult *r = [A2LaunchSessionResult resultWithStarted:started
                                                                 returnCode:rc
                                                                    message:message];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(r); });
    };

    if (![self runtimeChainEnabled]) {
        // ★开关=关的判据行★（默认关 ⇒ 与旧版零行为差异）
        [A2Log log:@"[A2-CHAIN] 开关=关（debug.rt_p1_runtime / RT_P1_RUNTIME / 标志文件）⇒ 零副作用返回，行为与旧版一致"];
        finish(NO, 0, @"自研启动链未启用（设置 → 诊断 → 运行环境 · 启动链）");
        return;
    }
    // ★开关=开的判据行★
    [A2Log log:@"[A2-CHAIN] 开关=开 ⇒ 走自研链（① 下发 JIT 脚本 → ② 探测 JIT → ③ 建 VM）"];

    A2Version *version = A2VersionManager.shared.currentVersion;
    if (version == nil) {
        finish(NO, 0, @"还没有选中版本");
        return;
    }

    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *gameHome = A2VersionManager.shared.gameHome ?: @"";
    NSString *gameDir = version.gameDirectory ?: gameHome;
    NSString *librariesDir = [gameHome stringByAppendingPathComponent:@"libraries"];
    NSString *assetsDir = [gameHome stringByAppendingPathComponent:@"assets"];
    NSString *versionJar = [version.versionPath stringByAppendingPathComponent:
                            [version.name stringByAppendingPathExtension:@"jar"]];
    NSString *javaJarDir = [bundle stringByAppendingPathComponent:@"Java"];
    NSString *entryJar = [javaJarDir stringByAppendingPathComponent:A2LaunchJavaEntryJarName];
    NSString *patchJar = [javaJarDir stringByAppendingPathComponent:A2LaunchJavaPatchJarName];
    NSString *frameworks = [bundle stringByAppendingPathComponent:@"Frameworks"];
    NSString *lwjglDir = A2LaunchFirstSubdirectory([bundle stringByAppendingPathComponent:@"libs"],
                                                   @"lwjgl-");
    NSString *javaHome = A2LaunchFirstSubdirectory([bundle stringByAppendingPathComponent:@"java_runtimes"],
                                                   @"java-");
    NSString *userHome = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES) firstObject];
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *planPath = [gameDir stringByAppendingPathComponent:@"air2-launch-plan.json"];

    if (![NSFileManager.defaultManager fileExistsAtPath:entryJar]) {
        finish(NO, 0, [NSString stringWithFormat:@"包内缺启动核心 %@", A2LaunchJavaEntryJarName]);
        return;
    }
    if (javaHome.length == 0) {
        finish(NO, 0, @"包内没有 JVM 运行时（java_runtimes/）—— 请先跑 scripts/stage_runtime.sh 再出包");
        return;
    }
    if (lwjglDir.length == 0) {
        finish(NO, 0, @"包内没有 libs/lwjgl-<ver>/");
        return;
    }

    // 账号取值（Core/Account）⇒ 纯值字典，交给 Core/Version
    A2Account *account = A2AccountManager.shared.currentAccount;
    NSMutableDictionary<NSString *, NSString *> *accountDict = [NSMutableDictionary dictionary];
    accountDict[@"username"] = account.username ?: @"Player";
    accountDict[@"accessToken"] = account.accessToken ?: @"0";
    accountDict[@"uuid"] = account.profileID ?: @"";
    switch (account.type) {
        case A2AccountTypeMicrosoft: accountDict[@"userType"] = @"msa"; break;
        case A2AccountTypeThirdParty: accountDict[@"userType"] = @"mojang"; break;
        default: accountDict[@"userType"] = @"legacy"; break;
    }

    // 计划产出（Core/Version）
    NSError *planError = nil;
    A2LaunchPlan *plan = [A2LaunchPlan planForVersionDirectory:version.versionPath
                                                     versionID:version.name
                                                   accountDict:accountDict
                                                       gameDir:gameDir
                                                     assetsDir:assetsDir
                                                  librariesDir:librariesDir
                                                versionJarPath:versionJar
                                                         error:&planError];
    if (plan == nil) {
        finish(NO, 0, [NSString stringWithFormat:@"启动计划产出失败：%@",
                       planError.localizedDescription ?: @"(无详情)"]);
        return;
    }
    if (![plan writeToFile:planPath error:&planError]) {
        finish(NO, 0, [NSString stringWithFormat:@"启动计划写盘失败：%@",
                       planError.localizedDescription ?: @"(无详情)"]);
        return;
    }

    NSInteger memoryMB = A2Settings.shared.ramAllocationMB;
    if (memoryMB < A2SettingsMinRAMMB) memoryMB = A2SettingsMinRAMMB;
    NSArray<NSString *> *jvmOptions = [plan jvmOptionsWithMemoryMB:memoryMB];

    // 建 VM 会阻塞 ⇒ 放后台队列；结果回主线程。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ★[JIT↔VM] 启动链：① 下发脚本 → ② 探测 JIT → ③ 建 VM★
        //   ★「走到哪一步 / 为什么停」只由 chain.stage + chain.failureReason 一处持有★；
        //   JIT 是否可用只由 A2JITEnvironment.lastRegionVerdict（经 probe）一处给出。
        //   ★禁止用局部 BOOL 记 JIT 状态★（历史缺陷：早期下发路径用局部变量记「已就绪」，
        //   与探测结果不一致 ⇒ 误判；本单改用单一真相源，见 tests/JIT §⑱ 的回归断言）。
        A2JITEnvironmentProbe *probe = [[A2JITEnvironmentProbe alloc] init];
        __block int vmRC = 0;

        A2LaunchChain *chain = [A2LaunchChain
            chainWithDeliverScript:^BOOL(NSError **deliverError) {
                // ① 实现 = Bridge 的 A2JITScriptDelivery（Natives 下发原语只在 Bridge 里调）；失败【不拦路】。
                return [A2JITScriptDelivery deliverSelfContainedScriptWithError:deliverError];
            }
            verify:^BOOL(NSString **reason) {
                // ② Bridge 真调 Natives/A2JITEnvironment（brk #0x69 区域取证）。
                return [probe ensureJITUsableWithinBudget:A2LaunchJITVerifyBudget reason:reason];
            }
            createJVM:^BOOL(NSError **vmError) {
                // ③ Bridge 唯一调 a2_launch_jvm_with_argv 的地方。
                vmRC = [A2LaunchRunner launchWithPlanPath:planPath
                                             entryJarPath:entryJar
                                           patchJarPath:patchJar
                                               jvmOptions:jvmOptions
                                                 javaHome:javaHome
                                                  gameDir:gameDir
                                                 userHome:userHome
                                                   tmpDir:tmpDir
                                            librariesPath:librariesDir
                                                 lwjglDir:lwjglDir
                                           frameworksPath:frameworks];
                if (vmRC == 0) {
                    return YES;
                }
                if (vmError) {
                    *vmError = [NSError errorWithDomain:@"A2LaunchChainCreateVM"
                                                   code:vmRC
                                               userInfo:@{ NSLocalizedDescriptionKey:
                        [A2LaunchFailure userMessageForVMFailureCode:vmRC] }];
                }
                return NO;
            }];

        NSError *chainError = nil;
        if ([chain runWithError:&chainError]) {
            finish(YES, 0, @"自研链：主类 main 正常返回");
            return;
        }

        // 如实分类（按【停在哪一步】），不把推测当结论。
        A2LaunchFailureClass cls = [A2LaunchFailure classForChainStage:chain.stage];
        if (cls == A2LaunchFailureClassJITBlocked) {
            // ★JIT 不可用 ⇒ 如实阻断：打判据行 + 给「怎么开」（按 verdict 分流的四语文案）★
            A2JITReadinessVerdict verdict = probe.lastVerdict;
            [A2Log log:@"%@", [A2LaunchFailure diagnosticForJITVerdict:verdict
                                                              evidence:probe.lastEvidence]];
            finish(NO, 0, [A2LaunchFailure userMessageForJITVerdict:verdict]);
            return;
        }
        if (cls == A2LaunchFailureClassVMFailed) {
            [A2Log log:@"[A2-CHAIN] ③ 建 VM 失败 rc=%d", vmRC];
            finish(NO, vmRC, [A2LaunchFailure userMessageForVMFailureCode:vmRC]);
            return;
        }
        finish(NO, 0, chainError.localizedDescription ?: @"启动链未完成");
    });
}

@end

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
#import "A2LaunchContract.h"
#import "A2VersionManager.h"
#import "A2AccountManager.h"
#import "A2Account.h"
#import "A2Settings.h"
#import "A2Log.h"

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
        finish(NO, 0, @"自研启动链未启用（设置 → 诊断 → 运行环境 · 启动链）");
        return;
    }

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
        int rc = [A2LaunchRunner launchWithPlanPath:planPath
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
        if (rc == 0) {
            finish(YES, rc, @"自研链：主类 main 正常返回");
        } else {
            finish(NO, rc, [NSString stringWithFormat:@"自研链返回 rc=%d（见 a2_launch.h 契约）", rc]);
        }
    });
}

@end

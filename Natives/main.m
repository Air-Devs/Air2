#import <mach-o/dyld.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "customcontrols/CustomControlsUtils.h"
#import "HostManagerBridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "UIKit+hook.h"
#import "config.h"

#include <libgen.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include "utils.h"
#include "codesign.h"
#include <dlfcn.h>

#define CS_PLATFORM_BINARY 0x4000000
#define PT_TRACE_ME 0
#define PT_DETACH 11 
int ptrace(int, pid_t, caddr_t, int);
#define fm NSFileManager.defaultManager
extern char** environ;

void printEntitlementAvailability(NSString *key) {
    NSLog(@"* %@: %@", key, getEntitlementValue(key) ? @"YES" : @"NO");
}

void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"Uncaught exception: %@", exception.description);
    NSLog(@"Call stack: %@", exception.callStackSymbols);
    usleep(10000);
    handle_fatal_exit(SIGABRT);
}

bool init_checkForsubstrated() {
    // Please kindly tell pwn20wnd that he sucks
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    size_t size;
    int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
    struct kinfo_proc * process = NULL;
    struct kinfo_proc * newprocess = NULL;
    do {
        size += size / 10;
        newprocess = realloc(process, size);
        if (!newprocess){
            if (process){
                free(process);
            }
            return nil;
        }
        process = newprocess;
        st = sysctl(mib, miblen, process, &size, NULL, 0);
    } while (st == -1 && errno == ENOMEM);
    if (st == 0){
        if (size % sizeof(struct kinfo_proc) == 0){
            int nprocess = size / sizeof(struct kinfo_proc);
            if (nprocess){
                for (int i = nprocess - 1; i >= 0; i--){
                    if(strcmp(process[i].kp_proc.p_comm,"substrated") == 0) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

// ============================================================================
// ★ [ROOTHIDE] RootHide 环境探测（独立于 init_checkForJailbreak，勿混入 isJailbroken）
// ----------------------------------------------------------------------------
// RootHide 是“隐藏越狱”的 rootless 变体（Dopamine-roothide / palera1n-roothide）：
//   · 越狱根 jbroot 随机化到 /var/containers/Bundle/Application/.jbroot-<16hex>/，
//     不再用固定 /var/jb（dopamine 固定、roothide 随机化以躲检测）；每个含 Mach-O
//     的目录里放一个 .jbroot 符号链接指向 jbroot，jbroot/rootfs 才是系统根；
//   · 取消全局 dyld 补丁，改用【进程级补丁】注入 systemhook.dylib，且该文件名也被随机化；
//   · 只对“加入隐藏名单”的 App 藏越狱痕迹（路径重定向 + 进程列表隐藏）。
//
// 本文件 init_checkForJailbreak() 的三条判据在 RootHide 上全部落空：
//   · substrated 不存在（Dopamine/RootHide 用 ElleKit，不是 CydiaSubstrate）⇒ 假阴性；
//   · systemhook.dylib 名字被随机化 ⇒ strstr("/systemhook.dylib") 失配 ⇒ 假阴性；
//   · 普通 App 不是 platform binary ⇒ 假阴性（与普通无根越狱一致）；
//   只剩 opendir("/Applications") 一条，且仅在【无沙盒】安装（TrollStore/.tipa）时成立。
// ⇒ 结论：RootHide 下 isJailbroken 大概率 = false（假阴性）。这不是“没越狱”，
//   故环境分类必须单独认，不能把“检测不到 jailbreak”当“非越狱”。
//
// ⚠ 设计约束（[JB-ADAPT] 后更新）：RootHide / 越狱环境识别**只用于【选路径/选策略】**，
//   不得放宽 isJITEnabled。原实现 utils.m 的 isJITEnabled(NO) 用
//   `dynamic-codesigning || isJailbroken` 当“JIT 能力”代理，故当时刻意不把 RootHide 并入
//   isJailbroken。本轮 [JB-ADAPT] 已把 `isJailbroken` 从 isJITEnabled 的代理里移除
//   （JIT 能力只认 dynamic-codesigning entitlement / CS_DEBUGGED 这些**真实证据**），
//   越狱环境改由启动闸门走「原生 JIT + 真能力自检」（AMEJailbreakNativeJITPathApplies /
//   AMEJailbreakNativeJITReady）。因此现在把 RootHide（及其它越狱环境）正确并入
//   isJailbroken 是安全的：它只影响【选哪条策略/哪条路径】与诊断分类，不再放宽 JIT 判据。
// ============================================================================
static BOOL gAmeIsRootHide = NO;
static char gAmeRootHideJBROOT[PATH_MAX] = {0};

// 尽力解析 jbroot 的 real path（无则空串）。识别两类证据：
//   (1) 进程内已加载 roothide 注入库：镜像路径含 ".jbroot-" 或 "roothideinit.dylib"
//       ⇒ 本进程已被 roothide 接管（“隐藏名单”里的 App 也是这样被注入的）；
//   (2) 文件系统上存在 .jbroot-*：只有无沙盒进程能列 /var/containers/Bundle/Application；
//       列不到也不算失败（(1) 已足够）。
bool init_checkForRootHide(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL) continue;
        const char *mark = strstr(name, ".jbroot-");
        if (mark != NULL || strstr(name, "roothideinit.dylib") != NULL) {
            gAmeIsRootHide = YES;
            if (mark != NULL && gAmeRootHideJBROOT[0] == '\0') {
                size_t len = (size_t)(mark - name);
                if (len > 0 && len < sizeof(gAmeRootHideJBROOT)) {
                    memcpy(gAmeRootHideJBROOT, name, len);
                    gAmeRootHideJBROOT[len] = '\0';
                }
            }
        }
    }

    if (!gAmeIsRootHide) {
        const char *parent = "/var/containers/Bundle/Application";
        DIR *d = opendir(parent);
        if (d != NULL) {
            struct dirent *ent;
            while ((ent = readdir(d)) != NULL) {
                if (strncmp(ent->d_name, ".jbroot-", 8) == 0) {
                    snprintf(gAmeRootHideJBROOT, sizeof(gAmeRootHideJBROOT), "%s/%s", parent, ent->d_name);
                    gAmeIsRootHide = YES;
                    break;
                }
            }
            closedir(d);
        }
    }

    if (gAmeIsRootHide) {
        NSLog(@"[ROOTHIDE] RootHide environment detected (jbroot=%s)",
              gAmeRootHideJBROOT[0] ? gAmeRootHideJBROOT : "(unresolved)");
    } else {
        NSLog(@"[ROOTHIDE] no RootHide environment detected");
    }
    return gAmeIsRootHide;
}

bool init_checkForJailbreak() {
    if (NSProcessInfo.processInfo.macCatalystApp) {
        // macOS doesn't automatically enable JIT.
        return false;
    } else if (init_checkForsubstrated()) {
        return true;
    }

    // Check if posix_spawn is hooked
    for (int i=0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i),"/usr/lib/pspawn_payload-stg2.dylib") == 0 ||
            strstr(_dyld_get_image_name(i),"/systemhook.dylib") != NULL) {
            return true;
        }
    }

    // Check if we have platform bit set
    uint32_t flags;
    csops(0, CS_OPS_STATUS, &flags, sizeof(flags));
    if ((flags & CS_PLATFORM_BINARY) != 0) {
        return true;
    }

    // ★ [JB-ADAPT] 多证据越狱识别（修假阴性）。原 4 条判据在现代越狱上大面积漏报：
    //   · Dopamine / palera1n(rootless) / Taurine / Odyssey / RootHide 一律不用
    //     CydiaSubstrate（没有 substrated 进程）⇒ 判据①全灭；
    //   · RootHide 把 systemhook.dylib 文件名随机化 ⇒ 判据②strstr 失配；
    //   · 普通 App 不是 platform binary ⇒ 判据③只在越狱 App 身份安装时为真；
    //   · opendir("/Applications") 只与「无沙盒」相关，与是否越狱无关。
    //   这里补上「注入框架 + 越狱根 + 家族标记」三类证据（判据与来源见 utils.h
    //   [JB-ADAPT] 注释块；实现 utils.m ameJBDetectEnvironmentOnce）。命中即越狱。
    //   ⚠ 本函数的返回值 isJailbroken 只用于【选路径/选策略/诊断】，**不再**参与
    //     isJITEnabled 判定（见 utils.m isJITEnabled 的 [JB-ADAPT] 注释）。
    AMEJBEnvironment jbEnv = AMEJailbreakEnvironment();
    if (jbEnv != AMEJBEnvironmentNone) {
        NSLog(@"[JB-ADAPT] jailbreak detected via multi-evidence: env=%ld (%@)",
              (long)jbEnv, AMEJailbreakEnvSummary());
        return true;
    }

    return opendir("/Applications") != NULL;
}

void init_logDeviceAndVer(char *argument) {
    // Amethyst version
    NSLog(@"[Pre-Init] Amethyst iOS Remastered INIT!");
    NSLog(@"[Pre-Init] GitHub: https://github.com/herbrine8403/Amethyst-iOS-MyRemastered");
    NSLog(@"[Pre-Init] Please try not to post this log of the remastered launcher to the original GitHub Issues for help.");
    NSLog(@"[Pre-Init] Version: %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"], CONFIG_TYPE);
    NSLog(@"[Pre-Init] Commit: %s (%s)", CONFIG_COMMIT, CONFIG_BRANCH);
    
    // ★ [ROOTHIDE] TrollStore 标记有两个已知落点：<bundle>/../_TrollStore（TrollStore
    //   自己建）与 <bundle>/_TrollStore。RootHide 1.1.3 起“隐藏更多 jailbreak/
    //   trollstore 痕迹”，该标记对【被隐藏的 App】可能不可见 ⇒ 单靠它会把根在 RootHide
    //   上的 TrollStore 环境误判为普通越狱。这里两处都查，并把 RootHide 环境单独标出
    //   （RootHide 不并入 isJailbroken，原因见 init_checkForRootHide 顶部注释）。
    NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    BOOL hasTrollStoreMarker =
        (!access(tsPath.UTF8String, F_OK)) ||
        ([fm fileExistsAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"_TrollStore"]]);
    const char *type;
    if (gAmeIsRootHide && hasTrollStoreMarker) {
        type = "RootHide+TrollStore";
    } else if (gAmeIsRootHide) {
        type = "RootHide";
    } else if (hasTrollStoreMarker) {
        type = "TrollStore";
    } else if (isJailbroken) {
        type = "Jailbroken";
    } else {
        type = "Unjailbroken";
    }
    setenv("POJAV_DETECTEDINST", type, 1);

    if (gAmeIsRootHide) {
        // ★ [ROOTHIDE] 可辨识日志：设备跑 RootHide。越狱根是随机路径，本启动器不硬编码
        //   /var/jb（运行时一律走 POJAV_HOME/容器），故路径假设不受影响；但 TrollStore
        //   标记与 systemhook 名字被随机化会影响 isTrollStoreInstall / JIT 使能选择。
        NSLog(@"[ROOTHIDE] env class=%s jbroot=%s detectedTrollStoreMarker=%d isJailbroken=%d",
              type, gAmeRootHideJBROOT[0] ? gAmeRootHideJBROOT : "(unresolved)",
              hasTrollStoreMarker ? 1 : 0, isJailbroken ? 1 : 0);
    }
    
    NSLog(@"[Pre-Init] Device: %@", [HostManager GetModelName]);
    NSLog(@"[Pre-Init] %@ (%s)", UIDevice.currentDevice.completeOSVersion, type);
    
    NSLog(@"[Pre-init] Entitlements availability:");
    printEntitlementAvailability(@"com.apple.developer.kernel.extended-virtual-addressing");
    printEntitlementAvailability(@"com.apple.developer.kernel.increased-memory-limit");
    printEntitlementAvailability(@"com.apple.private.security.no-sandbox");
    //printEntitlementAvailability(@"dynamic-codesigning");
}

void init_redirectStdio() {
    if (getenv("LOG_TO_CONSOLE") != NULL) {
        NSLog(@"[Pre-init] LOG_TO_CONSOLE is set, not logging to latestlog.txt");
        return;
    }

    NSLog(@"[Pre-init] Starting logging STDIO to latestlog.txt\n");

    NSString *home = @(getenv("POJAV_HOME"));
    NSString *currName = [home stringByAppendingPathComponent:@"latestlog.txt"];
    NSString *oldName = [home stringByAppendingPathComponent:@"latestlog.old.txt"];

    // ★ [LOG-FIX] 每实例日志隔离：真身仍写实例目录，但 POJAV_HOME 下那两个名字
    //   改用【硬链接】（旧版是符号链接 —— 已确认会坏日志功能）。
    //   为什么 symlink 不行：iOS 文件 API 把它当独立条目 —— attributesOfItemAtPath:
    //   报 NSFileTypeSymbolicLink、NSFileSize=目标串长度（不是内容长度）；分享
    //   (UIActivityViewController)/文件 App/AFC/拷贝/第三方工具会【原样拷走链接本身】，
    //   目标一旦不在接收方沙盒就读空或断裂 ⇒ 导出/外拉全废。硬链接与真身【同一
    //   inode】：对上述一切读方与改动前的普通文件完全等价，内容实时就是当前实例那次
    //   运行，零额外写入，隔离收益（真身每实例一份）不丢。
    //   硬链接不可用（跨卷/无权限）⇒ 回退改动前的单一路径：日志可用优先于隔离。
    NSString *instLog = ameVILatestLogPath();
    NSString *instOld = ameVILatestLogRotatedPath();
    BOOL isolated = (instLog.length > 0 && instOld.length > 0);
    NSString *logTarget = currName;

    // 清理旧版（symlink 方案）残留在 POJAV_HOME 下的符号链接：removeItemAtPath: 只删
    // 链接本身，不动实例内真身；不先清掉的话，后面的 move/硬链接会落在这条链接上。
    if (ameVIPathIsSymlink(currName)) [fm removeItemAtPath:currName error:nil];
    if (ameVIPathIsSymlink(oldName))  [fm removeItemAtPath:oldName  error:nil];

    if (isolated) {
        // 一次性迁移：把旧的共享日志（普通文件）搬进本实例，保留最后一次会话。
        // 幂等：仅当实例日志尚不存在时才搬。
        if (![fm fileExistsAtPath:instLog] && [fm fileExistsAtPath:currName]) {
            [fm moveItemAtPath:currName toPath:instLog error:nil];
        }
        // 轮转真身：move 把旧 inode 留给 latestlog.old.txt，再 create 出一个全新 inode，
        // 与改动前的语义成对；随后 POJAV_HOME 下两个名字都重建硬链接。
        [fm removeItemAtPath:instOld error:nil];
        [fm moveItemAtPath:instLog toPath:instOld error:nil];
        [fm createFileAtPath:instLog contents:nil attributes:nil];

        if (ameVIHardLinkLog(instLog, currName)) {
            // .old 首次运行可能不存在 ⇒ 尽力而为，失败不影响 latestlog.txt 可用。
            if (!ameVIHardLinkLog(instOld, oldName)) {
                NSLog(@"[LOG-FIX] latestlog.old hardlink skipped/failed (non-fatal)");
            }
            NSLog(@"[LOG-FIX] per-instance log -> %@ (hardlink %@)", instLog, currName);
            logTarget = instLog;
        } else {
            // 硬链接不可用：回退改动前的共享日志，保证 POJAV_HOME/latestlog.txt 始终
            // 是普通文件、日志功能完全不受影响（代价：失去按实例隔离）。
            NSLog(@"[LOG-FIX] hardlink latestlog failed -- using shared log (isolation dropped)");
            isolated = NO;
        }
    }

    if (!isolated) {
        // 与改动前完全一致：POJAV_HOME 下直接轮转 + 新建普通文件。
        [fm removeItemAtPath:oldName error:nil];
        [fm moveItemAtPath:currName toPath:oldName error:nil];
        [fm createFileAtPath:currName contents:nil attributes:nil];
        logTarget = currName;
    }

    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:logTarget];

    if (!file) {
        NSLog(@"[Pre-init] Error: failed to open %@", logTarget);
        // ★ [DEMINE] 原为 assert(0,...)：Release 下 C assert 被 -DNDEBUG 编译掉(无效)，
        //   但 Debug 构建会在此直接 abort 整个启动；且一旦走到这里，原代码仍会把
        //   stdout/stderr 重定向进管道、由 nil 的 file 静默吞掉全部输出 —— 用户什么都
        //   看不到。这里降级为记日志并直接返回(保持 oslog 输出)，App 继续启动。
        return;
    }

    setvbuf(stdout, 0, _IOLBF, 0); // make stdout line-buffered
    setvbuf(stderr, 0, _IONBF, 0); // make stderr unbuffered

    /* create the pipe and redirect stdout and stderr */
    static int pfd[2];
    pipe(pfd);
    dup2(pfd[1], fileno(stdout));
    dup2(pfd[1], fileno(stderr));

    /* create the logging thread */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        static BOOL filteredSessionID;
        ssize_t rsize;
        char buf[2048];
        while((rsize = read(pfd[0], buf, sizeof(buf)-1)) > 0) {
            if (rsize < 2048) {
                buf[rsize] = '\0';
            }
            // Filter out Session ID here
            int index;
            if (!filteredSessionID) {
                char *sessionStr = strstr(buf, "(Session ID is ");
                if (sessionStr) {
                    char *censorStr = "(Session ID is <censored>)\n\0";
                    strcpy(sessionStr, censorStr);
                    rsize = strlen(buf);
                    filteredSessionID = true;
                }
            }
            if (canAppendToLog) {
                // canAppendToLog=YES 时，通过 appendToLog: 同时更新 UI 表格和发送通知
                [PLLogOutputView appendToLog:@(buf)];
            } else {
                // canAppendToLog=NO 时（默认状态，用户未打开日志面板），
                // PLLogOutputView 不会更新 UI，但 LanPortDetector 仍需要实时检测
                // MC "对局域网开放"端口。直接在后台线程发送通知，
                // LanPortDetector 的处理是线程安全的（processLogLine: 是无状态的，
                // setPort:source: 内部 dispatch_async 到主线程）。
                //
                // 关键修复：之前 canAppendToLog=NO 时完全不发送通知，
                // 导致 LanPortDetector 无法实时检测端口，用户先"对局域网开放"
                // 再点"当房主"时无法生成分享代码。
                NSString *logString = @(buf);
                NSArray *lines = [logString componentsSeparatedByCharactersInSet:
                    [NSCharacterSet newlineCharacterSet]];
                for (NSString *line in lines) {
                    if (line.length > 0) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"PLLogOutputLineNotification"
                                                                            object:nil
                                                                          userInfo:@{@"line": line}];
                    }
                }
            }
            [file writeData:[NSData dataWithBytes:buf length:rsize]];
            [file synchronizeFile];
        }
        [file closeFile];
    });

    // We can start catching exception right now
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
}

void init_setupAccounts() {
    NSString *controlPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"accounts"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
}

void init_setupCustomControls() {
    NSString *controlPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"controlmap"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControl();
    generateAndSaveCustomControl();
    NSString *gamepadControlPath = [controlPath stringByAppendingPathComponent:@"gamepads"];
    [fm createDirectoryAtPath:gamepadControlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControlForGamepad();
}

void init_setupMultiDir() {
    NSString *multidir = getPrefObject(@"general.game_directory");
    if (multidir.length == 0) {
        multidir = @"default";
        setPrefObject(@"general.game_directory", multidir);
        NSLog(@"[Pre-init] Game directory was not set. Defaulting to %@ for future use.\n", multidir);
    } else {
        NSLog(@"[Pre-init] Restored game directory preference (%@)\n", multidir);
    }

    const char *home = getenv("POJAV_HOME");
    NSString *lasmPath = [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", home];
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", home, multidir];


    NSArray *dirsToCreate = @[
        [NSString stringWithFormat:@"%s/.demo", home],
        [NSString stringWithFormat:@"%s/java_runtimes", home],
        lasmPath.stringByDeletingLastPathComponent,
        multidirPath
    ];
    for (NSString *dir in dirsToCreate) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fm removeItemAtPath:lasmPath error:nil];
    [fm createSymbolicLinkAtPath:lasmPath withDestinationPath:multidirPath error:nil];
    [fm changeCurrentDirectoryPath:lasmPath];
    setenv("POJAV_GAME_DIR", lasmPath.UTF8String, 1);
}

void init_setupResolvConf() {
    // Write known DNS servers to the config
    NSString *path = [NSString stringWithFormat:@"%s/resolv.conf", getenv("POJAV_HOME")];
    if (![fm fileExistsAtPath:path]) {
        [@"nameserver 8.8.8.8\n"
         @"nameserver 8.8.4.4"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void init_setupHomeDirectory() {
    setenv("HOME", [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject.path.stringByDeletingLastPathComponent.UTF8String, 1);
    NSString *homeDir;
    NSError *homeError;
    
    BOOL isNotSandboxed = [@(getenv("HOME")).lastPathComponent isEqualToString:NSUserName()];
    homeDir = [NSString stringWithFormat:@"%s/Documents%@", getenv("HOME"),
        isNotSandboxed ? @"/AngelAuraAmethyst":@""];

    // ★ [ROOTHIDE] 防御：RootHide 会把 CFFIXED_USER_HOME/部分 HOME 相关路径重定向进随机
    //   jbroot（.../Application/.jbroot-<16hex>/...）；若带着随机段，POJAV_HOME 会随每次
    //   越狱换名字 ⇒ 实例/账号/日志全部“消失”。这里若发现路径含 /.jbroot-<随机段>，
    //   就把它剥掉还原为 rootfs 真实路径（RootHide 的 <jbroot>/rootfs 才是系统根）。
    //   正常环境下该分支永不触发（路径里不会出现 .jbroot-），故对既有行为零影响。
    if (gAmeIsRootHide) {
        const char *cffix = getenv("CFFIXED_USER_HOME");
        NSLog(@"[ROOTHIDE] home resolve: URL-home=%s CFFIXED_USER_HOME=%s", homeDir.UTF8String, cffix ?: "(unset)");
        NSRange jb = [homeDir rangeOfString:@"/.jbroot-"];
        if (jb.location != NSNotFound) {
            NSRange tail = NSMakeRange(jb.location + 1, homeDir.length - (jb.location + 1));
            NSUInteger slash = [homeDir rangeOfString:@"/" options:0 range:tail].location;
            if (slash != NSNotFound) {
                NSString *realHome = [homeDir substringFromIndex:slash];
                NSLog(@"[ROOTHIDE] HOME was redirected into jbroot (%@) -- using real path %@", homeDir, realHome);
                homeDir = realHome;
            } else {
                NSLog(@"[ROOTHIDE] HOME looks jbroot-redirected but no suffix found (%@) -- keeping as-is", homeDir);
            }
        }
    }

    if (![fm fileExistsAtPath:homeDir] ) {
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:NO attributes:nil error:&homeError];
    }
    
    if(homeError != nil) {
        // TODO: Persistent storage
        homeError = nil;
        homeDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).lastObject;
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:YES attributes:nil error:&homeError];
    }
    
    // ★ [ROOTHIDE] 原实现直接把 realpath() 的返回值喂给 setenv()：realpath 失败返回 NULL，
    //   而 setenv(name, NULL, 1) 是未定义行为（可能崩）。改为失败时回退 homeDir 本身，
    //   并打印最终 POJAV_HOME —— RootHide/沙盒/无沙盒三种落点一眼可辨（排障用）。
    char *resolved = realpath(homeDir.UTF8String, NULL);
    setenv("POJAV_HOME", resolved ? resolved : homeDir.UTF8String, 1);
    if (resolved) free(resolved);
    NSLog(@"[Pre-init] POJAV_HOME=%s (sandboxed=%d)", getenv("POJAV_HOME"), !isNotSandboxed);
}

int main(int argc, char *argv[]) {
    // Air Task 42：shaderc 编译沙箱 helper 子进程分支。必须在【一切】
    // launcher/JVM/hook 初始化之前分支。父进程的 shaderc shim 通过
    // posix_spawn 以 AME_SHADERC_SANDBOX=1 + AME_SB_FD=3 拉起本进程。
    // 缺此分支时，被拉起的子进程会跑完整 launcher 启动流程（建目录、
    // 起悬浮球、永不发 ready 握手）→ 父进程死等 → 启动卡死。
    // 符号在 libshaderc.dylib 垫片里（Makefile 编入 shaderc_sandbox.m），
    // 故用 dlsym 解析，避免主可执行文件链接期依赖。
    if (getenv("AME_SHADERC_SANDBOX") != NULL) {
        void *sbh = dlopen("@rpath/libshaderc.dylib", RTLD_NOW);
        if (!sbh) {
            sbh = dlopen("libshaderc.dylib", RTLD_NOW);
        }
        if (sbh) {
            int (*sb_child_main)(void) = dlsym(sbh, "ame_shaderc_sandbox_child_main");
            if (sb_child_main) {
                return sb_child_main();
            }
        }
        fprintf(stderr, "[shaderc-sandbox] child entry unavailable\n");
        return 1;
    }

    if (pJLI_Launch) {
        return pJLI_Launch(argc, (const char **)argv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
    }

    if (!isJITEnabled(true) && argc == 2) {
        NSLog(@"calling ptrace(PT_TRACE_ME)");
        // Child process can call to PT_TRACE_ME
        // then both parent and child processes get CS_DEBUGGED
        int ret = ptrace(PT_TRACE_ME, 0, 0, 0);
        return ret;
    }

    setenv("BUNDLE_PATH", dirname(argv[0]), 1);
    isJailbroken = init_checkForJailbreak();
    // ★ [ROOTHIDE] 环境探测必须在 init_setupHomeDirectory() 之前 —— 后者用 gAmeIsRootHide
    //   判断 HOME 是否被重定向进随机 jbroot 并做还原。探测本身不改变 isJailbroken
    //   （见 init_checkForRootHide 顶部“设计约束”）。
    init_checkForRootHide();
    init_setupHomeDirectory();
    init_redirectStdio();
    init_logDeviceAndVer(argv[0]);

    loadPreferences(NO);
    init_hookFunctions();
    init_hookUIKitConstructor();

    debugLogEnabled = getPrefBool(@"general.debug_logging");
    NSLog(@"[Debugging] Debug log enabled: %@", debugLogEnabled ? @"YES" : @"NO");

    init_setupResolvConf();
    init_setupMultiDir();
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];
    // ★ [VER-ISOLATE-PCL] 版本隔离开关一次性幂等迁移：必须在 POJAV_GAME_DIR 就绪
    // （init_setupMultiDir）与 PLProfiles 刷新之后；哨兵保证只跑一次，失败不阻断启动。
    amePCLMigrateVersionIsolationOnce();
    init_setupAccounts();
    init_setupCustomControls();

    // If sandbox is disabled, W^X JIT can be enabled by Amethyst itself
    if (!isJITEnabled(true) && getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        NSLog(@"[Pre-init] no-sandbox: YES, trying to enable JIT");
        int pid;
        int ret = posix_spawnp(&pid, argv[0], NULL, NULL, (char *[]){argv[0], "", NULL}, environ);
        if (ret == 0) {
            // Cleanup child process
            waitpid(pid, NULL, WUNTRACED);
            ptrace(PT_DETACH, pid, NULL, 0);
            kill(pid, SIGTERM);
            wait(NULL);

            if (isJITEnabled(true)) {
                NSLog(@"[Pre-init] JIT has been enabled with PT_TRACE_ME");
            } else {
                NSLog(@"[Pre-init] Failed to enable JIT: unknown reason");
            }
        } else {
            NSLog(@"[Pre-init] Failed to enable JIT: posix_spawn() failed errno %d", errno);
        }
    }

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}

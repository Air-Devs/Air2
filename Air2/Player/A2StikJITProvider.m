//
//  A2StikJITProvider.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 【内建 JIT】三个动作的真实现（配对文件 → RSD 端点 → attach 开 JIT）。
//
//  ★为什么不重写隧道★：TLS-PSK + RSD 服务调用在 StikJIT.framework 内部（Rust
//  rppairing），我们只准备「配对文件 + 端点」。本仓自研的 a2_tlspsk_* 是另一条
//  链（缺的正是 RSD service 调用），两条并存、互不替代，见 docs/JIT-BUILTIN-STIKJIT.md §6。
//
//  ★为什么用 NSNetServiceBrowser 而不是 A2RPRSDDiscovery★：后者返回的是
//  `nw_endpoint_t`（Bonjour 服务类型端点，给 pair-verify 直接建连用），拿不到
//  「host + port」这两个 StikJIT.Configuration 需要的值；NSNetService 解析后才给
//  hostName/port。两者都是 `_remotepairing._tcp`，不是第二套协议。
//
//  ★日志前缀★：所有判据行 `[A2-JIT-BUILTIN]`（真机 grep 这一串即可复盘整条链）。
//

#import "A2StikJITProvider.h"
#import "A2Log.h"
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#import "A2JITHelperBridge.h"   // ★内建 JIT 走扩展进程（进程不能 attach 自己）

#import <UIKit/UIKit.h>
#import <dlfcn.h>

#import "A2JITPairingFileStore.h"
#import "a2_log.h"
#import "A2StikJITBridge.h"

/// 端点发现的时间上限（秒）。★上限由这里夹住★：Bonjour 不给结果时不能把
/// A2JITEnabler 的等待预算（120s）全耗在发现上。
static const NSTimeInterval kA2StikJITDiscoveryCap = 8.0;
/// 发现失败时的日志去重标记（同一进程内只打一次「没发现端点」的完整解释）。
static BOOL gA2StikJITLoggedNoEndpoint = NO;

#pragma mark - 日志出口（Swift 桥 → a2_log）

/// 桥的进度日志 → 统一判据出口。★C 函数指针，不许捕获上下文★。
static void a2stikjit_bridge_log_sink(const char *line) {
    if (line == NULL) return;
    a2_log_criterion(@"[A2-JIT-BUILTIN] %s", line);
}

#pragma mark - 框架定位 / 加载

/// 包内框架路径（<App>/Frameworks/StikJIT.framework）。
static NSString *a2stikjit_framework_path(void) {
    NSString *frameworks = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    return [frameworks stringByAppendingPathComponent:@"StikJIT.framework"];
}

static NSString *a2stikjit_framework_binary(void) {
    return [a2stikjit_framework_path() stringByAppendingPathComponent:@"StikJIT"];
}

/// 幂等 dlopen。★为什么要 dlopen 而不是只靠链接★：框架是 weak_framework 链接的
/// （iOS < 17.4 装不上时不至于让主程序起不来），所以「能不能真的用」要在运行时确认；
/// dlopen 失败 ⇒ 一条可读原因，绝不去碰弱符号（碰了就是 0 地址调用）。
static BOOL a2stikjit_ensure_loaded(NSString *_Nullable *_Nullable whyOut) {
    static dispatch_once_t once;
    static BOOL loaded = NO;
    static NSString *loadWhy = nil;
    dispatch_once(&once, ^{
        NSString *binary = a2stikjit_framework_binary();
        if (![NSFileManager.defaultManager fileExistsAtPath:binary]) {
            loadWhy = [NSString stringWithFormat:@"包内没有 Frameworks/StikJIT.framework/StikJIT（%@）", binary];
            return;
        }
        void *h = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (h == NULL) {
            const char *e = dlerror();
            loadWhy = [NSString stringWithFormat:@"dlopen 失败：%s（iOS < 17.4？框架 minos=17.4）", e ?: "?"];
            return;
        }
        loaded = YES;
    });
    if (!loaded && whyOut) *whyOut = loadWhy ?: @"StikJIT.framework 未能加载";
    return loaded;
}

#pragma mark - 端点发现

/// `_remotepairing._tcp` 的一个解析结果。
@interface A2StikJITEndpoint : NSObject
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@end
@implementation A2StikJITEndpoint
@end

/// 在**当前线程**跑一小段 runloop，等 Bonjour 解析出 host/port。
/// ★必须在后台线程调用★（会阻塞到 deadline 或解析成功）。
@interface A2StikJITDiscovery : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSNetServiceBrowser *browser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *services;
@property (nonatomic, strong) A2StikJITEndpoint *resolved;
@property (nonatomic, copy) NSString *lastError;
@end

@implementation A2StikJITDiscovery

- (instancetype)init {
    self = [super init];
    if (self) {
        _services = [NSMutableArray array];
    }
    return self;
}

- (nullable A2StikJITEndpoint *)waitForEndpointWithTimeout:(NSTimeInterval)budget {
    self.browser = [[NSNetServiceBrowser alloc] init];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_remotepairing._tcp." inDomain:@""];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:budget];
    while (self.resolved == nil && [deadline timeIntervalSinceNow] > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    [self.browser stop];
    self.browser = nil;
    return self.resolved;
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
            didFindService:(NSNetService *)service
                moreComing:(BOOL)moreComing {
    (void)browser; (void)moreComing;
    service.delegate = self;
    [self.services addObject:service];
    [service resolveWithTimeout:2.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
          didNotFindService:(NSNetService *)service
                moreComing:(BOOL)moreComing {
    (void)browser; (void)service; (void)moreComing;
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    (void)browser;
    self.lastError = [NSString stringWithFormat:@"Bonjour 搜索被拒（%@）—— Info.plist 的 NSBonjourServices 是否含 _remotepairing._tcp？",
                      errorDict];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSString *host = sender.hostName;
    NSInteger port = sender.port;
    if (host.length == 0 || port <= 0 || port > 65535) return;
    // ★Bonjour 的 hostName 常带结尾点★（"localhost." / "Mac.local."），去掉再交给框架。
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    A2StikJITEndpoint *ep = [A2StikJITEndpoint new];
    ep.host = host;
    ep.port = (uint16_t)port;
    if (self.resolved == nil) self.resolved = ep;
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    (void)sender; (void)errorDict;
}

@end

#pragma mark - A2StikJITProvider

@implementation A2StikJITProvider

+ (BOOL)isAvailable {
    return [self unavailableReason] == nil;
}

+ (NSString *)unavailableReason {
    if (@available(iOS 17.4, *)) {
        // 继续
    } else {
        return @"内建 JIT 需要 iOS 17.4+（StikJIT.framework 的最低系统版本）";
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:a2stikjit_framework_binary()]) {
        return @"包内缺少 Frameworks/StikJIT.framework（打包时未嵌入：见 docs/JIT-BUILTIN-STIKJIT.md §4）";
    }
    NSString *why = nil;
    if (!a2stikjit_ensure_loaded(&why)) {
        return why;
    }
    return nil;
}

+ (NSString *)frameworkVersion {
    NSString *plistPath = [a2stikjit_framework_path() stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *v = info[@"CFBundleShortVersionString"];
    return v.length > 0 ? v : nil;
}

+ (NSString *)pairingFilePath {
    A2JITPairingFileStore *store = [A2JITPairingFileStore defaultStore];
    NSString *path = [store importedFilePath];
    if (path.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:path]) {
        return path;
    }
    // 兜底：约定目录下的候选名（与 A2JITLocalFactsSource.candidatePairingFilePaths 同口径，
    // 但不新造第三套路径规则——只查 A2JITPairingFileStore 自己声明的候选名）。
    NSString *dir = [A2JITPairingFileStore defaultDirectory];
    for (NSString *name in [A2JITPairingFileStore candidateFileNames]) {
        NSString *candidate = [dir stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

+ (BOOL)enableBuiltInJITWithBudget:(NSTimeInterval)budget
                            reason:(NSString *_Nullable *_Nullable)whyOut {
    if (whyOut) *whyOut = nil;

    NSString *unavailable = [self unavailableReason];
    if (unavailable != nil) {
        if (whyOut) *whyOut = unavailable;
        a2_log_criterion(@"[A2-JIT-BUILTIN] 不可用：%@", unavailable);
        return NO;
    }

    // ---- ① 配对文件 ----
    NSString *pairing = [self pairingFilePath];
    if (pairing.length == 0) {
        NSString *why = @"没有可用的配对文件（先在「运行环境 › JIT」导入 pairingFile.plist / .mobiledevicepairing）";
        if (whyOut) *whyOut = why;
        a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤1/3 配对文件：%@", why);
        return NO;
    }
    a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤1/3 配对文件就绪：%@（%llu B）",
                     pairing.lastPathComponent,
                     (unsigned long long)[[NSFileManager.defaultManager attributesOfItemAtPath:pairing error:NULL] fileSize]);

    // ---- ①b LocalDevVPN 必须先连上（Henge JITSetup.swift:496-504 同口径）----
    //   判据：存在 utun 接口且地址落在 10.7.0.0/16。没连就拉起 localdevvpn://enable?scheme=air2。
    //   DDI 下载/挂载与 attach 都要走这条隧道，没连上时 appex 只会报「不可达」。
    {
        BOOL vpnUp = NO;
        struct ifaddrs *list = NULL;
        if (getifaddrs(&list) == 0 && list != NULL) {
            for (struct ifaddrs *p = list; p != NULL; p = p->ifa_next) {
                if (p->ifa_addr == NULL || p->ifa_addr->sa_family != AF_INET) continue;
                if ((p->ifa_flags & IFF_UP) == 0) continue;
                if (strncmp(p->ifa_name, "utun", 4) != 0) continue;
                uint32_t ip = ntohl(((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr);
                if ((ip >> 16) == 0x0a07) { vpnUp = YES; break; }   // 10.7.0.0/16
            }
        }
        if (list != NULL) freeifaddrs(list);
        [A2Log criterion:@"[A2-JIT-BUILTIN] 步骤1b LocalDevVPN=%s", vpnUp ? @"已连接（utun 10.7/16）" : @"未连接"];
        if (!vpnUp) {
            NSURL *vpn = [NSURL URLWithString:@"localdevvpn://enable?scheme=air2"];
            // ★UIKit 只能主线程★：enableBuiltInJIT 是在后台队列被调的，直接 openURL 会崩。
            __block BOOL canOpen = NO;
            if ([NSThread isMainThread]) {
                canOpen = (vpn != nil && [[UIApplication sharedApplication] canOpenURL:vpn]);
                if (canOpen) [[UIApplication sharedApplication] openURL:vpn options:@{} completionHandler:nil];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    canOpen = (vpn != nil && [[UIApplication sharedApplication] canOpenURL:vpn]);
                    if (canOpen) [[UIApplication sharedApplication] openURL:vpn options:@{} completionHandler:nil];
                });
            }
            if (canOpen) {
                [A2Log criterion:@"[A2-JIT-BUILTIN] 已拉起 LocalDevVPN（enable?scheme=air2）⇒ 连上后再点一次开启 JIT"];
                if (whyOut) *whyOut = @"LocalDevVPN 未连接：已帮你打开它，连上后回来再点一次";
                return NO;
            }
            [A2Log criterion:@"[A2-JIT-BUILTIN] LocalDevVPN 未安装？（localdevvpn:// 打不开）"];
        }
    }

    // ---- ② RSD 端点 ----
    NSTimeInterval findBudget = MIN(MAX(budget, 2.0), kA2StikJITDiscoveryCap);
    A2StikJITDiscovery *discovery = [A2StikJITDiscovery new];
    A2StikJITEndpoint *ep = [discovery waitForEndpointWithTimeout:findBudget];
    if (ep == nil) {
        // ★2026-11-08 用户口径★ Bonjour 名字（Zhous-iPhone.local）在 appex 里连不上，
        //   改走 LocalDevVPN 的回环地址；端口退回 iOS 默认的 49152。
        if (!gA2StikJITLoggedNoEndpoint) {
            gA2StikJITLoggedNoEndpoint = YES;
            a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤2/3 Bonjour 未发现端点 ⇒ 用 LocalDevVPN 隧道地址 10.7.0.1:49152（Bonjour=%@）",
                             discovery.lastError ?: @"无结果");
        }
    }
    // ★LocalDevVPN 隧道里的"本机"地址 = 10.7.0.1★（Henge JITSetup.swift:496-504：
    //   网段 10.7.0.0/16、VPN 自身 10.7.1.1、被访问设备 10.7.0.1 = StikJIT 默认 device address）。
    // ★主机恒用 LocalDevVPN 的设备地址 10.7.0.1★（用户实测：device 10.7.0.1/32、tunnel 10.7.1.1/32）。
    //   Bonjour 给出的 Zhous-iPhone.local 在 appex 里解析不了，只能借它的**端口**。
    NSString *rsdHost = @"10.7.0.1";
    NSNumber *rsdPort = @((ep != nil) ? ep.port : 49152);
    a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤2/3 目标端点：%@@%@", rsdHost, rsdPort);

    // ---- ②b 先让扩展 prepare：下载/挂载 DDI（Henge JITSetup.swift:315-330 同口径）----
    //   DDI 不准备好，enable 只会 attach 失败。
    {
        NSError *prepErr = nil;
        NSData *prepReq = [A2JITHelperBridge requestDataWithOperation:A2JITHelperOperationPrepare
                                                            targetPID:0
                                                          pairingData:[NSData dataWithContentsOfFile:pairing]
                                                         scriptBase64:nil
                                                              rsdPort:rsdPort
                                                         deviceAddress:rsdHost
                                                                error:&prepErr];
        if (prepReq != nil) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSInteger prepCode = -1;
            __block NSString *prepMsg = nil;
            [A2JITHelperBridge startWithRequestData:prepReq completion:^(NSDictionary<NSString *, id> *resp, NSError *err) {
                prepCode = resp ? [resp[A2JITHelperResponseCodeKey] integerValue] : -1;
                prepMsg = resp ? resp[A2JITHelperResponseMessageKey] : err.localizedDescription;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
            [A2Log criterion:@"[A2-JIT-BUILTIN] 步骤2b DDI 准备：code=%ld %@", (long)prepCode, prepMsg ?: @"(无应答)"];
            if (prepCode != 10) {
                if (whyOut) *whyOut = [NSString stringWithFormat:@"开发者镜像未就绪：%@", prepMsg ?: @"超时"];
                return NO;
            }
        }
    }

    // ---- ③ 交给扩展进程去 attach（进程不能 attach 自己）----
    //   ★2026-11-08★ 原先在这里直接调 a2_stikjit_enable_jit(getpid()) ⇒ 自己 attach 自己，
    //   必然失败。改走 Air2JITHelper.appex：把 pid + 配对文件 + 脚本交给它，
    //   由它在独立进程里 attach 我们并服务 brk。参考 Henge JITBuiltIn.swift。
    NSString *helperWhy = [A2JITHelperBridge unavailableReason];
    if (helperWhy.length > 0) {
        if (whyOut) *whyOut = helperWhy;
        a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 扩展不可用：%@", helperWhy);
        return NO;
    }
    NSData *pairingData = [NSData dataWithContentsOfFile:pairing];
    if (pairingData.length == 0) {
        if (whyOut) *whyOut = @"读不到配对文件内容";
        return NO;
    }
    NSString *scriptPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Air2JIT69.js"];
    NSString *scriptText = [NSString stringWithContentsOfFile:scriptPath encoding:NSUTF8StringEncoding error:NULL];
    NSString *scriptB64 = [[scriptText dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];

    NSError *reqErr = nil;
    NSData *req = [A2JITHelperBridge requestDataWithOperation:A2JITHelperOperationEnable
                                                   targetPID:(int32_t)getpid()
                                                 pairingData:pairingData
                                                scriptBase64:scriptB64
                                                     rsdPort:rsdPort
                                                deviceAddress:rsdHost
                                                       error:&reqErr];
    if (req == nil) {
        NSString *why = [NSString stringWithFormat:@"构造请求失败：%@", reqErr.localizedDescription ?: @"—"];
        if (whyOut) *whyOut = why;
        a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 %@", why);
        return NO;
    }
    a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 交给扩展：pid=%d rsd=%@:%u script=%llu B pairing=%llu B",
                     (int)getpid(), rsdHost.UTF8String, (unsigned)rsdPort.unsignedIntValue,
                     (unsigned long long)scriptB64.length, (unsigned long long)pairingData.length);

    __block BOOL helperOK = NO;
    __block NSString *helperMsg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    BOOL started = [A2JITHelperBridge startWithRequestData:req
                                                completion:^(NSDictionary<NSString *, id> *resp, NSError *err) {
        if (resp != nil) {
            helperOK = [resp[A2JITHelperResponseSuccessKey] boolValue];
            helperMsg = resp[A2JITHelperResponseMessageKey];
        } else {
            helperMsg = err.localizedDescription;
        }
        dispatch_semaphore_signal(sem);
    }];
    if (!started) {
        if (whyOut) *whyOut = @"扩展请求未被受理（appex 缺失或系统拒绝）";
        a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 扩展请求未被受理");
        return NO;
    }
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(MAX(budget, 5.0) * NSEC_PER_SEC)));
    if (waited != 0) {
        if (whyOut) *whyOut = [NSString stringWithFormat:@"扩展 %.0f 秒内没有应答", MAX(budget, 5.0)];
        a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 超时：扩展没应答（appex 可能没被拉起）");
        return NO;
    }
    if (!helperOK) {
        NSString *why = [NSString stringWithFormat:@"扩展失败：%@", helperMsg ?: @"(无原因)"];
        if (whyOut) *whyOut = why;
        a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 %@", why);
        return NO;
    }
    a2_log_criterion(@"[A2-JIT-BUILTIN] 步骤3/3 扩展报告成功：%@（★进程是否真有 JIT 由 A2LegacyJITGate 复验★）", helperMsg ?: @"—");
    return YES;
}

+ (BOOL)prepareDDIWithBudget:(NSTimeInterval)budget
                      reason:(NSString *_Nullable *_Nullable)whyOut {
    if (whyOut) *whyOut = nil;
    NSString *unavailable = [A2JITHelperBridge unavailableReason];
    if (unavailable.length > 0) { if (whyOut) *whyOut = unavailable; return NO; }

    NSString *pairing = [self pairingFilePath];
    if (pairing.length == 0) {
        if (whyOut) *whyOut = @"没有配对文件（先在上一行导入）";
        return NO;
    }
    NSData *pairingData = [NSData dataWithContentsOfFile:pairing];
    if (pairingData.length == 0) {
        if (whyOut) *whyOut = @"读不到配对文件内容";
        return NO;
    }
    NSError *reqErr = nil;
    NSData *req = [A2JITHelperBridge requestDataWithOperation:A2JITHelperOperationPrepare
                                                   targetPID:0
                                                 pairingData:pairingData
                                                scriptBase64:nil
                                                     rsdPort:nil
                                                deviceAddress:@"10.7.0.1"
                                                       error:&reqErr];
    if (req == nil) {
        if (whyOut) *whyOut = [NSString stringWithFormat:@"构造请求失败：%@", reqErr.localizedDescription ?: @"—"];
        return NO;
    }
    __block BOOL ok = NO;
    __block NSString *msg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    BOOL started = [A2JITHelperBridge startWithRequestData:req
                                               completion:^(NSDictionary<NSString *, id> *resp, NSError *err) {
        if (resp != nil) {
            ok = [resp[A2JITHelperResponseSuccessKey] boolValue];
            msg = resp[A2JITHelperResponseMessageKey];
        } else {
            msg = err.localizedDescription;
        }
        dispatch_semaphore_signal(sem);
    }];
    if (!started) { if (whyOut) *whyOut = @"扩展请求未被受理"; return NO; }
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(MAX(budget, 20.0) * NSEC_PER_SEC))) != 0) {
        if (whyOut) *whyOut = @"扩展 20 秒内没应答（下载 DDI 可能更久，稍后重试）";
        return NO;
    }
    if (!ok) { if (whyOut) *whyOut = msg ?: @"扩展返回失败"; return NO; }
    a2_log_criterion(@"[A2-JIT-BUILTIN] DDI 就绪：%@", msg ?: @"—");
    return YES;
}

@end

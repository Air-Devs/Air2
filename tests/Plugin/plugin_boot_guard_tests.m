//
//  plugin_boot_guard_tests.m
//  Air2 —— tests/Plugin：★P1 第⑤块 boot marker + 连续 3 次未跨首帧自动停用★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（直接链接真实实现，落真实临时目录，不 mock 文件系统）：
//    Air2/Core/Plugin/A2PluginBootGuard.m  ← marker 写/结算/清
//    Air2/Core/Plugin/A2PluginRegistry.m   ← failureCount / lastAutoDisabledReason 落盘
//
//  三档口径就是这里的断言（第 1、2 次只记录，第 3 次停用，之后不再动手）：
//  改代码改坏了口径，这几条会红。
//
//  运行：python3 tests/Plugin/run_plugin_tests.py
//

#import <Foundation/Foundation.h>

#import "A2PluginBootGuard.h"
#import "A2PluginRegistry.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL condition, NSString *what) {
    if (condition) {
        gPass++;
        printf("PASS  %s\n", what.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", what.UTF8String);
    }
}

static void eqInt(NSInteger got, NSInteger want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）",
                     what, (long)got, (long)want]);
}

static NSString *TempDirectory(void) {
    NSString *directory = [NSTemporaryDirectory()
                           stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"a2bootguard_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return directory;
}

static NSString *ValidHash(void) {
    NSMutableString *hash = [NSMutableString stringWithString:@"sha256:"];
    for (int i = 0; i < 64; i++) [hash appendString:@"a"];
    return hash;
}

/// 一条能过写前校验的最小条目（只有这段测试关心的字段是变量）。
static A2PluginRegistryEntry *MakeEntry(NSString *pluginId) {
    A2PluginRegistryEntry *entry = [[A2PluginRegistryEntry alloc] init];
    entry.pluginId = pluginId;
    entry.version = @"1.0.0";
    entry.packageHash = ValidHash();
    entry.sourceKind = @"local-import";
    entry.sourceDetail = @"hello.air2plugin";
    entry.sourceInstalledAt = @"2026-10-31T10:00:00Z";
    entry.permissionsGranted = @[];
    entry.permissionSet = @"";
    entry.grantRevision = 0;
    entry.enabled = YES;
    entry.installedAt = @"2026-10-31T10:00:00Z";
    entry.updatedAt = @"2026-10-31T10:00:00Z";
    return entry;
}

/// 把条目直接写进 <dir>/registry.json（走真实 registry 的原子写）。
static BOOL SeedRegistry(NSString *directory, NSArray<A2PluginRegistryEntry *> *entries) {
    A2PluginRegistry *registry = [[A2PluginRegistry alloc] initWithPluginsDirectory:directory];
    (void)[registry loadWithError:NULL];
    for (A2PluginRegistryEntry *entry in entries) {
        if (![registry upsertEntry:entry error:NULL]) return NO;
    }
    return YES;
}

/// 从磁盘重读一条（不信任内存里的对象：要证明的是「落了盘」）。
static A2PluginRegistryEntry *LoadEntry(NSString *directory, NSString *pluginId) {
    A2PluginRegistry *registry = [[A2PluginRegistry alloc] initWithPluginsDirectory:directory];
    if (![registry loadWithError:NULL]) return nil;
    return [registry entryForPluginId:pluginId];
}

/// 模拟一次「点了启动但没走到首帧」（写 marker → 进程崩溃 → 下一次启动结算）。
///
/// 真实的调用顺序是：宿主启动/插件页加载 ⇒ evaluatePreviousLaunch（结算上一次），
/// 点启动 ⇒ markLaunchStarted（写新的 marker）。测试里把这两个动作并成一步，
/// 因为它对磁盘的效果完全一致（markLaunchStarted 内部也会先结算）。
/// @return evaluatePreviousLaunch 的返回值（本次自动停用的条目）。
static NSArray<A2PluginRegistryEntry *> *SimulateFailedLaunch(A2PluginBootGuard *guard) {
    (void)[guard markLaunchStarted];
    return [guard evaluatePreviousLaunch];
}

#pragma mark - 用例

/// ① 首次启动：没有 marker ⇒ 不计数。
static void testNoMarkerNoCount(void) {
    NSString *directory = TempDirectory();
    ok(SeedRegistry(directory, @[ MakeEntry(@"top.example.p") ]), @"① 种一条已启用插件");

    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];
    ok(![[NSFileManager defaultManager] fileExistsAtPath:guard.bootMarkerPath],
       @"① 首次启动前没有 marker 文件");

    NSArray<A2PluginRegistryEntry *> *disabled = [guard evaluatePreviousLaunch];
    eqInt((NSInteger)disabled.count, 0, @"① 没有 marker ⇒ 没有任何条目被自动停用");

    A2PluginRegistryEntry *entry = LoadEntry(directory, @"top.example.p");
    eqInt(entry.failureCount, 0, @"① 没有 marker ⇒ failureCount 仍是 0");
    ok(entry.isEnabled, @"① 没有 marker ⇒ 插件仍然启用");
    ok(entry.lastAutoDisabledReason.length == 0, @"① 没有 marker ⇒ 没有自动停用原因");
}

/// ② 连续 1 次、2 次未跨首帧 ⇒ 只记录（enabled 仍为 YES，failureCount 1、2）。
static void testFirstTwoFailuresOnlyCount(void) {
    NSString *directory = TempDirectory();
    ok(SeedRegistry(directory, @[ MakeEntry(@"top.example.p") ]), @"② 种一条已启用插件");
    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];

    NSArray<A2PluginRegistryEntry *> *first = SimulateFailedLaunch(guard);
    eqInt((NSInteger)first.count, 0, @"② 第 1 次失败不停用任何插件");
    A2PluginRegistryEntry *afterFirst = LoadEntry(directory, @"top.example.p");
    eqInt(afterFirst.failureCount, 1, @"② 第 1 次失败 ⇒ failureCount = 1");
    ok(afterFirst.isEnabled, @"② 第 1 次失败 ⇒ 仍然启用");

    NSArray<A2PluginRegistryEntry *> *second = SimulateFailedLaunch(guard);
    eqInt((NSInteger)second.count, 0, @"② 第 2 次失败不停用任何插件");
    A2PluginRegistryEntry *afterSecond = LoadEntry(directory, @"top.example.p");
    eqInt(afterSecond.failureCount, 2, @"② 第 2 次失败 ⇒ failureCount = 2");
    ok(afterSecond.isEnabled, @"② 第 2 次失败 ⇒ 仍然启用");
    ok(afterSecond.lastAutoDisabledReason.length == 0,
       @"② 停用之前不写原因（否则 UI 会说「已自动停用」却还开着）");
}

/// ③ 第 3 次 ⇒ 自动停用 + 原因非空（并返回给 UI 提示）。
static void testThirdFailureDisables(void) {
    eqInt(A2PluginBootGuardAutoDisableThreshold, 3, @"③ 阈值就是 3（口径钉死）");

    NSString *directory = TempDirectory();
    ok(SeedRegistry(directory, @[ MakeEntry(@"top.example.p") ]), @"③ 种一条已启用插件");
    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];

    (void)SimulateFailedLaunch(guard);
    (void)SimulateFailedLaunch(guard);
    NSArray<A2PluginRegistryEntry *> *third = SimulateFailedLaunch(guard);

    eqInt((NSInteger)third.count, 1, @"③ 第 3 次失败 ⇒ 本次自动停用 1 个插件");
    ok([third.firstObject.pluginId isEqualToString:@"top.example.p"],
       @"③ 被停用的正是那个插件");

    A2PluginRegistryEntry *entry = LoadEntry(directory, @"top.example.p");
    eqInt(entry.failureCount, 3, @"③ 第 3 次失败 ⇒ failureCount = 3");
    ok(!entry.isEnabled, @"③ 第 3 次失败 ⇒ enabled = NO");
    ok(entry.lastAutoDisabledReason.length > 0,
       [NSString stringWithFormat:@"③ 第 3 次失败 ⇒ 停用原因非空（%@）",
        entry.lastAutoDisabledReason ?: @"(nil)"]);

    // 停用之后不再进 marker，所以也不会继续累加（否则每次启动都在给一个
    // 已经不加载的插件记账）。
    (void)SimulateFailedLaunch(guard);
    A2PluginRegistryEntry *afterFourth = LoadEntry(directory, @"top.example.p");
    eqInt(afterFourth.failureCount, 3, @"③ 停用之后的失败不再累加");
    ok(!afterFourth.isEnabled, @"③ 停用之后保持停用");

    // 用户手动重新启用 ⇒ 第 4 次不归本块管（P2 的安全模式才管），不能立刻再关。
    A2PluginRegistryEntry *reEnabled = LoadEntry(directory, @"top.example.p");
    reEnabled.enabled = YES;
    A2PluginRegistry *writer =
        [[A2PluginRegistry alloc] initWithPluginsDirectory:directory];
    ok([writer loadWithError:NULL], @"③ 重新读表（准备手动启用）");
    ok([writer upsertEntry:reEnabled error:NULL], @"③ 手动重新启用成功");

    NSArray<A2PluginRegistryEntry *> *fourth = SimulateFailedLaunch(guard);
    A2PluginRegistryEntry *afterReEnabledFailure = LoadEntry(directory, @"top.example.p");
    eqInt(afterReEnabledFailure.failureCount, 4, @"③ 第 4 次失败照记（4）");
    ok(afterReEnabledFailure.isEnabled,
       @"③ 第 4 次及以后本块不管 ⇒ 不会被本块再自动停用");
    eqInt((NSInteger)fourth.count, 0, @"③ 第 4 次失败不产生自动停用结果");
}

/// ④ 某次启动成功跨过首帧 ⇒ 该插件计数清零、marker 删除。
static void testFirstFrameResetsCounter(void) {
    NSString *directory = TempDirectory();
    ok(SeedRegistry(directory, @[ MakeEntry(@"top.example.p") ]), @"④ 种一条已启用插件");
    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];

    (void)SimulateFailedLaunch(guard);
    (void)SimulateFailedLaunch(guard);
    eqInt(LoadEntry(directory, @"top.example.p").failureCount, 2,
          @"④ 先欠下 2 次失败");

    ok([guard markLaunchStarted], @"④ 又一次启动开始（写 marker）");
    ok([[NSFileManager defaultManager] fileExistsAtPath:guard.bootMarkerPath],
       @"④ 启动开始后 marker 存在");

    ok([guard markFirstFrameReached], @"④ 首帧到达 ⇒ 清零成功");
    A2PluginRegistryEntry *cleared = LoadEntry(directory, @"top.example.p");
    eqInt(cleared.failureCount, 0, @"④ 跨过首帧之后 failureCount 归零");
    ok(cleared.isEnabled, @"④ 跨过首帧不会顺手把插件关掉");
    ok(![[NSFileManager defaultManager] fileExistsAtPath:guard.bootMarkerPath],
       @"④ 跨过首帧之后 marker 被删除");

    // marker 已删 ⇒ 下一次结算不计数（否则「成功」也会被算成一次失败）。
    NSArray<A2PluginRegistryEntry *> *afterSuccess = [guard evaluatePreviousLaunch];
    eqInt((NSInteger)afterSuccess.count, 0, @"④ 成功之后没有待结算的失败");
    eqInt(LoadEntry(directory, @"top.example.p").failureCount, 0,
          @"④ 成功之后仍然没有失败记录");

    // 同一次启动里重复调 markFirstFrameReached 是安全的空操作。
    ok([guard markFirstFrameReached], @"④ 重复调 markFirstFrameReached 不报错");
    eqInt(LoadEntry(directory, @"top.example.p").failureCount, 0,
          @"④ 重复调之后计数仍是 0");
}

/// ⑤ marker 损坏 ⇒ 不崩、按「没有 marker」处理。
static void testCorruptMarkerIsIgnored(void) {
    NSString *directory = TempDirectory();
    ok(SeedRegistry(directory, @[ MakeEntry(@"top.example.p") ]), @"⑤ 种一条已启用插件");
    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];

    // 半截 JSON（写到一半掉电的典型形态）。
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [guard.bootMarkerPath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSData *truncated = [@"{ \"version\": 1, \"plugins\": [\"top.exa"
                          dataUsingEncoding:NSUTF8StringEncoding];
    [truncated writeToFile:guard.bootMarkerPath atomically:YES];

    NSArray<A2PluginRegistryEntry *> *disabled = [guard evaluatePreviousLaunch];
    eqInt((NSInteger)disabled.count, 0, @"⑤ 损坏的 marker ⇒ 不产生自动停用");
    A2PluginRegistryEntry *entry = LoadEntry(directory, @"top.example.p");
    eqInt(entry.failureCount, 0, @"⑤ 损坏的 marker ⇒ 按没有 marker 处理，不计数");
    ok(entry.isEnabled, @"⑤ 损坏的 marker ⇒ 插件仍然启用");

    // 结构对但类型不对（plugins 不是数组）也只当没有 marker。
    NSData *wrongShape = [@"{\"version\":1,\"plugins\":\"top.example.p\"}"
                          dataUsingEncoding:NSUTF8StringEncoding];
    [wrongShape writeToFile:guard.bootMarkerPath atomically:YES];
    eqInt((NSInteger)[guard evaluatePreviousLaunch].count, 0,
          @"⑤ 结构不对的 marker ⇒ 同样按没有 marker 处理");
    eqInt(LoadEntry(directory, @"top.example.p").failureCount, 0,
          @"⑤ 结构不对的 marker ⇒ 不计数");
    ok([[NSFileManager defaultManager] fileExistsAtPath:guard.bootMarkerPath],
       @"⑤ 结算过程不会顺手删掉读不懂的文件（留给诊断）");

    // 损坏之后正常启动仍然能写出一份新 marker，并且从此计数正常。
    ok([guard markLaunchStarted], @"⑤ marker 损坏后仍能开始新一轮启动");
    (void)[guard evaluatePreviousLaunch];
    eqInt(LoadEntry(directory, @"top.example.p").failureCount, 1,
          @"⑤ 重写 marker 之后计数恢复正常");
}

/// ⑥ 结算幂等：同一次失败只算一次（两个接线点都会结算，不能翻倍）。
static void testEvaluationIsIdempotent(void) {
    NSString *directory = TempDirectory();
    ok(SeedRegistry(directory, @[ MakeEntry(@"top.example.p") ]), @"⑥ 种一条已启用插件");
    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];

    ok([guard markLaunchStarted], @"⑥ 启动开始（写 marker）");
    (void)[guard evaluatePreviousLaunch];
    (void)[guard evaluatePreviousLaunch];
    (void)[guard evaluatePreviousLaunch];
    eqInt(LoadEntry(directory, @"top.example.p").failureCount, 1,
          @"⑥ 同一次失败被结算多次也只算 1 次");
}

/// ⑦ 多个插件各自记账；未启用的插件不进 marker、也不被累加。
static void testPerPluginAccounting(void) {
    NSString *directory = TempDirectory();
    A2PluginRegistryEntry *enabled = MakeEntry(@"top.example.on");
    A2PluginRegistryEntry *disabled = MakeEntry(@"top.example.off");
    disabled.enabled = NO;
    disabled.failureCount = 5;      // 用户之前手动关掉时留下的计数
    ok(SeedRegistry(directory, @[ enabled, disabled ]), @"⑦ 种一条启用 + 一条停用");

    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];

    NSData *marker = [NSData dataWithContentsOfFile:guard.bootMarkerPath];
    ok(marker == nil, @"⑦ 还没启动过，没有 marker");
    ok([guard markLaunchStarted], @"⑦ 启动开始");
    NSString *markerText = [NSString stringWithContentsOfFile:guard.bootMarkerPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
    ok([markerText containsString:@"top.example.on"], @"⑦ marker 里记录了已启用插件");
    ok(![markerText containsString:@"top.example.off"],
       @"⑦ marker 里没有已停用插件（它这一轮不会被加载）");

    (void)[guard evaluatePreviousLaunch];
    eqInt(LoadEntry(directory, @"top.example.on").failureCount, 1,
          @"⑦ 启用的插件被记 1 次");
    eqInt(LoadEntry(directory, @"top.example.off").failureCount, 5,
          @"⑦ 停用的插件计数不动（不替别人背锅）");
}

/// ⑧ 注册表读不出来时不动磁盘：不能因为「读不出来」就把计数清零/写空表。
static void testCorruptRegistryIsLeftAlone(void) {
    NSString *directory = TempDirectory();
    A2PluginBootGuard *guard =
        [[A2PluginBootGuard alloc] initWithPluginsDirectory:directory];
    ok([guard markLaunchStarted], @"⑧ 首装（无插件）时启动记账不失败");
    ok(![[NSFileManager defaultManager] fileExistsAtPath:guard.bootMarkerPath],
       @"⑧ 没有已启用插件 ⇒ 不写 marker（没有可保护的对象）");
    ok(![[NSFileManager defaultManager]
            fileExistsAtPath:[directory stringByAppendingPathComponent:@"registry.json"]],
       @"⑧ 记账不会顺手创建 registry.json");

    NSData *garbage = [@"{ \"plugins\": [ /* 半截 */ "
                        dataUsingEncoding:NSUTF8StringEncoding];
    [garbage writeToFile:[directory stringByAppendingPathComponent:@"registry.json"]
              atomically:YES];

    eqInt((NSInteger)[guard evaluatePreviousLaunch].count, 0,
          @"⑧ 注册表损坏时结算是空操作");
    ok(![guard markFirstFrameReached], @"⑧ 注册表损坏时 markFirstFrameReached 返回 NO");
    NSData *after = [NSData dataWithContentsOfFile:
                     [directory stringByAppendingPathComponent:@"registry.json"]];
    ok([after isEqualToData:garbage], @"⑧ 损坏的 registry.json 一个字节都没被改");
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        testNoMarkerNoCount();
        testFirstTwoFailuresOnlyCount();
        testThirdFailureDisables();
        testFirstFrameResetsCounter();
        testCorruptMarkerIsIgnored();
        testEvaluationIsIdempotent();
        testPerPluginAccounting();
        testCorruptRegistryIsLeftAlone();

        printf("\n---- %d passed, %d failed ----\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}

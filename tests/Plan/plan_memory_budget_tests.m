//
//  plan_memory_budget_tests.m
//  Air2 —— tests/Plan：★启动内存预算 + 按 Java 档位的参数集★ 纯逻辑单测
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是 Python/文本镜像★）：
//    Air2/Utils/A2LaunchMemory.m        ← 安全堆顶（api/fallback）+ 档位决策 + 档判据
//    Air2/Core/Version/A2LaunchPlan.m   ← jvmOptionsWithMemoryMB:javaMajorVersion: 的参数集拼装
//    Air2/Utils/A2LaunchRuntimeFacts.m  ← 计划里 runtimeFacts 的取值（只在有事实时下发 -D）
//    Air2/Utils/A2LaunchContract.m      ← 两个系统属性名 + 类加载器名的字面量
//    Air2/Utils/A2Log.m                 ← 计划里记日志的门面（只链接，不调用）
//
//  为什么要有它：
//    本单要修死的是「-Xmx 写死」「参数集不分档」「没有内存判据行」三件事。
//    ★逐项断言拼出来的字符串★，而不是只断言「有 -Xmx」——档位差一个 -XX 都会红。
//
//  运行：python3 tests/Plan/run_plan_memory_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

#import "A2LaunchMemory.h"
#import "A2LaunchPlan.h"
#import "A2LaunchRuntimeFacts.h"
#import "A2LaunchContract.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) {
        gPass++;
        printf("PASS  %s\n", what.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", what.UTF8String);
    }
}

/// 造一个「无运行时事实」的最小计划 —— 这样 VM 选项里就不会掺入两条 -D，
/// 参数集本身可以被逐项、逐位置地钉死（有事实的两条另有历史套件 plan_runtime_facts_tests.m 管）。
static A2LaunchPlan *PlanNoFacts(void) {
    NSError *error = nil;
    return [A2LaunchPlan planFromVersionJSON:@{ @"mainClass": @"net.minecraft.client.main.Main" }
                                   versionID:@"1.21.5"
                                 accountDict:@{}
                                     gameDir:@"/tmp/g"
                                   assetsDir:@"/tmp/a"
                                librariesDir:@"/tmp/l"
                              versionJarPath:nil
                                runtimeFacts:nil
                                       error:&error];
}

static BOOL ArrayEquals(NSArray<NSString *> *a, NSArray<NSString *> *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (![a[i] isEqualToString:b[i]]) return NO;
    }
    return YES;
}

static BOOL ArrayContains(NSArray<NSString *> *haystack, NSString *needle) {
    for (NSString *s in haystack) if ([s isEqualToString:needle]) return YES;
    return NO;
}

static NSString *Join(NSArray<NSString *> *a) {
    return [a componentsJoinedByString:@" "];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("Air2 tests/Plan —— 启动内存预算 + 按 Java 档位分参数集（★真实实现★）\n");
        printf("----------------------------------------\n");

        // ================================================================= ①
        printf("[①] 安全堆顶：权威路径（available>0）\n");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:1807 physicalMB:3072]] == 607,
           @"★老线实测档对得上★ available=1807MB ⇒ ceiling=607MB（1807 − 1200 原生预留）");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:3000 physicalMB:4096]] == 1800,
           @"available=3000MB ⇒ ceiling=1800MB");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:5000 physicalMB:8192]] == 3800,
           @"available=5000MB ⇒ ceiling=3800MB");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:1000 physicalMB:3072]] == 256,
           @"★available 扣不穿预留（1000−1200=−200）⇒ 下限保护 256MB★");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:6000 physicalMB:8192]] == 4096,
           @"★available 很大（4800）⇒ 上限保护 4096MB★");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:1 physicalMB:1]] == 256,
           @"available=1MB（几乎没内存）⇒ 仍是 256MB（下限，保证 -Xmx 是合法正数）");

        // ================================================================= ②
        printf("[②] 安全堆顶：default 回退（available 取不到 ⇒ 物理内存 × 0.6）\n");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:0 physicalMB:4096]] == 2457,
           @"available=0, phys=4096MB ⇒ 2457MB（4096 × 0.6）");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:0 physicalMB:3072]] == 1843,
           @"available=0, phys=3072MB ⇒ 1843MB（截断）");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:0 physicalMB:1024]] == 1024,
           @"★phys=1024 ⇒ 614MB 减去后被 1024 保底抬起（老线 fallback 的 1024 下限）★");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:0 physicalMB:8192]] == 4096,
           @"phys=8192 ⇒ 4915 被上限压回 4096");
        ok([A2LaunchMemory safeHeapCeilingMBForProbe:
            [A2MemoryProbe probeWithAvailableMB:0 physicalMB:0]] == 1024,
           @"★两个读数都没有 ⇒ 默认 1024MB（如实回退，不崩、不伪造）★");

        // ================================================================= ③
        printf("[③] 来源标记（判据行 source=<api|default> 的唯一实现）\n");
        ok([[A2MemoryProbe probeWithAvailableMB:1807 physicalMB:3072].source isEqualToString:@"api"],
           @"有权威读数 ⇒ source=api");
        ok([[A2MemoryProbe probeWithAvailableMB:1 physicalMB:0].source isEqualToString:@"api"],
           @"available=1（>0）⇒ 仍算 api（读数真实存在）");
        ok([[A2MemoryProbe probeWithAvailableMB:0 physicalMB:4096].source isEqualToString:@"default"],
           @"★没有权威读数（但物理内存有）⇒ source=default★");
        ok([[A2MemoryProbe probeWithAvailableMB:0 physicalMB:0].source isEqualToString:@"default"],
           @"★两个都没有 ⇒ source=default★");

        // ================================================================= ④
        printf("[④] 档位决策：xmxMBWithCeilingMB:mode:requestedMB:\n");
        ok([A2LaunchMemory xmxMBWithCeilingMB:2048 mode:A2LaunchMemoryModeAuto requestedMB:4096] == 2048,
           @"★自动档忽略用户值，直接用安全顶★（ceiling=2048 ⇒ -Xmx2048M）");
        ok([A2LaunchMemory xmxMBWithCeilingMB:607 mode:A2LaunchMemoryModeAuto requestedMB:2048] == 607,
           @"自动档：ceiling=607 ⇒ -Xmx607M（不因用户设了 2048 就冲顶）");
        ok([A2LaunchMemory xmxMBWithCeilingMB:2048 mode:A2LaunchMemoryModeManual requestedMB:1024] == 1024,
           @"手动档低于安全顶 ⇒ 用用户值 1024MB");
        ok([A2LaunchMemory xmxMBWithCeilingMB:2048 mode:A2LaunchMemoryModeManual requestedMB:4096] == 2048,
           @"★手动档高于安全顶 ⇒ 压回 ceiling（超顶会被 jetsam 杀）★");
        ok([A2LaunchMemory xmxMBWithCeilingMB:607 mode:A2LaunchMemoryModeManual requestedMB:2048] == 607,
           @"★手动档 + 小设备 ⇒ 仍压回 607MB★");
        ok([A2LaunchMemory xmxMBWithCeilingMB:2048 mode:A2LaunchMemoryModeManual requestedMB:0] == 2048,
           @"手动档但没给值 ⇒ 退回安全顶（不留 0/负的 -Xmx）");
        ok([A2LaunchMemory xmxMBWithCeilingMB:2048 mode:A2LaunchMemoryModeManual requestedMB:-5] == 2048,
           @"手动档给了负数 ⇒ 退回安全顶");
        ok([A2LaunchMemory xmxMBWithCeilingMB:100 mode:A2LaunchMemoryModeAuto requestedMB:0] == 256,
           @"★ceiling 异常小（100）⇒ 结果仍被抬到下限 256MB★");
        ok([A2LaunchMemory xmxMBWithCeilingMB:9000 mode:A2LaunchMemoryModeAuto requestedMB:0] == 4096,
           @"★ceiling 异常大（9000）⇒ 结果被压到上限 4096MB★");

        // ================================================================= ⑤
        printf("[⑤] Java 档位判据（G1 只在 17+）—— 参数集分档的唯一实现\n");
        ok([A2LaunchMemory usesG1TuningForJavaMajorVersion:8] == NO,
           @"★Java 8 ⇒ 不启用 G1 调优（老线：8 的 G1 不成熟）★");
        ok([A2LaunchMemory usesG1TuningForJavaMajorVersion:0] == NO,
           @"★档位未知（0）⇒ 按 8 处理（给它加 G1 会让 JVM 直接起不来）★");
        ok([A2LaunchMemory usesG1TuningForJavaMajorVersion:17] == YES, @"Java 17 ⇒ 启用");
        ok([A2LaunchMemory usesG1TuningForJavaMajorVersion:21] == YES, @"Java 21 ⇒ 启用");
        ok([A2LaunchMemory usesG1TuningForJavaMajorVersion:25] == YES, @"Java 25 ⇒ 启用");
        ok([[A2LaunchMemory gcNameForJavaMajorVersion:25] isEqualToString:@"G1"], @"gc 名：25 ⇒ G1");
        ok([[A2LaunchMemory gcNameForJavaMajorVersion:8] isEqualToString:@"default"], @"gc 名：8 ⇒ default");

        // ================================================================= ⑥
        printf("[⑥] ★参数集逐项 + 逐位置断言★（Java 8 档：无 G1 组）\n");
        NSArray<NSString *> *j8 = [PlanNoFacts() jvmOptionsWithMemoryMB:1024 javaMajorVersion:8];
        NSArray<NSString *> *want8 = @[
            @"-Xms128M", @"-Xmx1024M",
            // ★真机崩溃修复后✗★：不再下发 CompressedClassSpaceSize/MaxMetaspace/CodeCache/DirectMemory，
            // 改为显式关闭压缩类指针（依据 iPhone 17 Pro 崩溃报告 + 老线 JavaLauncher.m:2563/3469 的已验证行为）。
            @"-XX:-UseCompressedClassPointers",
            @"-Xss1m", @"-XX:SoftRefLRUPolicyMSPerMB=250",
            // ★JIT/代码缓存组（老线 JavaLauncher.m:2327-2384 已验证）：Java 8 只有 Unlock，
            //   且没有 MirrorMappedCodeCache（Java 8 的 libjvm 不认，老线 ISSUE-FIX #70）。
            @"-XX:+UnlockExperimentalVMOptions",
            @"-XX:+DisablePrimordialThreadGuardPages",
            @"-XX:ReservedCodeCacheSize=64m",
            @"-XX:InitialCodeCacheSize=16m",
            @"-XX:CodeCacheExpansionSize=4m",
            @"-Xlog:init=debug:stderr",
            [NSString stringWithFormat:@"-Djava.system.class.loader=%@", A2LaunchGameClassLoaderName],
        ];
        ok(ArrayEquals(j8, want8),
           [NSString stringWithFormat:@"Java 8 档选项表逐项/逐位置一致（实际 %lu 条：%@）",
            (unsigned long)j8.count, Join(j8)]);
        ok(!ArrayContains(j8, @"-XX:+UseG1GC") && !ArrayContains(j8, @"-XX:MaxGCPauseMillis=50") &&
           !ArrayContains(j8, @"-XX:+UseStringDeduplication"),
           @"★Java 8 档【一条 GC 参数都没有】（保持 JVM 默认 GC）★");
        ok([j8[0] isEqualToString:@"-Xms128M"] && [j8[1] isEqualToString:@"-Xmx1024M"],
           @"-Xms 紧接 -Xmx（初始堆小、上限由预算给）");

        // ================================================================= ⑦
        printf("[⑦] ★参数集逐项 + 逐位置断言★（Java 17+ 档：含 G1 组）\n");
        NSArray<NSString *> *j25 = [PlanNoFacts() jvmOptionsWithMemoryMB:2048 javaMajorVersion:25];
        NSArray<NSString *> *want17 = @[
            @"-Xms128M", @"-Xmx2048M",
            @"-XX:-UseCompressedClassPointers",
            @"-Xss1m", @"-XX:SoftRefLRUPolicyMSPerMB=250",
            @"-XX:+UnlockExperimentalVMOptions", @"-XX:+UseG1GC",
            @"-XX:MaxGCPauseMillis=50", @"-XX:+UseStringDeduplication",
            // ★JIT/代码缓存组★（Unlock 已在 G1 组里 ⇒ 这里不重复）+ Java≥17 的镜像映射
            @"-XX:+DisablePrimordialThreadGuardPages",
            @"-XX:ReservedCodeCacheSize=64m",
            @"-XX:InitialCodeCacheSize=16m",
            @"-XX:CodeCacheExpansionSize=4m",
            @"-XX:+MirrorMappedCodeCache",
            @"-Xlog:init=debug:stderr",
            [NSString stringWithFormat:@"-Djava.system.class.loader=%@", A2LaunchGameClassLoaderName],
        ];
        ok(ArrayEquals(j25, want17),
           [NSString stringWithFormat:@"Java 25 档选项表逐项/逐位置一致（实际 %lu 条：%@）",
            (unsigned long)j25.count, Join(j25)]);
        NSArray<NSString *> *j17 = [PlanNoFacts() jvmOptionsWithMemoryMB:2048 javaMajorVersion:17];
        ok(ArrayEquals(j17, j25), @"Java 17 档 === Java 25 档（同一档位，逐项一致）");
        NSArray<NSString *> *j21 = [PlanNoFacts() jvmOptionsWithMemoryMB:2048 javaMajorVersion:21];
        ok(ArrayEquals(j21, j25), @"Java 21 档 === Java 25 档（同一档位，逐项一致）");

        // ================================================================= ⑧
        printf("[⑧] 档位差异只在 GC 那一组（其余参数两档逐项相同）\n");
        NSMutableArray<NSString *> *want8b = [want8 mutableCopy];
        [want8b replaceObjectAtIndex:1 withObject:@"-Xmx2048M"];   // 只改堆上限，与 j25 对齐
        NSMutableArray<NSString *> *j25NoGC = [j25 mutableCopy];
        // G1 组 = 以 -XX:+UnlockExperimentalVMOptions 起头的连续 4 条。
        // ★按标记定位，不写死下标★：参数集一改（如撤掉四项封顶）写死的范围就越界崩溃，
        // 而「去掉 G1 后与 Java 8 档一致」这条断言本身依然有效。
        NSUInteger g1Start = [j25NoGC indexOfObject:@"-XX:+UnlockExperimentalVMOptions"];
        ok(g1Start != NSNotFound, @"Java 17+ 档里能找到 G1 组起点（-XX:+UnlockExperimentalVMOptions）");
        // ★两档差异 = G1 组（4 条）+ MirrorMappedCodeCache（仅 Java≥17）★ ⇒ 两处都摘掉再比
        [j25NoGC removeObject:@"-XX:+MirrorMappedCodeCache"];
        g1Start = [j25NoGC indexOfObject:@"-XX:+UnlockExperimentalVMOptions"];
        if (g1Start != NSNotFound && g1Start + 4 <= j25NoGC.count) {
            [j25NoGC removeObjectsInRange:NSMakeRange(g1Start, 4)];
        } else {
            printf("FAIL  G1 组不足 4 条或找不到起点，无法比对（实际 %lu 条）\n",
                   (unsigned long)j25NoGC.count);
        }
        // Java 8 档为了开 DisablePrimordialThreadGuardPages(诊断项)自己也带 Unlock；
        // 而上面摘 G1 组时把 Unlock 一起摘掉了 ⇒ 这里补回到同一位置再比。
        if (![j25NoGC containsObject:@"-XX:+UnlockExperimentalVMOptions"]) {
            NSUInteger softRef = [j25NoGC indexOfObject:@"-XX:SoftRefLRUPolicyMSPerMB=250"];
            if (softRef != NSNotFound) {
                [j25NoGC insertObject:@"-XX:+UnlockExperimentalVMOptions" atIndex:softRef + 1];
            }
        }
        ok(ArrayEquals(j25NoGC, want8b),
           [NSString stringWithFormat:@"去掉 G1 4 条后与 Java 8 档逐项相同（实际：%@）", Join(j25NoGC)]);

        // ================================================================= ⑨
        printf("[⑨] 边界：memoryMB<=0 时不下发任何堆指令（既有语义不变）\n");
        NSArray<NSString *> *none = [PlanNoFacts() jvmOptionsWithMemoryMB:0 javaMajorVersion:25];
        ok(!ArrayContains(none, @"-Xms128M") && !ArrayContains(none, @"-Xmx0M"),
           @"★memoryMB=0 ⇒ 既无 -Xms 也无 -Xmx★");
        BOOL anyXmx = NO;
        for (NSString *s in none) if ([s hasPrefix:@"-Xmx"]) anyXmx = YES;
        ok(!anyXmx, @"memoryMB=0 ⇒ 一条 -Xmx 都不产出");
        ok(ArrayContains(none, @"-XX:-UseCompressedClassPointers") && ArrayContains(none, @"-Xss1m"),
           @"非堆项/线程栈与堆无关 ⇒ 照常下发");
        ok(ArrayContains(none, @"-XX:+UseG1GC"), @"Java 25 档在 memoryMB=0 时仍有 G1 组（与堆无关）");

        // ================================================================= ⑩
        printf("[⑩] 各档共有项与次序（类加载器 -D 永远在最后、且只此一条）\n");
        NSString *loader = [NSString stringWithFormat:@"-Djava.system.class.loader=%@", A2LaunchGameClassLoaderName];
        ok(ArrayContains(j8, loader) && ArrayContains(j25, loader) && ArrayContains(none, loader),
           @"三份选项表都含类加载器 -D");
        ok([j25.lastObject isEqualToString:loader] && [j8.lastObject isEqualToString:loader],
           @"类加载器 -D 是最后一条（不掺入上面几组）");
        int loaderCount = 0;
        for (NSString *s in j25) if ([s hasPrefix:@"-Djava.system.class.loader="]) loaderCount++;
        ok(loaderCount == 1, @"类加载器 -D 只出现一次");
        ok(A2LaunchMemoryMinXmxMB == 256,
           @"下限常量 = 256（与 A2SettingsMinRAMMB 同值：再低 JVM 起不来）");
        ok(A2LaunchMemoryMaxXmxMB == 4096, @"上限常量 = 4096（本单的保守天花板）");
        ok(A2LaunchMemoryNativeReserveMB == 1200, @"原生预留 = 1200（出处：老线 ame173）");

        printf("----------------------------------------\n");
        printf("TOTAL pass=%d fail=%d\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}

//
//  plan_runtime_facts_tests.m
//  Air2 —— tests/Plan：启动计划「运行时事实」纯逻辑单测
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是 Python/文本镜像★）：
//    Air2/Core/Version/A2LaunchPlan.m      ← 计划产出 + jvmOptionsWithMemoryMB:
//    Air2/Utils/A2LaunchRuntimeFacts.m     ← 值对象 + "WxH" 格式
//    Air2/Utils/A2LaunchContract.m         ← 两个系统属性名的字面量
//    Air2/Utils/A2Log.m                    ← 计划里记日志用的门面（只链接，不调用）
//
//  为什么要有它（针对本单要修的硬卡点）：
//    复用线覆盖层 `GLFW.java:538/557` 的**静态块**读 `glfw.windowSize`（`split("x")`）
//    与 `UIScreen.maximumFramesPerSecond`（`Integer.parseInt`）。本测试把
//    「计划真的产出这两条 -D」以及「★拿不到真值就一条都不产出★」跑成可执行的绿/红，
//    而不是只靠源码扫描（扫描只能证明「像」，执行才能证明「是」）。
//
//  运行：python3 tests/Plan/run_plan_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>

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

/// 造一个最小可用的计划（只给 mainClass；其余语义不在本测试关注面内）。
static A2LaunchPlan *PlanWithFacts(A2LaunchRuntimeFacts *facts) {
    NSError *error = nil;
    A2LaunchPlan *plan = [A2LaunchPlan planFromVersionJSON:@{ @"mainClass": @"net.minecraft.client.main.Main" }
                                                versionID:@"1.21.5"
                                              accountDict:@{}
                                                  gameDir:@"/tmp/g"
                                                assetsDir:@"/tmp/a"
                                             librariesDir:@"/tmp/l"
                                           versionJarPath:nil
                                             runtimeFacts:facts
                                                    error:&error];
    if (plan == nil) {
        printf("FAIL  计划产出失败：%s\n", (error.localizedDescription ?: @"(无详情)").UTF8String);
        gFail++;
    }
    return plan;
}

static BOOL ArrayContains(NSArray<NSString *> *haystack, NSString *needle) {
    for (NSString *s in haystack) {
        if ([s isEqualToString:needle]) return YES;
    }
    return NO;
}

static BOOL ArrayHasPrefix(NSArray<NSString *> *haystack, NSString *prefix) {
    for (NSString *s in haystack) {
        if ([s hasPrefix:prefix]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("Air2 tests/Plan —— 启动计划运行时事实（★真实实现★）\n");
        printf("----------------------------------------\n");

        // ---- ① 值对象：格式就是「十进制 x 十进制」（对齐 GLFW.java:538 的 split("x")）----
        printf("[①] A2LaunchRuntimeFacts 的 glfw.windowSize 取值格式\n");
        A2LaunchRuntimeFacts *facts = [A2LaunchRuntimeFacts factsWithSurfaceWidthPixels:2436
                                                                            heightPixels:1125
                                                                   maximumFramesPerSecond:120];
        ok(facts.hasSurfaceSize, @"宽高都给了 ⇒ hasSurfaceSize = YES");
        ok(facts.hasMaximumFramesPerSecond, @"帧率 > 0 ⇒ hasMaximumFramesPerSecond = YES");

        NSString *sizeValue = facts.glfwWindowSizeValue;
        ok([sizeValue isEqualToString:@"2436x1125"],
           [NSString stringWithFormat:@"取值 = \"2436x1125\"（实际 \"%@\"）", sizeValue ?: @"(nil)"]);

        // 模拟 Java 侧：String.split("x") + Integer.valueOf 两段
        NSArray<NSString *> *javaParts = [sizeValue componentsSeparatedByString:@"x"];
        ok(javaParts.count == 2, @"按小写 \"x\" 切分恰好 2 段（split(\"x\") 语义）");
        NSScanner *sc1 = [NSScanner scannerWithString:(javaParts.count == 2 ? javaParts[0] : @"")];
        NSScanner *sc2 = [NSScanner scannerWithString:(javaParts.count == 2 ? javaParts[1] : @"")];
        int w = 0, h = 0;
        ok([sc1 scanInt:&w] && sc1.isAtEnd && [sc2 scanInt:&h] && sc2.isAtEnd,
           @"两段都能被 Integer.valueOf 吃下（十进制整数）");
        ok(w == 2436 && h == 1125, @"数值与输入一致");

        // ---- ② 计划真的产出两条 -D（字面量与契约常量逐字相同）----
        printf("[②] A2LaunchPlan.jvmOptionsWithMemoryMB: 产出这两条 -D\n");
        A2LaunchPlan *plan = PlanWithFacts(facts);
        NSArray<NSString *> *opts = [plan jvmOptionsWithMemoryMB:2048 javaMajorVersion:25];

        NSString *wantSize = [NSString stringWithFormat:@"-D%@=%@", A2LaunchSysPropGLFWWindowSize, @"2436x1125"];
        NSString *wantFps  = [NSString stringWithFormat:@"-D%@=120", A2LaunchSysPropMaximumFramesPerSecond];
        ok(ArrayContains(opts, wantSize),
           [NSString stringWithFormat:@"含 \"%@\"", wantSize]);
        ok(ArrayContains(opts, wantFps),
           [NSString stringWithFormat:@"含 \"%@\"", wantFps]);
        ok(ArrayContains(opts, @"-Xmx2048M"), @"原有 -Xmx 未受影响");
        ok(ArrayHasPrefix(opts, @"-Djava.system.class.loader="), @"原有系统类加载器选项未受影响");
        // ★copy 属性契约★：runtimeFacts 头文件里是 copy 属性（与计划其余字段同风格），
        //   其 setter 会对值发 copyWithZone: ⇒ 值对象必须实现 NSCopying。
        //   本单首跑就是在这里炸的（-[A2LaunchRuntimeFacts copyWithZone:]: unrecognized selector），
        //   这条断言把它钉住。
        ok(plan.runtimeFacts != nil,
           @"★计划收下了 runtimeFacts（copy 属性 ⇒ 值对象实现了 NSCopying）★");
        ok([plan.runtimeFacts.glfwWindowSizeValue isEqualToString:@"2436x1125"],
           @"收下的对象内容与传入一致");
        ok([A2LaunchSysPropGLFWWindowSize isEqualToString:@"glfw.windowSize"],
           @"契约常量的字面量 = \"glfw.windowSize\"（与 GLFW.java:538 一致）");
        ok([A2LaunchSysPropMaximumFramesPerSecond isEqualToString:@"UIScreen.maximumFramesPerSecond"],
           @"契约常量的字面量 = \"UIScreen.maximumFramesPerSecond\"（与 GLFW.java:557 一致）");

        // ---- ③ ★不写猜的值★：拿不到真值 ⇒ 一条 -D 都不产出（绝不填默认值蒙过去）----
        printf("[③] ★阴性：拿不到真值就不产出（不填猜的值）★\n");
        A2LaunchRuntimeFacts *nothing = [A2LaunchRuntimeFacts factsWithSurfaceWidthPixels:0
                                                                             heightPixels:0
                                                                    maximumFramesPerSecond:0];
        ok(!nothing.hasSurfaceSize, @"0x0 ⇒ hasSurfaceSize = NO");
        ok(!nothing.hasMaximumFramesPerSecond, @"fps=0 ⇒ hasMaximumFramesPerSecond = NO");
        ok(nothing.glfwWindowSizeValue == nil, @"没取到表面尺寸 ⇒ glfwWindowSizeValue = nil（不是 \"0x0\"）");

        NSArray<NSString *> *noneOpts = [PlanWithFacts(nothing) jvmOptionsWithMemoryMB:1024 javaMajorVersion:25];
        ok(!ArrayHasPrefix(noneOpts, [NSString stringWithFormat:@"-D%@=", A2LaunchSysPropGLFWWindowSize]),
           @"★缺真值时【不下发】-Dglfw.windowSize★");
        ok(!ArrayHasPrefix(noneOpts, [NSString stringWithFormat:@"-D%@=", A2LaunchSysPropMaximumFramesPerSecond]),
           @"★缺真值时【不下发】-DUIScreen.maximumFramesPerSecond★");
        ok(ArrayContains(noneOpts, @"-Xmx1024M"), @"其余 VM 选项照旧（只少这两条）");

        // ---- ④ 只缺一项 ⇒ 只少一条（两项独立判断，不互相拖累）----
        printf("[④] 只缺一项时只少一条\n");
        A2LaunchRuntimeFacts *onlySize = [A2LaunchRuntimeFacts factsWithSurfaceWidthPixels:1179
                                                                             heightPixels:2556
                                                                    maximumFramesPerSecond:0];
        NSArray<NSString *> *onlySizeOpts = [PlanWithFacts(onlySize) jvmOptionsWithMemoryMB:0 javaMajorVersion:25];
        ok(ArrayContains(onlySizeOpts, [NSString stringWithFormat:@"-D%@=1179x2556", A2LaunchSysPropGLFWWindowSize]),
           @"有尺寸 ⇒ 下发 windowSize");
        ok(!ArrayHasPrefix(onlySizeOpts, [NSString stringWithFormat:@"-D%@=", A2LaunchSysPropMaximumFramesPerSecond]),
           @"无帧率 ⇒ 不下发帧率那条");
        ok(!ArrayHasPrefix(onlySizeOpts, @"-Xmx"), @"memoryMB=0 ⇒ 连 -Xmx 也不产出（既有语义不变）");

        // ---- ⑤ runtimeFacts = nil 也不崩、也不猜 ----
        printf("[⑤] runtimeFacts = nil 的安全行为\n");
        A2LaunchPlan *nilPlan = PlanWithFacts(nil);
        NSArray<NSString *> *nilOpts = [nilPlan jvmOptionsWithMemoryMB:512 javaMajorVersion:25];
        ok(nilOpts.count > 0, @"计划仍可用（只少运行时事实那两条）");
        ok(!ArrayHasPrefix(nilOpts, [NSString stringWithFormat:@"-D%@=", A2LaunchSysPropGLFWWindowSize]) &&
           !ArrayHasPrefix(nilOpts, [NSString stringWithFormat:@"-D%@=", A2LaunchSysPropMaximumFramesPerSecond]),
           @"★nil ⇒ 两条 -D 都不产出（不崩、不猜）★");

        printf("----------------------------------------\n");
        printf("TOTAL pass=%d fail=%d\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}

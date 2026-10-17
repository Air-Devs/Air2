//
//  jli_entry_tests.m
//  Air2 —— tests/Natives：★JLI 入口纯逻辑（a2_jli_entry）单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是源码扫描/文本镜像★）：
//    Natives/Context/a2_jli_entry.m
//      · a2_jli_candidate_paths / a2_jli_resolve_libjli  —— 版本布局差异（Java 8 vs 9+）与优先级
//      · a2_jli_build_argv                               —— 命令行顺序 / 单一 classpath 来源 /
//                                                            特殊字符 / 空 classpath / 程序参数
//      · a2_jli_should_fallback                          —— 「不可用才回退」的判定
//
//  为什么必须真跑：这些规则决定真机上 JLI_Launch 到底收到什么命令行。argv 排错（比如 classpath
//  注入两次、程序参数被吞、字符串被提前释放）在真机上只表现为「主类找不到」或随机崩溃，
//  日志里看不出是数组顺序错了。所以把顺序与内容变成可执行的绿/红。
//
//  运行：python3 tests/Natives/run_jli_entry_tests.py   （需 macOS + clang；Windows 无 clang 属预期）
//

#import <Foundation/Foundation.h>
#import "a2_jli_entry.h"

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

static void eqStr(NSString *got, NSString *want, NSString *what) {
    ok([got isEqualToString:want],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, got ?: @"(nil)", want ?: @"(nil)"]);
}

static void eqInt(NSInteger got, NSInteger want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）",
                     what, (long)got, (long)want]);
}

/// argv 转成可读串（失败信息里一眼看出顺序错在哪）
static NSString *Join(NSArray<NSString *> *argv) {
    return [argv componentsJoinedByString:@" ⏐ "];
}

static void eqArgv(NSArray<NSString *> *got, NSArray<NSString *> *want, NSString *what) {
    BOOL same = (got.count == want.count);
    if (same) {
        for (NSUInteger i = 0; i < got.count; i++) {
            if (![got[i] isEqualToString:want[i]]) { same = NO; break; }
        }
    }
    ok(same, [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, Join(got), Join(want)]);
}

/// 造一个假 JRE 目录：只建给定的相对路径（内容随便，存在性才是判据）
static NSString *FakeJavaHome(NSArray<NSString *> *relativeFiles) {
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"a2jli_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:home
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *rel in relativeFiles) {
        NSString *p = [home stringByAppendingPathComponent:rel];
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"x" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return home;
}

// ============================================================================
#pragma mark - ① libjli 候选路径（版本布局差异）
// ============================================================================

static void testCandidates(void) {
    printf("\n=== ① libjli 候选路径与选定（Java 8 vs 9+ 布局）===\n");

    NSArray<NSString *> *c = a2_jli_candidate_paths(@"/jre/java-25-openjdk");
    eqInt((NSInteger)c.count, 2, @"候选恒为两条（8 布局 + 9+ 布局）");
    eqStr(c[0], @"/jre/java-25-openjdk/lib/jli/libjli.dylib", @"候选①＝Java 8 布局 lib/jli/");
    eqStr(c[1], @"/jre/java-25-openjdk/lib/libjli.dylib", @"候选②＝Java 9+ 布局 lib/");

    eqInt((NSInteger)a2_jli_candidate_paths(@"").count, 0, @"javaHome 为空 ⇒ 无候选（不猜进程 CWD）");

    // 尾斜杠归并（避免 /home//bin/java 这类路径）
    eqStr(a2_jli_candidate_paths(@"/jre/java-21-openjdk/")[1], @"/jre/java-21-openjdk/lib/libjli.dylib",
          @"javaHome 尾斜杠被归并（单斜杠）");
    eqStr(a2_jli_candidate_paths(@"/jre/java-21-openjdk///")[0], @"/jre/java-21-openjdk/lib/jli/libjli.dylib",
          @"多重尾斜杠也被归并");

    // —— 选定：按「真实存在」而不是「按版本猜」——
    NSString *only8  = FakeJavaHome(@[ @"lib/jli/libjli.dylib" ]);
    eqStr(a2_jli_resolve_libjli(only8), [only8 stringByAppendingPathComponent:@"lib/jli/libjli.dylib"],
          @"只有 Java 8 布局 ⇒ 选 lib/jli/libjli.dylib");

    NSString *only11 = FakeJavaHome(@[ @"lib/libjli.dylib" ]);
    eqStr(a2_jli_resolve_libjli(only11), [only11 stringByAppendingPathComponent:@"lib/libjli.dylib"],
          @"只有 Java 9+ 布局 ⇒ 选 lib/libjli.dylib（本包 java-21/25 即此）");

    NSString *both = FakeJavaHome(@[ @"lib/jli/libjli.dylib", @"lib/libjli.dylib" ]);
    eqStr(a2_jli_resolve_libjli(both), [both stringByAppendingPathComponent:@"lib/jli/libjli.dylib"],
          @"两种布局都在 ⇒ 优先 Java 8 布局（老线 isJava8 同源口径）");

    NSString *none = FakeJavaHome(@[]);
    ok(a2_jli_resolve_libjli(none) == nil, @"两种布局都不存在 ⇒ nil（交给回退判定）");

    ok(a2_jli_resolve_libjli(@"") == nil, @"javaHome 为空 ⇒ nil");
    ok(a2_jli_resolve_libjli(nil) == nil, @"javaHome 为 nil ⇒ nil");
}

// ============================================================================
#pragma mark - ② argv 组装
// ============================================================================

static void testArgvShape(void) {
    printf("\n=== ② argv 组装：形态 / 顺序 / argv[0] ===\n");

    NSArray<NSString *> *a = a2_jli_build_argv(@"/jre/java-25-openjdk",
                                               @[ @"-Xmx2G", @"-Duser.dir=/g/data" ],
                                               @"/cp/a.jar:/cp/b.jar",
                                               @"dev.airdevs.air2.launch.A2Entry",
                                               @[ @"--plan", @"/g/plan.json" ]);
    eqArgv(a, (@[ @"/jre/java-25-openjdk/bin/java", @"-Xmx2G", @"-Duser.dir=/g/data",
                  @"-cp", @"/cp/a.jar:/cp/b.jar", @"dev.airdevs.air2.launch.A2Entry",
                  @"--plan", @"/g/plan.json" ]),
           @"完整命令行：java → 选项（原序）→ -cp cp → 主类 → 程序参数");

    eqStr(a.firstObject, @"/jre/java-25-openjdk/bin/java", @"argv[0]＝<javaHome>/bin/java（老线同款）");
    eqStr(a[a.count - 2], @"--plan", @"程序参数在主类之后且保序（第 1 项）");
    eqStr(a.lastObject, @"/g/plan.json", @"程序参数在主类之后且保序（第 2 项）");

    eqArgv(a2_jli_build_argv(@"/j", @[ @"-Xss1m" ], @"", @"M", nil),
           (@[ @"/j/bin/java", @"-Xss1m", @"M" ]),
           @"空 classpath ⇒ ★不产生 -cp 对★；程序参数 nil 视作空");

    eqArgv(a2_jli_build_argv(@"/j", @[], @"", @"M", @[]),
           (@[ @"/j/bin/java", @"M" ]),
           @"options 与 programArgs 都空 ⇒ 只有 [java, 主类]");

    eqArgv(a2_jli_build_argv(@"/j", nil, @"/cp", @"M", nil),
           (@[ @"/j/bin/java", @"-cp", @"/cp", @"M" ]),
           @"options 为 nil ⇒ 视作空表，不影响 -cp");

    // 尾斜杠（argv[0] 不能出现 //）
    eqStr(a2_jli_build_argv(@"/j/", @[], @"", @"M", nil).firstObject, @"/j/bin/java",
          @"javaHome 尾斜杠归并 ⇒ /j/bin/java");

    // 无 javaHome ⇒ 退回裸 "java"（不让 argv[0] 变空串）
    eqStr(a2_jli_build_argv(@"", @[], @"", @"M", nil).firstObject, @"java",
          @"javaHome 空 ⇒ argv[0] 用裸 \"java\"");
    eqStr(a2_jli_build_argv(nil, @[], @"", @"M", nil).firstObject, @"java",
          @"javaHome nil ⇒ argv[0] 用裸 \"java\"");
}

static void testArgvSingleClasspathSource(void) {
    printf("\n=== ③ classpath 单一来源（选项区里的 classpath/jar 一律丢弃）===\n");

    NSArray<NSString *> *opts = @[ @"-cp", @"WRONG-CP", @"-classpath", @"ALSO-WRONG",
                                   @"-Djava.class.path=THIRD-WRONG", @"-jar", @"x.jar" ];
    eqArgv(a2_jli_build_argv(@"/j", opts, @"/RIGHT", @"M", nil),
           (@[ @"/j/bin/java", @"-cp", @"/RIGHT", @"M" ]),
           @"-cp/-classpath/-jar ★连值★与 -Djava.class.path= 全丢（classpath 只认参数那一份）");

    // 只丢旗标不丢值 = 那个值会顶上主类位置 ⇒ 必须成对丢（本套单测最易回归的一条）
    eqArgv(a2_jli_build_argv(@"/j", @[ @"-cp", @"WRONG-CP" ], @"/RIGHT", @"M", nil),
           (@[ @"/j/bin/java", @"-cp", @"/RIGHT", @"M" ]),
           @"-cp 的值被一起丢掉（不会残留成第二个主类）");

    // 末尾孤立旗标（无值）不得越界读
    eqArgv(a2_jli_build_argv(@"/j", @[ @"-Xmx1G", @"-cp" ], @"", @"M", nil),
           (@[ @"/j/bin/java", @"-Xmx1G", @"M" ]),
           @"末尾孤立 -cp（无值）⇒ 只丢旗标、不越界、不崩");

    eqArgv(a2_jli_build_argv(@"/j", @[ @"-Djava.class.path" ], @"", @"M", nil),
           (@[ @"/j/bin/java", @"-Djava.class.path", @"M" ]),
           @"无等号的 -Djava.class.path 是普通属性 ⇒ 保留（只丢 = 形态）");

    eqArgv(a2_jli_build_argv(@"/j", @[ @"-cpfoo", @"-classpathfoo" ], @"", @"M", nil),
           (@[ @"/j/bin/java", @"-cpfoo", @"-classpathfoo", @"M" ]),
           @"前缀相近但不相同的选项 ⇒ 原样保留（不做模糊匹配）");

    // 空串选项跳过（margv 里可能有空 -D 值）
    eqArgv(a2_jli_build_argv(@"/j", @[ @"", @"-Xmx1G", @"" ], @"", @"M", nil),
           (@[ @"/j/bin/java", @"-Xmx1G", @"M" ]),
           @"空串选项被跳过");

    // 程序参数里的 -jar 必须留住（它是给主类的，不是 JLI 选项）
    eqArgv(a2_jli_build_argv(@"/j", @[], @"/cp", @"M", @[ @"-jar", @"instance.jar" ]),
           (@[ @"/j/bin/java", @"-cp", @"/cp", @"M", @"-jar", @"instance.jar" ]),
           @"主类之后的 -jar 属程序参数 ⇒ 必须保留");
}

static void testArgvSpecialChars(void) {
    printf("\n=== ④ 特殊字符 / 长 classpath 原样搬运 ===\n");

    NSString *spaced = @"/Users/a b/Library/Application Support/Air2/libs/lwjgl 3.4.1/lwjgl.jar";
    eqArgv(a2_jli_build_argv(@"/j", @[], spaced, @"M", nil),
           (@[ @"/j/bin/java", @"-cp", spaced, @"M" ]),
           @"含空格的路径作为一个 token 原样传递");

    NSString *cn = @"/用户/我的 实例/libraries/中文 mod.jar";
    eqStr(a2_jli_build_argv(@"/j", @[], cn, @"M", nil)[2], cn, @"含中文的路径原样传递");

    NSString *weird = @"/a/$HOME/%PATH%\"x\"'y'/\\z.jar";
    eqStr(a2_jli_build_argv(@"/j", @[], weird, @"M", nil)[2], weird,
          @"$ % 引号 反斜杠 原样传递（不做 shell 展开/转义）");

    NSMutableArray<NSString *> *many = [NSMutableArray array];
    for (int i = 0; i < 200; i++) [many addObject:[NSString stringWithFormat:@"/libs/j%03d.jar", i]];
    NSString *longCP = [many componentsJoinedByString:@":"];
    NSArray<NSString *> *argv = a2_jli_build_argv(@"/j", @[], longCP, @"M", nil);
    eqStr(argv[2], longCP, @"200 条 classpath（单 token）不被拆分");
    eqInt((NSInteger)argv.count, 4, @"200 条 classpath 仍只占 1 个 token ⇒ argv 总数 4");
    ok([longCP componentsSeparatedByString:@":"].count == 200, @"（自检）样本确实是 200 条");

    // -X 参数里的空格/等号照原样
    eqStr(a2_jli_build_argv(@"/j", @[ @"-Dmetallum.ios.view.pointer=0x1234" ], @"", @"M", nil)[1],
          @"-Dmetallum.ios.view.pointer=0x1234", @"-D 选项值原样保留");
}

static void testArgvReject(void) {
    printf("\n=== ⑤ 拒绝组装的条件 ===\n");

    ok(a2_jli_build_argv(@"/j", @[ @"-Xmx1G" ], @"/cp", @"", nil) == nil, @"主类为空（\"\"）⇒ nil");
    ok(a2_jli_build_argv(@"/j", @[ @"-Xmx1G" ], @"/cp", nil, nil) == nil, @"主类为 nil ⇒ nil");
    ok(a2_jli_build_argv(@"/j", @[], @"", @"M", nil).count >= 2, @"（对照）主类非空 ⇒ 有构造结果");
}

// ============================================================================
#pragma mark - ⑥ 回退判定
// ============================================================================

static void testFallbackDecision(void) {
    printf("\n=== ⑥ 回退判定（只有 JLI 不可用才回退）===\n");

    ok(a2_jli_should_fallback(A2JLIRCDlopenFailed) == YES, @"dlopen 失败 ⇒ 回退 JNI_CreateJavaVM");
    ok(a2_jli_should_fallback(A2JLIRCDlsymFailed)  == YES, @"缺 JLI_Launch 符号 ⇒ 回退");
    ok(a2_jli_should_fallback(A2JLIRCCalled)       == NO,  @"已调用（JLI 成功接管）⇒ 不回退");
    ok(a2_jli_should_fallback(A2JLIRCBadArgs)      == NO,  @"入参非法 ⇒ 不回退（回退只会把同一份错参数再错一次）");

    eqInt(A2JLIRCCalled, 0, @"返回码 0＝已调用（与 launch facade 的 0＝成功区分靠返回值本身）");
    eqInt(A2JLIRCDlopenFailed, 2, @"返回码 2＝dlopen 失败");
    eqInt(A2JLIRCDlsymFailed, 3, @"返回码 3＝dlsym 失败");
    eqInt(A2JLIRCBadArgs, 1, @"返回码 1＝入参非法");
}

// ============================================================================

int main(void) {
    @autoreleasepool {
        testCandidates();
        testArgvShape();
        testArgvSingleClasspathSource();
        testArgvSpecialChars();
        testArgvReject();
        testFallbackDecision();
        printf("\n[jli_entry_tests] PASS=%d FAIL=%d\n", gPass, gFail);
    }
    return (gFail == 0) ? 0 : 1;
}

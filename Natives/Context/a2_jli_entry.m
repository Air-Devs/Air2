// ============================================================================
// Natives/Context/a2_jli_entry.m
// ★ [JLI-LAUNCH] JLI 入口纯逻辑（实现）—— 规则与理由见 .h
// ============================================================================
#import "a2_jli_entry.h"

// 归并尾斜杠：`/a/b/` `/a/b//` ⇒ `/a/b`（避免拼出 `/a/b//bin/java`）。
// 全斜杠（如 "/"）⇒ 空串（调用方按「无 javaHome」处理，不猜路径）。
static NSString *a2_jli_trim_trailing_slashes(NSString *path) {
    NSUInteger n = path.length;
    while (n > 0 && [path characterAtIndex:n - 1] == '/') n--;
    return (n == path.length) ? path : [path substringToIndex:n];
}

// 这些 token 不进 JLI 选项区（★带值的旗标要连值一起丢★）：
//   -cp <值> / -classpath <值>  —— classpath 由 a2_jli_build_argv 单独注入（单一来源）；
//                                 ★只丢 -cp 不动它的值，那个值会变成 JLI 眼里的主类★，
//                                 真主类反而沦为程序参数 —— 这正是最难从日志看出的错法。
//   -jar <值>                   —— jar 模式在 facade 已判 jarMode；残留会抢走主类位置，同样连值丢。
//   -Djava.class.path=<值>      —— 形态 A 的等价写法，只丢自身（单 token）。
static BOOL a2_jli_is_paired_flag(NSString *token) {
    return ([token isEqualToString:@"-cp"] ||
            [token isEqualToString:@"-classpath"] ||
            [token isEqualToString:@"-jar"]);
}

static BOOL a2_jli_is_reserved_token(NSString *token) {
    return [token hasPrefix:@"-Djava.class.path="];
}

NSArray<NSString *> *a2_jli_candidate_paths(NSString *javaHome) {
    NSString *home = a2_jli_trim_trailing_slashes(javaHome ?: @"");
    if (home.length == 0) return @[];
    return @[ [home stringByAppendingPathComponent:@"lib/jli/libjli.dylib"],   // Java 8 布局
              [home stringByAppendingPathComponent:@"lib/libjli.dylib"] ];    // Java 9+ 布局
}

NSString *a2_jli_resolve_libjli(NSString *javaHome) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in a2_jli_candidate_paths(javaHome)) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

NSArray<NSString *> *a2_jli_build_argv(NSString *javaHome,
                                       NSArray<NSString *> *options,
                                       NSString *classpath,
                                       NSString *mainClass,
                                       NSArray<NSString *> *programArgs) {
    if (mainClass.length == 0) return nil;   // 没主类 ⇒ 组出来的命令行无意义

    NSString *home = a2_jli_trim_trailing_slashes(javaHome ?: @"");
    NSMutableArray<NSString *> *argv = [NSMutableArray array];

    // argv[0]：老线同款 `<javaHome>/bin/java`（JLI 用它作进程名/启动器身份）
    [argv addObject:(home.length > 0 ? [home stringByAppendingPathComponent:@"bin/java"] : @"java")];

    // VM 选项：原序保留，丢掉空串与 classpath/jar 残留（带值的连值一起丢）
    for (NSUInteger i = 0; i < options.count; i++) {
        NSString *opt = options[i];
        if (opt.length == 0) continue;
        if (a2_jli_is_paired_flag(opt)) {
            if (i + 1 < options.count) i += 1;     // 吞掉它的值（末尾无值则只丢旗标）
            continue;
        }
        if (a2_jli_is_reserved_token(opt)) continue;
        [argv addObject:opt];
    }

    // classpath：★唯一注入点★；空则整对省略（不产生空的 `-cp ""`）
    if (classpath.length > 0) {
        [argv addObject:@"-cp"];
        [argv addObject:classpath];
    }

    // 主类 + 程序参数（原序；程序参数里的 `-jar` / `--plan` 必须留住）
    [argv addObject:mainClass];
    for (NSString *arg in programArgs) {
        if (arg.length == 0) continue;
        [argv addObject:arg];
    }
    return argv;
}

BOOL a2_jli_should_fallback(int rc) {
    return (rc == A2JLIRCDlopenFailed || rc == A2JLIRCDlsymFailed);
}

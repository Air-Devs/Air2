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

// 这些 token 不进 JLI 选项区：
//   -cp / -classpath         —— classpath 由 a2_jli_build_argv 单独注入（单一来源）
//   -Djava.class.path=…      —— 同上（形态 A 的等价写法）
//   -jar                     —— jar 模式在 facade 已判 jarMode 并处理；留在选项区会让 JLI 找 jar 而不是主类
static BOOL a2_jli_is_reserved_token(NSString *token) {
    if ([token isEqualToString:@"-cp"] || [token isEqualToString:@"-classpath"]) return YES;
    if ([token isEqualToString:@"-jar"]) return YES;
    if ([token hasPrefix:@"-Djava.class.path="]) return YES;
    return NO;
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

    // VM 选项：原序保留，丢掉空串与 classpath/jar 保留字
    for (NSString *opt in options) {
        if (opt.length == 0) continue;
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

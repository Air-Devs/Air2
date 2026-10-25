// ============================================================================
// Natives/runtime/a2_launch.m
// ★ [RT-P1] facade 启动编排（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.3/§3.4/§3.6 + §4
// ----------------------------------------------------------------------------
// ★ [RT-P1I] 日志分级（正常启动安静；细节按需开）：
//   · 默认输出：阶段里程碑 / 失败与原因 / 开关决策 / 一行「参数就绪」标记；
//   · verbose（默认关）：逐项路径、条数长度、options 明细 —— 见 a2_launch_verbose_enabled()；
//   · 去重：原「runtime 层启用」行（与开关行重复）已删；开关行本身即里程碑。
// ★ [RT-STRICT] 回退门：全链唯一回退点（facade）经 a2_fallback_gate 处理 —— 默认打默认可见
//   高亮告警 `[RT-STRICT] FALLBACK -> 旧链: 原因=…` + 回退计数；RT_P1_STRICT=1 则禁止回退、阻断启动。
// ★ [JLI-LAUNCH] 建 VM 的入口改了：优先 dlopen(libjli) + JLI_Launch（老线真机验过的 HotSpot
//   自带启动器，内部完成「建 VM + 跑 main」）；只有 libjli 不可用才回退 dlopen(libjvm) +
//   JNI_CreateJavaVM。原因：后者在真机上停在 `[A2JVM] R4 调用 JNI_CreateJavaVM` 之后不返回。
// ============================================================================
#include <unistd.h>
#import "a2_launch.h"
#import "a2_log.h"            // R7
#import "a2_argbuilder.h"     // R3
#import "a2_resourcepaths.h"  // R4
#import "a2_vmloader.h"       // R2
#import "a2_jli_entry.h"      // ★[JLI-LAUNCH] argv 组装/回退判定（纯逻辑）
#import "a2_jli_launch.h"     // ★[JLI-LAUNCH] dlopen(libjli) + JLI_Launch（默认入口）

#include <stdlib.h>
#include <limits.h>

// ★ [RT-P1-SWITCH] 设置项读取统一收口：Air2 用 NSUserDefaults（本仓无旧线的
//   $POJAV_HOME/launcher_preferences_v2.plist 机制；设置页「运行环境 · 启动链」写的也是它）。
static BOOL a2_pref_bool(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

// 请求的 JNI 版本（Java 8）。R2（a2_vm_create）会在 1.8/9/10/21 间自适应；本常量
// 只用于 R3 的 JavaVMInitArgs 记账与 verbose 日志，避免散落的魔数 0x00010008。
static const jint kA2RequestedJNIVersion = 0x00010008;

// ============================================================================
// facade 开关（唯一读环境变量的地方；读一次 → 显式下传）
// ============================================================================
// ★[RT-STRICT] 严格回退门开关（优先级最高）。真值来源（边界读一次）：
//   env RT_P1_STRICT=1 ⇒ 开；=0 ⇒ 关（显式否决设置项）；未置 ⇒ 设置项 debug.rt_p1_strict（默认关）。
//   ★ 严格 = 强制 runtime 链 + 禁止任何回退旧链（两端都读本函数，保证同一次启动内一致）。
BOOL a2_launch_strict_enabled(void) {
    const char *v = getenv("RT_P1_STRICT");
    if (v != NULL && v[0] == '1') return YES;
    if (v != NULL && v[0] == '0') return NO;
    return a2_pref_bool(@"debug.rt_p1_strict");
}

// ★ [RT-NOAGENT] P2 第一步开关：不注入 javaagent（默认关）。真值来源（边界读一次）：
//   env RT_NO_AGENT=1 ⇒ 开；=0 ⇒ 关（显式否决其余来源）；
//   未置 ⇒ 标志文件 $POJAV_HOME/rt_no_agent.enable 存在 ⇒ 开（侧载 App 由 SpringBoard 启动，
//         不继承 shell 环境 ⇒ 与 rt_p1_runtime.enable 同款「文件开关」，真机可达且可辨）；
//   否则 ⇒ 设置项 debug.rt_no_agent（设置 → 调试；键已在 PLPreferences.m 注册，否则 getPrefBool 静默失败）。
//   语义：本开关只让【runtime 链】在构建 JavaVMInitArgs 前把 -javaagent 从选项表里摘掉；
//   旧链（pJLI_Launch）不经本层 ⇒ 不受影响（要强制切链请 RT_P1_STRICT=1）。
BOOL a2_launch_no_agent_enabled(void) {
    const char *v = getenv("RT_NO_AGENT");
    if (v != NULL && v[0] == '1') return YES;
    if (v != NULL && v[0] == '0') return NO;
    const char *home = getenv("POJAV_HOME");
    if (home != NULL && home[0] != '\0') {
        NSString *flag = [NSString stringWithFormat:@"%s/rt_no_agent.enable", home];
        if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) return YES;
    }
    return a2_pref_bool(@"debug.rt_no_agent");
}

BOOL a2_launch_runtime_enabled(void) {
    // ★[RT-STRICT] 严格回退门（优先级最高）：STRICT=1 ⇒ 强制 runtime 链
    //   （覆盖 RT_P1_RUNTIME=0 / 标志文件 / 设置项三者），并要求“禁止任何回退旧链”。
    //   理由：回退只发生在新链内 —— 若严格模式不强制切链，“禁止回退”就无的放矢。
    if (a2_launch_strict_enabled()) {
        a2_log_strict(@"[SWITCH] 严格回退门=开（RT_P1_STRICT=1）⇒ 强制 runtime 链 + 禁止任何回退旧链");
        return YES;
    }
    // 源 1（构建间 A/B）：环境变量 RT_P1_RUNTIME=1/0（读一次 → 显式返回）。
    const char *v = getenv("RT_P1_RUNTIME");
    if (v != NULL && v[0] == '1') {
        a2_log_line(@"[RT-P1][SWITCH] runtime 链=开（源: env RT_P1_RUNTIME=1）");
        return YES;
    }
    if (v != NULL && v[0] == '0') {
        a2_log_line(@"[RT-P1][SWITCH] runtime 链=关（源: env RT_P1_RUNTIME=0）⇒ 旧链（对照点）");
        return NO;
    }
    // 源 2（真机侧载可达）：容器内标志文件 $POJAV_HOME/rt_p1_runtime.enable。
    //   侧载 App 由 SpringBoard 启动，不继承 shell 环境变量 ⇒ 提供文件开关：
    //   可开（放文件）/ 可关（删文件），且日志可辨。POJAV_HOME 与 accounts/controlmap 同落点。
    const char *home = getenv("POJAV_HOME");
    if (home != NULL && home[0] != '\0') {
        NSString *flag = [NSString stringWithFormat:@"%s/rt_p1_runtime.enable", home];
        if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
            a2_log_f(@"[RT-P1][SWITCH] runtime 链=开（源: 标志文件 %s）", flag.UTF8String);
            return YES;
        }
    }
    // ★ [RT-P1-SWITCH] 源 3（★设置页开关★，用户可自行切换）：debug.rt_p1_runtime
    //   设置 → 调试 → 「使用全新启动链(runtime)」。默认关(=旧链)；打开即走 runtime 链。
    //   优先级：env > 标志文件 > 本设置项。
    //   ★设置页「运行环境 · 启动链」写的即是本 key（NSUserDefaults），与此处同一来源。
    if (a2_pref_bool(@"debug.rt_p1_runtime")) {
        a2_log_line(@"[RT-P1][SWITCH] runtime 链=开（源: 设置项 debug.rt_p1_runtime）");
        return YES;
    }
    a2_log_line(@"[RT-P1][SWITCH] runtime 链=关（默认 ⇒ 旧链；可在 设置 → 调试 打开「使用全新启动链」，或放 $POJAV_HOME/rt_p1_runtime.enable）");
    return NO;
}

// verbose 细节日志开关（默认关；同 a2_launch_runtime_enabled，边界读一次）：
//   · 环境变量 RT_P1_VERBOSE=1/0（构建间 A/B / 抓细节）；
//   · 设置项 debug.rt_p1_verbose（设置 → 调试；真机侧载可达）。
//   仅影响「逐项细节」日志（[RT-V] 行），不影响阶段/失败/开关等默认行。
static BOOL a2_launch_verbose_enabled(void) {
    const char *v = getenv("RT_P1_VERBOSE");
    if (v != NULL && v[0] == '1') return YES;
    if (v != NULL && v[0] == '0') return NO;
    return a2_pref_bool(@"debug.rt_p1_verbose");
}

// ============================================================================
// ★[RT-STRICT] 回退门：facade 在【唯一回退点】调用（把“回退旧链”从正常路径降级为异常安全网）
// ----------------------------------------------------------------------------
// 设计：新链在切换点前的失败分三类（见 a2_launch_jvm_with_argv 返回码契约）：
//   · 可回退（-1 jarMode / -8 摄取失败）——均未建 VM，回退安全 ⇒ 本门在默认下【报警 + 计数后放行】；
//   · 阻断（-9 classpath 漂移）——gate 本就拦住错 classpath，直接失败、不经本门；
//   · 硬失败（-2..-7）——VM 可能已建/主类已派发，回退无意义 ⇒ facade 直接返回，不经本门。
// ⇒ 本门只服务「可回退」这一类：默认=安全网；严格=禁止回退（阻断 + 取证）。
// 计数器为进程内自增（启动期单线程；同一次启动内多次回退可见 #N，便于矩阵统计）。
// ============================================================================
static int gA2FallbackCount = 0;

int a2_fallback_gate(const char *reason, const char *loc, const char *details) {
    const char *rs = (reason  && reason[0])  ? reason  : "(未提供)";
    const char *ls = (loc     && loc[0])     ? loc     : "(未提供)";
    const char *ds = (details && details[0]) ? details : "(未提供)";
    const int n = ++gA2FallbackCount;

    if (a2_launch_strict_enabled()) {
        // 严格：禁止回退 ⇒ 阻断启动 + 取证（原因 + 文件:行号 + 关键变量值）。绝不进旧链。
        a2_log_strict(@"BLOCK 严格回退门禁止回退旧链(RT_P1_STRICT=1): 原因=%s 源=%s 回退计数=%d", rs, ls, n);
        a2_log_strict(@"BLOCK 取证: %s", ds);
        a2_progress_fail(A2StageArgsReady, [NSString stringWithFormat:@"严格模式禁止回退旧链：%s", rs]);
        return 1;
    }
    // 非严格（默认）：异常安全网保留 —— 默认可见高亮告警 + 计数，允许回退旧链。
    a2_log_strict(@"FALLBACK -> 旧链: 原因=%s 源=%s 回退计数=%d", rs, ls, n);
    a2_log_strict(@"FALLBACK 取证: %s", ds);
    return 0;
}

// ============================================================================
// 在已创建的 VM 内 dispatch 主类 main（JNI_CreateJavaVM 不会自动跑 main）
// ============================================================================
static int a2_run_main(JNIEnv *env, NSString *mainClass, NSArray<NSString *> *args) {
    if (env == NULL || mainClass.length == 0) return -5;

    // ★cwd 切到 gameDir（真机证据：MC 报 logs/latest.log 相对路径不存在 ⇒ 进程 cwd 不是 gameDir）。
    //   A2Entry 这条路的 args 只有 2 个（不含 --gameDir），所以要回退到启动计划 JSON 里找。
    NSString *a2gd = nil;
    NSUInteger gi = [args indexOfObject:@"--gameDir"];
    if (gi != NSNotFound && gi + 1 < args.count) a2gd = args[gi + 1];
    if (a2gd.length == 0 && args.count > 0) {
        NSString *first = args.firstObject;
        if ([first hasSuffix:@".json"]) {
            NSData *jd = [NSData dataWithContentsOfFile:first];
            if (jd.length) {
                id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
                if ([obj isKindOfClass:NSDictionary.class]) {
                    NSArray *inner = ((NSDictionary *)obj)[@"arguments"];
                    if ([inner isKindOfClass:NSArray.class]) {
                        NSUInteger k = [inner indexOfObject:@"--gameDir"];
                        if (k != NSNotFound && k + 1 < inner.count) a2gd = inner[k + 1];
                    }
                }
            }
        }
    }
    if (a2gd.length > 0) {
        [NSFileManager.defaultManager createDirectoryAtPath:[a2gd stringByAppendingPathComponent:@"logs"]
                               withIntermediateDirectories:YES attributes:nil error:nil];
        int cdrc = chdir(a2gd.UTF8String);
        a2_log_f(@"[RT-P1] chdir(gameDir) rc=%d path=%@", cdrc, a2gd);
    } else {
        a2_log_f(@"[RT-P1] chdir 跳过：没能从参数/计划里取到 gameDir");
    }

    NSString *binary = [mainClass stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    jclass cls = (*env)->FindClass(env, binary.UTF8String);
    if (cls == NULL) {
        a2_log_f(@"[RT-P1] FindClass(%s) FAILED", binary.UTF8String);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return -5;
    }

    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "main", "([Ljava/lang/String;)V");
    if (mid == NULL) {
        a2_log_f(@"[RT-P1] GetStaticMethodID(%s.main) FAILED", binary.UTF8String);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return -6;
    }

    jclass strCls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray jargs = (*env)->NewObjectArray(env, (jsize)args.count, strCls, NULL);
    for (NSUInteger i = 0; i < args.count; i++) {
        jstring js = (*env)->NewStringUTF(env, args[i].UTF8String);
        if (js) {
            (*env)->SetObjectArrayElement(env, jargs, (jsize)i, js);
            (*env)->DeleteLocalRef(env, js);
        }
    }

    a2_log_f(@"[RT-P1] calling %s.main(%lu args)", mainClass.UTF8String, (unsigned long)args.count);
    (*env)->CallStaticVoidMethod(env, cls, mid, jargs);
    if ((*env)->ExceptionCheck(env)) {
        a2_log_f(@"[RT-P1] %s.main threw:", mainClass.UTF8String);
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return -7;
    }
    return 0;
}

// ============================================================================
// 启动编排
// ============================================================================
int a2_launch_jvm_with_argv(int argc, const char *const argv[], A2LaunchInput input) {
    const BOOL verbose = a2_launch_verbose_enabled();   // ★ [RT-P1I] 细节日志开关（边界读一次）
    a2_progress_enter(A2StageArgsReady);   // 阶段5：参数/资源就绪

    // ---- 边界读开关（显式下传；下层不读环境）----
    const char *cpFormEnv = getenv("RT_CP_FORM");
    A2ClasspathForm cpForm = a2_classpath_form_from_name(cpFormEnv ? @(cpFormEnv) : nil);
    const char *strictEnv = getenv("RT_VM_STRICT");
    BOOL ignoreUnrecognized = !(strictEnv && strictEnv[0] == '1');

    // ---- R3：摄取旧 margv（单一事实源；不复制业务参数清单）----
    A2ArgBuilder *builder = [A2ArgBuilder builder];
    builder.classpathForm = cpForm;                     // 显式设置（不靠环境隐式决定）
    BOOL ok = [builder ingestArgv:argv count:argc];
    if (!ok) {
        // ★ [VS-GAP][G3] 区分「真 jar 模式」与「摄取失败」，两者都只回退旧链（尚未建 VM）：
        //   · jarMode：`-jar` 落在【主类之前】的 JLI 选项区（真·java -jar 语义）⇒ 新链不支持；
        //   · 其余   ：未解析出主类 ⇒ 摄取失败。
        //   主类之后的 `-jar` 由 R3 当程序参数保留（见 a2_argbuilder.m）⇒ 不再是 jarMode。
        if (builder.jarMode) {
            a2_progress_fail(A2StageArgsReady, @"-jar 形态（JLI 选项区）");
            a2_log_fatal(@"[RT-P1] R3 判定 jarMode（-jar 在选项区）⇒ 因 jarMode 回退旧链（未建 VM）");
            return -1;
        }
        a2_progress_fail(A2StageArgsReady, @"未解析出主类");
        a2_log_fatal(@"[RT-P1] R3 摄取失败：未解析出主类 ⇒ facade 须回退旧链");
        return -8;
    }
    // ★ [RT-P1I] 参数明细（options 逐条 / 条数 / 长度）归 verbose；默认只打下方「参数就绪」一行。
    a2_log_detail(verbose, @"[RT-P1] R3 ingest ok: %s", [builder summary].UTF8String);

    // ---- R4：资源路径（§3.4 路径只由一处拼装）+ 注入项交给 R3 ----
    A2PathsInput pin = { nil, nil, nil, nil, nil, nil, nil, nil, nil };
    pin.bundlePath     = NSBundle.mainBundle.bundlePath;
    pin.gameDir        = input.gameDir;
    pin.userHome       = input.userHome;
    pin.tmpDir         = input.tmpDir;
    pin.javaHome       = input.javaHome;
    pin.librariesPath  = input.librariesPath;
    pin.lwjglDir       = input.lwjglDir;
    pin.frontJar       = input.frontJar;
    pin.frameworksPath = input.frameworksPath;

    A2Paths paths = a2_paths_resolve(pin);
    for (NSString *item in a2_paths_injection_items(paths)) {
        [builder addRawOption:item];                    // R3 按 key 去重 ⇒ 与旧 margv 重复注入安全
    }
    a2_log_detail(verbose, @"[RT-P1] R4 paths: frameworks=%s tmp=%s javaHome=%s",
                  paths.frameworksPath.UTF8String, (paths.tmpDir ?: @"(nil)").UTF8String,
                  (paths.javaHome ?: @"(nil)").UTF8String);

    // ★ [RT-NOAGENT] P2 第一步：不注入 javaagent（默认关）——
    //   目的：当场量出「没 agent 这条链差哪一步」（= P2 路线图首图）。
    //   做法：在【唯一一次】构建 JavaVMInitArgs 之前，从 R3 的原始选项表里摘掉全部 `-javaagent:*`
    //   条目，连带 agent 专属的 `-Dmetallum.mc.version=`（它只为 agent 选类集而注入，留着是死参数）。
    //   其余一切不变：classpath / 主类 / 程序参数 / 其它 -D/-X 一字不动。
    //   ★ 只摘【原始选项】：agent 不由本层 define/patch，本层也不感知 agent 语义 ⇒ 分层干净。
    if (a2_launch_no_agent_enabled()) {
        NSArray<NSString *> *removedAgents = [builder removeRawOptionsContaining:@"-javaagent:"];
        NSArray<NSString *> *removedProps  = [builder removeRawOptionsContaining:@"-Dmetallum.mc.version="];
        // ★ 判据行（**默认可见**，不受 verbose 影响）—— 真机 grep 锚点：
        //   `[RT-AGENT] javaagent disabled by RT_NO_AGENT -- 以无注入方式启动`
        a2_log_f(@"[RT-AGENT] javaagent disabled by RT_NO_AGENT -- 以无注入方式启动（[RT-NOAGENT] 移除 -javaagent %lu 项 / agent 专属 -D %lu 项）",
                 (unsigned long)removedAgents.count, (unsigned long)removedProps.count);
        for (NSString *ra in removedAgents) a2_log_f(@"[RT-NOAGENT]   已移除: %s", ra.UTF8String);
        for (NSString *rp in removedProps)  a2_log_f(@"[RT-NOAGENT]   已移除: %s", rp.UTF8String);
        if (removedAgents.count == 0) {
            // 开关开了、但 margv 里本就没有 javaagent ⇒ 如实报（避免“看起来生效了”的假判据）
            a2_log_f(@"[RT-NOAGENT] 注意：本次 margv 里没有 -javaagent 项（开关已开但无物可移除）");
        }
    } else {
        // 默认路径不新增默认可见行（对齐 [RT-P1I]「正常启动安静」）；verbose 下留一行“未启用”便于对照。
        a2_log_detail(verbose, @"[RT-NOAGENT] 开关未启用（RT_NO_AGENT / $POJAV_HOME/rt_no_agent.enable / debug.rt_no_agent 皆关）⇒ javaagent 照原样注入");
    }

    // ★ [RT-P1G] classpath 通配展开：旧链走 JLI_Launch（真 java 启动器）会自动展开
    //   "<dir>/*"；runtime 链把 classpath 以 "-Djava.class.path=<cp>" 交 JNI_CreateJavaVM，
    //   HotSpot/AppClassLoader **不展开** "*" ⇒ "<libs>/lwjgl-<ver>/*" 整条失效、目录内
    //   lwjgl.jar 不可达 ⇒ 真机 NoClassDefFoundError: org/lwjgl/glfw/GLFWErrorCallbackI
    //   （阶段 7 主类抛异常）。此处对 R3 摄取的 classpath 显式展开，使其等价于旧链生效形态。
    //   —— 展开归 R4（资源/路径单一拼装点），本条只做编排；R3 不感知文件系统。
    if (builder.classpath.length > 0) {
        NSString *expanded = a2_paths_expand_classpath_wildcards(builder.classpath);
        if (![expanded isEqualToString:builder.classpath]) {
            // ★ [VS-GAP][G7] 提回默认可见：通配展开是版本相关判据（lwjgl-<ver>/ 目录是否被展开）
            a2_log_f(@"[RT-P1] classpath 通配展开: %lu -> %lu 字符（\"<dir>/*\" ⇒ 显式 jar）",
                     (unsigned long)builder.classpath.length, (unsigned long)expanded.length);
            [builder setClasspath:expanded];
        }
    }

    // ★ [VS-GAP][G6] classpath 对齐校验（升级：逐项 → 不一致即【阻断启动】+ 取证）。
    //   背景：R4 依 facade 透传的 lwjglDir/javaHome/librariesPath 重算一份 classpath；
    //   若透传为空/错版本（如 lwjgl-333 vs lwjgl-341），R4 会静默产出缺 lwjgl 目录的 classpath。
    //   旧实现仅打 WARN ⇒ 带着错 classpath 硬跑 ⇒ 运行期 NoClassDefFoundError（不改则不许继续）。
    //   本校验以【R3 从旧 margv 摄取的 classpath】为权威（单一事实源），与 R4 产出逐项对齐：
    //     · 集合不一致（缺/多条目）⇒ 真漂移 ⇒ 阻断启动并输出取证（缺/多条 + lwjglDir/javaHome）。
    //     · 仅顺序不同（目录枚举顺序差异）⇒ 非漂移（旧链自身亦用 contentsOfDirectoryAtPath，
    //       顺序本就无保证）⇒ 记一条默认 WARN，继续用权威顺序，不阻断。
    if (paths.classpath.length > 0 && builder.classpath.length > 0) {
        NSArray<NSString *> *auth = [builder.classpath componentsSeparatedByString:@":"];
        NSArray<NSString *> *r4   = [paths.classpath componentsSeparatedByString:@":"];
        if ([auth isEqualToArray:r4]) {
            a2_log_f(@"[RT-P1] classpath 对齐(R4 == margv 展开)：%lu 条", (unsigned long)auth.count);
        } else {
            NSArray<NSString *> *as = [auth sortedArrayUsingSelector:@selector(compare:)];
            NSArray<NSString *> *rs = [r4   sortedArrayUsingSelector:@selector(compare:)];
            if ([as isEqualToArray:rs]) {
                // 排序后一致 ⇒ 仅顺序不同（非漂移）
                a2_log_f(@"[RT-P1] WARN classpath 顺序不同(目录枚举顺序)，集合一致 ⇒ 不阻断（用权威顺序）: %lu 条",
                         (unsigned long)auth.count);
            } else {
                // ★ 真漂移：取证 + 阻断（绝不带错 classpath 硬跑）
                NSMutableSet<NSString *> *missing = [NSMutableSet setWithArray:auth];  // 权威有、R4 无
                [missing minusSet:[NSSet setWithArray:r4]];
                NSMutableSet<NSString *> *extra   = [NSMutableSet setWithArray:r4];    // R4 多出
                [extra minusSet:[NSSet setWithArray:auth]];
                a2_log_fatal(@"[RT-P1] BLOCK classpath 漂移(margv 权威=%lu 条 vs R4=%lu 条)：缺=%lu 多=%lu",
                             (unsigned long)auth.count, (unsigned long)r4.count,
                             (unsigned long)missing.count, (unsigned long)extra.count);
                for (NSString *m in missing) a2_log_f(@"[RT-P1]   缺失(R4 未产出): %s", m.UTF8String);
                for (NSString *x in extra)   a2_log_f(@"[RT-P1]   多出(R4 多产出): %s", x.UTF8String);
                a2_log_f(@"[RT-P1]   取证：lwjglDir=%s javaHome=%s librariesPath=%s",
                         (input.lwjglDir ?: @"(nil)").UTF8String,
                         (input.javaHome ?: @"(nil)").UTF8String,
                         (input.librariesPath ?: @"(nil)").UTF8String);
                a2_progress_fail(A2StageArgsReady, @"classpath 与 R3 摄取不一致（版本/路径漂移）");
                return -9;   // ★ [VS-GAP][G6] 阻断启动（不得回退旧链：gate 就是要拦住错 classpath）
            }
        }
    }
    if (builder.classpath.length == 0 && paths.classpath.length > 0) {
        [builder setClasspath:paths.classpath];         // 摄取未带 classpath 时的兜底（R4 已展开）
    }
    if (builder.mainClass.length == 0) {
        a2_progress_fail(A2StageArgsReady, @"主类为空");
        return -2;
    }

    // ★ [RT-P1I] 默认一行「参数就绪」：只留可判定的标记（主类 / classpath 条数 / 形态 / 程序参数）；
    //   逐项 options 明细（R3 summary）已归 verbose。
    NSUInteger cpItems = (builder.classpath.length > 0)
        ? [builder.classpath componentsSeparatedByString:@":"].count : 0;
    // ★ [VS-GAP][G7] %@ 在 C 侧 vsnprintf 不受支持 ⇒ 改 %s（主类名是版本/加载器相关判据，必须可见且正确）
    a2_log_f(@"[RT-P1] 参数就绪：main=%s classpath=%lu 条 form=%s programArgs=%lu",
             builder.mainClass.UTF8String ?: "(nil)", (unsigned long)cpItems,
             (cpForm == A2ClasspathFormOption) ? "B" : "A",
             (unsigned long)builder.programArgs.count);

    // ============================================================================
    // ★[JLI-LAUNCH] 入口选择：优先 JLI_Launch（老线真机验证过的 HotSpot 自带启动器）
    // ----------------------------------------------------------------------------
    // 病象：本层原先直接 dlopen(libjvm) + JNI_CreateJavaVM，真机日志停在
    //   `[A2JVM] R4 调用 JNI_CreateJavaVM` 之后再无 `R5 返回` ⇒ 卡在 VM 初始化里。
    // 结论：老线根本不走 JNI_CreateJavaVM —— 它 dlopen(<javaHome>/lib[/jli]/libjli.dylib)
    //   → dlsym(JLI_Launch) → JLI_Launch(argv)，由 HotSpot 自带启动器完成「建 VM + 跑 main」。
    // 分工：argv 怎么排 = a2_jli_entry（纯函数，有单测）；dlopen/dlsym/调用/J1/J2/J3 =
    //   a2_jli_launch；本处只做「选入口 + 决定是否回退」。
    // ★日志判读（务必按此读，别把 J3 缺失当卡死）★：
    //   J1 dlopen libjli ok → J2 JLI_Launch 已调用 →（游戏真起来时）MC 自己的 stderr 行；
    //   J3 只在主类 main 结束/进程退出时才出现 —— 属于「退出时事件」，不是启动判据。
    // 回退：只有 JLI 不可用（libjli 打不开 / 缺 JLI_Launch 符号）才走下方既有的
    //   JNI_CreateJavaVM 路径 —— 该路径保留但不再默认。
    // ============================================================================
    {
        // ★诊断开关★ A2ForceJNIPath=YES ⇒ 跳过 JLI，强制走下面的 JNI_CreateJavaVM 路径。
        // ★默认走 JNI★（JLI 版真机一启动就闪退，先以 JNI 为准做诊断）；
        //   要试 JLI 就把偏好键 A2ForceJNIPath 显式置 NO。
        id a2ForceJNIVal = [NSUserDefaults.standardUserDefaults objectForKey:@"A2ForceJNIPath"];
        BOOL a2ForceJNI = (a2ForceJNIVal == nil) ? YES : [NSUserDefaults.standardUserDefaults boolForKey:@"A2ForceJNIPath"];
        if (a2ForceJNI) {
            a2_log_f(@"[RT-P1] ★A2ForceJNIPath=YES ⇒ 跳过 JLI，强制走 JNI_CreateJavaVM★");
        }
        if (!a2ForceJNI) {
        NSArray<NSString *> *jliArgv = a2_jli_build_argv(input.javaHome, [builder rawOptions],
                                                         builder.classpath, builder.mainClass,
                                                         builder.programArgs);
        a2_progress_enter(A2StageJVMStarting);   // 阶段6：JLI 即将接管（建 VM 在它内部完成）
        // 阶段7 与老线同款语义：JLI_Launch 起 JVM 后本线程就阻塞在这个调用里，
        // 直到主类 main 结束（老线把「等待首帧」压在这里，遮罩由 Java 侧首帧回调撤）。
        a2_progress_enter(A2StageWaitingFirstFrame);
        int jliRC = 0;
        int lrc = a2_vm_launch_with_jli(input.javaHome, jliArgv, builder.classpath,
                                        builder.mainClass, &jliRC);
        if (lrc == A2JLIRCCalled) {
            // JLI 已经把主类 main 跑完（建 VM 也由它完成）⇒ 绝不再走 a2_run_main（会二次派发）
            if (jliRC == 0) {
                a2_progress_enter(A2StageCompleted);
                a2_log_f(@"[RT-P1] JLI 入口：主类 main 正常结束、JLI_Launch 返回 rc=0（本次启动收尾）");
                return 0;
            }
            a2_progress_fail(A2StageWaitingFirstFrame, [NSString stringWithFormat:@"JLI rc=%d", jliRC]);
            a2_log_fatal(@"[RT-P1] JLI 入口：主类 main 结束但 JLI_Launch 返回 rc=%d（非 0 ⇒ 启动器/主类异常退出）", jliRC);
            return -13;
        }
        if (!a2_jli_should_fallback(lrc)) {
            // 入参非法（javaHome/主类/argv 空）：不靠回退掩盖 —— 同一份错参数换条路只会再错一次
            a2_progress_fail(A2StageJVMStarting, [NSString stringWithFormat:@"JLI 入参非法 rc=%d", lrc]);
            a2_log_fatal(@"[RT-P1] JLI 入口入参非法 rc=%d（javaHome/主类/argv 为空）⇒ 不启动，也不回退", lrc);
            return -14;
        }
        // JLI 不可用 ⇒ 保留的 JNI_CreateJavaVM 路径（异常安全网；默认已不是主路）
        a2_log_f(@"[RT-P1] JLI 入口不可用 rc=%d（libjli 打不开或缺 JLI_Launch）⇒ 回退 JNI_CreateJavaVM 路径", lrc);
    }
        }   // if (!a2ForceJNI)

    // ---- R2：定位 libjvm + 建 VM ----
    NSString *libjvm = a2_vm_resolve_libjvm(input.javaHome);
    if (!libjvm) {
        a2_progress_fail(A2StageArgsReady, @"未找到 libjvm.dylib");
        a2_log_fatal(@"[RT-P1] 定位 libjvm 失败 ⇒ 无可用 JRE");
        return -3;
    }
    // ★ [VS-GAP][G7] 默认可见：选用哪个 JRE/libjvm 是版本相关判据（Java8/17/21/25 布局不同）
    a2_log_f(@"[RT-P1] R2 libjvm=%s java.home=%s", libjvm.UTF8String, input.javaHome.UTF8String);

    A2VMArgsBundle *bundle = [builder buildInitArgsWithVersion:kA2RequestedJNIVersion
                                            ignoreUnrecognized:ignoreUnrecognized];
    JavaVMInitArgs vmArgs = [bundle initArgs];
    // ★ [VS-GAP][G7] 默认可见：VM 选项条数是版本相关判据（Java8/17+ 选项集不同）
    a2_log_f(@"[RT-P1] R3 JavaVMInitArgs: nOptions=%d ignoreUnrecognized=%d",
             vmArgs.nOptions, vmArgs.ignoreUnrecognized);

    a2_progress_enter(A2StageJVMStarting);   // 阶段6
    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint usedVer = 0;
    // ★全量探针(2026-10-17)★：把最终 argv 与环境一次性打出来，避免再来回猜。
    {
        // optionStrings 是 C 数组（const char *const *），不是 NSArray —— 逐条打出来。
        const char *const *opts = [bundle optionStrings];
        int optCount = [bundle optionCount];
        a2_log_f(@"[A2JVM-DIAG] argv 共 %d 条：", optCount);
        for (int i = 0; i < optCount; i++) {
            a2_log_f(@"[A2JVM-DIAG]   [%02d] %s", i, opts[i] ? opts[i] : "(null)");
        }
        a2_log_f(@"[A2JVM-DIAG] classpath=%s", builder.classpath.UTF8String ?: "");
        a2_log_f(@"[A2JVM-DIAG] mainClass=%s", builder.mainClass.UTF8String ?: "");
        char cwdBuf[PATH_MAX] = {0};
        (void)getcwd(cwdBuf, sizeof(cwdBuf));
        a2_log_f(@"[A2JVM-DIAG] env HOME=%s TMPDIR=%s JAVA_HOME=%s POJAV_HOME=%s cwd=%s",
                 getenv("HOME") ?: "", getenv("TMPDIR") ?: "",
                 getenv("JAVA_HOME") ?: "", getenv("POJAV_HOME") ?: "", cwdBuf);
    }

    int rc = a2_vm_create(libjvm, [bundle optionStrings], [bundle optionCount],
                          ignoreUnrecognized, &vm, &env, &usedVer);
    if (rc != 0) {
        a2_progress_fail(A2StageJVMStarting, [NSString stringWithFormat:@"R2 rc=%d", rc]);
        a2_log_fatal(@"[RT-P1] R2 建 VM 失败 rc=%d（请求 JNI 版本 0x00010008）", rc);
        return -4;
    }
    a2_log_f(@"[RT-P1] R2 VM ready: usedVer=0x%08x", (unsigned)usedVer);

    // ★2026-10-18★ JNIEnv 是【每线程私有】的：VM 是在专用大栈线程上创建的，那个 env 只对
    //   创建线程有效。本线程（dispatch 线程）必须 AttachCurrentThread 才能拿到可用 env，
    //   否则 FindClass 会踩坏 JVM 的 SymbolTable —— 真机 SIGSEGV 正是崩在
    //   SymbolTable::do_lookup ← jni_FindClass ← a2_launch_jvm_with_argv。
    {
        JNIEnv *threadEnv = NULL;
        jint ar = (*vm)->AttachCurrentThread(vm, (void **)&threadEnv, NULL);
        a2_log_f(@"[RT-P1] AttachCurrentThread rc=%d env=%p（创建线程的 env=%p）", ar, threadEnv, env);
        if (ar == 0 && threadEnv != NULL) env = threadEnv;
    }

    // ---- 阶段7：派发主类 main ----
    // ★2026-10-18 真机行为修正★
    //   MC 的 main 是【不会返回】的（它一直跑到游戏退出）。旧实现同步调用它 ⇒
    //   启动完成回调永远不触发 ⇒ 启动器一直转圈。
    //   ⇒ 把 main 派发到后台线程，主流程立即返回成功（启动器收转圈），游戏侧继续跑。
    a2_progress_enter(A2StageWaitingFirstFrame);   // 阶段7
    {
        JavaVM *vmRef = vm;
        NSString *mainCls = [builder.mainClass copy];
        NSArray *pargs = [builder.programArgs copy];
        // ★cwd 必须切到 gameDir★（真机证据：MC 报 logs/latest.log 相对路径找不到，
        //   说明进程 cwd 不是 gameDir；老启动器在进 Main 之前都做这一步）。
        //   否则 MC 里按相对路径读到的内容会被当成配置解析，表现是 gson
        //   "Expected BEGIN_OBJECT but was STRING" 之类的假错误。
        NSUInteger a2gdIdx = [pargs indexOfObject:@"--gameDir"];
        NSString *a2gd = (a2gdIdx != NSNotFound && a2gdIdx + 1 < pargs.count) ? pargs[a2gdIdx + 1] : nil;
        if (a2gd.length > 0) {
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm createDirectoryAtPath:[a2gd stringByAppendingPathComponent:@"logs"]
          withIntermediateDirectories:YES attributes:nil error:nil];
            int rc = chdir(a2gd.UTF8String);
            a2_log_f(@"[RT-P1] chdir(gameDir) rc=%d path=%@", rc, a2gd);
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            JNIEnv *tenv = NULL;
            if (vmRef == NULL || (*vmRef)->AttachCurrentThread(vmRef, (void **)&tenv, NULL) != 0 || tenv == NULL) {
                a2_log_fatal(@"[RT-P1] main 派发线程 AttachCurrentThread 失败");
                return;
            }
            int mrc2 = a2_run_main(tenv, mainCls, pargs);
            a2_log_f(@"[RT-P1] 主类 main 返回 rc=%d（后台线程；MC 正常运行时不会走到这里）", mrc2);
        });
    }
    a2_log_line(@"[RT-P1] 主类 main 已派发到后台线程 ⇒ 启动器可以收转圈");

    // ★心跳判据（2026-10-18）★ 真机出现「无崩溃报告、日志突然截断」的静默结束（SIGKILL），
    //   信号处理器接不到。这里每 3 秒写一行，日志最后一条心跳的时刻 = 进程死亡时刻，
    //   配合设备崩溃报告就能判定是"被系统杀"还是"我们卡住"。
    {
        static volatile int hbStop = 0;
        hbStop = 0;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int n = 0;
            while (!hbStop) {
                sleep(3);
                n += 3;
                a2_log_f(@"[A2-HB] 存活 %ds（main 线程=%d）", n, (int)!NSThread.isMainThread);
                if (n >= 600) break;   // 10 分钟后不再刷，避免日志无限长
            }
        });
    }
    a2_progress_enter(A2StageCompleted);
    return 0;
}

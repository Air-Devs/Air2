// ============================================================================
// Natives/runtime/a2_launch.m
// ★ [RT-P1] facade 启动编排（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.3/§3.4/§3.6 + §4
// ============================================================================
#import "a2_launch.h"
#import "a2_log.h"            // R7
#import "a2_argbuilder.h"     // R3
#import "a2_resourcepaths.h"  // R4
#import "a2_vmloader.h"       // R2

#include <stdlib.h>

// ============================================================================
// facade 开关（唯一读环境变量的地方；读一次 → 显式下传）
// ============================================================================
BOOL a2_launch_runtime_enabled(void) {
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
    NSNumber *prefOn = [[NSUserDefaults standardUserDefaults] objectForKey:@"debug.rt_p1_runtime"];
    if (prefOn != nil && [prefOn boolValue]) {
        a2_log_line(@"[RT-P1][SWITCH] runtime 链=开（源: 设置项 debug.rt_p1_runtime）");
        return YES;
    }
    a2_log_line(@"[RT-P1][SWITCH] runtime 链=关（默认 ⇒ 旧链；可在 设置 → 调试 打开「使用全新启动链」，或放 $POJAV_HOME/rt_p1_runtime.enable）");
    return NO;
}

// ============================================================================
// 在已创建的 VM 内 dispatch 主类 main（JNI_CreateJavaVM 不会自动跑 main）
// ============================================================================
static int a2_run_main(JNIEnv *env, NSString *mainClass, NSArray<NSString *> *args) {
    if (env == NULL || mainClass.length == 0) return -5;

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
    a2_log_line(@"[RT-P1] runtime 层启用：launchJVM 切到自研链（R3+R4+R7+R2；旧链保留为回退）");
    a2_progress_enter(A2StageArgsReady);   // 阶段5

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
        NSString *why = builder.jarMode ? @"-jar 形态（runtime 层暂不支持）" : @"未解析出主类";
        a2_progress_fail(A2StageArgsReady, why);
        a2_log_fatal(@"[RT-P1] R3 摄取失败：%s ⇒ facade 须回退旧链", why.UTF8String);
        return -1;
    }
    a2_log_f(@"[RT-P1] R3 ingest ok: %s", [builder summary].UTF8String);
    a2_log_f(@"[RT-P1] R3 classpath 形态=%s（A=-Djava.class.path / B=-cp 条目；env RT_CP_FORM 可切）",
             (cpForm == A2ClasspathFormOption) ? "B" : "A");

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
    a2_log_f(@"[RT-P1] R4 paths: frameworks=%s tmp=%s javaHome=%s",
             paths.frameworksPath.UTF8String, (paths.tmpDir ?: @"(nil)").UTF8String,
             (paths.javaHome ?: @"(nil)").UTF8String);

    // 漂移对照：R4 重算的 classpath 应与旧 margv 摄取的 classpath 一致（不一致只记日志）。
    if (paths.classpath.length > 0 && builder.classpath.length > 0 &&
        ![paths.classpath isEqualToString:builder.classpath]) {
        a2_log_f(@"[RT-P1] WARN classpath 漂移：margv=%s  R4=%s",
                 builder.classpath.UTF8String, paths.classpath.UTF8String);
    }
    if (builder.classpath.length == 0 && paths.classpath.length > 0) {
        [builder setClasspath:paths.classpath];         // 摄取未带 classpath 时的兜底
    }
    if (builder.mainClass.length == 0) {
        a2_progress_fail(A2StageArgsReady, @"主类为空");
        return -2;
    }

    // ---- R2：定位 libjvm + 建 VM ----
    NSString *libjvm = a2_vm_resolve_libjvm(input.javaHome);
    if (!libjvm) {
        a2_progress_fail(A2StageArgsReady, @"未找到 libjvm.dylib");
        a2_log_fatal(@"[RT-P1] 定位 libjvm 失败 ⇒ 无可用 JRE");
        return -3;
    }
    a2_log_f(@"[RT-P1] R2 libjvm=%s java.home=%s", libjvm.UTF8String, input.javaHome.UTF8String);

    A2VMArgsBundle *bundle = [builder buildInitArgsWithVersion:0x00010008
                                            ignoreUnrecognized:ignoreUnrecognized];
    JavaVMInitArgs vmArgs = [bundle initArgs];
    a2_log_f(@"[RT-P1] R3 JavaVMInitArgs: nOptions=%d ignoreUnrecognized=%d",
             vmArgs.nOptions, vmArgs.ignoreUnrecognized);

    a2_progress_enter(A2StageJVMStarting);   // 阶段6
    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint usedVer = 0;
    int rc = a2_vm_create(libjvm, [bundle optionStrings], [bundle optionCount],
                          ignoreUnrecognized, &vm, &env, &usedVer);
    if (rc != 0) {
        a2_progress_fail(A2StageJVMStarting, [NSString stringWithFormat:@"R2 rc=%d", rc]);
        a2_log_fatal(@"[RT-P1] R2 建 VM 失败 rc=%d（请求 JNI 版本 0x00010008）", rc);
        return -4;
    }
    a2_log_f(@"[RT-P1] R2 VM ready: usedVer=0x%08x env=%p", (unsigned)usedVer, (void *)env);

    // ---- 阶段7：派发主类 main（此后由游戏/安装器接管；真·首帧完成由既有链路负责）----
    a2_progress_enter(A2StageWaitingFirstFrame);   // 阶段7
    int mrc = a2_run_main(env, builder.mainClass, builder.programArgs);
    if (mrc != 0) {
        a2_progress_fail(A2StageWaitingFirstFrame, [NSString stringWithFormat:@"main rc=%d", mrc]);
        a2_log_fatal(@"[RT-P1] 主类 main 派发失败 rc=%d", mrc);
        return mrc;
    }

    a2_progress_enter(A2StageCompleted);
    a2_log_line(@"[RT-P1] 主类 main 正常返回（runtime 链收尾）");
    return 0;
}

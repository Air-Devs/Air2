// ============================================================================
// Natives/runtime/a2_vmloader.m
// ★ [RT-P1] R2 —— VMLoader（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.2
// ============================================================================
#import "a2_vmloader.h"
#import "a2_log.h"        // [A2JVM] R4/R5 与心跳行（单一日志出口）

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>

// 输入签名：JNI_CreateJavaVM(JavaVM **pvm, void **penv, void *args)
typedef jint (*a2_create_vm_fn)(JavaVM **, void **, void *);

NSString *a2_vm_resolve_libjvm(NSString *javaHome) {
    if (javaHome.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    // 三布局：Java 11+ 与本工程 java-{8,17,21,25}-openjdk；经典 macOS JDK8；历史 hotspot。
    NSArray<NSString *> *rels = @[ @"lib/server/libjvm.dylib",
                                   @"jre/lib/server/libjvm.dylib",
                                   @"lib/hotspot/libjvm.dylib" ];
    for (NSString *rel in rels) {
        NSString *p = [javaHome stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>

/// ★心跳★：建 VM 期间每 10 秒打一行 —— 让「卡死」与「慢」在日志上分得开。
/// 退出条件：a2_vm_create 返回后把 gA2VMInFlight 置 0，线程自然结束（detached）。
static atomic_int gA2VMInFlight = 0;

static void *a2_vm_heartbeat(void *ctx) {
    (void)ctx;
    int seconds = 0;
    while (atomic_load(&gA2VMInFlight) != 0) {
        sleep(10);
        seconds += 10;
        if (atomic_load(&gA2VMInFlight) == 0) break;
        a2_log_f(@"[A2JVM] 建 VM 仍在进行（已 %ds）—— JNI_CreateJavaVM 未返回", seconds);
    }
    return NULL;
}


/// ★建 VM 前必须把崩溃兜底装的信号处理器复位★
/// 依据:老线 Natives/JavaLauncher.m:2762-2771 在 JLI_Launch 之前显式
///   signal(SIGSEGV/SIGPIPE/SIGILL/SIGFPE, SIG_DFL) —— HotSpot 要靠
///   SIGSEGV(隐式空指针检查/安全点轮询)自己接管;若被 App 的 handler 占着,
///   VM 初始化会停在原地(JNI_CreateJavaVM 不返回,死因与真机现象一致)。
void a2_vm_reset_signal_handlers(void) {
    signal(SIGSEGV, SIG_DFL);
    signal(SIGBUS,  SIG_DFL);
    signal(SIGILL,  SIG_DFL);
    signal(SIGFPE,  SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTRAP, SIG_DFL);
    a2_log_f(@"[A2JVM] 信号处理器已复位 SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGPIPE/SIGTRAP -> SIG_DFL（JVM 要自己接管）");
}


// ============================================================================
// ★卡住探针★：建 VM 期间若 20 秒不返回，就暂停这条线程、取 pc/lr/sp/fp，
// 并用 dladdr 解析出「落在哪个镜像/哪个符号」——把“永远不知道卡在哪”变成一行日志。
// 只在诊断期用；拿到结论后应删除（见报告）。
// ============================================================================
static atomic_int  gA2VMProbeDone   = 0;
static atomic_int  gA2VMStuckLogged = 0;
static mach_port_t gA2VMThreadPort  = MACH_PORT_NULL;

static const char *a2_vm_short_image(uintptr_t addr, Dl_info *info, long *offsetOut) {
    if (addr == 0 || dladdr((void *)addr, info) == 0) { if (offsetOut) *offsetOut = 0; return "?"; }
    const char *path = info->dli_fname ?: "?";
    const char *slash = strrchr(path, '/');
    if (offsetOut) *offsetOut = (long)(addr - (uintptr_t)info->dli_fbase);
    return slash ? slash + 1 : path;
}

static void *a2_vm_stuck_probe(void *ctx) {
    (void)ctx;
    for (int waited = 0; waited < 20; waited += 2) {
        sleep(2);
        if (atomic_load(&gA2VMProbeDone)) return NULL;
    }
    if (gA2VMThreadPort == MACH_PORT_NULL) return NULL;
    if (atomic_exchange(&gA2VMStuckLogged, 1) != 0) return NULL;

    thread_suspend(gA2VMThreadPort);
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(gA2VMThreadPort, ARM_THREAD_STATE64,
                                        (thread_state_t)&st, &cnt);
    if (kr == KERN_SUCCESS) {
        uintptr_t pc = (uintptr_t)st.__pc, lr = (uintptr_t)st.__lr;
        Dl_info ipc = {0}, ilr = {0};
        long offPC = 0, offLR = 0;
        const char *imgPC = a2_vm_short_image(pc, &ipc, &offPC);
        const char *imgLR = a2_vm_short_image(lr, &ilr, &offLR);
        a2_log_f(@"[A2JVM] ★卡在 VM 创建(20s)：pc=0x%lx (%s+%ld sym=%s) lr=0x%lx (%s+%ld sym=%s) sp=0x%lx fp=0x%lx x0=0x%llx x1=0x%llx",
                 (unsigned long)pc, imgPC, offPC, ipc.dli_sname ?: "?",
                 (unsigned long)lr, imgLR, offLR, ilr.dli_sname ?: "?",
                 (unsigned long)(uintptr_t)st.__sp, (unsigned long)(uintptr_t)st.__fp,
                 (unsigned long long)st.__x[0], (unsigned long long)st.__x[1]);
    } else {
        a2_log_f(@"[A2JVM] ★卡在 VM 创建(20s)：thread_get_state 失败 kr=%d", (int)kr);
    }
    thread_resume(gA2VMThreadPort);
    return NULL;
}

/// 在大栈线程上调 createVM（GCD 线程栈只有 ~512KB；VM 初始化可能需要更多）。
typedef struct {
    a2_create_vm_fn fn;
    JavaVM **vm;
    void **env;
    JavaVMInitArgs *args;
    jint rc;
} A2VMCallJob;

static void *a2_vm_call_worker(void *p) {
    A2VMCallJob *job = (A2VMCallJob *)p;
    gA2VMThreadPort = pthread_mach_thread_np(pthread_self());   // 探针盯这条
    job->rc = job->fn(job->vm, job->env, job->args);
    return NULL;
}

int a2_vm_create(NSString *libjvmPath,
                 const char *const optionStrings[], int nOptions,
                 BOOL ignoreUnrecognized,
                 JavaVM **outVM, JNIEnv **outEnv, jint *outUsedVersion) {
    if (libjvmPath.length == 0 || nOptions < 0) return 1;

    a2_vm_reset_signal_handlers();

    // ★启动器环境★：真正的 java 启动器在调 VM 前会置 JAVA_HOME；我们从 libjvm 路径反推。
    {
        NSString *jh = libjvmPath;
        for (NSString *suffix in @[ @"/lib/server/libjvm.dylib",
                                    @"/jre/lib/server/libjvm.dylib",
                                    @"/lib/hotspot/libjvm.dylib" ]) {
            if ([jh hasSuffix:suffix]) {
                jh = [jh substringToIndex:jh.length - suffix.length];
                break;
            }
        }
        setenv("JAVA_HOME", jh.UTF8String, 1);
        BOOL hasJavaHomeOpt = NO;
        for (int i = 0; i < nOptions; i++) {
            if (optionStrings[i] && strncmp(optionStrings[i], "-Djava.home=", 13) == 0) { hasJavaHomeOpt = YES; break; }
        }
        a2_log_f(@"[A2JVM] env JAVA_HOME=%s java.home选项=%@", jh.UTF8String, hasJavaHomeOpt ? @"有" : @"无");
    }

    // R2.1 dlopen(libjvm)：RTLD_NOW 立即绑定、RTLD_LOCAL 不污染全局符号表（§3.2 主路径）
    void *libjvm = dlopen(libjvmPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!libjvm) return 2;

    // 心跳线程（失败不影响建 VM；只是少了“还在进行”的行）
    atomic_store(&gA2VMInFlight, 1);
    pthread_t hb;
    pthread_attr_t hbAttr;
    pthread_attr_init(&hbAttr);
    pthread_attr_setdetachstate(&hbAttr, PTHREAD_CREATE_DETACHED);
    pthread_create(&hb, &hbAttr, a2_vm_heartbeat, NULL);
    pthread_attr_destroy(&hbAttr);

    // 卡住探针（20s 后抓 pc/lr/镜像）
    atomic_store(&gA2VMProbeDone, 0);
    atomic_store(&gA2VMStuckLogged, 0);
    gA2VMThreadPort = pthread_mach_thread_np(pthread_self());   // 兜底：若大栈线程建失败
    pthread_t probeTh;
    pthread_attr_t probeAttr;
    pthread_attr_init(&probeAttr);
    pthread_attr_setdetachstate(&probeAttr, PTHREAD_CREATE_DETACHED);
    pthread_create(&probeTh, &probeAttr, a2_vm_stuck_probe, NULL);
    pthread_attr_destroy(&probeAttr);

    a2_create_vm_fn createVM = (a2_create_vm_fn)dlsym(libjvm, "JNI_CreateJavaVM");
    if (!createVM) return 3;

    // R2.2 组装 JavaVMOption（optionString 由调用方 R3 持有；本函数只借用不释放）
    JavaVMOption *opts = (JavaVMOption *)calloc((size_t)(nOptions > 0 ? nOptions : 1),
                                                sizeof(JavaVMOption));
    for (int i = 0; i < nOptions; i++) {
        opts[i].optionString = (char *)optionStrings[i];
        opts[i].extraInfo    = NULL;
    }

    // R2.3 版本自适应（Java 8 只认 1.8；较新 VM 亦接受 1.8，万一拒绝则退到 9/10/21/25）
    //   ★ [VS-GAP][G4] 补 0x00190000(JNI 25) 显式项，与 P0 自举 jni_boot.m 的 kVersions 同口径
    //     （两处表保持一致，避免 runtime 链在 java-25 上无匹配 version 项可用）。
    const jint kVersions[] = { 0x00010008 /*1.8*/, 0x00090000 /*9*/,
                               0x000a0000 /*10*/, 0x00150000 /*21*/,
                               0x00190000 /*25*/ };
    const int kVerCount = (int)(sizeof(kVersions) / sizeof(kVersions[0]));
    jint rc = JNI_ERR, used = 0;
    JavaVM *vm = NULL; JNIEnv *env = NULL;
    for (int i = 0; i < kVerCount; i++) {
        JavaVMInitArgs args;
        memset(&args, 0, sizeof(args));
        args.version            = kVersions[i];
        args.nOptions           = nOptions;
        args.options            = opts;
        args.ignoreUnrecognized = ignoreUnrecognized ? JNI_TRUE : JNI_FALSE;

        vm = NULL; env = NULL;
        a2_log_f(@"[A2JVM] R4 调用 JNI_CreateJavaVM（version=0x%08x nOptions=%d）—— 若之后没有 R5 行 ⇒ 卡在 VM 初始化",
                 (unsigned)args.version, nOptions);
        // ★大栈线程★：GCD 线程栈 ~512KB，VM 初始化可能需要更多（老线在专用线程上起）
        A2VMCallJob job;
        job.fn = createVM; job.vm = &vm; job.env = (void **)&env; job.args = &args; job.rc = JNI_ERR;
        pthread_t vmTh;
        pthread_attr_t vmAttr;
        pthread_attr_init(&vmAttr);
        pthread_attr_setstacksize(&vmAttr, 8ull * 1024ull * 1024ull);
        int vmThRC = pthread_create(&vmTh, &vmAttr, a2_vm_call_worker, &job);
        pthread_attr_destroy(&vmAttr);
        if (vmThRC == 0) {
            a2_log_f(@"[A2JVM] 建 VM 线程=大栈(8MB)");
            pthread_join(vmTh, NULL);
            rc = job.rc;
        } else {
            a2_log_f(@"[A2JVM] 建 VM 线程=当前线程(pthread_create 失败 rc=%d)", vmThRC);
            gA2VMThreadPort = pthread_mach_thread_np(pthread_self());
            rc = createVM(&vm, (void **)&env, &args);
        }
        a2_log_f(@"[A2JVM] R5 JNI_CreateJavaVM 返回 rc=%d vm=%p env=%p", rc, (void *)vm, (void *)env);
        if (rc == JNI_OK) { used = kVersions[i]; break; }
        if (rc != JNI_EVERSION) break;   // 非版本问题，重试无意义
    }
    free(opts);
    atomic_store(&gA2VMInFlight, 0);   // 心跳收尾
    atomic_store(&gA2VMProbeDone, 1);  // 探针收尾

    if (rc != JNI_OK || env == NULL) return 4;
    if (outVM)          *outVM = vm;
    if (outEnv)         *outEnv = env;
    if (outUsedVersion) *outUsedVersion = used;
    return 0;
}

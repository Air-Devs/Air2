//
//  A2JVMContext.m
//  Air2
//
//  实现 —— 逐条搬运自 feat/runtime-native 的 Natives/runtime/jni_boot.m：
//    · R1 libjvm 布局探测（L157–L170）
//    · R2 VMLoader（L241–L375）：dlopen + dlsym(JNI_CreateJavaVM) + 最小 JavaVMInitArgs
//      + 版本自适应 + GetVersion + 可选 DestroyJavaVM。
//    · 去掉了 PoC 的 HelloWorld/DefineClass 演示与 UI 提示条（后者属上层）。
//
//  依赖（见 docs/DEPENDENCIES.md）：OpenJDK（iOS build）提供 <jni.h>。
//

#import "A2JVMContext.h"
#import "A2JITEnvironment.h"   // 统一诊断日志 a2_jit_log（Natives/Support）

#if __has_include(<jni.h>)
#  include <jni.h>
#else
#  error "A2JVMContext 需要 <jni.h>（由 docs/DEPENDENCIES.md 登记的 OpenJDK 提供；编译 Natives 时须把其 include 路径加入）"
#endif

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

// JNI_CreateJavaVM(JavaVM **pvm, void **penv, void *args)
//   来源：jni_boot.m L147–L148。
typedef jint (*a2_create_vm_fn)(JavaVM **, void **, void *);

// 私有可写属性（对外只读）。
@interface A2JVMContext ()
@property (nonatomic, readwrite, nullable) void *vm;
@property (nonatomic, readwrite, nullable) void *env;
@property (nonatomic, readwrite) int actualJNIVersion;
@property (nonatomic, readwrite, copy) NSString *libjvmPath;
@property (nonatomic, readwrite) A2JVMStage stage;
@property (nonatomic, assign, nullable) void *libjvmHandle;   // dlopen 句柄，供 destroy
@end

// ============================================================================
// R1 —— libjvm 布局探测
//   来源：jni_boot.m L157–L170（rt_libjvmIn）。
//   判据与工程既有 ameJREHomeLooksValid 同源：目录内存在 lib/server/libjvm.dylib。
//   本工程 java-{8,17,21,25}-openjdk 统一为 <home>/lib/server/libjvm.dylib；
//   另兼容经典 macOS JDK8 的 <home>/jre/lib/server 与历史 <home>/lib/hotspot 布局。
// ============================================================================
NSString *a2_jvm_locate_libjvm(NSString *javaHome) {
    if (javaHome.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    static NSString *const rels[] = {
        @"lib/server/libjvm.dylib",       // Java 11+ 与本工程 java-{8,17,21,25}-openjdk 统一布局
        @"jre/lib/server/libjvm.dylib",   // 经典 macOS JDK8（<Home>/jre/lib/server）
        @"lib/hotspot/libjvm.dylib",      // 历史兜底
    };
    for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); i++) {
        NSString *p = [javaHome stringByAppendingPathComponent:rels[i]];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// JNI 版本号 → 可读串（来源：jni_boot.m L224–L238）。
static NSString *a2_jvm_jni_version_string(int v) {
    switch (v) {
        case 0x00010002: return @"1.2";
        case 0x00010004: return @"1.4";
        case 0x00010006: return @"1.6";
        case 0x00010008: return @"1.8";
        case 0x00090000: return @"9";
        case 0x000a0000: return @"10";
        case 0x00110000: return @"17";
        case 0x00140000: return @"20";
        case 0x00150000: return @"21";
        case 0x00180000: return @"24";
        default: return [NSString stringWithFormat:@"0x%08x", (unsigned)v];
    }
}

#pragma mark - A2JVMConfig

@implementation A2JVMConfig

+ (instancetype)configWithJavaHome:(NSString *)javaHome {
    A2JVMConfig *c = [A2JVMConfig new];
    c.javaHome = javaHome;
    c.classPath = @"";
    c.useMirrorMappedCodeCache = NO;
    c.isJava8 = NO;
    c.reservedCodeCacheSizeMB = 64;
    c.initialCodeCacheSizeMB = 16;
    c.codeCacheExpansionSizeMB = 4;
    return c;
}

@end

#pragma mark - A2JVMContext

// 统一的失败收口（用 static 函数而非 block：避免 block 捕获对象 out-param
// 触发 -Wblock-capture-autoreleasing 的潜在 use-after-free）。
static A2JVMContext *a2_jvm_fail(A2JVMStage stage, NSString *why,
                                 A2JVMStage *stageOut, NSString **reasonOut) {
    if (stageOut) *stageOut = stage;
    if (reasonOut) *reasonOut = why;
    a2_jit_log("[A2JVM] create FAILED stage=%ld: %s", (long)stage, why.UTF8String);
    return nil;
}

@implementation A2JVMContext

+ (instancetype)createWithConfig:(A2JVMConfig *)config
                           stage:(A2JVMStage *)stageOut
                          reason:(NSString **)reasonOut {

    // ---- javaHome → libjvm 真身 ----
    if (config.javaHome.length == 0) {
        return a2_jvm_fail(A2JVMStageNoLibjvm, @"javaHome 为空", stageOut, reasonOut);
    }
    NSString *libjvmPath = a2_jvm_locate_libjvm(config.javaHome);
    if (libjvmPath.length == 0) {
        return a2_jvm_fail(A2JVMStageNoLibjvm, [NSString stringWithFormat:
            @"javaHome 内未找到 libjvm.dylib: %@", config.javaHome], stageOut, reasonOut);
    }

    // ---- dlopen(libjvm)：RTLD_NOW 立即绑定、RTLD_LOCAL 不污染全局符号表 ----
    //   来源：jni_boot.m L243–L248。★同进程内★，不经 libjli。
    void *libjvm = dlopen(libjvmPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!libjvm) {
        return a2_jvm_fail(A2JVMStageDlopenFailed, [NSString stringWithFormat:
            @"dlopen(libjvm) 失败: %s", dlerror() ?: "(null)"], stageOut, reasonOut);
    }
    a2_jit_log("[A2JVM] dlopen(libjvm) ok -> %s", libjvmPath.UTF8String);

    a2_create_vm_fn createVM = (a2_create_vm_fn)dlsym(libjvm, "JNI_CreateJavaVM");
    if (!createVM) {
        dlclose(libjvm);
        return a2_jvm_fail(A2JVMStageDlsymFailed, [NSString stringWithFormat:
            @"dlsym(JNI_CreateJavaVM) 失败: %s", dlerror() ?: "(null)"], stageOut, reasonOut);
    }
    a2_jit_log("[A2JVM] dlsym(JNI_CreateJavaVM) ok");

    // ---- 最小 JavaVMInitArgs（来源：jni_boot.m L257–L291）----
    //   只给 java.home；其余由 VM 从 java.home 推导（Java 9+ lib/modules；Java 8 lib/rt.jar）。
    //   选项字符串用栈缓冲，生命周期覆盖到 JNI_CreateJavaVM 返回，无需堆分配/释放。
    char opt_home[2048];
    snprintf(opt_home, sizeof(opt_home), "-Djava.home=%s", config.javaHome.UTF8String);
    char opt_res[64], opt_init[64], opt_exp[64];
    snprintf(opt_res,  sizeof(opt_res),  "-XX:ReservedCodeCacheSize=%llum", config.reservedCodeCacheSizeMB);
    snprintf(opt_init, sizeof(opt_init), "-XX:InitialCodeCacheSize=%llum", config.initialCodeCacheSizeMB);
    snprintf(opt_exp,  sizeof(opt_exp),  "-XX:CodeCacheExpansionSize=%llum", config.codeCacheExpansionSizeMB);

    JavaVMOption opts[8];
    int nOpts = 0;
    opts[nOpts].optionString = opt_home;              opts[nOpts].extraInfo = NULL; nOpts++;
    opts[nOpts].optionString = "-Djava.class.path=";  opts[nOpts].extraInfo = NULL; nOpts++;  // 用 DefineClass，不依赖 classpath
    if (!config.isJava8) {
        // CodeCache 尺寸对齐 JavaLauncher(64m/16m/4m)，避免 256m 镜像区越界 SIGBUS。
        opts[nOpts].optionString = opt_res;  opts[nOpts].extraInfo = NULL; nOpts++;
        opts[nOpts].optionString = opt_init; opts[nOpts].extraInfo = NULL; nOpts++;
        opts[nOpts].optionString = opt_exp;  opts[nOpts].extraInfo = NULL; nOpts++;
    }
    if (config.useMirrorMappedCodeCache && nOpts + 2 <= 8) {
        // ★iOS 26+ 非 Java 8 的 VM 走 -XX:+MirrorMappedCodeCache：code cache 的 RX 内存由
        //   在场调试器经 brk #0x69 分配交付；不加此选项时 JVM 走普通 mmap(RW)+mprotect(RX)，
        //   在无 dynamic-codesigning/allow-jit entitlement 的机器上取指保护失败 ⇒ SIGBUS。
        //   来源：jni_boot.m L286–L289。
        opts[nOpts].optionString = "-XX:+UnlockExperimentalVMOptions"; opts[nOpts].extraInfo = NULL; nOpts++;
        opts[nOpts].optionString = "-XX:+MirrorMappedCodeCache";       opts[nOpts].extraInfo = NULL; nOpts++;
    }
    a2_jit_log("[A2JVM] options(n=%d java8=%d mirrorMappedCodeCache=%d): java.home=%s",
               nOpts, (int)config.isJava8, (int)config.useMirrorMappedCodeCache, config.javaHome.UTF8String);

    // ---- 版本自适应：Java 8 只认 1.8；较新 VM 亦接受 1.8，万一拒绝则依次退到 9/10/21 ----
    const jint kVersions[] = { 0x00010008 /*1.8*/, 0x00090000 /*9*/,
                               0x000a0000 /*10*/, 0x00150000 /*21*/ };
    const int kVerCount = (int)(sizeof(kVersions) / sizeof(kVersions[0]));

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint rc = JNI_ERR;
    jint usedVer = 0;
    for (int i = 0; i < kVerCount; i++) {
        JavaVMInitArgs args;
        memset(&args, 0, sizeof(args));
        args.version = kVersions[i];
        args.nOptions = nOpts;
        args.options = opts;
        args.ignoreUnrecognized = JNI_FALSE;

        vm = NULL; env = NULL;
        rc = createVM(&vm, (void **)&env, &args);
        if (rc == JNI_OK) { usedVer = kVersions[i]; break; }
        a2_jit_log("[A2JVM] JNI_CreateJavaVM attempt ver=%s -> rc=%d",
                   a2_jvm_jni_version_string(kVersions[i]).UTF8String, rc);
        if (rc != JNI_EVERSION) break;   // 非版本问题，重试无意义
    }
    if (rc != JNI_OK || env == NULL) {
        const char *err = dlerror();
        a2_jit_log("[A2JVM] JNI_CreateJavaVM FAILED rc=%d%s%s", rc,
                   err ? " dlerror=" : "", err ?: "");
        dlclose(libjvm);
        return a2_jvm_fail(A2JVMStageCreateVMFailed, [NSString stringWithFormat:
            @"JNI_CreateJavaVM 失败（rc=%d，多为 JIT/内存）", rc], stageOut, reasonOut);
    }

    jint actual = (*env)->GetVersion(env);
    a2_jit_log("[A2JVM] JNI_CreateJavaVM ok ver=%s (requested 0x%08x actual 0x%08x)",
               a2_jvm_jni_version_string(actual).UTF8String, (unsigned)usedVer, (unsigned)actual);

    A2JVMContext *ctx = [A2JVMContext new];
    ctx.vm = (void *)vm;
    ctx.env = (void *)env;
    ctx.actualJNIVersion = (int)actual;
    ctx.libjvmPath = libjvmPath;
    ctx.stage = A2JVMStageOK;
    ctx.libjvmHandle = libjvm;
    if (stageOut) *stageOut = A2JVMStageOK;
    if (reasonOut) *reasonOut = @"ok";
    // ★PoC 语义：成功创建后不 DestroyJavaVM（保活，留给后续阶段接管）。见 jni_boot.m L373。
    return ctx;
}

- (void)destroy {
    if (self.vm != NULL) {
        a2_jit_log("[A2JVM] DestroyJavaVM ...");
        JavaVM *vm = (JavaVM *)self.vm;
        (*vm)->DestroyJavaVM(vm);
        self.vm = NULL;
        self.env = NULL;
    }
    if (self.libjvmHandle != NULL) {
        dlclose(self.libjvmHandle);
        self.libjvmHandle = NULL;
    }
}

@end

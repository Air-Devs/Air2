// ============================================================================
// Natives/runtime/a2_vmloader.m
// ★ [RT-P1] R2 —— VMLoader（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.2
// ============================================================================
#import "a2_vmloader.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

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

int a2_vm_create(NSString *libjvmPath,
                 const char *const optionStrings[], int nOptions,
                 BOOL ignoreUnrecognized,
                 JavaVM **outVM, JNIEnv **outEnv, jint *outUsedVersion) {
    if (libjvmPath.length == 0 || nOptions < 0) return 1;

    // R2.1 dlopen(libjvm)：RTLD_NOW 立即绑定、RTLD_LOCAL 不污染全局符号表（§3.2 主路径）
    void *libjvm = dlopen(libjvmPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!libjvm) return 2;

    a2_create_vm_fn createVM = (a2_create_vm_fn)dlsym(libjvm, "JNI_CreateJavaVM");
    if (!createVM) return 3;

    // R2.2 组装 JavaVMOption（optionString 由调用方 R3 持有；本函数只借用不释放）
    JavaVMOption *opts = (JavaVMOption *)calloc((size_t)(nOptions > 0 ? nOptions : 1),
                                                sizeof(JavaVMOption));
    for (int i = 0; i < nOptions; i++) {
        opts[i].optionString = (char *)optionStrings[i];
        opts[i].extraInfo    = NULL;
    }

    // R2.3 版本自适应（Java 8 只认 1.8；较新 VM 亦接受 1.8，万一拒绝则退到 9/10/21）
    const jint kVersions[] = { 0x00010008 /*1.8*/, 0x00090000 /*9*/,
                               0x000a0000 /*10*/, 0x00150000 /*21*/ };
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
        rc = createVM(&vm, (void **)&env, &args);
        if (rc == JNI_OK) { used = kVersions[i]; break; }
        if (rc != JNI_EVERSION) break;   // 非版本问题，重试无意义
    }
    free(opts);

    if (rc != JNI_OK || env == NULL) return 4;
    if (outVM)          *outVM = vm;
    if (outEnv)         *outEnv = env;
    if (outUsedVersion) *outUsedVersion = used;
    return 0;
}

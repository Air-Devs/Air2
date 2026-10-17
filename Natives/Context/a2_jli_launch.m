// ============================================================================
// Natives/Context/a2_jli_launch.m
// ★ [JLI-LAUNCH] dlopen(libjli) → dlsym(JLI_Launch) → 调用（实现）
// ----------------------------------------------------------------------------
// 调用约定（与老线验过的那条一致，逐项说明「为什么」）：
//   · dlopen 用 RTLD_GLOBAL：libjli 之后要自己去 dlopen libjvm 并让 JNI 符号互相可见，
//     RTLD_LOCAL 会把符号表关在本镜像内（老线同款）。
//   · 调前 setenv("INTERNAL_JLI_PATH", <选中的 libjli>)：libjli 靠它定位自身/同源目录，
//     而不是去算「主可执行文件路径」（iOS 上那是 Air2.app/Air2，推出错的 java.home）。
//   · 调前把 SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGPIPE/SIGTRAP 复位为 SIG_DFL：
//     HotSpot 要用 SIGSEGV 做隐式空指针检查/安全点轮询，App 的崩溃兜底 handler 占着它就停在那儿。
//   · argv 里的 C 字符串必须活到 JLI_Launch 返回：本函数用 strong 的 NSArray 强引用每条
//     NSString，再由它取 UTF8String —— 不依赖 autorelease pool 什么时候 drain（悬垂指针 = 随机崩）。
//   · 14 个实参：jargs/appclasspath 全空（classpath 走 argv 的 -cp），版本串仅 Java 8 布局有意义
//     （Java 17+ 忽略），cpwildcard=JNI_TRUE（允许 `<dir>/*`），ergo=JNI_TRUE。
// ============================================================================
#import "a2_jli_launch.h"
#import "a2_log.h"        // 判据行统一出口（J1/J2/J3 默认可见）
#import "a2_vmloader.h"   // a2_vm_reset_signal_handlers（与 JNI 路径共用同一份复位实现）

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#include "jni.h"          // jboolean / JNI_TRUE / JNI_FALSE（含 include_directories 的 Natives/）

// JLI_Launch 的函数签名（OpenJDK 启动器导出，Java 8 与 9+ 一致）：
//   argc/argv                 完整 java 命令行（argv[0] = java 可执行路径）
//   jargc/jargv               JAVA_ARGS 区（我们不用 ⇒ 0/NULL）
//   appclassc/appclassv       app classpath 区（同上 ⇒ 0/NULL，classpath 走 -cp）
//   fullversion/dotversion    版本串（Java 17+ 忽略，Java 8 布局用它做 ergonomics）
//   pname/lname               程序名/启动器名
//   javaargs/cpwildcard/javaw/ergo  启动器策略位
typedef jint (*a2_jli_launch_fn)(int argc, const char **argv,
                                 int jargc, const char **jargv,
                                 int appclassc, const char **appclassv,
                                 const char *fullversion, const char *dotversion,
                                 const char *pname, const char *lname,
                                 jboolean javaargs, jboolean cpwildcard,
                                 jboolean javaw, jint ergo);

int a2_vm_launch_with_jli(NSString *javaHome,
                          NSArray<NSString *> *argv,
                          NSString *classpath,
                          NSString *mainClass,
                          int *outJLIRC) {
    if (outJLIRC) *outJLIRC = 0;
    if (javaHome.length == 0 || argv.count == 0 || mainClass.length == 0) {
        a2_log_criterion(@"[A2JVM] J1 dlopen libjli 未尝试：入参非法（javaHome=%@ argv=%lu main=%@）",
                         javaHome.length ? javaHome : @"(空)",
                         (unsigned long)argv.count,
                         mainClass.length ? mainClass : @"(空)");
        return A2JLIRCBadArgs;
    }

    // 1) 定位 + dlopen libjli（Java 8 布局优先，9+ 布局兜底）
    NSArray<NSString *> *candidates = a2_jli_candidate_paths(javaHome);
    NSString *libjliPath = a2_jli_resolve_libjli(javaHome);
    if (libjliPath.length == 0) {
        a2_log_criterion(@"[A2JVM] J1 dlopen libjli 失败：候选路径都不存在（javaHome=%@ 候选=%@）",
                         javaHome, [candidates componentsJoinedByString:@" | "]);
        return A2JLIRCDlopenFailed;
    }

    // HotSpot 需要自己接管这些信号：在 dlopen/建 VM 之前就复位（App 崩溃兜底不挡路）
    a2_vm_reset_signal_handlers();

    setenv("INTERNAL_JLI_PATH", libjliPath.UTF8String, 1);
    dlerror();                                        // 清陈旧错误，保证下面 dlerror() 说的就是本次
    void *libjli = dlopen(libjliPath.UTF8String, RTLD_GLOBAL);
    if (libjli == NULL) {
        const char *err = dlerror();
        a2_log_criterion(@"[A2JVM] J1 dlopen libjli 失败 path=%@ err=%s",
                         libjliPath, err ? err : "(dlerror 无输出)");
        return A2JLIRCDlopenFailed;
    }
    a2_log_criterion(@"[A2JVM] J1 dlopen libjli ok path=%@", libjliPath);

    // 2) 取 JLI_Launch
    a2_jli_launch_fn launch = (a2_jli_launch_fn)dlsym(libjli, "JLI_Launch");
    if (launch == NULL) {
        const char *err = dlerror();
        a2_log_criterion(@"[A2JVM] J1 dlopen libjli 失败：dlsym(JLI_Launch) 缺失 path=%@ err=%s",
                         libjliPath, err ? err : "(dlerror 无输出)");
        return A2JLIRCDlsymFailed;
    }

    // 3) 组 C argv：★字符串生命周期★
    //    strong 的 keep 持有每条 NSString（先 copy，防调用方回头改可变数组），
    //    cargv 里的指针指向这些 NSString 的 UTF-8 缓冲 ⇒ 只要 keep 活着就有效，
    //    与 autorelease pool 何时 drain 无关；keep 在本函数返回后才释放（> JLI_Launch 返回）。
    NSArray<NSString *> *keep = [argv copy];
    const NSUInteger n = keep.count;
    const char **cargv = (const char **)calloc(n + 1, sizeof(char *));
    if (cargv == NULL) {
        a2_log_criterion(@"[A2JVM] J1 dlopen libjli 失败：argv 分配失败（%lu 条）", (unsigned long)n);
        return A2JLIRCBadArgs;
    }
    for (NSUInteger i = 0; i < n; i++) {
        // UTF8String 非 NULL：NSString 非空即返回 C 串；空串也会返回 ""（保留原样）
        cargv[i] = keep[i].UTF8String ?: "";
    }
    cargv[n] = NULL;   // 防御：JLI 不该依赖它（argc 已给），但让越界读停在 NULL 上

    // 4) ★J2 判据行：在【进入调用前】打印★ ——
    //    JLI_Launch 一旦成功接管就（正常情况下）不再返回本进程；若它内部卡住/崩溃，
    //    这行是唯一能证明「已经进了 JLI」（而不是还停在我们自己的准备阶段）的证据。
    a2_log_criterion(@"[A2JVM] J2 JLI_Launch 已调用 argv=%lu classpathLen=%lu main=%@",
                     (unsigned long)n, (unsigned long)classpath.length, mainClass);

    jint rc = launch((int)n, cargv,
                     0, NULL,                 // jargc/jargv：JAVA_ARGS 区（不用）
                     0, NULL,                 // appclassc/appclassv（classpath 走 argv 的 -cp）
                     "1.8.0-internal", "1.8", // fullversion / dotversion（Java 17+ 忽略）
                     "java", "openjdk",       // pname / lname
                     JNI_FALSE,               // javaargs
                     JNI_TRUE,                // cpwildcard：允许 classpath 里的 `<dir>/*`
                     JNI_FALSE,               // javaw（仅 Windows 有意义）
                     JNI_TRUE);               // ergo

    // 5) 走到这里 = 主类 main 已结束（或启动器提前返回）⇒ J3 属「退出时」事件，非卡死判据
    a2_log_criterion(@"[A2JVM] J3 JLI_Launch 返回 rc=%d（主类 main 已结束；本行只在退出时出现）", (int)rc);

    if (outJLIRC) *outJLIRC = (int)rc;
    free(cargv);
    return A2JLIRCCalled;
}

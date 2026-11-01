// ============================================================================
// Natives/Context/a2_exit_guard.m
// ★[A2-EXIT-GUARD] 进程级退出拦截：exit / _exit / abort★
// ----------------------------------------------------------------------------
// 分层：本层只做「拦下 / 转调」+ 广播一个 native 已有的 notification，不认识 UIKit、
//   不判断「该弹什么页」（那是 App 层 A2AppDelegate 的事）。
//
// ★拦截判据只有一条★（a2_exit_guard_should_intercept）：
//   游戏运行中（gA2GameRunning==1）**且** 退出码非 0 ⇒ 拦。
//   · 非运行期（启动链里 / 已经退过一次）⇒ 原样转调原函数 —— 启动器自己的退出、
//     dlclose/静态析构里的 exit 都不能被改写；
//   · code==0（用户主动退出）⇒ 原样转调原函数 —— 遮罩不弹、行为与从前一字不变。
//
// ★为什么拦下后必须 park（不返回调用方）★：exit() 的契约是「不返回」。让它返回，调用方
//   就会继续跑 exit 之后的收尾代码（JVM 已假定自己要死），比停住更不可预测。所以本层
//   让**这一条线程**睡住，进程（主线程 + UIKit）继续活着 ⇒ 崩溃遮罩才有机会弹出来。
//
// ★与 A2CrashGuard 不双弹★（读过 Air2/App/A2CrashGuard.m 再写的）：
//   它用 `signal(SIGABRT, …)` 接 abort —— 那只在**真的**发了 SIGABRT 时才跑。本层拦下
//   abort 后**不转调**真 abort ⇒ 信号不会发出 ⇒ A2CrashGuard 那条路不进 ⇒ 不会两个页面。
//   反之（未拦截时）本层不介入，A2CrashGuard 的行为与从前完全一样。
//
// ★拦截装在哪★：`__DATA,__interpose` 表（元组唯一定义处）+ `a2_exit_guard_arm()` 里逐镜像
//   `dyld_dynamic_interpose`（真机生效的那一步 —— 原因见 arm() 的注释：dyld4 只登记
//   MH_DYLIB 镜像的静态 __interpose 段，App 主程序是 MH_EXECUTE）。
// ============================================================================
#include <dlfcn.h>       // dlsym(RTLD_NEXT) / dlopen(RTLD_NOLOAD)：取「原函数」与 dyld_dynamic_interpose
#include <mach-o/dyld.h> // _dyld_image_count / _dyld_get_image_header / _dyld_get_image_name
#include <mach-o/loader.h>   // struct mach_header（dyld_dynamic_interpose 的第一个实参）
#include <pthread.h>     // pthread_main_np：判据行里的「主线程=…」
#include <stdlib.h>      // exit / abort（interpose 的 replacee）
#include <string.h>      // strncmp：镜像路径过滤
#include <unistd.h>      // _exit / sleep
#import <Foundation/Foundation.h>
#import "a2_exit_guard.h"
#import "a2_log.h"      // a2_log_criterion（判据行统一出口：控制台 + 会话日志）

/// 游戏是否正在运行（定义处；写点/读点见 a2_exit_guard.h 的文件头）。
volatile sig_atomic_t gA2GameRunning = 0;

/// 游戏退出广播名（★native 侧唯一字面量定义处★，见 a2_exit_guard.h）。
NSString *const a2_exit_guard_exited_notification_name = @"A2GameExitedNotification";

/// abort 对外的「退出码」：约定 128+SIGABRT，与 shell 对「被 SIGABRT 杀掉」的报告口径一致
/// ⇒ 崩溃页上的退出码是 134（用户/日志一眼能认出是 SIGABRT，而不是一个来历不明的数字）。
static const int kA2ExitGuardAbortCode = 128 + SIGABRT;

#pragma mark - 原函数（转调用）

typedef void (*A2ExitGuardExitFn)(int);
typedef void (*A2ExitGuardAbortFn)(void);

/// 取「原函数」——★必须真的是原函数★：替换函数里再按名字调 `exit` 会调到自己身上（死递归）。
/// 两路取法：① `dlsym(RTLD_NEXT)`（本镜像之后的下一个镜像，即 libSystem）；
///           ② libSystem 句柄（`RTLD_NOLOAD` 只取句柄、不触发加载），句柄由紧跟的 `dlclose` 配平。
/// ★为什么不用 `dymd_dynamic_interpose` 那一路（见 Natives/Renderer/a2_gl_bridge.m）★：
///   那一路要「目标镜像的 mach_header」，而游戏 JVM 是 dlopen 进来的、之后还可能有别的镜像；
///   `__DATA,__interpose` 静态段是「对所有后加载镜像一并生效」，也正好能在 nm 里看到判据。
/// @return NULL = 两路都取不到（本机不可能：三者都由 libSystem 导出）⇒ 调用方 park 停住。
static void *a2_exit_guard_resolve_original(const char *name) {
    void *sym = dlsym(RTLD_NEXT, name);
    if (sym == NULL) {
        void *libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (libSystem != NULL) {
            sym = dlsym(libSystem, name);
            dlclose(libSystem);   // ★配平 NOLOAD 的引用★（libSystem 常驻，不会真被卸）
        }
    }
    return sym;
}

/// `exit` 的原函数（★懒取一次★；取到就缓存，避免每次退出路径都 dlsym）。
static A2ExitGuardExitFn a2_exit_guard_original_exit(void) {
    static A2ExitGuardExitFn orig = NULL;
    if (orig == NULL) orig = (A2ExitGuardExitFn)a2_exit_guard_resolve_original("exit");
    return orig;
}

/// `_exit` 的原函数（同上）。
static A2ExitGuardExitFn a2_exit_guard_original_underscore_exit(void) {
    static A2ExitGuardExitFn orig = NULL;
    if (orig == NULL) orig = (A2ExitGuardExitFn)a2_exit_guard_resolve_original("_exit");
    return orig;
}

/// `abort` 的原函数（同上）。
static A2ExitGuardAbortFn a2_exit_guard_original_abort(void) {
    static A2ExitGuardAbortFn orig = NULL;
    if (orig == NULL) orig = (A2ExitGuardAbortFn)a2_exit_guard_resolve_original("abort");
    return orig;
}

#pragma mark - 拦截动作

/// ★停住当前线程、永不返回★（替代「真退出」）。
/// 用 sleep 循环而不是 pause()：pause() 遇任何信号都会立刻返回，循环体会被反复执行；
/// sleep 只让**本线程**睡，进程与主线程上的 UIKit 继续活着 ⇒ 崩溃遮罩才弹得出来。
static void a2_exit_guard_park(void) __attribute__((noreturn));
static void a2_exit_guard_park(void) {
    for (;;) {
        sleep(60);
    }
}

/// ★拦截判据（唯一一处）★：游戏运行中 + 退出码非 0。
/// 写成函数而不是各处内联：判据只有一处，改口径就改这里。
static int a2_exit_guard_should_intercept(int code) {
    return (code != 0 && gA2GameRunning != 0) ? 1 : 0;
}

/// 广播「游戏异常退出」：主线程派发 + 与 a2_launch.m「主类 main 返回」同一个 notification
/// 名 / 同一个 userInfo 口径（`code` → NSNumber）⇒ App 层不用区分两个发出点。
static void a2_exit_guard_broadcast_exit(int code) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:a2_exit_guard_exited_notification_name
                          object:nil
                        userInfo:@{ @"code": @(code) }];
    });
}

/// 拦下之后的统一动作：打判据行（仅第一次）+ 广播 + park。
/// ★只拦第一次★：多条 JVM 线程可能同时退出，重复广播会让 App 层弹两张遮罩
/// （`__sync_lock_test_and_set` 返回旧值，只有第一个拿到 0 的那条线程负责广播）。
/// @param what 判据行里的出口名（"exit" / "_exit" / "abort"），不参与逻辑。
static void a2_exit_guard_intercept(const char *what, int code) __attribute__((noreturn));
static void a2_exit_guard_intercept(const char *what, int code) {
    static int intercepted = 0;   // ★原子★：__sync_lock_test_and_set 自带屏障，返回旧值
    if (__sync_lock_test_and_set(&intercepted, 1) == 0) {
        // 判据行（中文）：一条同时进控制台与会话日志 ⇒ 真机上 grep [A2-EXIT-GUARD] 即可
        a2_log_criterion(@"[A2-EXIT-GUARD] 拦下 %s code=%d 游戏运行中=%d 主线程=%d"
                         @"（不真退出，已广播 A2GameExitedNotification 等 App 层弹崩溃遮罩）",
                         what, code, (int)(gA2GameRunning != 0), (int)pthread_main_np());
        a2_exit_guard_broadcast_exit(code);
    }
    a2_exit_guard_park();
}

#pragma mark - 替换函数（interpose 的 replacement）

/// `exit` 的替换：不拦就原样转调，拦就 park（★两条路都不返回调用方★，与 exit 的契约一致）。
__attribute__((used)) static void a2_exit_guard_exit(int code) __attribute__((noreturn));
__attribute__((used)) static void a2_exit_guard_exit(int code) {
    if (!a2_exit_guard_should_intercept(code)) {
        A2ExitGuardExitFn orig = a2_exit_guard_original_exit();
        if (orig != NULL) orig(code);
        // 原函数取不到（本机不可能）或意外返回 ⇒ 也不能返回调用方，停住（见 resolve 的注释）
        a2_exit_guard_park();
    }
    a2_exit_guard_intercept("exit", code);
}

/// `_exit` 的替换：判据与 `exit` 完全相同（HotSpot 的快速退出路径会直接调它）。
__attribute__((used)) static void a2_exit_guard_underscore_exit(int code) __attribute__((noreturn));
__attribute__((used)) static void a2_exit_guard_underscore_exit(int code) {
    if (!a2_exit_guard_should_intercept(code)) {
        A2ExitGuardExitFn orig = a2_exit_guard_original_underscore_exit();
        if (orig != NULL) orig(code);
        a2_exit_guard_park();
    }
    a2_exit_guard_intercept("_exit", code);
}

/// `abort` 的替换：abort 没有退出码 ⇒ 一律按非 0 看（kA2ExitGuardAbortCode）。
/// ★拦下时不转调真 abort★：转了就会发 SIGABRT ⇒ A2CrashGuard 的处理器也跑 ⇒ 可能双弹。
__attribute__((used)) static void a2_exit_guard_abort(void) __attribute__((noreturn));
__attribute__((used)) static void a2_exit_guard_abort(void) {
    if (gA2GameRunning == 0) {
        A2ExitGuardAbortFn orig = a2_exit_guard_original_abort();
        if (orig != NULL) orig();
        a2_exit_guard_park();
    }
    a2_exit_guard_intercept("abort", kA2ExitGuardAbortCode);
}

#pragma mark - ★拦截段：__DATA,__interpose★

/// 一条 interpose 元组（= `dyld_priv.h` 的 `struct dyld_interpose_tuple`：{replacement, replacee}）。
/// 本层不 import 私有头，只按它公开的字段顺序自声明（事实性 ABI 约定）——与
/// Natives/Renderer/a2_gl_bridge.m 的 A2GlBridgeInterposeTuple 同口径。
typedef struct {
    const void *replacement;   ///< 新实现：本文件的替换函数
    const void *replacee;      ///< 被替换的旧实现：libSystem 导出的原函数
} A2ExitGuardInterposeTuple;

/// ★拦截段★：dyld 加载本镜像时读这张表，把**其他镜像**里对 `exit`/`_exit`/`abort` 的
/// 绑定改指本文件的替换函数（本镜像自己的调用不被改写 —— 所以替换函数里可以放心按名字
/// 取原函数地址；转调仍走 dlsym(RTLD_NEXT)，不依赖这一条）。
/// ★必须是静态存储★：dyld 只在加载时读一次，表放栈上会在函数返回后失效。
/// ★`used`★：没有任何代码「引用」它（只被 dyld 按段名发现），不让编译器/链接器丢掉。
__attribute__((used))
static const A2ExitGuardInterposeTuple gA2ExitGuardInterpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)&a2_exit_guard_exit,            (const void *)&exit  },
    { (const void *)&a2_exit_guard_underscore_exit, (const void *)&_exit },
    { (const void *)&a2_exit_guard_abort,           (const void *)&abort },
};

/// 表内各条的符号名（★顺序必须与 gA2ExitGuardInterpose 一一对应★：自检按这个顺序比对）。
static const char *const gA2ExitGuardTupleNames[] = { "exit", "_exit", "abort" };

#pragma mark - 自检（判据行）+ ★dyld 动态 interpose：真机上真正生效的那一条★

/// `dyld_dynamic_interpose` 的函数原型（★私有符号★：只声明在 dyld 私有头
/// `include/mach-o/dyld_priv.h`，公开 SDK 不给 ⇒ 不 import、不链接，只 dlsym。
/// 语义（私有头原话）=「Update all bindings on specified image」：把**指定镜像**里
/// 指向 replacee 的绑定改指 replacement。与 Natives/Renderer/a2_gl_bridge.m 同一取法。）
typedef void (*A2PFN_dyld_dynamic_interpose)(const struct mach_header *mh,
                                             const A2ExitGuardInterposeTuple *array,
                                             size_t count);

/// 取 `dyld_dynamic_interpose`：① `dlsym(RTLD_DEFAULT)`；② libdyld 句柄（`RTLD_NOLOAD`
/// 只取句柄、不触发加载，句柄由紧跟的 `dlclose` 配平）。@return NULL = 本系统没导出它。
static A2PFN_dyld_dynamic_interpose a2_exit_guard_resolve_dynamic_interpose(void) {
    void *sym = dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose");
    if (sym == NULL) {
        void *dyldHandle = dlopen("/usr/lib/libdyld.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (dyldHandle != NULL) {
            sym = dlsym(dyldHandle, "dyld_dynamic_interpose");
            dlclose(dyldHandle);   // 配平 NOLOAD 的引用（libdyld 常驻，不会真被卸）
        }
    }
    return (A2PFN_dyld_dynamic_interpose)sym;
}

/// 该镜像该不该改：跳过 `/System/`、`/usr/lib/` —— 那是 dyld 共享缓存里的页，
/// 跨进程共享，改它的绑定不安全（系统 `exit`/`abort` 本体就在那儿）；其余（App 自己 bundle
/// 里的 libjvm、libjli、插件 dylib）都可以改。
static int a2_exit_guard_image_targetable(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    if (strncmp(path, "/System/", 8) == 0) return 0;
    if (strncmp(path, "/usr/lib/", 9) == 0) return 0;
    return 1;
}

/// ★进「游戏运行中」窗口之前装一次（调用方唯一：Natives/Context/a2_launch.m）★
/// 做四件事，顺序不能换：
///   ① 先把三个**原函数**地址缓存下来（见下面的注释：装完再 dlsym 会取到自己）；
///   ② 表值核对（判据行）：__interpose 表里的 replacee 是否等于原函数地址；
///   ③ 逐镜像 `dyld_dynamic_interpose` —— **为什么不能只靠静态段**：dyld4 启动时只扫
///      **MH_DYLIB** 镜像的 __interpose 段（源码 `DyldRuntimeState.cpp` 的
///      `buildInterposingTables`：`if ( !hdr->isDylib() ) continue;`），而本 App 是
///      MH_EXECUTE ⇒ 那份静态表在真机上**根本不会被登记**。静态段保留作「元组的唯一定义处」，
///      真正生效靠这里逐镜像改绑定（libjvm 是 dlopen 进来的独立镜像，也要改它）。
///   ④ 判据行：装了几个镜像 + dlsym 探针。
/// ★不拦到时行为一字不变★：只有绑定了 `exit`/`_exit`/`abort` 的槽被改指本层；本层对
///   「非运行期 / 退出码 0」一律原样转调原函数。
void a2_exit_guard_arm(void) {
    static int armed = 0;
    if (armed) return;    // ★幂等★：只装一次（重试/重进都不重复装）
    armed = 1;

    const int n = (int)(sizeof(gA2ExitGuardInterpose) / sizeof(gA2ExitGuardInterpose[0]));

    // ---- ① 缓存原函数（★必须在装 interpose 之前★）----
    //   dyld 把 interpose 也算进 dlsym 的结果里（源码 Loader.cpp：解析符号时
    //   `targetAddressForDlsym = interpose(state, …)`）⇒ 装完之后再 dlsym("exit") 会拿到
    //   **我们自己**的替换函数，转调就成了自己调自己（死递归）。这三个访问器是
    //   「懒取一次 + 静态缓存」，先调一次就把值锁死在真原函数上。
    (void)a2_exit_guard_original_exit();
    (void)a2_exit_guard_original_underscore_exit();
    (void)a2_exit_guard_original_abort();

    // ---- ② 表值核对（判据行）：一条一行，真机上不需要调试器就能判「表对不对」 ----
    for (int i = 0; i < n; i++) {
        const void *tableValue = gA2ExitGuardInterpose[i].replacee;
        const void *realValue  = a2_exit_guard_resolve_original(gA2ExitGuardTupleNames[i]);
        a2_log_criterion(@"[A2-EXIT-GUARD] 表值核对 %s：表内 replacee=%p 原函数=%p 一致=%d",
                         gA2ExitGuardTupleNames[i], tableValue, realValue,
                         (int)(tableValue == realValue));
    }

    // ---- ③ 逐镜像装 ----
    A2PFN_dyld_dynamic_interpose interpose = a2_exit_guard_resolve_dynamic_interpose();
    if (interpose == NULL) {
        a2_log_criterion(@"[A2-EXIT-GUARD] ★拦不住★ 取不到 dyld_dynamic_interpose"
                         @"（RTLD_DEFAULT 与 libdyld 句柄都试过）⇒ 进程级退出不会被拦，"
                         @"崩溃遮罩只剩「主类 main 返回」那条路");
        return;
    }

    A2ExitGuardInterposeTuple tuples[3];    // 栈上拷贝：即使某个镜像改写让表自己变样，也只影响这一次
    size_t count = 0;
    for (int i = 0; i < n; i++) {
        if (gA2ExitGuardInterpose[i].replacee == NULL) continue;   // 未绑定（不该发生，跳过）
        tuples[count++] = gA2ExitGuardInterpose[i];
    }
    if (count == 0) {
        a2_log_criterion(@"[A2-EXIT-GUARD] ★拦不住★ 表里没有可用元组（replacee 全为空）");
        return;
    }

    int images = 0;
    const uint32_t total = _dyld_image_count();
    const struct mach_header *selfHeader = _dyld_get_image_header(0);   // 本镜像 = 主可执行文件
    for (uint32_t i = 0; i < total; i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        if (hdr == NULL) continue;
        if (hdr == selfHeader) continue;    // ★跳过本镜像★：本层自己不再直接调 exit（见 terminate_now），
                                           //   改它只会把「元组来源表」本身改写掉
        if (!a2_exit_guard_image_targetable(_dyld_get_image_name(i))) continue;
        interpose(hdr, tuples, count);
        images++;
    }

    // ---- ④ 判据行 ----
    //   dlsym 探针：若 dyld 把这次 interpose 也登记进全局替换表，`dlsym(RTLD_DEFAULT,"exit")`
    //   会直接返回本层的替换函数。探针未命中**不等于**没装（有些 dyld 只改已解析绑定、
    //   不登记全局替换），所以两件事分开记；最终判据是真崩一次，看
    //   「[A2-EXIT-GUARD] 拦下 …」那行有没有出现。
    void *probe = dlsym(RTLD_DEFAULT, "exit");
    a2_log_criterion(@"[A2-EXIT-GUARD] 已装：%d 条元组 × %d 个镜像（共 %u 个镜像，共享缓存/本镜像跳过）；"
                     @"dlsym 探针 exit 命中=%d",
                     (int)count, images, (unsigned)total, (int)(probe == (void *)&a2_exit_guard_exit));
}

#pragma mark - 给 App 层的「立刻退出」（唯一调用方见头文件）

/// 见 a2_exit_guard.h：行为 = `exit(code)`，但 **不产生 `exit` 的 stub**（走缓存的函数指针）。
/// ★为什么本文件里不写 `exit(code)`★：这里按名字调 `exit` 会让本镜像为 `exit` 生成 stub，
///   于是 __interpose 表里 replacee 那格被链接器写成 stub 地址 ⇒ dyld 认为该格没被绑定 ⇒
///   整条退出拦截失效（原因详解见头文件那段注释）。改走指针调用就绕开这一点。
void a2_exit_guard_terminate_now(int code) {
    A2ExitGuardExitFn orig = a2_exit_guard_original_exit();
    if (orig != NULL) orig(code);
    a2_exit_guard_park();   // 原函数取不到（本机不可能）⇒ 也不返回调用方
}

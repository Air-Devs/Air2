// Based on: https://blog.xpnsec.com/restoring-dyld-memory-loading
// https://github.com/xpn/DyldDeNeuralyzer/blob/main/DyldDeNeuralyzer/DyldPatch/dyldpatch.m

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <sys/syscall.h>
#include <libkern/OSCacheControl.h>

#include "utils.h"
#import "LauncherPreferences.h"

#define ASM(...) __asm__(#__VA_ARGS__)
// ldr x8, value; br x8; value: .ascii "\x41\x42\x43\x44\x45\x46\x47\x48"
char patch[] = {0x88,0x00,0x00,0x58,0x00,0x01,0x1f,0xd6,0x1f,0x20,0x03,0xd5,0x1f,0x20,0x03,0xd5,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41};

// Signatures to search for
char mmapSig[] = {0xB0, 0x18, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
char fcntlSig[] = {0x90, 0x0B, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
char syscallSig[] = {0x01, 0x10, 0x00, 0xD4};
int (*orig_fcntl)(int fildes, int cmd, void *param) = 0;
bool (*redirectFunction)(char *name, void *patchAddr, void *target) = NULL;

extern void* __mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
extern int __fcntl(int fildes, int cmd, void* param);

// Since we're patching libsystem_kernel, we must avoid calling to its functions
static void builtin_memcpy(char *target, char *source, size_t size) {
    for (int i = 0; i < size; i++) {
        target[i] = source[i];
    }
}

kern_return_t builtin_vm_protect(mach_port_name_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_max, vm_prot_t new_prot);
// Originated from _kernelrpc_mach_vm_protect_trap
ASM(_builtin_vm_protect: \n
    mov x16, #-0xe       \n
    svc #0x80            \n
    ret
);

// redirectFunction for iOS 18 and below
bool redirectFunctionDirect(char *name, void *patchAddr, void *target) {
    kern_return_t kret = builtin_vm_protect(mach_task_self(), (vm_address_t)patchAddr, sizeof(patch), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    if (kret != KERN_SUCCESS) {
        NSDebugLog(@"[DyldLVBypass] vm_protect(RW) fails at line %d", __LINE__);
        return FALSE;
    }
    
    builtin_memcpy((char *)patchAddr, patch, sizeof(patch));
    *(void **)((char*)patchAddr + 16) = target;
    sys_icache_invalidate((void*)patchAddr, sizeof(patch));
    
    kret = builtin_vm_protect(mach_task_self(), (vm_address_t)patchAddr, sizeof(patch), false, PROT_READ | PROT_EXEC);
    if (kret != KERN_SUCCESS) {
        NSDebugLog(@"[DyldLVBypass] vm_protect(RX) fails at line %d", __LINE__);
        return FALSE;
    }
    
    NSDebugLog(@"[DyldLVBypass] hook %s succeed!", name);
    return TRUE;
}
// redirectFunction for iOS 26+ (TXM)
bool redirectFunctionMirrored(char *name, void *patchAddr, void *target) {
    if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
        // ★ [JIT-NOCRASH] 该步靠调试器服务 brk #0xf00d；裸调用在调试器不在岗时
        // 会 SIGTRAP 直接致死。走安全网：降级则本轮补丁整体跳过(返回 FALSE)。
        if (!JIT26PrepareRegionForPatchingSafe(patchAddr, sizeof(patch))) {
            NSDebugLog(@"[DyldLVBypass] PrepareRegionForPatching degraded (no debugger servicing brk) -- skip hook %s", name);
            return FALSE;
        }
    }
    // mirror `addr` (rx, JIT applied) to `mirrored` (rw)
    vm_address_t mirrored = 0;
    vm_prot_t cur_prot, max_prot;
    kern_return_t ret = vm_remap(mach_task_self(), &mirrored, sizeof(patch), 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)patchAddr, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
    if (ret != KERN_SUCCESS) {
        NSDebugLog(@"[DyldLVBypass] vm_remap() fails at line %d", __LINE__);
        return FALSE;
    }
    
    mirrored += (vm_address_t)patchAddr & PAGE_MASK;
    vm_protect(mach_task_self(), mirrored, sizeof(patch), NO,
               VM_PROT_READ | VM_PROT_WRITE);
    builtin_memcpy((char *)mirrored, patch, sizeof(patch));
    *(void **)((char*)mirrored + 16) = target;
    sys_icache_invalidate((void*)patchAddr, sizeof(patch));
    
    NSDebugLog(@"[DyldLVBypass] hook %s succeed!", name);
    
    vm_deallocate(mach_task_self(), mirrored, sizeof(patch));
    return TRUE;
}
// redirectFunction for iOS 26+ (non-TXM)
bool redirectFunctionHWBreakpoint(char *name, void *patchAddr, void *target) {
    for(int i = 0; i < 6; i++) {
        if(hwRedirectOrig[i] == (uint64_t)patchAddr) {
            NSDebugLog(@"[DyldLVBypass] hook %s already exists!", name);
            return TRUE;
        } else if(!hwRedirectOrig[i]) {
            hwRedirectOrig[i] = (uint64_t)patchAddr;
            hwRedirectTarget[i] = (uint64_t)target;
            NSDebugLog(@"[DyldLVBypass] hook %s succeed!", name);
            return TRUE;
        }
    }
    NSDebugLog(@"[DyldLVBypass] no slot for hook %s", name);
    NSDebugLog(@"[DyldLVBypass] hook %s fails line %d", name, __LINE__);
    return FALSE;
}

bool searchAndPatch(char *name, char *base, char *signature, int length, void *target) {
    char *patchAddr = NULL;
    for(int i=0; i < 0x80000; i+=4) {
        if (base[i] == signature[0] && memcmp(base+i, signature, length) == 0) {
            patchAddr = base + i;
            break;
        }
    }
    
    if (patchAddr == NULL) {
        NSDebugLog(@"[DyldLVBypass] hook %s fails line %d", name, __LINE__);
        return FALSE;
    }
    
    NSDebugLog(@"[DyldLVBypass] found %s at %p", name, patchAddr);
    return redirectFunction(name, patchAddr, target);
}

// ★ [MG-FIRSTFRAME] 纯搜索(只读,不改内存):判定签名是否存在,但不落补丁。
//   searchAndPatch() 是「搜到即改」;有些补丁需要在【改之前】决定该不该改,
//   所以需要一个只读版探针。语义与 searchAndPatch 的搜索段完全一致。
static char *ameSearchSignatureOnly(char *base, char *signature, int length) {
    for(int i=0; i < 0x80000; i+=4) {
        if (base[i] == signature[0] && memcmp(base+i, signature, length) == 0) {
            return base + i;
        }
    }
    return NULL;
}

void *getDyldBase(void) {
    struct task_dyld_info dyld_info;
    mach_vm_address_t image_infos;
    struct dyld_all_image_infos *infos;
    
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t ret;
    
    ret = task_info(mach_task_self_,
                    TASK_DYLD_INFO,
                    (task_info_t)&dyld_info,
                    &count);
    
    if (ret != KERN_SUCCESS) {
        return NULL;
    }
    
    image_infos = dyld_info.all_image_info_addr;
    
    infos = (struct dyld_all_image_infos *)image_infos;
    return (void *)infos->dyldImageLoadAddress;
}

void* hooked_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    // this is to avoid a legacy codepath checking if process is allowed to map RWX which never worked properly
    if (flags & MAP_JIT) {
        errno = EINVAL;
        return MAP_FAILED;
    }
    
    void *map = __mmap(addr, len, prot, flags, fd, offset);
    if (fd == -1 || (prot & PROT_EXEC) == 0) {
        return map;
    }
    
    // Handle some cases where it will still map but without executable permission
    if (mprotect(map, len, prot) == -1) {
        munmap(map, len);
        map = MAP_FAILED;
    }
    if (map == MAP_FAILED) {
        //printf("[DyldLVBypass] mmap(prot=%d, flags=%d, fd=%d)\n", prot, flags, fd);
        map = __mmap(addr, len, prot, flags | MAP_PRIVATE | MAP_ANON, 0, 0);
        // ★ [SHADER-SIGBUS] 走到这条兜底路径意味着：该 RX 段【不是文件后备】
        // （直连 mmap + mprotect(RX) 都失败了），随后它的内容由"镜像 + memcpy"
        // 写进去 —— 正是本文件第 269 行注释里"修改执行页可能导致 SIGBUS"的场景
        // （项目历史上 glslang 从 jar 解包出的未签名副本就死在这里）。
        // 这里只【记录】是哪份文件（fcntl F_GETPATH），不改变任何行为：下一次
        // 真机日志一眼就能看出"哪个 dylib 走了危险路径"。
        do {
            static int s_ameSigbusMmapLogs = 0;
            // ★ [LOG-CLEAN] 原允许 12 行 ⇒ 只打一次(同句多份 dylib 重复刷屏)。
            if (s_ameSigbusMmapLogs < 1) {
                ++s_ameSigbusMmapLogs;
                char fpath[1024] = {0};
                const char *who = "(unknown fd / not a file)";
                if (fd >= 0 && orig_fcntl != NULL &&
                    orig_fcntl(fd, F_GETPATH, fpath) == 0 && fpath[0] != '\0') {
                    who = fpath;
                }
                NSLog(@"[DyldLVBypass][SHADER-SIGBUS] RX mmap fell back to anon+mirror: "
                      @"len=%zu file=%s (mprotect(RX) failed; pages are rewritten "
                      @"through a mirror -- executing them may SIGBUS)", len, who);
            }
        } while (0);
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            // ★ [JIT-NOCRASH] 裸 PrepareRegion 在调试器不在岗时 SIGTRAP 致死；
            // 安全网降级 ⇒ 放弃这次 RX 映射(否则随后执行非可执行页会 SIGBUS)。
            if (!JIT26PrepareRegionSafe(map, len)) {
                NSDebugLog(@"[DyldLVBypass] PrepareRegion degraded (no debugger servicing brk) -- munmap and fail mmap");
                munmap(map, len);
                return MAP_FAILED;
            }
        }
        
        void *memoryLoadedFile = __mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, offset);
        if (redirectFunction == redirectFunctionDirect) {
            mprotect(map, len, PROT_READ | PROT_WRITE);
            memcpy(map, memoryLoadedFile, len);
            mprotect(map, len, prot);
        } else {
            // mirror `addr` (rx, JIT applied) to `mirrored` (rw)
            vm_address_t mirrored = 0;
            vm_prot_t cur_prot, max_prot;
            kern_return_t ret = vm_remap(mach_task_self(), &mirrored, len, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)map, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
            if(ret == KERN_SUCCESS) {
                vm_protect(mach_task_self(), mirrored, len, NO,
                           VM_PROT_READ | VM_PROT_WRITE);
                memcpy((void*)mirrored, memoryLoadedFile, len);
                vm_deallocate(mach_task_self(), mirrored, len);
            }
        }
        munmap(memoryLoadedFile, len);
    }
    return map;
}

int hooked___fcntl(int fildes, int cmd, void *param) {
    if (cmd == F_ADDFILESIGS_RETURN) {
#if !(TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR)
        // attempt to attach code signature on iOS only as the binaries may have been signed
        // on macOS, attaching on unsigned binaries without CS_DEBUGGED will crash
        // ignoreFcntl is a special case for vphone or dev unit with TXM JIT enforcement disabled
        BOOL ignoreFcntl = DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_HAS_TXM) && !DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED);
        if (!ignoreFcntl) {
            orig_fcntl(fildes, cmd, param);
        }
#endif
        fsignatures_t *fsig = (fsignatures_t*)param;
        // called to check that cert covers file.. so we'll make it cover everything ;)
        fsig->fs_file_start = 0xFFFFFFFF;
        return 0;
    }

    // Signature sanity check by dyld
    else if (cmd == F_CHECK_LV) {
        //orig_fcntl(fildes, cmd, param);
        // Just say everything is fine
        return 0;
    }
    
    // If for another command or file, we pass through
    return orig_fcntl(fildes, cmd, param);
}

// ★ [DYLD-SWITCH] 总开关求值 —— 是否应当安装 dyld library-validation 旁路。
//   供 init_bypassDyldLibValidation() 与 JavaLauncher 的容错 SIGBUS handler 共用,
//   保证「装不装旁路 hook」与「装不装容错 handler」始终同进同退:
//     - 环境逃生口 AMETHYST_DYLD_BYPASS=0 → NO(整体跳过,用于 A/B 二分);
//     - 否则取设置页开关 java.dyld_bypass(PLPreferences 注册默认 @NO,即【默认关闭】)。
//   [来源: fork 分支 fix/dyld-bypass-default-off @ c26262a58b]
BOOL ame_dyldBypassRequested(void) {
    const char *bypassOff = getenv("AMETHYST_DYLD_BYPASS");
    if (bypassOff != NULL && bypassOff[0] == '0') {
        return NO;
    }
    return getPrefBool(@"java.dyld_bypass");
}

void init_bypassDyldLibValidation() {
    static BOOL bypassed;
    if (bypassed) return;
    bypassed = YES;

    NSDebugLog(@"[DyldLVBypass] init");

    // ★ [DYLD-SWITCH] 环境逃生口(保留自 [DYLD-BYPASS]):AMETHYST_DYLD_BYPASS=0 时
    //   无论设置页开关如何,都整体跳过旁路,回到「不打任何补丁」的旧行为。
    const char *bypassOff = getenv("AMETHYST_DYLD_BYPASS");
    if (bypassOff != NULL && bypassOff[0] == '0') {
        NSDebugLog(@"[DyldLVBypass] skipped (AMETHYST_DYLD_BYPASS=0)");
        return;
    }

    // ---- 总开关：默认关闭 ---- (fork 原文,见 fix/dyld-bypass-default-off @ c26262a58b)
    // 设置页: Java 调整 → 绕过 dyld 库校验 (偏好键 java.dyld_bypass, 默认 @NO)。
    //
    // 真机 A/B（iPhone 14 Pro Max / iOS 16.2 / TrollStore，MC 26.2 + Java 25，
    // build f60d830）结论：旁路就是 dlopen(libjli) 崩溃的元凶。
    //   旁路开 + MetalANGLE → 卡死在 dlopen(libjli)，SIGBUS 活锁，连
    //                          [Init] Found JLI lib 都没有；
    //   旁路关 + 同一渲染器 → JVM 正常起来，一路走到 Minecraft.<init>。
    // 同一对照里旁路关 + MoltenVK 能进游戏。
    //
    // 原因是本机签名（TrollStore + no-sandbox + increased-memory-limit）本身
    // 已放宽校验，dlopen libjli 不需要这个补丁；补丁反而把 dyld 的
    // mmap/fcntl 入口改成 RW，在 iOS 16.2 上执行非可执行页 → SIGBUS。
    //
    // 因此默认不再安装钩子，改由 Java 调整里的开关显式开启（保留逃生口：
    // 某些非 TrollStore 环境可能仍需要它）。设置项改动需完全重启 App 生效，
    // 因为本函数在启动流程里只跑一次。
    if (!getPrefBool(@"java.dyld_bypass")) {
        NSDebugLog(@"[DyldLVBypass] disabled by default (java.dyld_bypass=OFF), no hook installed");
        return;
    }
    NSDebugLog(@"[DyldLVBypass] enabled by user (java.dyld_bypass=ON)");

    // The original switch used exact bitmask matching, so a device with
    // IS_IOS_26 + HAS_TXM (no FORCE_MIRRORED) — i.e. a normal iPhone 17 on
    // iOS 26 with StikDebug-provided JIT — fell through to redirectFunction
    // Direct, whose vm_protect(RX) call iOS 26 blocks. The half-applied
    // patch left dyld code pages RW with modified bytes, then dyld faulted
    // executing non-X memory on the next mmap call → SIGBUS ignored → hang
    // at dlopen(libjli). Use bitmask checks so iOS 26 + TXM correctly picks
    // the mirrored variant.
    if (DeviceHasJITFlags(JIT_FLAG_HAS_TXM) &&
        (DeviceHasJITFlags(JIT_FLAG_IS_IOS_26) || DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED))) {
        NSDebugLog(@"[DyldLVBypass] Using redirectFunctionMirrored");
        redirectFunction = redirectFunctionMirrored;
    } else if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED)) {
        // Special special case for non-TXM iOS 26+. We can JIT without
        // script, but we cannot modify existing code in dsc without it.
        // Use hardware breakpoint to avoid patching dsc code at all.
        NSDebugLog(@"[DyldLVBypass] Using redirectFunctionHWBreakpoint");
        redirectFunction = redirectFunctionHWBreakpoint;
    } else {
        NSDebugLog(@"[DyldLVBypass] Using redirectFunctionDirect");
        redirectFunction = redirectFunctionDirect;
    }

    // ★ [MG-FIRSTFRAME] 记录实际选中的重定向形态。这是排查「无首帧」的第一判据:
    //   出画面的场次一律是 mirrored / hwbreakpoint,或 direct 但 dyld_fcntl 的
    //   直接补丁【失败】后走 Dopamine 兜底;direct 且自补 fcntl 成功的场次全部无首帧。
    setenv("AMETHYST_DYLD_BYPASS_MODE",
           (redirectFunction == redirectFunctionMirrored) ? "mirrored" :
           (redirectFunction == redirectFunctionHWBreakpoint) ? "hwbreakpoint" : "direct", 1);
    NSDebugLog(@"[MG-FIRSTFRAME] dyld bypass mode=%s (java.dyld_bypass=ON)",
               getenv("AMETHYST_DYLD_BYPASS_MODE"));
    
    // ★ [DYLD-BYPASS] 原做法是无条件 signal(SIGBUS, SIG_IGN)。SIG_IGN 语义下,
    //   触发 SIGBUS 的那条指令会被内核反复重投 —— 这不是「等一下就好」,而是无限
    //   活锁:主线程照常跑、界面照常可点,而 launchJVM 线程永远卡在 dlopen(libjli)
    //   不返回(控制台最后一行停在「[JavaLauncher] JVM GC optimization ...」,
    //   其后 Caciocavallo / Found JLI lib / Calling JLI_Launch 三条日志全缺席,
    //   也没有任何崩溃报告)。这就是「26.2 + Java 25 启动永久卡死」的根因。
    //
    //   现改为:默认不再忽略,交给 JavaLauncher 在本函数返回后立刻安装的「容错
    //   SIGBUS handler」(ame_installTolerantSigbusHandler):前 8 次把 pc/sp/lr/
    //   si_addr 写进 native-crash.log 后放行重试(与 SIG_IGN 同样的重试语义),
    //   连续超限则转 SIG_DFL,宁可带完整日志崩溃,也不要无声活锁。
    //   需要旧行为时设 AMETHYST_SIGBUS_IGNORE=1 即时切回(逃生开关)。
    //   [来源:herbrine8403 test 分支 26e479f7d9f0 / 1173a6ef2af2]
    const char *sigbusIgnore = getenv("AMETHYST_SIGBUS_IGNORE");
    if (sigbusIgnore != NULL && sigbusIgnore[0] == '1') {
        signal(SIGBUS, SIG_IGN);
        NSDebugLog(@"[DyldLVBypass] SIGBUS set to SIG_IGN (AMETHYST_SIGBUS_IGNORE=1)");
    }
    
    orig_fcntl = __fcntl;
    char *dyldBase = getDyldBase();
    //redirectFunction("mmap", mmap, hooked_mmap);
    //redirectFunction("fcntl", fcntl, hooked_fcntl);
    searchAndPatch("dyld_mmap", dyldBase, mmapSig, sizeof(mmapSig), hooked_mmap);

    // ★ [MG-FIRSTFRAME] 「无首帧」根因闸门 —— 由真机 A/B + 全量历史日志逐行对照得出。
    //
    //   证据(把本机全部历史日志按 [DyldLVBypass] 行分类后的分组结果):
    //     · 出画面的场次:redirectFunctionMirrored(iOS 26/27),或
    //       「hook dyld_fcntl fails line 123 → (Dopamine) succeed」(iOS 16.7.15,越狱已先钩 dyld);
    //     · 【无首帧】的场次(iOS 16.2 / 16.3.1 / 17.2)一律是 redirectFunctionDirect,
    //       且【我们自己的】inline 补丁直接命中 dyld_fcntl —— 日志里就是
    //       "hook dyld_fcntl succeed!",之后再没有 [Init] Found JLI lib。
    //
    //   机制:redirectFunctionDirect 把 dyld 的 mmap/fcntl 入口页改成 RW 再写;在 iOS 16/17 上
    //     此后执行该页会 SIGBUS。老版本（build 70b8bea 的 dyld_bypass_validation.m:260）
    //     无条件 signal(SIGBUS, SIG_IGN) ⇒ 出错指令被内核无限重投 ⇒ launchJVM 线程永久卡在
    //     dlopen(libjli)（JavaLauncher.m:2225）不返回;控制台最后一行停在
    //     "[JavaLauncher] JVM GC optimization"，其后 Caciocavallo / "[Init] Found JLI lib" /
    //     "[Init] Calling JLI_Launch" 三条全缺席;主线程照常跑(displayLinkTick #1..#5、
    //     InputDiag 继续)、无崩溃报告,45s 后 overlay 超时 → exit(0)。
    //     卡点在 pre-JLI,与实例/渲染器无关 ⇒ 这正好解释观察到的
    //     「所有实例 + 所有渲染器都一样没首帧」与「机型不同但都越狱」。
    //
    //   处置:在 Direct（非 iOS26 的 legacy 路径）+ dyld_fcntl 签名确实存在 这条【已被证伪】的
    //     组合上,默认不再打 dyld_fcntl 的直接补丁（保留 dyld_mmap 补丁），让流程回落到下面
    //     既有的 Dopamine 探测分支 —— 即恢复到「出画面」场次实际生效的那种配置
    //     (mmap 直补 + fcntl 不由我们直补)。要退回旧行为设 AMETHYST_DYLD_BYPASS_FORCE_FCNTL=1。
    BOOL ameMgDirectLegacyFcntl = (redirectFunction == redirectFunctionDirect) &&
                                  (getenv("AMETHYST_DYLD_BYPASS_FORCE_FCNTL") == NULL);
    bool fcntlPatchSuccess = false;
    if (ameMgDirectLegacyFcntl && ameSearchSignatureOnly(dyldBase, fcntlSig, sizeof(fcntlSig)) != NULL) {
        NSLog(@"[MG-FIRSTFRAME] dyld_fcntl direct inline patch SKIPPED -- lethal combo "
              @"(redirectFunctionDirect + own fcntl patch) => dlopen(libjli) SIGBUS livelock / no first frame. "
              @"Falling back to the Dopamine-detect path; set AMETHYST_DYLD_BYPASS_FORCE_FCNTL=1 to force legacy.");
        setenv("AMETHYST_DYLD_BYPASS_LETHAL_SKIPPED", "1", 1);
    } else {
        fcntlPatchSuccess = searchAndPatch("dyld_fcntl", dyldBase, fcntlSig, sizeof(fcntlSig), hooked___fcntl);
    }
    
    // https://github.com/LiveContainer/LiveContainer/commit/c978e62
    // dopamine already hooked it, try to find its hook instead
    if(!fcntlPatchSuccess) {
        char* fcntlAddr = 0;
        // search all syscalls and see if the the instruction before it is a branch instruction
        for(int i=0; i < 0x80000; i+=4) {
            if (dyldBase[i] == syscallSig[0] && memcmp(dyldBase+i, syscallSig, 4) == 0) {
                char* syscallAddr = dyldBase + i;
                uint32_t* prev = (uint32_t*)(syscallAddr - 4);
                if(*prev >> 26 == 0x5) {
                    fcntlAddr = (char*)prev;
                    break;
                }
            }
        }
        
        if(fcntlAddr) {
            uint32_t* inst = (uint32_t*)fcntlAddr;
            int32_t offset = ((int32_t)((*inst)<<6))>>4;
            NSLog(@"[DyldLVBypass] Dopamine hook offset = %x", offset);
            orig_fcntl = (void*)((char*)fcntlAddr + offset);
            redirectFunction("dyld_fcntl (Dopamine)", fcntlAddr, hooked___fcntl);
        } else {
            NSLog(@"[DyldLVBypass] Dopamine hook not found");
        }
    }
}

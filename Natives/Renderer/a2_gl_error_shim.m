// ============================================================================
//  Natives/Renderer/a2_gl_error_shim.m
//  Air2 —— ★MobileGlues 的 glGetError 保护★
// ----------------------------------------------------------------------------
//  真机证据（26.2 + MobileGlues）：
//    # A fatal error has been detected by the Java Runtime Environment:
//    10  libmobileglues.dylib  glGetError + 24   ← SIGSEGV
//     4  libjvm.dylib  os::abort()
//  ⇒ MG 的 glGetError 在它的跳转表就绪前被调用会直接崩（"黑屏"其实是被 abort）。
//
//  做法（不拦 dlsym —— iOS 没有 dlvsym，拦了拿不回真正的 dlsym）：
//    MG 加载后，直接把它 glGetError 的头两条指令改写成
//        mov w0, #0     (0x52800000)   ← 返回 GL_NO_ERROR
//        ret            (0xD65F03C0)
//    glGetError 只用于诊断，恒返回 0 不影响渲染正确性；改完再调用绝不会崩。
//
//  安全阀：页保护改为 RWX 后写回 RX；任何一步失败就原样不动（宁可不修，不能写坏）。
// ============================================================================

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

void a2_gl_error_shim_install_for_handle(void *handle) {
    if (handle == NULL) return;

    void *sym = dlsym(handle, "glGetError");
    if (sym == NULL) {
        NSLog(@"[A2-MG-SHIM] 未找到 glGetError 符号，跳过");
        return;
    }

    uintptr_t page = (uintptr_t)sym & ~(uintptr_t)(PAGE_SIZE - 1);
    if (mprotect((void *)page, (size_t)PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        NSLog(@"[A2-MG-SHIM] mprotect(RWX) 失败 errno=%d ⇒ 不改写（保持原样）", errno);
        return;
    }

    uint32_t *code = (uint32_t *)sym;
    code[0] = 0x52800000u;   // mov w0, #0
    code[1] = 0xD65F03C0u;   // ret

    sys_icache_invalidate(sym, 8);
    mprotect((void *)page, (size_t)PAGE_SIZE, PROT_READ | PROT_EXEC);

    NSLog(@"[A2-MG-SHIM] 已把 MobileGlues 的 glGetError 改写为 return 0（防 SIGSEGV 崩溃）");
}

#ifndef A2_MEMORY_PRESSURE_H
#define A2_MEMORY_PRESSURE_H

// 大整合包真正会崩的地方不是帧率，是 iOS 的进程内存上限：
// 堆接近满时 G1 的普通回收只扫一小片，剩下的垃圾不动 ⇒ 驱动下一次分配就 OOM。
// 这里在 iOS 发内存压力通知时，主动让 Java 侧做一次 full GC 把内存还回去。
//
// 移植自 weecritikal/Flux-Launcher-iOS（MemoryPressureRelief），改成用我们自己的 VM 指针。
// 调用点：
//   a2_vmloader.m（JNI_CreateJavaVM 成功后）→ a2_mem_note_vm(vm) + a2_mem_start()

#ifdef __cplusplus
extern "C" {
#endif

/// 记录建好的 VM（只在建 VM 成功后调用一次；传 NULL 表示清空）
void a2_mem_note_vm(void *vm);

/// 开始监听 iOS 内存压力通知（幂等，可重复调用）
void a2_mem_start(void);

#ifdef __cplusplus
}
#endif

#endif  // A2_MEMORY_PRESSURE_H

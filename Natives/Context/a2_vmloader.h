// ============================================================================
// Natives/runtime/a2_vmloader.h
// ★ [RT-P1] R2 —— VMLoader：dlopen(libjvm) + JNI_CreateJavaVM（Air2 命名：a2_*）
// ----------------------------------------------------------------------------
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.2（进程内加载 libjvm，不经 libjli）
//
// 单一职责：本文件【只负责加载 libjvm 并创建 VM】，不拼参数（R3）、不碰资源路径（R4）、不写日志（R7）。
//   ★ 全程同进程、不调 JLI_Launch、不 posix_spawn。★
// ============================================================================
#ifndef A2_VMLOADER_H
#define A2_VMLOADER_H

#import <Foundation/Foundation.h>
#include "jni.h"

/// 在给定 javaHome 内定位 libjvm.dylib（三布局：lib/server、jre/lib/server、lib/hotspot）。无则返回 nil。
/// 说明：这是「在已选定的 JRE home 内找库」，属 VMLoader 职责；跨多个候选 home 的 R1 定位由上层负责。
NSString *a2_vm_resolve_libjvm(NSString *javaHome);

/// dlopen(libjvm, RTLD_NOW|RTLD_LOCAL) → dlsym(JNI_CreateJavaVM) → 版本自适应创建 VM。
/// options 由调用方（R3）给定；本函数不内建任何参数。
/// 返回：0=JNI_OK（回填 vm/env/usedVersion）；1=参数非法 2=dlopen 失败 3=dlsym 失败 4=CreateJavaVM 失败。
int a2_vm_create(NSString *libjvmPath,
                 const char *const optionStrings[], int nOptions,
                 BOOL ignoreUnrecognized,
                 JavaVM **outVM, JNIEnv **outEnv, jint *outUsedVersion);

#endif /* A2_VMLOADER_H */

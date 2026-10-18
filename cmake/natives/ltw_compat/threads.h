/**
 * iOS 兼容层：为 LTW 提供 C11 <threads.h> 支持
 *
 * iOS SDK 不提供 <threads.h> 系统头文件，但 LTW 的 proc.h 以及 glsl_optimizer
 * 的 u_queue.c / u_thread.h 等文件需要 C11 threads API。本头文件通过包含
 * glsl_optimizer 自带的 c11/threads.h POSIX 模拟库来提供这些 API。
 *
 * 通过将本目录加入 include 路径，使 `#include <threads.h>` 解析到本文件。
 */
#ifndef LTW_COMPAT_THREADS_H
#define LTW_COMPAT_THREADS_H

/* C11 thread_local 关键字（iOS clang 原生支持 _Thread_local） */
#define thread_local _Thread_local

/* 使用 glsl_optimizer 自带的 C11 threads POSIX 模拟库 */
#include "c11/threads.h"

#endif /* LTW_COMPAT_THREADS_H */

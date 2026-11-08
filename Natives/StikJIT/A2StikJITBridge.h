//
//  A2StikJITBridge.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/StikJIT —— 内建 JIT 引擎（StikJIT.framework）的 C 入口
// ----------------------------------------------------------------------------
//  ★分层★：本头文件只有 C（无 Swift 类型跨越边界）。Swift 侧实现见
//  A2StikJITBridge.swift（@_cdecl），它 import StikJIT（接口桩见同目录 StikJIT.swift）。
//
//  ★调用链（谁调这些函数）★
//    a2_stikjit_set_log_sink  ← Air2/Player/A2StikJITProvider.m（首次使用时设一次）
//    a2_stikjit_enable_jit    ← Air2/Player/A2StikJITProvider.m
//                               `+enableBuiltInJITWithBudget:reason:`（后台队列调用，阻塞）
//    a2_stikjit_framework_version ← Air2/Player/A2StikJITProvider.m `+frameworkVersion`
//
//  ★前置条件★（调用方负责，本层不猜）：
//    ① StikJIT.framework 已随包在 <App>/Frameworks/ 且已被 dlopen 成功
//       （iOS < 17.4 该框架 minos=17.4，加载会失败 ⇒ 由调用方判否，不在这里兜）。
//    ② 配对文件路径真实存在（用户从 StikDebug / SideStore 导出的 .mobiledevicepairing）。
//    ③ 设备侧 RSD 端点在 address:port 可达（真机上靠 LocalDevVPN 之类把 RSD 暴露到本机）。
//
//  ★返回码★（负值 = 失败，一律附可读原因到 err 缓冲）
//    0  成功：debugserver 已 attach 本进程并跑完 JIT 脚本
//   -1  参数不合法（空指针 / 配对文件不存在）
//   -3  引擎抛出错误（StikJITError；原因已写 err）
//

#ifndef A2_STIKJIT_BRIDGE_H
#define A2_STIKJIT_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 进度日志出口。C 函数指针（Swift 侧 @convention(c)），每次回调一行 UTF-8 文本。
typedef void (*a2_stikjit_log_sink_t)(const char *line);

/// 安装进度日志出口（传 NULL 卸载）。★进程内全局、最后一次设置生效★。
void a2_stikjit_set_log_sink(a2_stikjit_log_sink_t sink);

/// 为进程 pid 开启 JIT（阻塞；★不要在主线程调★，真机耗时可达数十秒：RSD 握手 + attach + 脚本）。
///
/// @param pid          目标进程（自身 = getpid()）
/// @param pairingPath  配对文件绝对路径（UTF-8）
/// @param address      RSD 端点地址（IPv4/IPv6 字面量）
/// @param rsdPort      RSD 端口（network order 不用管，这里传主机序）
/// @param scriptPath   自定义 JIT 脚本路径；NULL/不存在 ⇒ 用框架自带 universal
/// @param forceScript  非 0 = 强制使用该脚本（对应框架的 forceScript:）
/// @param err          失败原因输出缓冲（可 NULL）
/// @param errCap       err 的容量（字节）
/// @return 见文件头返回码
int32_t a2_stikjit_enable_jit(int32_t pid,
                              const char *pairingPath,
                              const char *address,
                              uint16_t rsdPort,
                              const char *scriptPath,
                              int32_t forceScript,
                              char *err,
                              size_t errCap);

#ifdef __cplusplus
}
#endif

#endif /* A2_STIKJIT_BRIDGE_H */

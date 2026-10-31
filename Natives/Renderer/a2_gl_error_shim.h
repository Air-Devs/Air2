// ============================================================================
//  Natives/Renderer/a2_gl_error_shim.h
//  Air2 —— ★MobileGlues 的 glGetError 保护：安装 / 延迟重试的对外契约★
// ----------------------------------------------------------------------------
//  为什么必须有：真机（1.20.1 + MG 2.0.16 + java-21，lastlog-101）JVM 建成功、表面
//  2622x1206 两边一致之后仍然死在这一条**诊断接口**上：
//      #  SIGBUS (0xa) at pc=0x0000000125b8e4e4
//      # C  [libmobileglues.dylib+0x3e4e4]  glGetError+0x0
//  把该函数改写成 `mov w0,#0; ret` 之后，调用方再也执行不到 MG 那段入口（恒返回 GL_NO_ERROR，
//  只影响诊断，不影响渲染正确性）。
//
//  ★两段式（JIT 相位）★ —— 本模块第一次被调用时（`a2_gl_bridge_attach` 的 ④）进程里还没有
//  可写的代码页（iOS 26 禁 mprotect(RWX) ⇒ errno=13），所以：
//    ① 安装失败 ⇒ 记「待办」并返回 `A2GlErrorShimPending`（**绝不拦启动**），同时起一个有界看门狗
//       （250ms 一次、最长 180s、装上即停 —— 真机里 JIT 大区是 libjvm 建 VM 时才向调试器讨的，
//        进程内没有可等的「区已就绪」通知点）；
//    ② JIT 已验证（建 VM 的闸门放行）后 ⇒ 调用方再调 `a2_gl_error_shim_retry_pending()` 立即重试一次。
//  待办状态由本模块自持（宿主不保存任何标志），两条路都幂等：已生效时直接返回 Patched。
//
//  调用点（每处都在注释里写明）：
//    · `Natives/Renderer/a2_gl_bridge.m` ④ —— MG 后端加载后立即 install；
//    · `Air2/Bridge/A2LaunchRunner.m` 的 `+retryJITGatedGLPatches` —— JIT 闸门放行后 retry。
// ============================================================================
#ifndef A2_GL_ERROR_SHIM_H
#define A2_GL_ERROR_SHIM_H

#import <Foundation/Foundation.h>

/// 安装结果。★全部为「非负」★：本模块的任何结论都不许升级成启动阻断。
typedef NS_ENUM(int, A2GlErrorShimResult) {
    A2GlErrorShimPatched       = 0,  ///< glGetError 已是「return 0」（本次改写成功，或此前已改写）
    A2GlErrorShimPending       = 1,  ///< 本次改不动（典型：JIT 未就绪 ⇒ 代码页不可写）⇒ 已记待办
    A2GlErrorShimNotApplicable = 2,  ///< 该库里没有 glGetError 导出（或 handle 为空）⇒ 什么都不做
};

/// 安装（幂等）。`handle` = 后端本体的 dlopen 句柄。
/// 已生效 ⇒ 直接返回 `A2GlErrorShimPatched` 且只打一行「幂等跳过」，不重复改写。
A2GlErrorShimResult a2_gl_error_shim_install_for_handle(void *handle);

/// 有「待办」⇒ 按当前相位再试一次（可多次调用）；没有待办 ⇒ 原样返回当前状态、不打日志。
/// ★调用时机★：JIT 已验证 / 建 VM 之前（见上）。
A2GlErrorShimResult a2_gl_error_shim_retry_pending(void);

#endif /* A2_GL_ERROR_SHIM_H */

// ============================================================================
// Natives/runtime/a2_failbanner.h
// ★ [RT-P0.1] 运行时层「失败可见反馈」—— 非阻塞提示条 + 面向用户的文案（唯一一处）
// ----------------------------------------------------------------------------
// 单一职责：本模块【只做「把一次运行时失败变成一条可见提示条」】：
//   · 文案（含 JIT 取证分流）全部集中在本模块；调用方只给「失败的事实」
//     （判定分类 / 阶段码 / 取证文本），不自己拼中文；
//   · 非阻塞（NMToast 卡片，12s 自动消失、卡片外不拦触摸），绝不弹模态框；
//   · 主线程派发 + 有界等 key window（最多 ~20s），始终无窗口则只留日志。
//
// 分层：本模块是【边缘适配器】（运行时层里唯一 import UIKit/NMToast 的模块）；
//   jni_boot.m（启动决策）不再感知 UI。
// ============================================================================
#ifndef A2_FAILBANNER_H
#define A2_FAILBANNER_H

#import <Foundation/Foundation.h>
#import "utils.h"        // AMEJITRegionVerdict（JIT 取证分类）

/// JIT 不可用导致「已阻止创建 VM」时的可见反馈：按取证分类分流文案。
/// 调用方传入本次探测的事实（分类 / why / evidence）；任意线程可调。
void a2_failbanner_show_jit_unavailable(AMEJITRegionVerdict verdict,
                                        NSString *why,
                                        NSString *evidence);

/// 阶段码 → 可读原因 的可见反馈（映射表见 .m）。任意线程可调。
void a2_failbanner_show_stage_failure(int stageRc);

#endif /* A2_FAILBANNER_H */

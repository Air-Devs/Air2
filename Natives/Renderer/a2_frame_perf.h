// ============================================================================
//  Natives/Renderer/a2_frame_perf.h
//  Air2 —— ★帧性能判据（与渲染器无关）★
// ----------------------------------------------------------------------------
//  分层：属 Natives/Renderer（见 docs/ARCHITECTURE.md §Natives：Renderer/ =
//        「帧/表面生命周期与桥接」）。
//
//  ★单一职责★：把「一帧的若干**中立数值**」（帧序号 / CPU 帧时间 / draw 命令数 /
//  纹理（帧缓冲）字节估值 / 本帧是否新建着色器或管线 / 是否已呈现 / 本帧清屏区域像素 /
//  drawable 像素尺寸 / 渲染倍率 / 相位）汇总成**一行**可 grep 的判据行：
//      `[FRAME] frame=… phase=… cpu_fps=… cpu_ms=… draw=… tex≈… shaderNew=… presented=…
//                scale=… px=…x… clear=…x…`
//  由调用方每 N 帧输出一行（避免每帧刷日志）。
//
//  ★与渲染器解耦（本文件的硬约束）★
//    · 本文件与同名 .m **不出现任何图形后端名 / 后端头**，也不 import 任何图形框架；
//      只接收调用方算好的**中立数值**（像素数、毫秒、字节数、0/1 标志）。
//      机器判据：`scripts/verify_frame_perf_native.py` 的「渲染器解耦」项（命中 = 0）。
//    · 因此换任何渲染后端都不需要改本模块一行；它不知道帧是谁画的，只知道「这一帧的数字」。
//
//  ★量不到就不要声称量到了★
//    · 拿不到**真实 GPU 时间** ⇒ 本模块只用 **CPU 帧时间**（相邻两次记录之间的墙钟差）
//      及其倒数作 **fps**，判据行里以 `cpu_fps=` / `cpu_ms=` 前缀显式标注为代理指标。
//    · `draw`（提交的绘制/清屏命令数）与 `tex`（drawable 字节估值）同为**代理/估值**：
//      真实 draw call 数与纹理内存只有渲染器自己知道；本模块**如实打印收到的值**，
//      不替它猜、也不补默认值（收到的 0 就打印 0）。
//
//  ★调用点（都在启动链上，唯一）★
//    · 环境/相位 ：`Air2/Bridge/A2LaunchRunner.m`（附着前设 drawable 尺寸与渲染倍率；
//                  基线帧前设预览态、交给游戏前设真实态）。
//    · 记录每帧   ：`Natives/Renderer/a2_gl_bridge.m` 的帧动作（帧生产者每帧调一次）。
//    · 每 N 帧打印：`Air2/Bridge/A2LaunchRunner.m` 的宿主帧回调。
// ============================================================================
#ifndef A2_FRAME_PERF_H
#define A2_FRAME_PERF_H

#import <Foundation/Foundation.h>

/// ★判据前缀★ —— 真机 grep 锚点；出包后应能在主二进制里扫到（机器自证见出包脚本）。
extern const char *const A2FramePerfTag;

/// 帧相位：区分「预览态」与「真实态」，同一行里打印，便于真机一眼分辨。
typedef enum {
    /// 预览态：附着后的**基线帧**（帧源 = 启动链驱动的基线循环），
    /// 只证明「上下文在按当前渲染倍率清屏/呈现」，★不代表游戏真实负载★。
    A2FramePhasePreview = 0,
    /// 真实态：游戏 / 渲染器**接管帧生产**之后的帧（本包内若无人接管则不出此相位的行）。
    A2FramePhaseReal    = 1,
} A2FramePhase;

/// 设定本次会话的 drawable 尺寸与渲染倍率（由启动链在附着前调用一次）。
/// ★这里的像素数就是**缩放后**的 drawable 尺寸★（逻辑尺寸/点不在此结构里 —— 它没变）。
/// @param drawableWidthPixels  缩放后的 drawable 宽（像素）
/// @param drawableHeightPixels 缩放后的 drawable 高（像素）
/// @param renderScale          渲染倍率（1.0 = 原生像素；<1.0 = 降分辨率）
void a2_frame_perf_set_environment(int drawableWidthPixels, int drawableHeightPixels, double renderScale);

/// 设定后续帧的相位（由启动链调用）。
void a2_frame_perf_set_phase(A2FramePhase phase);

/// 记录一帧（由帧生产者每帧调用一次；本模块自算 CPU 帧时间与 fps）。
/// @param drawCalls 本帧提交的绘制/清屏命令数（★代理指标★）
/// @param shaderNew 本帧是否新建了着色器/管线（1 = 是；0 = 否）
/// @param presented 本帧是否真的呈现（1 = 已提交/换页）
/// @param clearWidthPixels  本帧实际清屏/绘制区域宽（像素；= 按渲染倍率算出的 drawable 宽）
/// @param clearHeightPixels 本帧实际清屏/绘制区域高（像素）
void a2_frame_perf_record_frame(int drawCalls, int shaderNew, int presented,
                                int clearWidthPixels, int clearHeightPixels);

/// 把最近一帧的数值组成判据行字符串（★不打印★；本函数是行格式的**唯一实现处**）。
/// 便于单测对行内容做断言 —— `a2_frame_perf_log_line` 只是把它交给日志。
NSString *a2_frame_perf_format_line(void);

/// 输出一行判据行（默认可见）。无帧样本时如实报 `frames=0`，不补默认值。
void a2_frame_perf_log_line(void);

#endif /* A2_FRAME_PERF_H */

// ============================================================================
//  Natives/Renderer/a2_frame_perf.m
//  Air2 —— ★帧性能判据（与渲染器无关）★ 实现（职责/边界/调用点见同名头文件）
// ----------------------------------------------------------------------------
//  实现要点：
//    · 纯计数 + 一次墙钟差分 ⇒ 不需要图形上下文，可在无 GPU 的机器（如 macOS 单测）上
//      真编译、真运行（`tests/Natives/run_frame_perf_tests.py`）。
//    · 行格式只有一处（`a2_frame_perf_format_line`）⇒ 「判据行长什么样」不会两头漂移。
//    · 一切取不到的值**如实打印**（0 / 0x0），不填默认值把问题盖住。
// ============================================================================
#import "a2_frame_perf.h"
#import "a2_log.h"

const char *const A2FramePerfTag = "[FRAME]";

// ---------------------------------------------------------------------------
// 状态（进程内一次性；start/attach 前由启动链设定）
// ---------------------------------------------------------------------------
static int          gDrawableWidthPixels  = 0;    // 缩放后的 drawable 宽（像素）
static int          gDrawableHeightPixels = 0;    // 缩放后的 drawable 高（像素）
static double       gRenderScale          = 1.0;  // 渲染倍率
static A2FramePhase gPhase                = A2FramePhasePreview;

static int    gFrameIndex      = 0;    // 已记录的帧数
static double gLastRecordTime  = 0.0;  // 上一帧的记录时刻（秒）
static double gLastFrameMs     = 0.0;  // 最近一次算出的 CPU 帧时间（毫秒）
static double gLastFps         = 0.0;  // 最近一次的 CPU 帧率（= 1000 / ms）

static int    gLastDrawCalls   = 0;
static int    gLastShaderNew   = 0;
static int    gLastPresented   = 0;
static int    gLastClearWidth  = 0;
static int    gLastClearHeight = 0;

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------

/// 当前时刻（秒，墙钟）。用 Foundation 的参考日期时间，避免引入平台头。
static double a2_frame_perf_now(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

/// 相位的中立英文词（判据行里机器可判；中文说明放文档与报告）。
static const char *a2_frame_perf_phase_word(A2FramePhase phase) {
    return (phase == A2FramePhaseReal) ? "real" : "preview";
}

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

void a2_frame_perf_set_environment(int drawableWidthPixels, int drawableHeightPixels, double renderScale) {
    gDrawableWidthPixels  = drawableWidthPixels;
    gDrawableHeightPixels = drawableHeightPixels;
    gRenderScale          = renderScale;

    // ★口径行（一次性）★：把「这行数字是什么、不是什么」说在明处 ——
    // 拿不到真实 GPU 时间，只用 CPU 帧时间 + draw 做代理；tex 是 drawable 字节估值。
    a2_log_f(@"%s 指标口径：★无真实 GPU 时间★ ⇒ cpu_fps/cpu_ms 为 CPU 帧时间（相邻帧墙钟差及其倒数）；"
             "draw 为提交的绘制/清屏命令数；tex 为 drawable 字节估值（非真实纹理内存）。"
             "drawable=%dx%d 像素 scale=%.2f",
             A2FramePerfTag, drawableWidthPixels, drawableHeightPixels, renderScale);
}

void a2_frame_perf_set_phase(A2FramePhase phase) {
    gPhase = phase;
}

void a2_frame_perf_record_frame(int drawCalls, int shaderNew, int presented,
                               int clearWidthPixels, int clearHeightPixels) {
    double now = a2_frame_perf_now();

    // 首帧没有前一帧可比 ⇒ fps/ms 留 0（如实：还没有样本）。
    if (gFrameIndex > 0 && now > gLastRecordTime) {
        gLastFrameMs = (now - gLastRecordTime) * 1000.0;
        gLastFps     = (gLastFrameMs > 0.0) ? (1000.0 / gLastFrameMs) : 0.0;
    }
    gLastRecordTime = now;
    gFrameIndex++;

    gLastDrawCalls   = drawCalls;
    gLastShaderNew   = shaderNew;
    gLastPresented   = presented;
    gLastClearWidth  = clearWidthPixels;
    gLastClearHeight = clearHeightPixels;
}

NSString *a2_frame_perf_format_line(void) {
    if (gFrameIndex == 0) {
        // 无帧样本：如实说「没有」，不编造一帧。
        return [NSString stringWithFormat:
                @"%s frames=0 ⇒ ★无帧样本★（帧生产者未产出帧；本行不补默认值）"
                @" phase=%s scale=%.2f px=%dx%d",
                A2FramePerfTag, a2_frame_perf_phase_word(gPhase), gRenderScale,
                gDrawableWidthPixels, gDrawableHeightPixels];
    }

    // 纹理（帧缓冲）字节估值：drawable 宽 × 高 × 4 字节（RGBA8）。★估值★，非真实纹理占用。
    long long textureBytes = (long long)gDrawableWidthPixels * (long long)gDrawableHeightPixels * 4LL;

    return [NSString stringWithFormat:
            @"%s frame=%d phase=%s cpu_fps=%.1f cpu_ms=%.2f draw=%d tex≈%lldKB shaderNew=%d presented=%d"
            @" scale=%.2f px=%dx%d clear=%dx%d",
            A2FramePerfTag, gFrameIndex, a2_frame_perf_phase_word(gPhase),
            gLastFps, gLastFrameMs, gLastDrawCalls, textureBytes / 1024LL,
            gLastShaderNew, gLastPresented, gRenderScale,
            gDrawableWidthPixels, gDrawableHeightPixels,
            gLastClearWidth, gLastClearHeight];
}

void a2_frame_perf_log_line(void) {
    // 注意：a2_log_f 走 vsnprintf ⇒ 只认 C 格式符（不认 %@），字符串一律用 %s + UTF8String。
    NSString *line = a2_frame_perf_format_line();
    a2_log_f(@"%s", line.UTF8String);
}

//
//  AmePerfProbe.m
//  ★ [PERF] 低开销滚动帧率探针实现（默认关闭；口径与用法见 AmePerfProbe.h 头部）
//

#import "AmePerfProbe.h"
#import "LauncherPreferences.h"
#import <QuartzCore/QuartzCore.h>

// ★ [PERF] 判据常量（单一事实源）
static const double kAmePerfFrameBudgetMs = 1000.0 / 60.0;   // 16.67ms = 60fps 单帧预算
static const double kAmePerfSevereMs      = 1000.0 / 30.0;   // 33.33ms = 已掉到 30fps 以下
// 数组维度必须是真正的编译期常量：用 enum 而不是 `static const int`
// （后者在 C 里不是常量表达式，clang 会以 -Wgnu-folding-constant 折叠成扩展 VLA）。
enum {
    kAmePerfMaxFrames = 4096,                                // 单会话最多保存的帧样本数
    kAmePerfMaxWorst  = 8,                                   // 最多记录几个「最重帧」
};
static const double kAmePerfIdleTimeout   = 0.25;            // 无滚动活动多久后结束本会话(秒)
static const double kAmePerfGapResetMs    = 500.0;           // 单帧 >500ms 视作断档，不计入

static int amePerfCmpDouble(const void *a, const void *b) {
    double x = *(const double *)a;
    double y = *(const double *)b;
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

@interface AmePerfProbe ()
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, copy, nullable) NSString *sessionTag;
@end

@implementation AmePerfProbe {
    CFTimeInterval _lastTimestamp;
    BOOL _haveLastTimestamp;
    CFTimeInterval _lastActivity;
    int _frameCount;      // 本会话测量到的帧数（可超过 kAmePerfMaxFrames；分布只统计前 kAmePerfMaxFrames 个）
    int _jankCount;
    int _severeCount;
    int _worstCount;
    double _samples[kAmePerfMaxFrames];
    double _worstMs[kAmePerfMaxWorst];
}

+ (instancetype)sharedProbe {
    static AmePerfProbe *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[AmePerfProbe alloc] init];
    });
    return shared;
}

+ (BOOL)isEnabled {
    static int cached = -1;
    if (cached >= 0) return cached == 1;
    BOOL on = NO;
    const char *env = getenv("AME_PERF_PROBE");
    if (env && env[0] == '1') on = YES;
    if (!on) {
        id pref = getPrefObject(@"debug.perf_probe");
        if ([pref respondsToSelector:@selector(boolValue)]) on = [pref boolValue];
    }
    cached = on ? 1 : 0;
    if (on) {
        NSLog(@"[PERF] AmePerfProbe 已启用 (判据: >16.7ms=jank, >33.4ms=severe, 占比<1%%&&severe==0=流畅)");
    }
    return on;
}

+ (void)noteScrollActivity:(NSString *)tag {
    if (![self isEnabled]) return;
    [[self sharedProbe] noteActivityWithTag:tag];
}

- (void)noteActivityWithTag:(NSString *)tag {
    if (self.displayLink == nil) {
        _frameCount = 0;
        _jankCount = 0;
        _severeCount = 0;
        _worstCount = 0;
        _haveLastTimestamp = NO;
        self.sessionTag = tag ?: @"?";
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleTick:)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.displayLink = link;
    }
    _lastActivity = CACurrentMediaTime();
}

- (void)handleTick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    if (_haveLastTimestamp) {
        double ms = (now - _lastTimestamp) * 1000.0;
        if (ms > 0.0 && ms < kAmePerfGapResetMs) {
            if (_frameCount < kAmePerfMaxFrames) _samples[_frameCount] = ms;
            _frameCount++;
            if (ms > kAmePerfFrameBudgetMs) _jankCount++;
            if (ms > kAmePerfSevereMs) {
                _severeCount++;
                [self recordWorstMs:ms];
            }
        }
    }
    _lastTimestamp = now;
    _haveLastTimestamp = YES;

    if (CACurrentMediaTime() - _lastActivity > kAmePerfIdleTimeout) {
        [self finishSession];
    }
}

- (void)recordWorstMs:(double)ms {
    if (_worstCount < kAmePerfMaxWorst) {
        _worstMs[_worstCount++] = ms;
        return;
    }
    int minIdx = 0;
    for (int i = 1; i < kAmePerfMaxWorst; i++) {
        if (_worstMs[i] < _worstMs[minIdx]) minIdx = i;
    }
    if (ms > _worstMs[minIdx]) _worstMs[minIdx] = ms;
}

- (void)finishSession {
    CADisplayLink *link = self.displayLink;
    if (link) {
        [link invalidate];
        self.displayLink = nil;
    }

    int n = _frameCount < kAmePerfMaxFrames ? _frameCount : kAmePerfMaxFrames;
    if (n <= 0) {
        _frameCount = 0; _jankCount = 0; _severeCount = 0; _worstCount = 0; _haveLastTimestamp = NO;
        self.sessionTag = nil;
        return;
    }

    double sum = 0.0, maxMs = 0.0;
    for (int i = 0; i < n; i++) {
        sum += _samples[i];
        if (_samples[i] > maxMs) maxMs = _samples[i];
    }
    double avg = sum / (double)n;

    double p95 = _samples[n - 1];
    if (n >= 2) {
        double *sorted = (double *)malloc(sizeof(double) * (size_t)n);
        if (sorted) {
            memcpy(sorted, _samples, sizeof(double) * (size_t)n);
            qsort(sorted, (size_t)n, sizeof(double), amePerfCmpDouble);
            int idx = (int)ceil(0.95 * (double)n) - 1;
            if (idx < 0) idx = 0;
            if (idx >= n) idx = n - 1;
            p95 = sorted[idx];
            free(sorted);
        }
    }

    double jankPct = (double)_jankCount * 100.0 / (double)n;
    BOOL smooth = (_severeCount == 0 && jankPct < 1.0);

    NSLog(@"[PERF][scroll] tag=%@ frames=%d avg=%.1fms p95=%.1fms max=%.1fms jank(>%.1fms)=%d(%.1f%%) severe(>%.1fms)=%d ⇒ %@",
          self.sessionTag ?: @"?",
          n, avg, p95, maxMs,
          kAmePerfFrameBudgetMs, _jankCount, jankPct,
          kAmePerfSevereMs, _severeCount,
          smooth ? @"判定:流畅" : @"判定:有卡顿");

    if (_severeCount > 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:(NSUInteger)_worstCount];
        for (int i = 0; i < _worstCount; i++) {
            [parts addObject:[NSString stringWithFormat:@"%.1fms", _worstMs[i]]];
        }
        NSLog(@"[PERF][scroll] tag=%@ 最重帧(共 %d 次 severe,记录 %d 个): %@",
              self.sessionTag ?: @"?", _severeCount, _worstCount,
              [parts componentsJoinedByString:@", "]);
    }

    _frameCount = 0;
    _jankCount = 0;
    _severeCount = 0;
    _worstCount = 0;
    _haveLastTimestamp = NO;
    self.sessionTag = nil;
}

@end

// ============================================================================
//  Natives/Input/A2InputRouter.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 路由器实现
// ----------------------------------------------------------------------------
//  本文件是「三种源 × 所有内核」的唯一交汇点，因此它必须自己扛住三件事：
//
//  ① 按下集合（_heldByTrigger）：按过什么、解算成了什么。
//     ★解算结果在按下时记下来、松开时直接复用★ —— 若松开时再查一次绑定表，
//     用户在「按着 W」期间改绑 W，松开就会落到另一个键：原来的键永远抬不起来
//     （MC 里表现为角色一直往前走）。这是本层最容易被忽略、也最难复现的坑。
//
//  ② 落点引用计数（_heldTargets）：多个源映射到同一个键时，只有全松才发 RELEASE。
//
//  ③ 汇的如实反馈：没有内核收下的事件要计数并留痕，而不是「投出去就算成功」。
//     手柄落点投给「没有手柄通道的内核」就是这种情形：必须查得出断在哪一段。
//
//  ★主线程契约★：UIKit 事件与窗口生命周期都在主线程，本类所有可变状态只在主线程
//    读写（不加锁 = 不给死锁与「偶发错序」留机会）。非主线程调用会记一条日志
//    而不是崩 —— 崩在输入路径上等于整局游戏陪葬，留痕足够定位。
// ============================================================================
#import "A2InputRouter.h"

#import "a2_log.h"

#pragma mark - 按下集合里的一格（落点 + 计数）

/// 一个仍被按着的落点。计数 = 有多少个「源触发」正压在它上面。
@interface A2InputHeldTarget : NSObject
@property (nonatomic, assign) A2InputTargetKind targetKind;
@property (nonatomic, assign) int code;
@property (nonatomic, assign) int mods;
@property (nonatomic, assign) int scancode;
@property (nonatomic, assign) NSUInteger count;
@end

@implementation A2InputHeldTarget
@end

#pragma mark - 路由器

@implementation A2InputRouter {
    NSMutableArray<id<A2InputSink>> *_sinks;
    NSMutableArray<id<A2InputSource>> *_sources;
    /// 触发键 → 落点键（按下时解算，松开时复用；见文件头 ①）
    NSMutableDictionary<NSString *, NSString *> *_heldByTrigger;
    /// 落点键 → A2InputHeldTarget（引用计数；见文件头 ②）
    NSMutableDictionary<NSString *, A2InputHeldTarget *> *_heldTargets;
    /// 已经打过「首个触发」判据行的源种类（真机诊断用：证明这条路真的通了）
    NSMutableSet<NSNumber *> *_announcedSourceKinds;
    /// 已经打过「内核不收这个落点」的落点种类（避免连按时刷屏）
    NSMutableSet<NSNumber *> *_announcedRejectedTargetKinds;
    BOOL _loggedOffMainThread;
    NSUInteger _rejectedEventCount;
    NSUInteger _unmappedTriggerCount;
}

- (instancetype)initWithBindings:(A2InputBindingTable *)bindings {
    self = [super init];
    if (self != nil) {
        _bindings = [bindings copy];
        _sinks = [NSMutableArray array];
        _sources = [NSMutableArray array];
        _heldByTrigger = [NSMutableDictionary dictionary];
        _heldTargets = [NSMutableDictionary dictionary];
        _announcedSourceKinds = [NSMutableSet set];
        _announcedRejectedTargetKinds = [NSMutableSet set];

        // ★退后台自动抬键★：玩家按着 W 切出去时，MC 收不到抬手 ⇒ 回来还在走。
        // 这里用通知名而不是 import UIKit：本类只依赖 Foundation，测试能在 macOS 上直接跑；
        // 通知名是 UIKit 的稳定公开常量（UIApplicationDidEnterBackgroundNotification）。
        [NSNotificationCenter.defaultCenter addObserver:self
                                              selector:@selector(a2_applicationDidEnterBackground:)
                                                  name:@"UIApplicationDidEnterBackgroundNotification"
                                                object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)a2_applicationDidEnterBackground:(NSNotification *)notification {
    (void) notification;
    [self releaseAllHeldTargets];
}

#pragma mark - 绑定

- (void)setBindings:(A2InputBindingTable *)bindings {
    if (bindings == nil) {
        return;
    }
    // 先抬键：改绑后旧落点就再也解算不出来了（见文件头 ①）。
    [self releaseAllHeldTargets];
    _bindings = [bindings copy];
    a2_log_f(@"[INPUT-MAP] 绑定表已更新：%d 条（键盘直通=%s）",
             (int) bindings.bindings.count,
             bindings.keyboardPassthrough ? "YES" : "NO");
}

#pragma mark - 汇

- (void)addSink:(id<A2InputSink>)sink {
    if (sink == nil || [_sinks indexOfObjectIdenticalTo:sink] != NSNotFound) {
        return;
    }
    [_sinks addObject:sink];
    a2_log_f(@"[INPUT-MAP] 内核汇已接入：%s（可用=%s）",
             sink.sinkIdentifier.UTF8String ?: "?",
             sink.isAvailable ? "YES" : "NO");
}

- (void)removeSink:(id<A2InputSink>)sink {
    if (sink == nil) {
        return;
    }
    NSUInteger idx = [_sinks indexOfObjectIdenticalTo:sink];
    if (idx == NSNotFound) {
        return;
    }
    // 这个汇收过的键必须抬起，否则它背后的内核会一直认为键还按着。
    // ★顺序★：先抬键（此时汇还在册，收得到 RELEASE），再摘汇。
    [self releaseAllHeldTargets];
    [_sinks removeObjectAtIndex:idx];
    a2_log_f(@"[INPUT-MAP] 内核汇已断开：%s", sink.sinkIdentifier.UTF8String ?: "?");
}

#pragma mark - 源

- (void)addSource:(id<A2InputSource>)source {
    if (source == nil || [_sources indexOfObjectIdenticalTo:source] != NSNotFound) {
        return;
    }
    source.delegate = self;
    [_sources addObject:source];
    if (source.isEnabled) {
        NSError *error = nil;
        if (![source startWithError:&error]) {
            // ★不崩、不藏★：未实现的源（虚拟按钮 / 手柄）就是在这里如实暴露的。
            a2_log_f(@"[INPUT-MAP] 源 %s 未启动：%s",
                     source.sourceIdentifier.UTF8String ?: "?",
                     error.localizedDescription.UTF8String ?: "未知原因");
        }
    }
}

- (void)removeSource:(id<A2InputSource>)source {
    if (source == nil) {
        return;
    }
    NSUInteger idx = [_sources indexOfObjectIdenticalTo:source];
    if (idx == NSNotFound) {
        return;
    }
    [source stop];
    source.delegate = nil;
    [_sources removeObjectAtIndex:idx];
    [self releaseAllHeldTargets];
}

- (nullable id<A2InputSource>)sourceForKind:(A2InputSourceKind)sourceKind {
    for (id<A2InputSource> source in _sources) {
        if (source.sourceKind == sourceKind) {
            return source;
        }
    }
    return nil;
}

#pragma mark - 唯一入口

- (void)inputSource:(id<A2InputSource>)source didProduceTrigger:(A2InputTrigger)trigger {
    (void) source;
    [self emitTrigger:trigger];
}

- (void)emitTrigger:(A2InputTrigger)trigger {
    if (!NSThread.isMainThread && !_loggedOffMainThread) {
        _loggedOffMainThread = YES;
        a2_log_f(@"[INPUT-MAP] 警告：非主线程投递输入（源=%s），状态可能错序",
                 A2InputSourceKindName(trigger.sourceKind).UTF8String ?: "?");
    }

    id<A2InputSource> source = [self sourceForKind:trigger.sourceKind];
    if (source != nil && !source.isEnabled) {
        return;
    }

    NSString *triggerKey = A2InputTriggerKey(trigger);
    if (trigger.action == A2InputActionPress) {
        [self handlePressTrigger:trigger triggerKey:triggerKey];
    } else {
        [self handleReleaseTrigger:trigger triggerKey:triggerKey];
    }
}

- (void)handlePressTrigger:(A2InputTrigger)trigger triggerKey:(NSString *)triggerKey {
    if (_heldByTrigger[triggerKey] != nil) {
        // 同一个触发重复按下（UIKit 重发 / 控件抖动）：忽略。
        // 不忽略会让引用计数凭空 +1，松开时抬不起来 —— 真机上就是「卡键」。
        return;
    }

    A2InputEvent event;
    if (![self resolveEventForTrigger:trigger event:&event]) {
        _unmappedTriggerCount++;
        return;
    }

    event.scancode = trigger.scancode;   // 键盘 scancode 透传给内核（见 A2InputTrigger 说明）

    [self announceIfNeededForSourceKind:trigger.sourceKind];

    NSString *targetKey = A2InputEventTargetKey(event);
    _heldByTrigger[triggerKey] = targetKey;

    A2InputHeldTarget *held = _heldTargets[targetKey];
    if (held == nil) {
        held = [[A2InputHeldTarget alloc] init];
        held.targetKind = event.targetKind;
        held.code = event.code;
        held.mods = event.mods;
        held.scancode = event.scancode;
        held.count = 0;
        _heldTargets[targetKey] = held;
    }
    held.count += 1;
    if (held.count > 1) {
        // 已有别的源压着同一个落点：不重复发 PRESS（MC 会当成第二次按下）。
        return;
    }
    [self dispatchEvent:event];
}

- (void)handleReleaseTrigger:(A2InputTrigger)trigger triggerKey:(NSString *)triggerKey {
    NSString *targetKey = _heldByTrigger[triggerKey];
    if (targetKey == nil) {
        // 没按下过就松开（例如进游戏前就按着某个键）：忽略。
        // 否则会给内核发一个「凭空松开」，MC 的按键状态会从「没按」跳到「松开」。
        return;
    }
    [_heldByTrigger removeObjectForKey:triggerKey];

    A2InputHeldTarget *held = _heldTargets[targetKey];
    if (held == nil) {
        return;
    }
    if (held.count > 1) {
        held.count -= 1;
        return;
    }
    [_heldTargets removeObjectForKey:targetKey];
    A2InputEvent release = A2InputEventMake(held.targetKind, held.code, A2InputActionRelease, trigger.mods);
    release.scancode = held.scancode;
    [self dispatchEvent:release];
}

/// 触发 → 事件。查不到绑定且不满足键盘直通时返回 NO（调用方计为「未映射」）。
- (BOOL)resolveEventForTrigger:(A2InputTrigger)trigger event:(A2InputEvent *)event {
    A2InputBinding *binding = [_bindings bindingForTrigger:trigger];
    if (binding != nil) {
        *event = A2InputEventMake(binding.targetKind, binding.targetCode, A2InputActionPress, trigger.mods);
        return YES;
    }
    if (trigger.sourceKind == A2InputSourceKindKeyboard && _bindings.keyboardPassthrough) {
        // 直通：没改绑的键就是它自己。★只在没有显式绑定时生效★（见头文件说明）。
        *event = A2InputEventMake(A2InputTargetKindKey, trigger.code, A2InputActionPress, trigger.mods);
        return YES;
    }
    return NO;
}

- (void)dispatchEvent:(A2InputEvent)event {
    BOOL delivered = NO;
    for (id<A2InputSink> sink in [_sinks copy]) {
        if (!sink.isAvailable) {
            continue;
        }
        if ([sink emitEvent:event]) {
            delivered = YES;
        }
    }
    if (delivered) {
        return;
    }
    _rejectedEventCount++;
    NSNumber *kindKey = @(event.targetKind);
    if (![_announcedRejectedTargetKinds containsObject:kindKey]) {
        [_announcedRejectedTargetKinds addObject:kindKey];
        // 判据行：这条能直接回答「手柄/手柄按键为什么没反应」。
        a2_log_criterion(@"[INPUT-MAP] 没有内核接收落点种类 %@（code=%d）—— 该目标空间在当前内核没有通道",
                         A2InputTargetKindName(event.targetKind), event.code);
    }
}

- (void)announceIfNeededForSourceKind:(A2InputSourceKind)sourceKind {
    NSNumber *key = @(sourceKind);
    if ([_announcedSourceKinds containsObject:key]) {
        return;
    }
    [_announcedSourceKinds addObject:key];
    a2_log_criterion(@"[INPUT-MAP] 首个 %@ 触发已到达映射层（绑定 %d 条）",
                     A2InputSourceKindName(sourceKind), (int) _bindings.bindings.count);
}

#pragma mark - 防卡键

- (void)releaseAllHeldTargets {
    if (_heldTargets.count == 0) {
        return;
    }
    NSUInteger heldCount = _heldTargets.count;
    NSArray<A2InputHeldTarget *> *heldTargets = [_heldTargets allValues];
    [_heldByTrigger removeAllObjects];
    [_heldTargets removeAllObjects];
    for (A2InputHeldTarget *held in heldTargets) {
        A2InputEvent release = A2InputEventMake(held.targetKind, held.code, A2InputActionRelease, held.mods);
        release.scancode = held.scancode;
        [self dispatchEvent:release];
    }
    a2_log_f(@"[INPUT-MAP] 已抬起全部仍按着的落点：%d 个", (int) heldCount);
}

#pragma mark - 自检

- (BOOL)isHeldKey:(int)glfwKey {
    return _heldTargets[A2InputEventTargetKey(A2InputEventMake(A2InputTargetKindKey, glfwKey,
                                                              A2InputActionPress, 0))] != nil;
}

- (NSUInteger)rejectedEventCount {
    return _rejectedEventCount;
}

- (NSUInteger)unmappedTriggerCount {
    return _unmappedTriggerCount;
}

@end

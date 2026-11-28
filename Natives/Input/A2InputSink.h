// ============================================================================
//  Natives/Input/A2InputSink.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 内核汇接口（所有 MC 内核共用一套）
// ----------------------------------------------------------------------------
//  「对目前所有的 MC 内核」就落在本协议上：映射层解算完的事件统一交给汇，
//  每个内核（GLFW 事件总线内核 / 26.3 的 SDL3 内核 / 将来的纯 SDL 内核）
//  各自实现一份汇，映射层与源一行都不用改。
//
//  为什么现在只有一份实现（A2KernelInputSink）却仍要协议：
//    · 它是「新内核接进来」的唯一缝：加内核 = 加一个汇，不改映射层；
//    · 单测要能用一个假汇断言「事件真的被投出去了、投了几次、被拒绝时怎么算」——
//      没有协议就只能测真内核，而真内核要 UIKit + JVM 才能跑。
//
//  ★emitEvent 返回 BOOL 是契约的核心★
//    YES = 本内核收下了；NO = 本内核**不收这个目标空间**（例如现在的 MC 没有原生
//    手柄通道，手柄按键汇进去也只能丢）。映射层据此计数并如实记日志 ——
//    而不是「投了就算成功」，让「手柄映射没反应」永远查不出是哪一段断的。
// ============================================================================
#ifndef A2_INPUT_SINK_H
#define A2_INPUT_SINK_H

#import <Foundation/Foundation.h>

#import "A2InputTypes.h"

NS_ASSUME_NONNULL_BEGIN

@protocol A2InputSink <NSObject>

/// 诊断用短名（"kernel-glfw" …）。只进日志与断言。
@property (nonatomic, copy, readonly) NSString *sinkIdentifier;

/// 该内核此刻能不能收事件（窗口已销毁 ⇒ NO，避免往死句柄里投）。
@property (nonatomic, readonly) BOOL isAvailable;

/// 投一个事件。★主线程调用★。返回 NO = 本内核不收这个目标空间（见文件头说明）。
- (BOOL)emitEvent:(A2InputEvent)event;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_INPUT_SINK_H */

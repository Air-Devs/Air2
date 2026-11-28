// ============================================================================
//  Natives/Input/A2KernelInputSink.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 内核汇（一份覆盖所有 MC 内核）
// ----------------------------------------------------------------------------
//  「对目前所有的 MC 内核」在这里落地。本仓现在有两条内核输入栈：
//
//    · ≤26.2：GLFW 事件总线（a2_glfw_window.m 的 a2_glfw_event_post）
//    · 26.3 ：SDL3 事件队列（MC 把窗口/输入栈换成了 SDL3，GLFW 事件收不到）
//
//  两条栈的「同一份输入」已经由 a2_glfw_input_post_key_event 内部完成
//  （GLFW 总线 + SDL 镜像），所以本汇只需要投一次，不需要按版本判断，
//  也不会出现「26.3 要单独接一份」这种版本分叉。
//
//  ★手柄按键为什么如实返回 NO★
//    现在的 MC 没有原生手柄输入通道（它只认 GLFW 的键/鼠标回调）。
//    把手柄按键「硬塞」成键盘需要用户绑定（A2InputBindingTable 的出厂表就是这么做的），
//    而不是在内核汇这里假装能收。返回 NO 会让映射层记一条判据行，
//    一眼看出「手柄没反应」是断在「目标空间没有通道」而不是断在绑定。
// ============================================================================
#ifndef A2_KERNEL_INPUT_SINK_H
#define A2_KERNEL_INPUT_SINK_H

#import <Foundation/Foundation.h>

#import "A2InputSink.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2KernelInputSink : NSObject <A2InputSink>

/// 绑定到某个窗口句柄（= GLFW window id）。句柄为 0 时 isAvailable 恒为 NO。
- (instancetype)initWithWindowHandle:(long)window NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) long windowHandle;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_KERNEL_INPUT_SINK_H */

// ============================================================================
//  Natives/Input/A2InputSource.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 输入源接口（三种源共用一套）
// ----------------------------------------------------------------------------
//  「三种输入一套接口」的落点就是这里：虚拟按钮 / 键盘 / 手柄都只实现本协议，
//  映射层（A2InputRouter）只认协议、不认具体类。
//
//  为什么源只吐「触发」不吐「事件」：
//    源知道「我按了 A 键」或「玩家按了手柄 A」，但**不知道** A 键该映射成什么 ——
//    那是用户的绑定表决定的（同一个手柄 A 今天可能是跳跃、明天可能是背包）。
//    源若直接吐「目标事件」，绑定表就没地方放，改绑只能改源。
//
//  ★start 必须如实★：没有实现的源（[INPUT-MAP-1] 的虚拟按钮 / 手柄）必须
//    返回 NO 并给出 A2InputErrorCodeNotImplemented。返回 YES 却什么也不做，
//    等于让上层以为「手柄已经能用了」—— 这种谎报在真机上极难识别。
// ============================================================================
#ifndef A2_INPUT_SOURCE_H
#define A2_INPUT_SOURCE_H

#import <Foundation/Foundation.h>

#import "A2InputTypes.h"

NS_ASSUME_NONNULL_BEGIN

@protocol A2InputSource;

/// 源 → 映射层 的唯一回调。
@protocol A2InputSourceDelegate <NSObject>
/// 源产生了一次触发。★主线程调用★（UIKit 事件都在主线程，映射层不跨线程）。
- (void)inputSource:(id<A2InputSource>)source didProduceTrigger:(A2InputTrigger)trigger;
@end

@protocol A2InputSource <NSObject>

/// 种类标签（决定用哪张绑定表）。
@property (nonatomic, readonly) A2InputSourceKind sourceKind;

/// 诊断用短名（"keyboard" / "virtual-button" / "gamepad"）。只进日志与断言。
@property (nonatomic, copy, readonly) NSString *sourceIdentifier;

/// 关闭后源不再产生触发（映射层也会忽略它）。默认 YES。
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 映射层。★weak★：源不该持有映射层（否则窗口销毁后两者互相吊着）。
@property (nonatomic, weak, nullable) id<A2InputSourceDelegate> delegate;

/// 建立底层监听（键盘 = 标记可接收；手柄 = 注册 GCController 通知）。
/// 不可用/未实现时返回 NO 并填 error，★不允许假装成功★。
- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error;

/// 撤销监听。可重复调用（幂等）。
- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_INPUT_SOURCE_H */

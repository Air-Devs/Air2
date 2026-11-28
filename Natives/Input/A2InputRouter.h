// ============================================================================
//  Natives/Input/A2InputRouter.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 路由器（唯一入口）
// ----------------------------------------------------------------------------
//  三种源（虚拟按钮 / 键盘 / 手柄）→ 一张绑定表 → 所有 MC 内核的汇。
//  数据流只有一条，任何新源/新内核都只是「注册进来」，不改这里的判断：
//
//      A2InputSource ──trigger──▶ A2InputRouter ──event──▶ A2InputSink（每个内核一份）
//                                      │
//                                      └─ A2InputBindingTable（改绑的唯一数据源）
//
//  ★为什么必须有一个「唯一入口」★
//    改绑、防卡键、多源同落点、内核能力差异这四件事都要看「全局正在按什么」。
//    若各源各自往内核里投事件，改绑之后旧键就抬不起来（真机上表现为
//    「走路停不下来」），而这类 bug 只能靠「记住按过什么」来防 —— 那就必须集中。
//
//  ★多源同落点用引用计数★
//    虚拟按钮「跳跃」和手柄 A 都映射到 SPACE 时，先松一个不能把 SPACE 抬起来，
//    否则游戏里会出现「按着手柄却一直跳一下停一下」。所以：落点被按下几次，
//    就要被松开几次，只有计数归零才真的发 RELEASE。
//
//  ★改绑时先抬键★
//    setBindings: 会先 releaseAllHeldTargets，否则「按下 W（映射到跳跃）→ 改绑 W →
//    松开 W」时，松开按新表解算到别的键，原来的 SPACE 永远抬不起来。
// ============================================================================
#ifndef A2_INPUT_ROUTER_H
#define A2_INPUT_ROUTER_H

#import <Foundation/Foundation.h>

#import "A2InputBinding.h"
#import "A2InputSink.h"
#import "A2InputSource.h"
#import "A2InputTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2InputRouter : NSObject <A2InputSourceDelegate>

/// 用给定绑定表建路由器（★装配点必须显式给表★：默认表只在 +defaultTable 里，
/// 不让路由器自己偷偷造一份，否则「用户改过的表」和「默认表」会同时存在）。
- (instancetype)initWithBindings:(A2InputBindingTable *)bindings NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - 绑定

@property (nonatomic, copy, readonly) A2InputBindingTable *bindings;

/// 换表（用户改绑后调用）。★会先把仍按着的落点全部抬起★（见文件头说明）。
- (void)setBindings:(A2InputBindingTable *)bindings;

#pragma mark - 汇（内核侧）

/// 注册一个内核汇。重复注册同一对象会被忽略。
- (void)addSink:(id<A2InputSink>)sink;
- (void)removeSink:(id<A2InputSink>)sink;

#pragma mark - 源（输入侧）

/// 注册一个源：设 delegate，并在其 enabled 时 start（start 失败只记日志，不崩）。
- (void)addSource:(id<A2InputSource>)source;
- (void)removeSource:(id<A2InputSource>)source;

/// 按种类取源（窗口层要拿键盘源转发 UIKit 的按下/抬起）。
- (nullable id<A2InputSource>)sourceForKind:(A2InputSourceKind)sourceKind;

#pragma mark - 唯一入口

/// 源产生的触发从这里进来。★主线程调用★。
- (void)emitTrigger:(A2InputTrigger)trigger;

#pragma mark - 防卡键

/// 把所有仍按着的落点全部抬起。
/// ★已自动接上退后台★（UIApplicationDidEnterBackgroundNotification），窗口销毁 / 改绑 / 摘汇
/// 也都由本类自己调；调用方只在「自己知道该收手」的场合（例如切版本）额外调一次。
- (void)releaseAllHeldTargets;

#pragma mark - 自检

/// 某个键盘键此刻是否处于按下状态（单测与真机自检用）。
- (BOOL)isHeldKey:(int)glfwKey;

/// 被所有汇如实拒绝的事件数（例如手柄落点投给了没有手柄通道的内核）。
@property (nonatomic, readonly) NSUInteger rejectedEventCount;

/// 查不到绑定、也不满足直通而被丢弃的触发数（改绑漏了/表读坏了的第一现场）。
@property (nonatomic, readonly) NSUInteger unmappedTriggerCount;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_INPUT_ROUTER_H */

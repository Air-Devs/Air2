//
//  A2LaunchRuntimeFacts.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Utils —— ★启动时的「运行时事实」值对象★（屏幕像素尺寸 / 系统最大帧率）。
//
//  ★为什么放 Utils（而不是 Core 或 Bridge）★：
//    这三个取值有三层要看到 ——
//      · 生产者 = `Air2/Bridge/A2LaunchRunner.m` 的 `+currentRuntimeFacts`
//        （Bridge 是启动链唯一与 Natives 相邻的跨层入口，也是链上唯一允许读 UIKit 的落点）；
//      · 中转   = `Air2/Player/A2LaunchSession.m`（把事实递进启动计划）；
//      · 消费者 = `Air2/Core/Version/A2LaunchPlan.m`（持有并落成 VM 级 `-D`）。
//    而分层规范是严格单向的（App → UI → Player → Core → Bridge）；
//    ★Core 不得 import Bridge、Bridge 不得 import Core★ ⇒ 这个类型只能落在
//    两者共同可见的叶子层。Utils 正是那一层（同目录的 A2LaunchContract 就是先例）。
//
//  ★它不含任何 UIKit，也不是 UI 组件★ —— 只是一个「已经被采集好的事实」的载体。
//
//  ★「取不到」的语义（不写猜的值）★：
//    所有字段一律用 `0` 表示「没取到」。没取到 ⇒ 对应 `-D` 一条都不下发
//    （见 `A2LaunchPlan.jvmOptionsWithMemoryMB:`），★绝不填一个默认值把问题盖住★。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 不可变值对象 ⇒ 实现 NSCopying：`A2LaunchPlan.runtimeFacts` 是 `copy` 属性
/// （与计划里其余字段同风格），而 `copy` 属性在 setter 里会对值发 `copyWithZone:` ——
/// 不实现就会在运行时抛 unrecognized selector（本单 2026-10-11 的 tests/Plan 首跑即抓到）。
@interface A2LaunchRuntimeFacts : NSObject <NSCopying>

/// 渲染宿主表面的★像素★宽（= `宿主窗口 bounds.宽 × 屏幕 scale`；0 = 没取到）。
@property (nonatomic, assign, readonly) NSInteger surfaceWidthPixels;
/// 渲染宿主表面的★像素★高（同上；0 = 没取到）。
@property (nonatomic, assign, readonly) NSInteger surfaceHeightPixels;
/// 系统最大帧率（= `UIScreen.mainScreen.maximumFramesPerSecond`；0 = 没取到）。
@property (nonatomic, assign, readonly) NSInteger maximumFramesPerSecond;

/// 构造。任一项没取到就传 0（语义见文件头）。
+ (instancetype)factsWithSurfaceWidthPixels:(NSInteger)surfaceWidthPixels
                              heightPixels:(NSInteger)surfaceHeightPixels
                     maximumFramesPerSecond:(NSInteger)maximumFramesPerSecond;

/// 是否拿到了可用的表面像素尺寸（宽、高都 > 0）。
- (BOOL)hasSurfaceSize;
/// 是否拿到了可用的最大帧率（> 0）。
- (BOOL)hasMaximumFramesPerSecond;

/// `glfw.windowSize` 的取值：`"<宽>x<高>"`（十进制像素值，分隔符是小写 `x`）。
///
/// ★这个格式的唯一实现处★：消费端是复用线覆盖层的 `GLFW.java:538`
/// `System.getProperty("glfw.windowSize").split("x")` —— 分隔符必须是小写 `x`，
/// 两端必须是能被 `Integer.valueOf` 吃下的十进制整数（负号不会出现，尺寸恒为正）。
/// 没取到表面尺寸 ⇒ 返回 nil（调用方据此不下发该 `-D`）。
- (nullable NSString *)glfwWindowSizeValue;

@end

NS_ASSUME_NONNULL_END

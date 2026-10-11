//
//  A2LaunchSession.h
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 一次启动会话的编排：产出启动计划（Core）→ 组命令行（Bridge）→ 建 VM 派发主类。
//
//  分层：Player 只做「顺序 + 取值」，不解析版本 JSON（Core）、不碰 JNI（Natives）、
//  不写 UI（UI 只拿本类的完成回调）。UI 因此只看见一个方法。
//
//  ★开关默认关★：`+runtimeChainEnabled` 为假时 `startCurrentVersionWithCompletion:` 立刻
//  以 `started = NO` 回调，**不产生任何副作用**（不建 VM、不落计划）⇒ 开箱行为不变。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一次启动尝试的结果。
@interface A2LaunchSessionResult : NSObject

/// 是否真的进入了自研链（成功建 VM 并派发主类 main 则为 YES）。
@property (nonatomic, assign, readonly) BOOL started;
/// 自研链返回码（`a2_launch_jvm_with_argv` 契约；未进入为 0）。
@property (nonatomic, assign, readonly) NSInteger returnCode;
/// 可读结果/失败原因（未启用时为「未启用」类文案）。
@property (nonatomic, copy, readonly) NSString *message;

@end

@interface A2LaunchSession : NSObject

/// 自研启动链是否启用（真值来源见 Natives a2_launch.h；默认关）。
+ (BOOL)runtimeChainEnabled;

/// 启动当前选中版本。回调在主线程。
/// 未启用 / 无版本 / 计划产出失败时以 `started = NO` 回调并给出原因。
+ (void)startCurrentVersionWithCompletion:(void (^)(A2LaunchSessionResult *result))completion;

@end

NS_ASSUME_NONNULL_END

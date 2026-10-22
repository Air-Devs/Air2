//
//  A2TaskLogOutput.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2TaskLogOutput.h
//  Air2
//
//  任务日志输出 —— 对照 ZL2 的 coroutine/TaskLogOutput.kt。
//
//  ZL2 的进度显示不是「进度条 + 百分比」，而是【实时日志流】：
//    ┌─────────────────────────────┐
//    │ 安装 1.20.1-fabric           │  标题
//    ├─────────────────────────────┤
//    │ [12:34:56] 开始下载客户端      │  等宽字体日志行
//    │ [12:34:58] 下载中 45%         │  自动滚到最新
//    │ [12:35:02] 解压依赖库…         │
//    └─────────────────────────────┘
//
//  为什么用日志流而不是进度条：
//    安装过程有多个阶段（下 json / 下 jar / 下库 / 下资源 / 装加载器），
//    单一进度条说不清「现在到底在干什么」。开发者视角的日志反而更清楚 ——
//    用户遇到问题截图就能定位。
//
//  行数有上限（默认 200）—— 安装过程可能产生上千行，
//  全留着会吃内存且没人往回翻。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2TaskLogOutput : NSObject

/// 任务标题（如「安装 1.20.1-fabric」）
@property (nonatomic, copy, readonly) NSString *title;
/// 当前已展示的日志行
@property (nonatomic, copy, readonly) NSArray<NSString *> *lines;
/// 是否处于日志输出会话中
@property (nonatomic, assign, readonly, getter=isActive) BOOL active;

/// 日志行上限
@property (nonatomic, assign) NSInteger maxLines;

- (instancetype)initWithTitle:(NSString *)title;
- (instancetype)initWithTitle:(NSString *)title maxLines:(NSInteger)maxLines;

/// 日志变化回调（主线程）
@property (nonatomic, copy, nullable) void (^onLinesChanged)(NSArray<NSString *> *lines);
/// 活跃状态变化
@property (nonatomic, copy, nullable) void (^onActiveChanged)(BOOL active);

/// 开始一次输出会话：清空已有内容
- (void)start;

/// 结束会话：保留已展示的内容
- (void)stop;

/// 追加一行。会自动加时间戳前缀。
- (void)append:(NSString *)line;

/// 追加带进度的一行（覆盖式 —— 同一类进度只保留最新一行）
///
/// 用于「下载中 45%」这类高频更新：每次都追加会瞬间刷满整个列表。
- (void)appendProgress:(NSString *)line;

/// 清空
- (void)clear;

@end

NS_ASSUME_NONNULL_END

//
//  A2LaunchDiagnostics.h
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
//  启动前检查的失败诊断。
//
//  ## 为什么要单独一层
//
//  启动失败最常见的反馈是「进不去游戏」—— 没有文件、地址、原因，
//  用户和开发者都只能猜。ZL2 在 task 失败时抛异常，异常 message 里
//  带失败文件路径（见 TaskBatch.kt / DownloadFailedException.kt）；
//  Air2 的 TaskFlow 只把 task.detail 原样塞进 NSError，信息量取决于
//  任务作者写了什么。这里把「哪个文件 / 哪个 URL / 什么原因 / 能否重试」
//  做成固定字段，所有启动任务共用同一套格式，UI 弹窗能直接展示。
//
//  ## 字段约定
//
//    A2LaunchErrorKindKey      A2LaunchErrorKind（决定引导到哪个修复入口）
//    A2LaunchErrorStepKey      出错的任务名（"校验并修复文件"）
//    A2LaunchErrorReasonKey    人能读懂的原因（含期望/实测大小、SHA1 等）
//    A2LaunchErrorFileKey      目标文件绝对路径（没有则为空）
//    A2LaunchErrorURLKey       最后尝试的下载地址（没有则为空）
//    A2LaunchErrorRetryableKey @YES 表示原样重试有成功可能
//
//  ## 与 ZL2 的对应
//
//    ZL2 GameLaunchFlow.kt 把失败分成 LaunchReloginRequired / LaunchCheckFailed
//    / LaunchRendererDeclined 三类（第 68~79 行），分别引导重新登录、
//    重试、取消启动。这里保留同样的分类，并额外带上文件/地址。
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 失败类型 —— 区分「要重新登录」和「网络问题」，处理方式完全不同。
/// 数值 0~4 与旧版 A2GameLaunchCoordinator.h 保持一致，新增项追加在末尾。
typedef NS_ENUM(NSInteger, A2LaunchErrorKind) {
    A2LaunchErrorKindReloginRequired = 0,   ///< 凭据被服务端拒绝（需重新登录）
    A2LaunchErrorKindCheckFailed,           ///< 网络/服务器问题（可重试）
    A2LaunchErrorKindFileIntegrity,         ///< 文件损坏且无法修复（需重装/改版本）
    A2LaunchErrorKindNoJRE,                 ///< 没有可用的 Java 运行时
    A2LaunchErrorKindUnknown,               ///< 未知
    A2LaunchErrorKindRendererUnsupported,   ///< 渲染器不可用 / 不支持该 MC 版本
    A2LaunchErrorKindCancelled,             ///< 用户取消（不作为失败弹窗）
};

FOUNDATION_EXPORT NSString *const A2LaunchErrorKindKey;
FOUNDATION_EXPORT NSString *const A2LaunchErrorStepKey;
FOUNDATION_EXPORT NSString *const A2LaunchErrorReasonKey;
FOUNDATION_EXPORT NSString *const A2LaunchErrorFileKey;
FOUNDATION_EXPORT NSString *const A2LaunchErrorURLKey;
FOUNDATION_EXPORT NSString *const A2LaunchErrorRetryableKey;

/// 组装一条可诊断的错误。file/url 可为 nil；reason 不要传空串。
FOUNDATION_EXPORT NSError *A2LaunchDiagnose(A2LaunchErrorKind kind,
                                            NSString *step,
                                            NSString *reason,
                                            NSString *_Nullable file,
                                            NSString *_Nullable url,
                                            BOOL retryable);

/// 把错误格式化成多行中文，供弹窗/日志直接展示。
/// 不含 file/url 时会省略对应行，不会输出「(null)」。
FOUNDATION_EXPORT NSString *A2LaunchDiagnosisText(NSError *_Nullable error);

/// 从错误里取可重试标记；缺省视为 NO（宁可让用户看清楚再重试）。
FOUNDATION_EXPORT BOOL A2LaunchErrorIsRetryable(NSError *_Nullable error);

NS_ASSUME_NONNULL_END

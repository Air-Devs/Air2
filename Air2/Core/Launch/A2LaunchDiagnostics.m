//
//  A2LaunchDiagnostics.m
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

#import "A2LaunchDiagnostics.h"

NSString *const A2LaunchErrorKindKey      = @"kind";
NSString *const A2LaunchErrorStepKey      = @"step";
NSString *const A2LaunchErrorReasonKey    = @"reason";
NSString *const A2LaunchErrorFileKey      = @"file";
NSString *const A2LaunchErrorURLKey       = @"url";
NSString *const A2LaunchErrorRetryableKey = @"retryable";

/// 统一格式。localizedDescription 也用这份文本 —— 旧 UI 只拿
/// error.localizedDescription 弹窗，不带 file/url 就白存了。
static NSString *A2LaunchFormatDiagnosis(NSString *step,
                                         NSString *reason,
                                         NSString *file,
                                         NSString *url,
                                         BOOL retryable) {
    NSString *safeStep = step.length ? step : @"启动检查";
    NSString *safeReason = reason.length ? reason : @"未知原因";

    NSMutableString *text = [NSMutableString stringWithFormat:@"%@失败：%@", safeStep, safeReason];
    if (file.length) [text appendFormat:@"\n文件：%@", file];
    if (url.length) [text appendFormat:@"\n地址：%@", url];
    [text appendFormat:@"\n可重试：%@", retryable ? @"是" : @"否（需要先修复上述问题）"];
    return text;
}

NSError *A2LaunchDiagnose(A2LaunchErrorKind kind,
                          NSString *step,
                          NSString *reason,
                          NSString *_Nullable file,
                          NSString *_Nullable url,
                          BOOL retryable) {
    NSString *safeStep = step.length ? step : @"启动检查";
    NSString *safeReason = reason.length ? reason : @"未知原因";
    NSString *description = A2LaunchFormatDiagnosis(safeStep, safeReason, file, url, retryable);

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description;
    userInfo[NSLocalizedFailureReasonErrorKey] = safeReason;
    userInfo[A2LaunchErrorKindKey] = @(kind);
    userInfo[A2LaunchErrorStepKey] = safeStep;
    userInfo[A2LaunchErrorReasonKey] = safeReason;
    userInfo[A2LaunchErrorRetryableKey] = @(retryable);
    if (file.length) userInfo[A2LaunchErrorFileKey] = file;
    if (url.length) userInfo[A2LaunchErrorURLKey] = url;

    return [NSError errorWithDomain:@"A2LaunchCoordinator"
                               code:(NSInteger)kind
                           userInfo:userInfo];
}

NSString *A2LaunchDiagnosisText(NSError *_Nullable error) {
    if (!error) return @"启动失败：未知原因";

    NSDictionary *info = error.userInfo ?: @{};
    NSString *step = info[A2LaunchErrorStepKey];
    NSString *reason = info[A2LaunchErrorReasonKey];

    // 不是本模块构造的错误（例如 A2GameInstaller 透传的 NSError），
    // 没有 step/reason 字段，直接用它自己的描述。
    if (![step isKindOfClass:NSString.class] || ![reason isKindOfClass:NSString.class]) {
        return error.localizedDescription ?: @"启动失败";
    }

    NSString *file = info[A2LaunchErrorFileKey];
    NSString *url = info[A2LaunchErrorURLKey];
    BOOL retryable = A2LaunchErrorIsRetryable(error);

    return A2LaunchFormatDiagnosis(step, reason,
                                   [file isKindOfClass:NSString.class] ? file : nil,
                                   [url isKindOfClass:NSString.class] ? url : nil,
                                   retryable);
}

BOOL A2LaunchErrorIsRetryable(NSError *_Nullable error) {
    NSNumber *v = error.userInfo[A2LaunchErrorRetryableKey];
    return [v isKindOfClass:NSNumber.class] ? v.boolValue : NO;
}

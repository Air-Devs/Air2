//
//  A2DownloadEngine.h
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
//  统一下载客户端。
//
//  设计参考 Amethyst-iOS 的 PLDownloadClient（Air 1 的下载实现），
//  后者又参考了 ZL2 的 NetWorkUtils：
//    · 镜像列表顺序尝试，单候选指数退避重试（1s/2s/4s 共 3 次）
//    · SHA1 流式校验 + zip EOCD 兜底
//    · 下载前检查已存在文件，校验通过则直接成功（零网络流量）
//    · 进度支持负 delta 回退，调用方累加即可保持贴合真实进度
//    · 断点续传：半成品写 .part，恢复时带 Range 头从已有长度继续
//      （不用系统的 resumeData —— 那是 downloadTask 的机制，
//       我们用 dataTask 自己管区间，两套混用会出错）
//
//  线程模型：start/pause/resume/cancel 可从任意线程调用；
//  回调在内部串行队列执行，UI 操作由调用方自行切回主线程。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 状态与错误

typedef NS_ENUM(NSInteger, A2DownloadState) {
    A2DownloadStateRunning = 0,
    A2DownloadStatePaused,
    A2DownloadStateCompleted,
    A2DownloadStateFailed,
    A2DownloadStateCancelled,
};

typedef NS_ENUM(NSInteger, A2DownloadErrorCode) {
    A2DownloadErrorNetworkFailure = 1,      ///< 连接错误 / 超时 / HTTP 非 2xx
    A2DownloadErrorChecksumMismatch = 2,    ///< SHA1 不匹配 / zip 结构损坏
    A2DownloadErrorAllCandidatesExhausted = 3,
    A2DownloadErrorInvalidParameter = 4,
    A2DownloadErrorFileWriteFailure = 5,
};

FOUNDATION_EXPORT NSString *const A2DownloadErrorDomain;
/// 全部候选耗尽时，各候选的错误数组放在这个 key 下
FOUNDATION_EXPORT NSString *const A2DownloadUnderlyingErrorsKey;

/// 进度回调：deltaBytes 为本次增量，可为负。
/// 镜像切换 / 重试 / 断点失效时会回退上报负值，
/// 调用方直接累加即可保证累计值贴合真实进度。
/// totalExpectedBytes 为服务端声明的总大小，未知时为 -1。
typedef void (^A2DownloadProgressHandler)(int64_t deltaBytes, int64_t totalExpectedBytes);

/// 速率回调：每秒采样一次，单位 bytes/s；结束时额外回调一次 0
typedef void (^A2DownloadSpeedHandler)(int64_t bytesPerSecond);

/// 完成回调：success = NO 时 error 非空
typedef void (^A2DownloadCompletion)(BOOL success, NSError * _Nullable error);

#pragma mark - 请求描述

@interface A2DownloadRequest : NSObject

/// 候选 URL，按优先级排序。单候选失败后按 1s/2s/4s 退避重试 3 次，再切下一候选。
@property (nonatomic, copy) NSArray<NSURL *> *candidateURLs;
/// 期望的 SHA1（十六进制，比较忽略大小写）；nil 则跳过
@property (nonatomic, copy, nullable) NSString *expectedSHA1;
/// 目标文件绝对路径（校验通过后原子替换）
@property (nonatomic, copy) NSString *destinationPath;
/// 断点续传的存取键；nil 时按 destinationPath + 首个 URL 稳定派生
@property (nonatomic, copy, nullable) NSString *taskIdentifier;
/// 无 SHA1 且目标是 .zip/.jar 时，从文件尾扫 EOCD 签名做兜底校验
@property (nonatomic, assign) BOOL allowZipFallbackCheck;
/// 期望文件大小（0 表示未知）—— 用于总进度计算
@property (nonatomic, assign) int64_t expectedSize;

@end

#pragma mark - 操作句柄

@interface A2DownloadOperation : NSObject
@property (nonatomic, readonly, assign) A2DownloadState state;
@property (nonatomic, readonly, strong) A2DownloadRequest *request;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#pragma mark - 客户端

@interface A2DownloadEngine : NSObject

+ (instancetype)sharedClient;

- (instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;

/// 开始下载。会先检查目标文件（SHA1 或 zip 校验通过则直接成功）；
/// 若 .part 半成品存在，则从其长度继续（断点续传）。
/// @return 操作句柄；参数错误时返回 nil 并异步回调错误
- (nullable A2DownloadOperation *)startRequest:(A2DownloadRequest *)request
                                      progress:(nullable A2DownloadProgressHandler)progress
                                         speed:(nullable A2DownloadSpeedHandler)speed
                                    completion:(nullable A2DownloadCompletion)completion;

- (void)pauseOperation:(A2DownloadOperation *)operation;
- (void)resumeOperation:(A2DownloadOperation *)operation;
- (void)cancelOperation:(A2DownloadOperation *)operation;

/// 取消全部进行中的下载。
/// 用于「取消安装」这类场景 —— 装到一半时把所有相关下载都停掉。
- (void)cancelAll;

#pragma mark - 便捷方法（供高层调用）

/// 下载单个文件（单 URL，自动补断点与校验）
- (void)downloadURL:(NSString *)url
        toPath:(NSString *)path
    expectedSize:(int64_t)size
       progress:(void (^)(int64_t received, int64_t total))progress
     completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

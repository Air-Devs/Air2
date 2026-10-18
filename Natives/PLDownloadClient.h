//
//  PLDownloadClient.h
//  Amethyst
//
//  统一下载客户端（spec: optimize-download-system Task 1.2）
//  镜像列表顺序尝试 + 单候选指数退避重试 + SHA1/zip 完整性校验 +
//  速率统计 + 进度回退 + resumeData 断点续传。
//
//  设计参考 ZalithLauncher2 NetWorkUtils.downloadFromMirrorList /
//  withSpeedReport（顺序尝试、sizeCallback 负数回退、每秒速率采样），
//  在 NSURLSession 体系下以 delegate + 串行状态队列实现。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 下载操作状态（PLDownloadOperation.state）
typedef NS_ENUM(NSInteger, PLDownloadOperationState) {
    /// 下载进行中（含镜像切换与退避重试等待）
    PLDownloadOperationStateRunning = 0,
    /// 已暂停（resumeData 已落盘，可 resumeOperation: 续传）
    PLDownloadOperationStatePaused,
    /// 已成功完成
    PLDownloadOperationStateCompleted,
    /// 失败（全部候选 URL 耗尽）
    PLDownloadOperationStateFailed,
    /// 已取消（resumeData 与半成品文件已清理）
    PLDownloadOperationStateCancelled,
};

/// 错误码（PLDownloadClientErrorDomain）
typedef NS_ENUM(NSInteger, PLDownloadClientErrorCode) {
    /// 网络失败（连接错误 / 超时 / HTTP 非 2xx）
    PLDownloadClientErrorCodeNetworkFailure = 1,
    /// 完整性校验失败（SHA1 不匹配 / zip EOCD 缺失）
    PLDownloadClientErrorCodeChecksumMismatch = 2,
    /// 全部候选 URL 耗尽（userInfo[PLDownloadClientUnderlyingErrorsKey] 为各候选错误数组）
    PLDownloadClientErrorCodeAllCandidatesExhausted = 3,
    /// 参数错误（candidateURLs 为空 / destinationPath 为空）
    PLDownloadClientErrorCodeInvalidParameter = 4,
    /// 文件写入失败（移动 / 原子替换到目标路径失败）
    PLDownloadClientErrorCodeFileWriteFailure = 5,
};

/// 错误域
FOUNDATION_EXPORT NSString *const PLDownloadClientErrorDomain;

/// 全部候选耗尽时聚合错误的 userInfo 键：NSArray<NSError *>，每个候选 URL 一个错误
FOUNDATION_EXPORT NSString *const PLDownloadClientUnderlyingErrorsKey;

/// 进度回调：deltaBytes 为本次增量，可为负。
/// 镜像切换 / 重试 / 断点失效时会回退上报负值（参考 ZL2 downloadFromMirrorList
/// 的 mirrorAttemptReported 负数回退），调用方直接累加即可保证累计值贴合真实进度。
/// totalExpectedBytes 为服务端声明的文件总大小，未知时为 -1。
typedef void (^PLDownloadProgressHandler)(int64_t deltaBytes, int64_t totalExpectedBytes);

/// 速率回调：每秒采样一次，单位 bytes/s；操作结束 / 暂停时额外回调一次 0
typedef void (^PLDownloadSpeedHandler)(int64_t bytesPerSecond);

/// 完成回调：success = NO 时 error 非空；取消时 error 为 NSURLErrorCancelled
typedef void (^PLDownloadCompletion)(BOOL success, NSError * _Nullable error);

/// 下载请求描述（镜像候选列表 + 校验信息 + 目标路径）
@interface PLDownloadRequest : NSObject

/// 候选 URL 列表，按优先级排序（参考 ZL2 downloadFromMirrorList 的顺序尝试语义）。
/// 单候选失败后按 1s/2s/4s 指数退避重试 3 次，再切换下一候选。
@property (nonatomic, copy) NSArray<NSURL *> *candidateURLs;

/// 期望的 SHA1（十六进制字符串，比较时忽略大小写）；为 nil 时跳过 SHA1 校验
@property (nonatomic, copy, nullable) NSString *expectedSHA1;

/// 目标文件绝对路径（校验通过后原子替换到此路径）
@property (nonatomic, copy) NSString *destinationPath;

/// 任务标识，作为 resumeData 断点续传的存取键；
/// 为 nil 时内部按 destinationPath + 首个 URL 稳定派生（同一文件重复下载可复用断点）。
@property (nonatomic, copy, nullable) NSString *taskIdentifier;

/// 无 expectedSHA1 且目标为 .zip / .jar 时，从文件尾扫描 EOCD 签名（"PK\x05\x06"）做完整性兜底
@property (nonatomic, assign) BOOL allowZipFallbackCheck;

@end

/// 下载操作句柄（由 startRequest: 返回，用于 pause / resume / cancel 与状态查询）
@interface PLDownloadOperation : NSObject

/// 当前状态（atomic，可从任意线程轮询）
@property (nonatomic, readonly, assign) PLDownloadOperationState state;

/// 暂停后可用的 resumeData（未暂停过或服务器不支持续传时为 nil）
@property (nonatomic, readonly, copy, nullable) NSData *resumeData;

/// 创建操作时传入的原始请求
@property (nonatomic, readonly, strong) PLDownloadRequest *request;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// 统一下载客户端。
///
/// 特性：
///   - 镜像列表顺序尝试，单候选指数退避重试（1s / 2s / 4s 共 3 次）
///   - SHA1 流式校验（CommonCrypto）与 zip EOCD 兜底校验
///   - 下载前检查已存在文件，校验通过直接成功（增量下载，零网络流量）
///   - 进度负 delta 回退，保证调用方累计单调贴合真实进度
///   - NSLock 保护的字节计数 + GCD 每秒定时器采样速率
///   - pause 落盘 resumeData，resume 优先断点续传
///
/// 线程模型：start / pause / resume / cancel 可从任意线程调用，内部派发到串行队列；
/// progress / speed / completion 回调均在内部串行队列上执行（非主线程），UI 操作请调用方自行切换线程。
@interface PLDownloadClient : NSObject

/// 使用指定会话配置创建客户端。
/// configuration 为 nil 时使用默认前台配置（HTTPMaximumConnectionsPerHost = 8，
/// requestTimeout 60s / resourceTimeout 86400s）；非 nil 时按传入配置使用（可覆盖并发数等）。
- (instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;

/// 全局共享实例（推荐业务方使用）。
/// 注意：实例与内部 NSURLSession 互相持有，自建实例需保证长期存活，不再使用时释放引用即可
///（内部已通过独立 delegate 对象打破强引用循环，dealloc 时自动 invalidate 会话）。
+ (instancetype)sharedClient;

/// 开始下载。
/// 下载前会检查目标文件：SHA1 匹配或 zip 校验通过则直接回调成功（增量下载）；
/// 若磁盘上存在同 taskIdentifier 的 resumeData 则优先断点续传。
/// @param request 下载请求（candidateURLs / destinationPath 必填）
/// @param progress 可选的增量进度回调（delta 可为负）
/// @param speed 可选的速率回调（每秒采样）
/// @param completion 完成回调（必然恰好回调一次；参数错误时也会异步回调）
/// @return 操作句柄；request 为 nil 或必填字段缺失时返回 nil 并异步回调参数错误
- (nullable PLDownloadOperation *)startRequest:(PLDownloadRequest *)request
                                      progress:(nullable PLDownloadProgressHandler)progress
                                         speed:(nullable PLDownloadSpeedHandler)speed
                                    completion:(PLDownloadCompletion)completion;

/// 暂停操作：cancelByProducingResumeData: 并将 resumeData 原子写入
/// <NSTemporaryDirectory>/PLDownloadResume/<taskIdentifier>.data；
/// 退避等待期间暂停则直接标记，恢复时立即重试当前候选。
- (void)pauseOperation:(id)operation;

/// 恢复操作：优先使用内存 / 磁盘 resumeData 经 downloadTaskWithResumeData: 续传，
/// 无断点数据（或服务器不支持 Range）时自动回退进度并重新下载。
- (void)resumeOperation:(id)operation;

/// 取消操作：终止下载，删除 resumeData 文件与 .part 半成品文件，
/// completion 以 NSURLErrorCancelled 回调。
- (void)cancelOperation:(id)operation;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

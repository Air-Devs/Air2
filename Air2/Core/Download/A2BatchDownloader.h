//
//  A2BatchDownloader.h
//  Air2
//
//  批量下载编排器 —— 对照 ZL2 的 BatchDownloader.kt。
//
//  与单个文件下载（A2DownloadEngine）的区别：
//    引擎负责「一个文件怎么下得快、怎么续传」；
//    编排器负责「几百个文件怎么排队、怎么统计总进度、什么时候该放弃」。
//
//  核心机制（照搬 ZL2 的设计）：
//
//    **文件级并发**：信号量控制同时传输的文件数。
//      注意要先取得许可再打开临时文件 —— 否则全部作业同时持着打开的
//      句柄排队，几百个句柄会拖垮存储层。
//
//    **整批重试轮次**：一轮里全候选源都失败的文件，进入下一轮重试。
//
//    **系统性故障熔断**：整批零成功的情况下，连续 N 个文件永久失败
//      即中止剩余文件。避免在确定性故障（如全部源地址配错）上
//      空转几百次重试。
//
//    **进度节流**：按固定间隔回调进度快照，而不是每个字节都回调。
//

#import <Foundation/Foundation.h>
#import "A2DownloadEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// 一批下载的进度快照
@interface A2BatchProgress : NSObject
@property (nonatomic, assign) long long downloadedBytes;
@property (nonatomic, assign) long long totalBytes;
@property (nonatomic, assign) NSInteger downloadedFiles;
@property (nonatomic, assign) NSInteger totalFiles;
@property (nonatomic, assign) double speedBytesPerSec;
/// 0.0~1.0
@property (nonatomic, assign, readonly) double fraction;
@end

@interface A2BatchDownloader : NSObject

/// @param requests 待下载项（每个含候选 URL 与目标路径）
/// @param maxConnections 同时传输的文件数上限
/// @param retryRounds 整批重试轮次（默认 1，即失败文件再跑一遍）
- (instancetype)initWithRequests:(NSArray<A2DownloadRequest *> *)requests
                  maxConnections:(NSInteger)maxConnections
                     retryRounds:(NSInteger)retryRounds;

/// 进度快照回调（主线程，已节流）
@property (nonatomic, copy, nullable) void (^onProgress)(A2BatchProgress *progress);

/// 单个文件成功
@property (nonatomic, copy, nullable) void (^onFileSuccess)(A2DownloadRequest *request);

/// 全部完成。
/// @param success 是否整批成功
/// @param failures 失败文件（key = 目标路径）
/// @param abortError 熔断时给出的可读错误（整批零成功且连续失败超阈值）；
///                   没有熔断时为 nil
@property (nonatomic, copy, nullable) void (^onCompletion)(BOOL success,
                                                          NSDictionary<NSString *, NSError *> *failures,
                                                          NSError * _Nullable abortError);

/// 预先登记「已复用的本地文件」，让总进度一开始就反映真实情况。
/// 必须在 start 之前调用。
- (void)registerReusedFileWithPath:(NSString *)path size:(long long)size;

/// 开始。同一实例只应调用一次。
- (void)start;

/// 取消
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

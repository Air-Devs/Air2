//
//  A2DownloadEngine.h
//  Air2
//
//  下载引擎 —— 分片、并发、断点续传。
//
//  设计要点：
//    · 单个文件按 Range 分片并发下载，片大小自适应
//    · 每片记录已写入的区间，中断后可从缺口续传
//    · 保持连接数上限，避免被服务端限流
//    · 有看门狗：一段时间没有新字节落盘就判定卡住，重建连接
//

#import <Foundation/Foundation.h>
#import "A2DownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DownloadEngine : NSObject

+ (instancetype)shared;

/// 并发连接数上限，默认 8
@property (nonatomic, assign) NSInteger maxConcurrentConnections;

/// 是否允许分片（小文件分片反而更慢）
@property (nonatomic, assign) BOOL enableChunking;

/// 下载一个文件到指定路径。带断点续传。
- (void)downloadItem:(A2DownloadItem *)item
              task:(nullable A2DownloadTask *)task
          progress:(nullable void (^)(long long received, long long total))progress
          completion:(void (^)(NSError * _Nullable error))completion;

/// 取消某个路径的下载
- (void)cancelDownloadForPath:(NSString *)path;

/// 取消全部
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END

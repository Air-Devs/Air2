//
//  A2ModpackFileDownloader.h
//  Air2
//
//  整合包文件批量下载器。
//
//  一个整合包的 mods / resourcepacks / shaderpacks 条目动辄上百个，
//  逐个串行太慢、全部并发又容易被源站限流，这里做固定并发度的批量
//  下载：复用 A2DownloadEngine 的 SHA1 校验与断点续传，单个文件失败
//  只记录不中断，最后把失败清单交回调用方汇总，避免静默吞掉错误。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ModpackFile;

/// 进度：completed 为已完成文件数（含失败），total 为总数
typedef void (^A2ModpackDownloadProgress)(NSInteger completed, NSInteger total, NSString *message);
/// 完成：failures 为失败项描述，全部成功时为空数组
typedef void (^A2ModpackDownloadCompletion)(NSArray<NSString *> *failures);

@interface A2ModpackFileDownloader : NSObject

/// 并发度小于等于 0 时取默认值 4
- (instancetype)initWithConcurrency:(NSUInteger)concurrency;

/// 把 files 按各自 relativePath 下载到 root 目录下。
/// 缺少下载地址或路径的条目按失败记录，跳过不下载。
- (void)downloadFiles:(NSArray<A2ModpackFile *> *)files
                toRoot:(NSString *)root
              progress:(nullable A2ModpackDownloadProgress)progress
            completion:(A2ModpackDownloadCompletion)completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END

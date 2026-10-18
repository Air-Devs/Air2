#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 下载历史存储（单例）。
 * 记录已完成下载任务的历史条目（名称/类型/大小/时间/结果等），
 * JSON 文件持久化到 <Home>/Library/Application Support/Amethyst/download_history.json，
 * 上限 200 条 LRU：新条目插入头部，超出裁尾。
 *
 * 线程模型：所有磁盘 IO 在专用串行队列执行；内存数组由 NSLock 保护，可从任意线程调用。
 */
@interface DownloadHistoryStore : NSObject

+ (instancetype)sharedStore;

/// 记录一条历史（新条目插头部，超出 200 条自动裁尾）。entry 为空时忽略。
- (void)recordEntryWithDictionary:(NSDictionary *)entry;

/// 返回全部历史条目（新→旧顺序）。首次访问时懒加载磁盘文件。
- (NSArray<NSDictionary *> *)allEntries;

/// 清空全部历史（内存 + 磁盘文件删除）。
- (void)clearAll;

@end

NS_ASSUME_NONNULL_END

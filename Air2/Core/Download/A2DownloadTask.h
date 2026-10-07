//
//  A2DownloadTask.h
//  Air2
//
//  下载任务模型 —— 进度、速度、状态。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2DownloadState) {
    A2DownloadStatePending = 0,
    A2DownloadStateRunning,
    A2DownloadStatePaused,
    A2DownloadStateCompleted,
    A2DownloadStateFailed,
};

/// 一个可下载的文件项
@interface A2DownloadItem : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *destinationPath;
@property (nonatomic, assign) long long expectedSize;   ///< 0 表示未知
@property (nonatomic, copy, nullable) NSString *sha1;
+ (instancetype)url:(NSString *)url destination:(NSString *)dest size:(long long)size;
@end

/// 下载任务（可含多个文件，如「安装版本」是一个任务包含若干文件）
@interface A2DownloadTask : NSObject

@property (nonatomic, copy, readonly) NSString *taskID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, assign, readonly) A2DownloadState state;

/// 总字节数（所有子项之和）
@property (nonatomic, assign, readonly) long long totalBytes;
/// 已下载字节数
@property (nonatomic, assign, readonly) long long downloadedBytes;
/// 进度 0.0~1.0
@property (nonatomic, assign, readonly) double progress;
/// 实时速度（字节/秒）
@property (nonatomic, assign, readonly) double speed;

/// 状态变化回调（主线程）
@property (nonatomic, copy, nullable) void (^onStateChange)(A2DownloadState state);
/// 进度回调（主线程，节流后）
@property (nonatomic, copy, nullable) void (^onProgress)(double progress, double speed);

- (instancetype)initWithTitle:(NSString *)title;
- (void)addItem:(A2DownloadItem *)item;

@end

NS_ASSUME_NONNULL_END

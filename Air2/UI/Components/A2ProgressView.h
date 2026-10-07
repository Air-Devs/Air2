//
//  A2ProgressView.h
//  Air2
//
//  下载进度显示 —— 三件套：
//    · A2RingProgress    环形进度（单任务，如版本安装）
//    · A2ProgressBar     线性进度条 + 速度 + 剩余时间
//    · A2TaskProgressView 完整任务卡片（多任务列表用）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 环形进度

@interface A2RingProgress : UIView

/// 进度 0.0~1.0
@property (nonatomic, assign) CGFloat progress;
/// 环宽，默认 6
@property (nonatomic, assign) CGFloat lineWidth;
/// 中心显示的大字（如百分比）
@property (nonatomic, copy, nullable) NSString *centerText;
/// 中心下方的小字（如"下载中"）
@property (nonatomic, copy, nullable) NSString *captionText;

/// 平滑动画到目标进度
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

#pragma mark - 线性进度条

@interface A2ProgressBar : UIView

@property (nonatomic, assign) CGFloat progress;        ///< 0.0~1.0
@property (nonatomic, copy, nullable) NSString *speedText;  ///< 如 "2.4 MB/s"
@property (nonatomic, copy, nullable) NSString *detailText; ///< 如 "1.2 GB / 2.0 GB"

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

#pragma mark - 任务卡片

typedef NS_ENUM(NSInteger, A2TaskState) {
    A2TaskStatePending = 0,
    A2TaskStateRunning,
    A2TaskStatePaused,
    A2TaskStateCompleted,
    A2TaskStateFailed,
};

@interface A2TaskProgressView : UIView

- (instancetype)initWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, assign) A2TaskState state;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, copy, nullable) NSString *speedText;

/// 右侧操作按钮回调（运行中显示暂停，暂停/失败显示继续）
@property (nonatomic, copy, nullable) void (^onTogglePause)(void);
@property (nonatomic, copy, nullable) void (^onTap)(void);

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

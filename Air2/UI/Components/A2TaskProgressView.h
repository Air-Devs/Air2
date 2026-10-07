//
//  A2TaskProgressView.h
//  Air2
//
//  任务卡片 —— 下载任务列表的一项。
//  含状态点（运行中呼吸）、标题、副标题、进度条、暂停/继续按钮。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

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

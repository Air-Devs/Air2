//
//  A2RingProgress.h
//  Air2
//
//  环形进度 —— 单任务的总进度展示（如版本安装）。
//  环上带进度弧，中心显示百分比与说明文字。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END

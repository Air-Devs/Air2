//
//  A2ProgressBar.h
//  Air2
//
//  线性进度条 —— 进度 + 已下载/总量 + 实时速度。
//  进度条头部带光晕，让推进有个明显的"亮头"。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ProgressBar : UIView

@property (nonatomic, assign) CGFloat progress;             ///< 0.0~1.0
@property (nonatomic, copy, nullable) NSString *speedText;  ///< 如 "2.4 MB/s"
@property (nonatomic, copy, nullable) NSString *detailText; ///< 如 "1.2 GB / 2.0 GB"

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

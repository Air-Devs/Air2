//
//  A2IndeterminateBar.h
//  Air2
//
//  不确定进度条 —— 对应 Material 的 LinearProgressIndicator() 无参形式。
//
//  ZL2 的用法：taskProgress < 0 时表示"不知道还要多久"，
//  显示一条来回滑动的短条，而不是停在某个百分比。
//
//  为什么需要它：
//    「统计下载任务」「解析安装包」这类阶段耗时不确定，
//    给个假百分比（比如一直 0%）比不给更糟 —— 用户会以为卡住了。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2IndeterminateBar : UIView

@property (nonatomic, assign) CGFloat barWidthRatio;   ///< 滑动条占轨道宽度的比例，默认 0.3

- (void)startAnimating;
- (void)stopAnimating;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

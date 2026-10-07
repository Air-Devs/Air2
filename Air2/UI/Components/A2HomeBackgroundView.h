//
//  A2HomeBackgroundView.h
//  Air2
//
//  主页背景 —— 主题渐变 + 两个径向光斑。
//
//  为什么要光斑：纯线性渐变太平，玻璃卡片浮在上面会显得"糊"，缺少明暗层次。
//  光斑让背景在不同区域有明暗变化，卡片透过去才有玻璃的质感。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2HomeBackgroundView : UIView

/// 重新套用主题
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

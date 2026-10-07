//
//  A2CardTitleBar.h
//  Air2
//
//  卡片顶栏 —— 参考 ZL2 的 CardTitleLayout。
//  半透明表面 + 标题 + 右侧可选操作按钮。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2CardTitleBar : UIView

- (instancetype)initWithTitle:(NSString *)title;

@property (nonatomic, copy) NSString *title;

/// 右侧操作按钮。设置后显示在标题右侧。
@property (nonatomic, strong, nullable) UIButton *accessoryButton;

/// 副标题（可选），显示在标题下方
@property (nonatomic, copy, nullable) NSString *subtitle;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END

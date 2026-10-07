//
//  A2HomeViewController_Internal.h
//  Air2
//
//  主页私有接口 —— 供分类（Category）实现访问内部视图。
//  只在本模块内 import，不对外暴露。
//

#import "A2HomeViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2HomeViewController ()

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) A2GlassCard *recentCard;
@property (nonatomic, strong) A2PrimaryButton *launchButton;
@property (nonatomic, strong) UILabel *heroVersionLabel;
@property (nonatomic, strong) UILabel *heroMetaLabel;

/// 由 A2HomeViewController+Recent 实现
- (void)setupRecentCard;

@end

NS_ASSUME_NONNULL_END

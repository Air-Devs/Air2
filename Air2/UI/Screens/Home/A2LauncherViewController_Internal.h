//
//  A2LauncherViewController_Internal.h
//  Air2
//
//  主界面私有接口 —— 供分类实现访问内部视图。
//

#import "A2LauncherViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2LauncherViewController ()

// 布局
@property (nonatomic, strong) UIScrollView *panelScroll;
@property (nonatomic, strong) UIStackView *panelStack;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UILabel *appNameLabel;
@property (nonatomic, strong) UIStackView *topTrailingStack;

// 账户卡
@property (nonatomic, strong) A2GlassCard *accountCard;
@property (nonatomic, strong) UIView *avatarView;
@property (nonatomic, strong) UILabel *avatarInitial;
@property (nonatomic, strong) UILabel *accountNameLabel;
@property (nonatomic, strong) UILabel *accountTypeLabel;

// 版本卡
@property (nonatomic, strong) A2GlassCard *versionCard;
@property (nonatomic, strong) UIView *versionIconBox;
@property (nonatomic, strong) UILabel *versionInitial;
@property (nonatomic, strong) UILabel *versionNameLabel;
@property (nonatomic, strong) UILabel *versionMetaLabel;
@property (nonatomic, strong) A2PrimaryButton *launchButton;

// 快捷入口
@property (nonatomic, strong) UIStackView *quickRow1;
@property (nonatomic, strong) UIStackView *quickRow2;

/// 由 A2LauncherViewController+Cards 实现
- (void)buildAccountCard;
- (void)buildVersionCard;
- (void)buildQuickGrid;

/// 由 A2LauncherViewController+Actions 实现
- (void)launchGame;
- (void)pushScreen:(UIViewController *)vc style:(A2TransitionStyle)style;
- (void)openAccount;
- (void)openSettings;
- (void)openVersions;
- (void)openDownload;
- (void)openMultiplayer;
- (void)openFiles;
- (void)openVersionSettings;

@end

NS_ASSUME_NONNULL_END

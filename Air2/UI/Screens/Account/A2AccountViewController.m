//
//  A2AccountViewController.m
//  Air2
//

#import "A2AccountViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 账号类型
typedef NS_ENUM(NSInteger, A2AccountType) {
    A2AccountTypeMicrosoft = 0,
    A2AccountTypeOffline,
    A2AccountTypeThirdParty,
};

@interface A2AccountViewController ()
@property (nonatomic, strong) A2GlassCard *currentCard;
@property (nonatomic, strong) UIView *avatarView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@end

@implementation A2AccountViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"账号管理";

    [self setupCurrentAccountCard];
    [self setupAddAccountSection];
    [self setupManageSection];
}

#pragma mark - 当前账号

- (void)setupCurrentAccountCard {
    _currentCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _currentCard.cornerRadius = A2RadiusXL;

    // 头像占位：圆形 + 首字母
    _avatarView = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.layer.cornerRadius = 30;
    _avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarView.clipsToBounds = YES;

    UILabel *initial = [[UILabel alloc] initWithFrame:CGRectZero];
    initial.translatesAutoresizingMaskIntoConstraints = NO;
    initial.text = @"S";
    initial.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    initial.textColor = UIColor.whiteColor;
    initial.textAlignment = NSTextAlignmentCenter;
    [_avatarView addSubview:initial];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    _nameLabel.text = @"Steve";

    _typeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _typeLabel.font = [A2Typography subtitleCard];
    _typeLabel.text = @"Microsoft 正版账号";

    UIStackView *nameStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _typeLabel]];
    nameStack.axis = UILayoutConstraintAxisVertical;
    nameStack.spacing = 3;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_avatarView, nameStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceL;
    row.alignment = UIStackViewAlignmentCenter;

    A2PrimaryButton *switchBtn = [[A2PrimaryButton alloc] initWithTitle:@"切换账号" style:A2ButtonStyleSecondary];
    switchBtn.icon = [UIImage systemImageNamed:@"arrow.left.arrow.right"];
    [switchBtn addTarget:self action:@selector(switchAccount) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[row, switchBtn]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;

    [_currentCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.widthAnchor constraintEqualToConstant:60],
        [_avatarView.heightAnchor constraintEqualToConstant:60],
        [initial.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [initial.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],

        [stack.topAnchor constraintEqualToAnchor:_currentCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_currentCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_currentCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_currentCard.contentView.trailingAnchor],
    ]];

    [self addSection:_currentCard];

    // 主题色头像
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(refreshAvatarColor)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [self refreshAvatarColor];
}

- (void)refreshAvatarColor {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _avatarView.backgroundColor = t.primary;
    _nameLabel.textColor = UIColor.whiteColor;
    _typeLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
}

#pragma mark - 添加账号

- (void)setupAddAccountSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"添加账号"];
    section.footerText = @"Microsoft 正版账号可加入正版服务器；离线账号仅用于单机与离线服务器；第三方认证服务器需自行填写地址。";

    A2SettingsRow *msRow = [[A2SettingsRow alloc] init];
    msRow.symbolName = @"person.badge.key.fill";
    msRow.symbolColor = [UIColor colorWithRed:0.0 green:0.47 blue:0.75 alpha:1.0];
    msRow.title = @"Microsoft 登录";
    msRow.subtitle = @"使用正版账号，支持皮肤与正版服务器";
    msRow.accessory = A2SettingsRowAccessoryDisclosure;
    msRow.onTap = ^{
        [A2Toast show:@"Microsoft 登录流程" inView:self.view];
    };
    [section addRow:msRow];

    A2SettingsRow *offlineRow = [[A2SettingsRow alloc] init];
    offlineRow.symbolName = @"person.fill";
    offlineRow.symbolColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:1.0];
    offlineRow.title = @"离线登录";
    offlineRow.subtitle = @"仅输入用户名，无需密码";
    offlineRow.accessory = A2SettingsRowAccessoryDisclosure;
    offlineRow.onTap = ^{
        [A2Toast show:@"离线登录" inView:self.view];
    };
    [section addRow:offlineRow];

    A2SettingsRow *thirdRow = [[A2SettingsRow alloc] init];
    thirdRow.symbolName = @"server.rack";
    thirdRow.symbolColor = [UIColor colorWithRed:0.85 green:0.45 blue:0.13 alpha:1.0];
    thirdRow.title = @"第三方认证服务器";
    thirdRow.subtitle = @"Yggdrasil 协议，如 LittleSkin";
    thirdRow.accessory = A2SettingsRowAccessoryDisclosure;
    thirdRow.onTap = ^{
        [A2Toast show:@"第三方登录" inView:self.view];
    };
    [section addRow:thirdRow];

    [self addSection:section];
}

#pragma mark - 管理

- (void)setupManageSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"账号设置"];

    A2SettingsRow *skinRow = [[A2SettingsRow alloc] init];
    skinRow.symbolName = @"figure.stand";
    skinRow.title = @"皮肤与披风";
    skinRow.valueText = @"已设置";
    skinRow.accessory = A2SettingsRowAccessoryDisclosure;
    skinRow.onTap = ^{ [A2Toast show:@"皮肤管理" inView:self.view]; };
    [section addRow:skinRow];

    A2SettingsRow *autoRow = [[A2SettingsRow alloc] init];
    autoRow.symbolName = @"checkmark.seal";
    autoRow.title = @"启动时自动登录";
    autoRow.accessory = A2SettingsRowAccessorySwitch;
    autoRow.on = YES;
    autoRow.onToggle = ^(BOOL isOn) {};
    [section addRow:autoRow];

    A2SettingsRow *removeRow = [[A2SettingsRow alloc] init];
    removeRow.symbolName = @"trash";
    removeRow.title = @"移除当前账号";
    removeRow.destructive = YES;
    removeRow.accessory = A2SettingsRowAccessoryNone;
    removeRow.showsBottomSeparator = NO;
    removeRow.onTap = ^{ [A2Toast show:@"已移除" inView:self.view]; };
    [section addRow:removeRow];

    [self addSection:section];
}

#pragma mark - 动作

- (void)switchAccount {
    [A2Toast show:@"切换账号列表" inView:self.view];
}

@end
